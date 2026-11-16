export { HostRelay } from "./relay";

const MAX_HOSTS = 50;
const BOARD_SESSION_SECONDS = 90 * 24 * 3600;
const LOGINS_PER_MINUTE = 60; // per IP, both login calls together
const UUID = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}";
const HOST_PATH = new RegExp(`^/v1/hosts/(${UUID})(?:/(listen|connect|ticket|accept/${UUID}|spare/${UUID}))?$`);
// "address:port", the address an IPv4 one or a bracketed IPv6 one.
const ADDRESS = /^(?:\d{1,3}(?:\.\d{1,3}){3}|\[[0-9a-fA-F:]{2,39}\]):\d{1,5}$/;
const SHORT = /^[\x20-\x7e]{1,64}$/;
const PUBLIC_KEY = /^[A-Za-z0-9+/]{43}=$/; // base64 of exactly 32 bytes
const HOST_COLUMNS = "id, name, platform, version, public_key, online, last_seen, addresses";

interface Account {
  id: number;
  login: string;
  name: string | null;
  avatar_url: string | null;
}

const json = (body: unknown, status = 200) => Response.json(body, { status });
const fail = (status: number, error: string) => json({ error }, status);

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    try {
      return await route(request, env);
    } catch (error) {
      // Only the message: it never carries a token or a device code.
      console.error(error instanceof Error ? error.message : "error");
      return fail(500, "internal");
    }
  },
} satisfies ExportedHandler<Env>;

async function route(request: Request, env: Env): Promise<Response> {
  const path = new URL(request.url).pathname;
  const call = `${request.method} ${path}`;

  if (call === "GET /") return new Response("ok");
  if (call === "POST /v1/login/device") return (await limited(request, env)) ?? loginDevice(env);
  if (call === "POST /v1/login/poll") return (await limited(request, env)) ?? loginPoll(request, env);

  const bearer = /^Bearer (.+)$/.exec(request.headers.get("Authorization") ?? "")?.[1];
  if (!bearer) return fail(401, "unauthorized");
  // Looked up by its hash, so the comparison never runs over the secret itself.
  const tokenHash = await sha256(bearer);
  const session = await env.DB.prepare(
    "SELECT a.id, a.login, a.name, a.avatar_url, s.host_id FROM sessions s JOIN accounts a ON a.id = s.account_id WHERE s.token_hash = ? AND (s.host_id IS NOT NULL OR s.created_at > ?)",
  )
    // A board signs in again after 90 days; a host's session lasts until the host is forgotten.
    .bind(tokenHash, Math.floor(Date.now() / 1000) - BOARD_SESSION_SECONDS)
    .first<Account & { host_id: string | null }>();
  if (!session) return fail(401, "unauthorized");
  const { host_id: hostSession, ...account } = session;

  if (call === "GET /v1/account") return json(account);
  if (call === "POST /v1/logout") {
    await env.DB.prepare("DELETE FROM sessions WHERE token_hash = ?").bind(tokenHash).run();
    return json({});
  }
  // Every board signed in to the account, this one included (a lost or sold computer). Hosts
  // stay: each is forgotten by name.
  if (call === "POST /v1/logout/boards") {
    if (hostSession) return fail(403, "wrong_session");
    await env.DB.prepare("DELETE FROM sessions WHERE account_id = ? AND host_id IS NULL").bind(account.id).run();
    return json({});
  }
  if (call === "GET /v1/hosts") {
    if (hostSession) return fail(403, "wrong_session");
    const { results } = await env.DB.prepare(`SELECT ${HOST_COLUMNS} FROM hosts WHERE account_id = ? ORDER BY name, id`)
      .bind(account.id)
      .all();
    return json(results.map(hostJSON));
  }

  const match = HOST_PATH.exec(path);
  if (!match) return fail(404, "not_found");
  const id = match[1].toLowerCase();
  const action = match[2]?.toLowerCase();

  // A host's session is that host and nothing else: read on one machine, it reaches no other.
  // And only a host's session speaks as the host: a board's can't take its line or its key.
  const asHost = (!action && request.method === "PUT") || action === "listen" || action?.startsWith("accept/") || action?.startsWith("spare/");
  if (hostSession ? hostSession !== id || !(asHost || (!action && request.method === "DELETE")) : asHost) {
    return fail(403, "wrong_session");
  }

  if (!action && request.method === "PUT") return putHost(request, env, account, id);
  if (action === "ticket") {
    if (request.method !== "POST") return fail(404, "not_found");
    const mine = await env.DB.prepare("SELECT 1 FROM hosts WHERE id = ? AND account_id = ?").bind(id, account.id).first();
    if (!mine) return fail(404, "not_found");
    const ticket = await relay(env, id, request).ticket();
    return ticket ? json({ ticket }) : fail(404, "offline");
  }
  if (request.method !== (action ? "GET" : "DELETE")) return fail(404, "not_found");

  if (!action) {
    const gone = await env.DB.prepare("DELETE FROM hosts WHERE id = ? AND account_id = ?").bind(id, account.id).run();
    if (!gone.meta.changes) return fail(404, "not_found");
    // Forgotten for good: the token it signed in with can't register it again. (A host
    // forgetting itself logs out next, with that token.)
    if (!hostSession) await env.DB.prepare("DELETE FROM sessions WHERE host_id = ? AND account_id = ?").bind(id, account.id).run();
    await relay(env, id, request).forget();
    return json({});
  }

  const owned = await env.DB.prepare("SELECT 1 FROM hosts WHERE id = ? AND account_id = ?").bind(id, account.id).first();
  if (!owned) return fail(404, "not_found");
  if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") return fail(426, "upgrade_required");
  return relay(env, id, request).fetch(`https://relay/${id}/${action}`, request);
}

