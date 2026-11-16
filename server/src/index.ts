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
const CHUNK_ID = /^[0-9a-f]{64}$/;
const VAULT_CHUNK_PATH = /^\/v1\/vault\/chunks\/([^/]+)$/;
const MAX_CHUNK = 1_100_000;
const MAX_MANIFEST = 1_500_000;
const MAX_VAULT = 512 * 1024 * 1024;
const MAX_MANIFEST_CHUNKS = 20_000;
const MAX_HAVE = 5000;
const BINDS = 99; // D1 takes at most 100 bound values a statement; one goes to the account

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

  // Any session of the account reads the vault, a host's included; only a board's writes it.
  if (path === "/v1/vault" || path.startsWith("/v1/vault/")) {
    if (request.method === "PUT" && hostSession) return fail(403, "wrong_session");
    return vault(request, env, account.id, path);
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

async function vault(request: Request, env: Env, account: number, path: string): Promise<Response> {
  const call = `${request.method} ${path}`;
  if (call === "GET /v1/vault") {
    const row = await env.DB.prepare("SELECT version, manifest FROM vault WHERE account_id = ?").bind(account).first<{ version: number; manifest: ArrayBuffer | number[] }>();
    return row ? json({ version: row.version, manifest: base64(new Uint8Array(row.manifest)) }) : fail(404, "no_vault");
  }
  if (call === "PUT /v1/vault") {
    const body = await readJSON(request);
    const { version, manifest, chunks } = body ?? {};
    if (!Number.isSafeInteger(version) || (version as number) < 0) return fail(400, "invalid_version");
    if (!Array.isArray(chunks) || chunks.length > MAX_MANIFEST_CHUNKS || !chunks.every((id) => typeof id === "string" && CHUNK_ID.test(id))) {
      return fail(400, "invalid_chunks");
    }
    const sealed = typeof manifest === "string" ? unbase64(manifest) : null;
    if (!sealed || !sealed.length) return fail(400, "invalid_manifest");
    if (sealed.length > MAX_MANIFEST) return fail(413, "too_large");
    // One transaction: the compare and set, refused too when a named chunk isn't held, then the
    // deletion of what it no longer names, which runs only if this very manifest went in (its
    // sealed bytes carry a random nonce, so no other write leaves the same ones). The ids go
    // in as one JSON array: 20000 of them are far more than a statement can bind.
    const named = JSON.stringify(chunks);
    const held = "NOT EXISTS (SELECT 1 FROM json_each(?) AS n WHERE n.value NOT IN (SELECT id FROM vault_chunks WHERE account_id = ?))";
    const [written] = await env.DB.batch([
      version === 0
        ? env.DB.prepare(`INSERT INTO vault (account_id, version, manifest) SELECT ?, 1, ? WHERE ${held} ON CONFLICT(account_id) DO NOTHING`).bind(account, sealed, named, account)
        : env.DB.prepare(`UPDATE vault SET version = version + 1, manifest = ? WHERE account_id = ? AND version = ? AND ${held}`).bind(sealed, account, version, named, account),
      env.DB.prepare(
        "DELETE FROM vault_chunks WHERE account_id = ? AND id NOT IN (SELECT value FROM json_each(?)) AND EXISTS (SELECT 1 FROM vault WHERE account_id = ? AND version = ? AND manifest = ?)",
      ).bind(account, named, account, (version as number) + 1, sealed),
    ]);
    if (!written.meta.changes) {
      // Stale first: a writer behind has to read again before anything else it sends matters.
      const current = await env.DB.prepare("SELECT version FROM vault WHERE account_id = ?").bind(account).first<{ version: number }>();
      if ((current?.version ?? 0) !== version) return fail(409, "stale");
      const { results } = await env.DB.prepare("SELECT DISTINCT n.value AS id FROM json_each(?) AS n WHERE n.value NOT IN (SELECT id FROM vault_chunks WHERE account_id = ?)")
        .bind(named, account)
        .all<{ id: string }>();
      return json({ error: "missing_chunks", missing: results.map((row) => row.id) }, 409);
    }
    return json({ version: (version as number) + 1 });
  }
  if (call === "POST /v1/vault/have") {
    const ids = (await readJSON(request))?.ids;
    if (!Array.isArray(ids) || ids.length > MAX_HAVE || !ids.every((id) => typeof id === "string" && CHUNK_ID.test(id))) return fail(400, "invalid_ids");
    const unique = [...new Set(ids as string[])];
    const found = unique.length
      ? await env.DB.batch<{ id: string }>(inBatches(unique).map((batch) => env.DB.prepare(`SELECT id FROM vault_chunks WHERE account_id = ? AND id IN (${marks(batch)})`).bind(account, ...batch)))
      : [];
    const have = new Set(found.flatMap((result) => result.results.map((row) => row.id)));
    return json({ missing: unique.filter((id) => !have.has(id)) });
  }

  const id = VAULT_CHUNK_PATH.exec(path)?.[1];
  if (id === undefined) return fail(404, "not_found");
  if (!CHUNK_ID.test(id)) return fail(400, "invalid_id");
  if (request.method === "GET") {
    const row = await env.DB.prepare("SELECT data FROM vault_chunks WHERE account_id = ? AND id = ?").bind(account, id).first<{ data: ArrayBuffer | number[] }>();
    // D1 hands a BLOB back as an array of numbers.
    return row ? new Response(new Uint8Array(row.data), { headers: { "Content-Type": "application/octet-stream" } }) : fail(404, "not_found");
  }
  if (request.method !== "PUT") return fail(404, "not_found");
  const length = Number(request.headers.get("Content-Length") ?? 0);
  if (length > MAX_CHUNK) return fail(413, "too_large");
  const data = new Uint8Array(await request.arrayBuffer());
  if (data.length > MAX_CHUNK) return fail(413, "too_large");
  if (!data.length) return fail(400, "invalid_chunk");
  // The same id again replaces itself, so it doesn't count against the room it needs.
  const used = await env.DB.prepare("SELECT COALESCE(SUM(size), 0) AS n FROM vault_chunks WHERE account_id = ? AND id != ?").bind(account, id).first<{ n: number }>();
  if (used!.n + data.length > MAX_VAULT) return fail(413, "vault_full");
  await env.DB.prepare(
    "INSERT INTO vault_chunks (account_id, id, size, data) VALUES (?, ?, ?, ?) ON CONFLICT(account_id, id) DO UPDATE SET size = excluded.size, data = excluded.data",
  )
    .bind(account, id, data.length, data)
    .run();
  return json({});
}

const inBatches = (ids: string[]) => Array.from({ length: Math.ceil(ids.length / BINDS) }, (_, i) => ids.slice(i * BINDS, (i + 1) * BINDS));
const marks = (ids: string[]) => ids.map(() => "?").join(", ");

function base64(bytes: Uint8Array): string {
  let text = "";
  // In slices: spreading a whole manifest into one call overflows the stack.
  for (let i = 0; i < bytes.length; i += 0x8000) text += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(text);
}

function unbase64(text: string): Uint8Array | null {
  if (!/^[A-Za-z0-9+/]*={0,2}$/.test(text) || text.length % 4) return null;
  try {
    return Uint8Array.from(atob(text), (c) => c.charCodeAt(0));
  } catch {
    return null;
  }
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