const REGIONS: Record<string, DurableObjectLocationHint> = { SA: "sam", NA: "enam", EU: "weur", AS: "apac", OC: "oc", AF: "afr" };

/** A host's relay, made near whoever first asks for it (the host, listening). */
function relay(env: Env, id: string, request: Request) {
  const hint = REGIONS[String(request.cf?.continent)];
  return env.RELAY.get(env.RELAY.idFromName(`v2:${id}`), hint ? { locationHint: hint } : {});
}

async function loginDevice(env: Env): Promise<Response> {
  const reply = await github("https://github.com/login/device/code", {
    method: "POST",
    body: new URLSearchParams({ client_id: env.GITHUB_CLIENT_ID, scope: "read:user" }),
  });
  if (typeof reply?.device_code !== "string") return fail(502, "github");
  const { device_code, user_code, verification_uri, interval, expires_in } = reply;
  return json({ device_code, user_code, verification_uri, interval, expires_in });
}

const POLL_STATUS: Record<string, string> = {
  authorization_pending: "pending",
  slow_down: "slow_down",
  expired_token: "expired",
  access_denied: "denied",
};

async function loginPoll(request: Request, env: Env): Promise<Response> {
  const body = await readJSON(request);
  const deviceCode = body?.device_code;
  if (typeof deviceCode !== "string" || !deviceCode || deviceCode.length > 256) return fail(400, "invalid_device_code");
  // A host signing in says which: its session then serves that host only.
  const host = body?.host;
  if (host !== undefined && (typeof host !== "string" || !new RegExp(`^${UUID}$`).test(host))) return fail(400, "invalid_host");

  const reply = await github("https://github.com/login/oauth/access_token", {
    method: "POST",
    body: new URLSearchParams({
      client_id: env.GITHUB_CLIENT_ID,
      device_code: deviceCode,
      grant_type: "urn:ietf:params:oauth:grant-type:device_code",
    }),
  });
  const status = POLL_STATUS[String(reply?.error)];
  if (status) return json({ status });
  if (typeof reply?.access_token !== "string") return fail(502, "github");

  // Used once to learn who signed in, then dropped.
  const user = await github("https://api.github.com/user", { headers: { Authorization: `Bearer ${reply.access_token}` } });
  if (!Number.isSafeInteger(user?.id) || typeof user?.login !== "string") return fail(502, "github");
  const account: Account = {
    id: user.id as number,
    login: user.login,
    name: typeof user.name === "string" ? user.name : null,
    avatar_url: typeof user.avatar_url === "string" ? user.avatar_url : null,
  };

  const bytes = crypto.getRandomValues(new Uint8Array(32));
  const token = btoa(String.fromCharCode(...bytes)).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
  await env.DB.batch([
    env.DB.prepare(
      "INSERT INTO accounts (id, login, name, avatar_url) VALUES (?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET login = excluded.login, name = excluded.name, avatar_url = excluded.avatar_url",
    ).bind(account.id, account.login, account.name, account.avatar_url),
    env.DB.prepare("INSERT INTO sessions (token_hash, account_id, created_at, host_id) VALUES (?, ?, ?, ?)").bind(
      await sha256(token),
      account.id,
      Math.floor(Date.now() / 1000),
      host?.toLowerCase() ?? null,
    ),
  ]);
  return json({ token, account });
}

async function putHost(request: Request, env: Env, account: Account, id: string): Promise<Response> {
  const body = await readJSON(request);
  const { name, platform, version, public_key } = body ?? {};
  // Up to 64 characters, no control characters, not blank at either end.
  if (typeof name !== "string" || !/^\P{Cc}{1,64}$/u.test(name) || name !== name.trim()) return fail(400, "invalid_name");
  if (typeof platform !== "string" || !SHORT.test(platform)) return fail(400, "invalid_platform");
  if (typeof version !== "string" || !SHORT.test(version)) return fail(400, "invalid_version");
  if (typeof public_key !== "string" || !PUBLIC_KEY.test(public_key)) return fail(400, "invalid_public_key");
  const addresses = body?.addresses ?? [];
  if (!Array.isArray(addresses) || addresses.length > 8 || !addresses.every((a) => typeof a === "string" && ADDRESS.test(a))) {
    return fail(400, "invalid_addresses");
  }

  // Where the host's connection comes from, at its port: a host with a public address of its
  // own (or a forwarded port) is then reached directly from anywhere.
  const seen = request.headers.get("CF-Connecting-IP");
  const port = /:(\d{1,5})$/.exec(addresses[0] ?? "")?.[1];
  if (seen && port && addresses.length < 8) {
    const address = `${seen.includes(":") ? `[${seen}]` : seen}:${port}`;
    if (ADDRESS.test(address) && !addresses.includes(address)) addresses.push(address);
  }

  const existing = await env.DB.prepare("SELECT account_id FROM hosts WHERE id = ?").bind(id).first<{ account_id: number }>();
  if (existing && existing.account_id !== account.id) return fail(404, "not_found");
  if (!existing) {
    const count = await env.DB.prepare("SELECT COUNT(*) AS n FROM hosts WHERE account_id = ?").bind(account.id).first<{ n: number }>();
    if (count!.n >= MAX_HOSTS) return fail(403, "too_many_hosts");
  }
  // The WHERE keeps a host registered by someone else in between from being taken over.
  const host = await env.DB.prepare(
    `INSERT INTO hosts (id, account_id, name, platform, version, public_key, addresses) VALUES (?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT(id) DO UPDATE SET name = excluded.name, platform = excluded.platform, version = excluded.version, public_key = excluded.public_key, addresses = excluded.addresses
     WHERE hosts.account_id = excluded.account_id
     RETURNING ${HOST_COLUMNS}`,
  )
    .bind(id, account.id, name, platform, version, public_key, JSON.stringify(addresses))
    .first();
  return host ? json(hostJSON(host)) : fail(404, "not_found");
}

// A host says something on its `listen` socket every minute (see docs/hosts.md): one silent for
// longer went away without its socket's close ever arriving.
const STALE_SECONDS = 150;
const hostJSON = (row: Record<string, unknown>) => ({
  ...row,
  online: row.online === 1 && Date.now() / 1000 - (row.last_seen as number) < STALE_SECONDS,
  addresses: JSON.parse(row.addresses as string),
});

/** A 429 when this IP has made too many login calls this minute. */
async function limited(request: Request, env: Env): Promise<Response | null> {
  const ip = request.headers.get("CF-Connecting-IP") ?? "";
  const minute = Math.floor(Date.now() / 60_000);
  const [, counted] = await env.DB.batch<{ count: number }>([
    env.DB.prepare("DELETE FROM login_rate WHERE minute < ?").bind(minute),
    env.DB.prepare(
      "INSERT INTO login_rate (ip, minute, count) VALUES (?, ?, 1) ON CONFLICT(ip, minute) DO UPDATE SET count = count + 1 RETURNING count",
    ).bind(ip, minute),
  ]);
  return counted.results[0].count > LOGINS_PER_MINUTE ? fail(429, "rate_limited") : null;
}

/** GitHub's JSON reply, or null when it did not give one. */
async function github(url: string, init: RequestInit): Promise<Record<string, unknown> | null> {
  try {
    const response = await fetch(url, {
      ...init,
      headers: { Accept: "application/json", "User-Agent": "agentboard-account-server", ...init.headers },
    });
    return (await response.json()) as Record<string, unknown>;
  } catch {
    return null;
  }
}

async function readJSON(request: Request): Promise<Record<string, unknown> | null> {
  try {
    const body: unknown = await request.json();
    return body && typeof body === "object" ? (body as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}

async function sha256(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}
