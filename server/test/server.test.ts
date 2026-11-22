import { env, exports } from "cloudflare:workers";
import { afterEach, beforeEach, expect, it, vi } from "vitest";

const ORIGIN = "https://account.test";
const PUBLIC_KEY = btoa(String.fromCharCode(...new Uint8Array(32).fill(7)));
const HOST = { name: "Build box", platform: "linux-x86_64", version: "0.1.0", public_key: PUBLIC_KEY };

// GitHub, as the Worker sees it. The Worker runs in this isolate, so the spy catches its calls.
let tokenReplies: unknown[] = [];
let githubUser: unknown = null;
let githubCalls: { url: string; body: string; authorization: string | null }[] = [];
let sockets: { ws: WebSocket; closed: Promise<number> }[] = [];
let nextIP = 0;

beforeEach(() => {
  tokenReplies = [];
  githubCalls = [];
  sockets = [];
  vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
    const request = new Request(input as RequestInfo, init);
    githubCalls.push({ url: request.url, body: new TextDecoder().decode(await request.arrayBuffer()), authorization: request.headers.get("Authorization") });
    switch (request.url) {
      case "https://github.com/login/device/code":
        return Response.json({
          device_code: "device-1",
          user_code: "ABCD-1234",
          verification_uri: "https://github.com/login/device",
          interval: 5,
          expires_in: 900,
        });
      case "https://github.com/login/oauth/access_token":
        return Response.json(tokenReplies.shift());
      case "https://api.github.com/user":
        return Response.json(githubUser);
    }
    throw new Error(`unexpected fetch: ${request.url}`);
  });
});

// Leaves nothing running in the relay when the test ends: no socket, and no presence write on its way.
afterEach(async () => {
  vi.restoreAllMocks();
  for (const { ws } of sockets) if (ws.readyState === 1) ws.close(1000);
  await Promise.all(sockets.map((socket) => socket.closed));
  const online = env.DB.prepare("SELECT COUNT(*) AS n FROM hosts WHERE online = 1");
  await vi.waitFor(async () => expect((await online.first<{ n: number }>())!.n).toBe(0));
});

function call(method: string, path: string, options: { token?: string; body?: unknown; ip?: string } = {}) {
  const headers: Record<string, string> = { "CF-Connecting-IP": options.ip ?? "192.0.2.1" };
  if (options.token) headers.Authorization = `Bearer ${options.token}`;
  const body = options.body === undefined ? undefined : JSON.stringify(options.body);
  return exports.default.fetch(new Request(ORIGIN + path, { method, headers, body }));
}

/** A session of the account: a board's, or with `host` that host's own. */
async function signIn(id: number, login: string, host?: string): Promise<string> {
  githubUser = { id, login, name: `${login} name`, avatar_url: `https://avatars.test/${id}` };
  tokenReplies = [{ access_token: "gho_secret", token_type: "bearer", scope: "read:user" }];
  const response = await call("POST", "/v1/login/poll", { body: { device_code: "device-1", host }, ip: `198.51.100.${nextIP++}` });
  return ((await response.json()) as { token: string }).token;
}

/** A registered host of the account, with the session it signed in with. */
async function register(account: number, login: string) {
  const id = crypto.randomUUID();
  const hostToken = await signIn(account, login, id);
  expect((await call("PUT", `/v1/hosts/${id}`, { token: hostToken, body: HOST })).status).toBe(200);
  return { id, hostToken };
}

function upgrade(path: string, token: string) {
  return exports.default.fetch(new Request(ORIGIN + path, { headers: { Upgrade: "websocket", Authorization: `Bearer ${token}` } }));
}

async function open(path: string, token: string) {
  const response = await upgrade(path, token);
  const ws = response.webSocket;
  if (!ws) throw new Error(`no WebSocket: ${response.status}`);
  const queue: (string | ArrayBuffer)[] = [];
  const waiting: ((data: string | ArrayBuffer) => void)[] = [];
  ws.addEventListener("message", (event) => {
    const waiter = waiting.shift();
    if (waiter) waiter(event.data);
    else queue.push(event.data);
  });
  const closed = new Promise<number>((resolve) => ws.addEventListener("close", (event) => resolve(event.code)));
  sockets.push({ ws, closed });
  ws.binaryType = "arraybuffer";
  ws.accept();
  const next = () => (queue.length ? Promise.resolve(queue.shift()!) : new Promise<string | ArrayBuffer>((resolve) => waiting.push(resolve)));
  return { ws, closed, next };
}

/** A host that listens and a board that connected to it, before the host accepted. */
async function pendingChannel() {
  const account = nextIP + 1000;
  const token = await signIn(account, "owner");
  const { id, hostToken } = await register(account, "owner");
  const listen = await open(`/v1/hosts/${id}/listen`, hostToken);
  const board = await open(`/v1/hosts/${id}/connect`, token);
  const { connect: channel } = JSON.parse((await listen.next()) as string) as { connect: string };
  return { token, hostToken, id, listen, board, channel };
}

const bytes = (data: string | ArrayBuffer) => [...new Uint8Array(data as ArrayBuffer)];
const frame = (...values: number[]) => new Uint8Array(values).buffer;
const refusal = async (response: Response) => [response.status, await response.json(), response.webSocket];
const WRONG_SESSION = [403, { error: "wrong_session" }, null];
const hosts = async (token: string) =>
  (await (await call("GET", "/v1/hosts", { token })).json()) as { id: string; name: string; online: boolean; last_seen: number | null; addresses: string[] }[];

it("answers the root with a plain ok and no CORS headers", async () => {
  const response = await call("GET", "/");
  expect(await response.text()).toBe("ok");
  expect(response.headers.get("Access-Control-Allow-Origin")).toBeNull();
});

it("signs in through the device flow: pending, slow_down, then a token", async () => {
  const device = await call("POST", "/v1/login/device");
  expect(await device.json()).toEqual({
    device_code: "device-1",
    user_code: "ABCD-1234",
    verification_uri: "https://github.com/login/device",
    interval: 5,
    expires_in: 900,
  });
  expect(githubCalls[0].body).toBe(`client_id=${env.GITHUB_CLIENT_ID}&scope=read%3Auser`);

  githubUser = { id: 4242, login: "octo", name: null, avatar_url: "https://avatars.test/4242" };
  tokenReplies = [{ error: "authorization_pending" }, { error: "slow_down", interval: 10 }, { access_token: "gho_secret" }];
  const poll = () => call("POST", "/v1/login/poll", { body: { device_code: "device-1" } });
  expect(await (await poll()).json()).toEqual({ status: "pending" });
  expect(await (await poll()).json()).toEqual({ status: "slow_down" });
  const { token, account } = (await (await poll()).json()) as { token: string; account: unknown };
  expect(account).toEqual({ id: 4242, login: "octo", name: null, avatar_url: "https://avatars.test/4242" });
  expect(token).toMatch(/^[A-Za-z0-9_-]{43}$/);

  const pollCall = githubCalls.find((c) => c.url.endsWith("/access_token"))!;
  expect(pollCall.body).toBe(
    `client_id=${env.GITHUB_CLIENT_ID}&device_code=device-1&grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code`,
  );
  expect(githubCalls.at(-1)).toMatchObject({ url: "https://api.github.com/user", authorization: "Bearer gho_secret" });

  expect(await (await call("GET", "/v1/account", { token })).json()).toEqual(account);

  // Only the token's hash is stored, and GitHub's token is stored nowhere.
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token));
  const hex = [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
  const sessions = await env.DB.prepare("SELECT * FROM sessions WHERE account_id = 4242").all();
  expect(sessions.results).toHaveLength(1);
  expect(sessions.results[0].token_hash).toBe(hex);
  expect(JSON.stringify(sessions.results)).not.toContain(token);
  expect(JSON.stringify(await env.DB.prepare("SELECT * FROM accounts").all())).not.toContain("gho_secret");
});

it("signing in again updates the account and keeps earlier tokens valid", async () => {
  const first = await signIn(77, "before");
  const second = await signIn(77, "after");
  expect(second).not.toBe(first);
  expect(await (await call("GET", "/v1/account", { token: first })).json()).toMatchObject({ id: 77, login: "after" });
});

it("reports a denied, an expired and a broken login", async () => {
  const poll = async (reply: unknown) => {
    tokenReplies = [reply];
    const response = await call("POST", "/v1/login/poll", { body: { device_code: "device-1" } });
    return [response.status, await response.json()];
  };
  expect(await poll({ error: "access_denied" })).toEqual([200, { status: "denied" }]);
  expect(await poll({ error: "expired_token" })).toEqual([200, { status: "expired" }]);
  expect(await poll({ error: "incorrect_device_code" })).toEqual([502, { error: "github" }]);
  expect((await call("POST", "/v1/login/poll", { body: {} })).status).toBe(400);
  expect((await call("POST", "/v1/login/poll")).status).toBe(400);
});

it("limits login calls per IP", async () => {
  for (let i = 0; i < 60; i++) expect((await call("POST", "/v1/login/device", { ip: "203.0.113.9" })).status).toBe(200);
  expect((await call("POST", "/v1/login/device", { ip: "203.0.113.9" })).status).toBe(429);
  expect((await call("POST", "/v1/login/poll", { ip: "203.0.113.9", body: { device_code: "device-1" } })).status).toBe(429);
  expect((await call("POST", "/v1/login/device", { ip: "203.0.113.10" })).status).toBe(200);
});

it("requires a valid bearer token and forgets it on logout", async () => {
  const token = await signIn(1, "one");
  expect((await call("GET", "/v1/account")).status).toBe(401);
  expect((await call("GET", "/v1/account", { token: "A".repeat(43) })).status).toBe(401);
  expect((await call("GET", `/v1/account?token=${token}`)).status).toBe(401);
  expect((await call("GET", "/v1/account", { token })).status).toBe(200);

  expect((await call("POST", "/v1/logout", { token })).status).toBe(200);
  expect((await call("GET", "/v1/account", { token })).status).toBe(401);
  expect((await call("GET", "/v1/hosts", { token })).status).toBe(401);
});

it("registers, lists, updates and forgets a host", async () => {
  const token = await signIn(2, "two");
  const id = crypto.randomUUID();
  const hostToken = await signIn(2, "two", id.toUpperCase());
  const created = await call("PUT", `/v1/hosts/${id.toUpperCase()}`, { token: hostToken, body: HOST });
  const host = { id, ...HOST, online: false, last_seen: null, addresses: [] };
  expect(await created.json()).toEqual(host);
  expect(await hosts(token)).toEqual([host]);

  await call("PUT", `/v1/hosts/${id}`, { token: hostToken, body: { ...HOST, name: "Renamed", version: "0.2.0" } });
  expect(await hosts(token)).toEqual([{ ...host, name: "Renamed", version: "0.2.0" }]);

  expect((await call("DELETE", `/v1/hosts/${id}`, { token })).status).toBe(200);
  expect(await hosts(token)).toEqual([]);
  expect((await call("DELETE", `/v1/hosts/${id}`, { token })).status).toBe(404);
});

it("rejects malformed hosts", async () => {
  const own = crypto.randomUUID();
  const token = await signIn(3, "three", own);
  const put = async (body: unknown, id: string = own) => (await call("PUT", `/v1/hosts/${id}`, { token, body })).status;
  expect(await put(HOST, "not-a-uuid")).toBe(404);
  expect(await put({ ...HOST, name: "" })).toBe(400);
  expect(await put({ ...HOST, name: " padded " })).toBe(400);
  expect(await put({ ...HOST, name: "line\nbreak" })).toBe(400);
  expect(await put({ ...HOST, name: "x".repeat(65) })).toBe(400);
  expect(await put({ ...HOST, name: "é".repeat(64) })).toBe(200);
  expect(await put({ ...HOST, platform: "p".repeat(65) })).toBe(400);
  expect(await put({ ...HOST, version: 1 })).toBe(400);
  expect(await put({ ...HOST, public_key: btoa("short") })).toBe(400);
  expect(await put({ ...HOST, public_key: btoa("x".repeat(33)) })).toBe(400);
  expect(await put("nonsense")).toBe(400);
  expect((await call("PUT", `/v1/hosts/${own}`, { token })).status).toBe(400);
});

it("caps the hosts of an account", async () => {
  const token = await signIn(4, "four");
  const insert = env.DB.prepare("INSERT INTO hosts (id, account_id, name, platform, version, public_key) VALUES (?, 4, 'h', 'p', 'v', ?)");
  await env.DB.batch(Array.from({ length: 50 }, () => insert.bind(crypto.randomUUID(), PUBLIC_KEY)));
  const existing = (await hosts(token))[0].id;
  const extra = crypto.randomUUID();
  const refused = await call("PUT", `/v1/hosts/${extra}`, { token: await signIn(4, "four", extra), body: HOST });
  expect([refused.status, await refused.json()]).toEqual([403, { error: "too_many_hosts" }]);
  expect((await call("PUT", `/v1/hosts/${existing}`, { token: await signIn(4, "four", existing), body: HOST })).status).toBe(200);
});

it("hides a host from every other account", async () => {
  const owner = await signIn(5, "owner");
  const other = await signIn(6, "other");
  const { id, hostToken } = await register(5, "owner");
  const listen = await open(`/v1/hosts/${id}/listen`, hostToken);
  // The other account, signed in as a board and as a host claiming this very id.
  const otherHost = await signIn(6, "other", id);

  expect(await hosts(other)).toEqual([]);
  expect((await call("PUT", `/v1/hosts/${id}`, { token: otherHost, body: { ...HOST, name: "Stolen" } })).status).toBe(404);
  expect((await call("DELETE", `/v1/hosts/${id}`, { token: otherHost })).status).toBe(404);
  expect((await call("DELETE", `/v1/hosts/${id}`, { token: other })).status).toBe(404);
  expect((await call("POST", `/v1/hosts/${id}/ticket`, { token: other })).status).toBe(404);
  for (const [path, token] of [["listen", otherHost], ["connect", other], [`accept/${crypto.randomUUID()}`, otherHost]]) {
    const response = await upgrade(`/v1/hosts/${id}/${path}`, token);
    expect(response.status).toBe(404);
    expect(response.webSocket).toBeNull();
  }
  // Each in the other's role is refused the same way for a host that does not exist.
  for (const at of [id, crypto.randomUUID()]) {
    expect(await refusal(await call("PUT", `/v1/hosts/${at}`, { token: other, body: HOST }))).toEqual(WRONG_SESSION);
    expect(await refusal(await upgrade(`/v1/hosts/${at}/listen`, other))).toEqual(WRONG_SESSION);
  }
  expect(await refusal(await upgrade(`/v1/hosts/${id}/connect`, otherHost))).toEqual(WRONG_SESSION);
  expect(await refusal(await call("POST", `/v1/hosts/${id}/ticket`, { token: otherHost }))).toEqual(WRONG_SESSION);

  // A stranger who learns a channel id still can't take the host's end of it.
  const board = await open(`/v1/hosts/${id}/connect`, owner);
  const { connect: channel } = JSON.parse((await listen.next()) as string);
  expect((await upgrade(`/v1/hosts/${id}/accept/${channel}`, otherHost)).status).toBe(404);

  expect(await hosts(owner)).toMatchObject([{ id, name: HOST.name, online: true }]);
  expect(listen.ws.readyState).toBe(1);
  expect(board.ws.readyState).toBe(1);
});

it("refuses the WebSocket calls without a token or without an upgrade", async () => {
  const { id, hostToken: token } = await register(7, "seven");
  const bare = await exports.default.fetch(new Request(`${ORIGIN}/v1/hosts/${id}/listen`, { headers: { Upgrade: "websocket" } }));
  expect(bare.status).toBe(401);
  expect((await call("GET", `/v1/hosts/${id}/listen`, { token })).status).toBe(426);
});

it("shows a host online while its listen socket is open", async () => {
  const token = await signIn(8, "eight");
  const { id, hostToken } = await register(8, "eight");
  const before = Math.floor(Date.now() / 1000);

  const listen = await open(`/v1/hosts/${id}/listen`, hostToken);
  const [online] = await hosts(token);
  expect(online.online).toBe(true);
  expect(online.last_seen).toBeGreaterThanOrEqual(before);

  listen.ws.send("ping");
  expect(await listen.next()).toBe("pong");

  listen.ws.close(1000);
  await listen.closed;
  await vi.waitFor(async () => expect((await hosts(token))[0].online).toBe(false));
});

it("relays a channel both ways, in order, with what the board sent before the accept", async () => {
  const { hostToken, id, listen, board, channel } = await pendingChannel();
  expect(channel).toMatch(/^[0-9a-f-]{36}$/);

  board.ws.send(frame(1, 2, 3));
  board.ws.send(frame(4));
  board.ws.send("early text");

  const host = await open(`/v1/hosts/${id}/accept/${channel}`, hostToken);
  board.ws.send(frame(5, 6));
  expect(bytes(await host.next())).toEqual([1, 2, 3]);
  expect(bytes(await host.next())).toEqual([4]);
  expect(await host.next()).toBe("early text");
  expect(bytes(await host.next())).toEqual([5, 6]);

  for (let i = 0; i < 50; i++) host.ws.send(frame(i, 255));
  for (let i = 0; i < 50; i++) expect(bytes(await board.next())).toEqual([i, 255]);
  host.ws.send("text back");
  expect(await board.next()).toBe("text back");

  const large = new Uint8Array(200_000).fill(9);
  board.ws.send(large.buffer);
  expect((await host.next() as ArrayBuffer).byteLength).toBe(200_000);

  // The channel can be accepted once.
  expect((await upgrade(`/v1/hosts/${id}/accept/${channel}`, hostToken)).status).toBe(404);
  expect(listen.ws.readyState).toBe(1);
});

it("closes the host's end when the board closes", async () => {
  const { hostToken, id, listen, board, channel } = await pendingChannel();
  const host = await open(`/v1/hosts/${id}/accept/${channel}`, hostToken);
  board.ws.close(1000);
  expect(await host.closed).toBe(1000);
  expect(await board.closed).toBe(1000);
  expect(listen.ws.readyState).toBe(1);
});

it("closes the board's end when the host closes", async () => {
  const { hostToken, id, listen, board, channel } = await pendingChannel();
  const host = await open(`/v1/hosts/${id}/accept/${channel}`, hostToken);
  host.ws.close(1000);
  expect(await board.closed).toBe(1000);
  expect(listen.ws.readyState).toBe(1);
});

it("closes a board with 4404 when the host is offline", async () => {
  const token = await signIn(9, "nine");
  const { id, hostToken } = await register(9, "nine");
  expect(await (await open(`/v1/hosts/${id}/connect`, token)).closed).toBe(4404);

  const listen = await open(`/v1/hosts/${id}/listen`, hostToken);
  listen.ws.close(1000);
  await listen.closed;
  expect(await (await open(`/v1/hosts/${id}/connect`, token)).closed).toBe(4404);
});

it("closes a board with 4408 when the host does not accept in 15 s", async () => {
  const { hostToken, id, board, channel } = await pendingChannel();
  board.ws.send(frame(1));
  const started = Date.now();
  expect(await board.closed).toBe(4408);
  expect(Date.now() - started).toBeGreaterThanOrEqual(14_000);
  expect((await upgrade(`/v1/hosts/${id}/accept/${channel}`, hostToken)).status).toBe(404);
});

it("lets a newer listen socket replace the older one", async () => {
  const token = await signIn(10, "ten");
  const { id, hostToken } = await register(10, "ten");
  const first = await open(`/v1/hosts/${id}/listen`, hostToken);
  const second = await open(`/v1/hosts/${id}/listen`, hostToken);
  expect(await first.closed).toBe(4409);
  // The old socket's close must not mark the host offline.
  await new Promise((resolve) => setTimeout(resolve, 200));
  expect((await hosts(token))[0].online).toBe(true);

  const board = await open(`/v1/hosts/${id}/connect`, token);
  const { connect: channel } = JSON.parse((await second.next()) as string);
  const host = await open(`/v1/hosts/${id}/accept/${channel}`, hostToken);
  board.ws.send(frame(1));
  expect(bytes(await host.next())).toEqual([1]);
});

it("closes a board with 1009 when it sends over 1 MiB before the accept", async () => {
  const { hostToken, id, board, channel } = await pendingChannel();
  const half = new Uint8Array(512 * 1024).buffer;
  board.ws.send(half);
  board.ws.send(half);
  board.ws.send(frame(1));
  expect(await board.closed).toBe(1009);
  expect((await upgrade(`/v1/hosts/${id}/accept/${channel}`, hostToken)).status).toBe(404);
});

it("caps the channels of a host at 64", async () => {
  const token = await signIn(11, "eleven");
  const { id, hostToken } = await register(11, "eleven");
  await open(`/v1/hosts/${id}/listen`, hostToken);
  const boards = [];
  for (let i = 0; i < 64; i++) boards.push(await open(`/v1/hosts/${id}/connect`, token));
  expect(await (await open(`/v1/hosts/${id}/connect`, token)).closed).toBe(4429);
  expect(boards.every((board) => board.ws.readyState === 1)).toBe(true);
});

it("drops a forgotten host's sockets", async () => {
  const { token, id, listen, board } = await pendingChannel();
  expect((await call("DELETE", `/v1/hosts/${id}`, { token })).status).toBe(200);
  expect(await listen.closed).toBe(4404);
  expect(await board.closed).toBe(4404);
});

it("hands a board a ticket the host hears on its line, and keeps the host's addresses", async () => {
  const token = await signIn(77, "ticket-owner");
  const id = crypto.randomUUID();
  const hostToken = await signIn(77, "ticket-owner", id);
  const addresses = ["192.168.1.8:47470", "[2804:d4b::1]:47470"];
  expect((await call("PUT", `/v1/hosts/${id}`, { token: hostToken, body: { ...HOST, addresses } })).status).toBe(200);
  // Its own, then the one the server saw it come from (the `call` default), at the same port.
  expect((await hosts(token))[0].addresses).toEqual([...addresses, "192.0.2.1:47470"]);
  expect((await call("PUT", `/v1/hosts/${id}`, { token: hostToken, body: { ...HOST, addresses: ["example.com:80"] } })).status).toBe(400);

  expect((await call("POST", `/v1/hosts/${id}/ticket`, { token })).status).toBe(404);
  const listen = await open(`/v1/hosts/${id}/listen`, hostToken);
  const reply = await call("POST", `/v1/hosts/${id}/ticket`, { token });
  const { ticket } = (await reply.json()) as { ticket: string };
  expect(atob(ticket).length).toBe(32);
  expect(JSON.parse((await listen.next()) as string)).toEqual({ ticket });
  expect((await call("POST", `/v1/hosts/${id}/ticket`, { token: await signIn(78, "stranger") })).status).toBe(404);
  listen.ws.close();
});

it("takes only a UUID as the host of a session", async () => {
  for (const host of ["build-box", 7, null, `${crypto.randomUUID()}0`]) {
    const response = await call("POST", "/v1/login/poll", { body: { device_code: "device-1", host } });
    expect([response.status, await response.json()]).toEqual([400, { error: "invalid_host" }]);
  }
  expect(githubCalls).toEqual([]);
});

it("keeps a host's session to its own host", async () => {
  const token = await signIn(20, "twenty");
  const mine = await register(20, "twenty");
  const sibling = await register(20, "twenty");
  await open(`/v1/hosts/${mine.id}/listen`, mine.hostToken);
  await open(`/v1/hosts/${sibling.id}/listen`, sibling.hostToken);
  const session = { token: mine.hostToken };

  // Nothing a board does, not even on its own host.
  expect(await refusal(await call("GET", "/v1/hosts", session))).toEqual(WRONG_SESSION);
  expect(await refusal(await upgrade(`/v1/hosts/${mine.id}/connect`, mine.hostToken))).toEqual(WRONG_SESSION);
  expect(await refusal(await call("POST", `/v1/hosts/${mine.id}/ticket`, session))).toEqual(WRONG_SESSION);

  // And nothing at all on another host of the same account, registered or not.
  for (const id of [sibling.id, crypto.randomUUID()]) {
    expect(await refusal(await call("PUT", `/v1/hosts/${id}`, { ...session, body: { ...HOST, name: "Taken" } }))).toEqual(WRONG_SESSION);
    expect(await refusal(await call("DELETE", `/v1/hosts/${id}`, session))).toEqual(WRONG_SESSION);
    expect(await refusal(await call("POST", `/v1/hosts/${id}/ticket`, session))).toEqual(WRONG_SESSION);
    for (const path of ["listen", "connect", `accept/${crypto.randomUUID()}`]) {
      expect(await refusal(await upgrade(`/v1/hosts/${id}/${path}`, mine.hostToken))).toEqual(WRONG_SESSION);
    }
  }
  expect((await hosts(token)).map(({ id, name, online }) => ({ id, name, online })).sort((a, b) => a.id.localeCompare(b.id))).toEqual(
    [mine.id, sibling.id].sort().map((id) => ({ id, name: HOST.name, online: true })),
  );

  // What is left to it: who it is, taking itself off the account, signing out.
  expect(await (await call("GET", "/v1/account", session)).json()).toMatchObject({ id: 20, login: "twenty" });
  expect((await call("DELETE", `/v1/hosts/${mine.id}`, session)).status).toBe(200);
  expect((await hosts(token)).map((host) => host.id)).toEqual([sibling.id]);
  expect((await call("POST", "/v1/logout", session)).status).toBe(200);
  expect((await call("GET", "/v1/account", session)).status).toBe(401);
});

it("keeps a board's session from speaking as a host", async () => {
  const { token, id, listen, board, channel } = await pendingChannel();
  for (const at of [id, crypto.randomUUID()]) {
    expect(await refusal(await call("PUT", `/v1/hosts/${at}`, { token, body: { ...HOST, name: "Taken" } }))).toEqual(WRONG_SESSION);
    expect(await refusal(await upgrade(`/v1/hosts/${at}/listen`, token))).toEqual(WRONG_SESSION);
    expect(await refusal(await upgrade(`/v1/hosts/${at}/accept/${channel}`, token))).toEqual(WRONG_SESSION);
  }
  // Nothing was registered, renamed, replaced or accepted.
  expect(await hosts(token)).toMatchObject([{ id, name: HOST.name, online: true }]);
  expect(await hosts(token)).toHaveLength(1);
  expect(listen.ws.readyState).toBe(1);
  expect(board.ws.readyState).toBe(1);
});

it("adds the address the host was seen at, once, at the port of its first address", async () => {
  const token = await signIn(21, "twenty-one");
  const id = crypto.randomUUID();
  const hostToken = await signIn(21, "twenty-one", id);
  const put = async (addresses: string[] | undefined, ip: string) => {
    const response = await call("PUT", `/v1/hosts/${id}`, { token: hostToken, body: { ...HOST, addresses }, ip });
    expect(response.status).toBe(200);
    const listed = (await hosts(token))[0].addresses;
    expect(((await response.json()) as { addresses: string[] }).addresses).toEqual(listed);
    return listed;
  };
  const local = ["192.168.1.8:47470", "10.0.0.2:5000"];
  expect(await put(local, "203.0.113.7")).toEqual([...local, "203.0.113.7:47470"]);
  expect(await put(local, "2001:db8::5")).toEqual([...local, "[2001:db8::5]:47470"]);
  // Already among its own: not repeated. Sent back as listed: still once.
  expect(await put(["203.0.113.7:47470", "10.0.0.2:5000"], "203.0.113.7")).toEqual(["203.0.113.7:47470", "10.0.0.2:5000"]);
  expect(await put([...local, "203.0.113.7:47470"], "203.0.113.7")).toEqual([...local, "203.0.113.7:47470"]);
  // No address of its own gives no port to reach it at, and a full list has no room.
  expect(await put([], "203.0.113.7")).toEqual([]);
  expect(await put(undefined, "203.0.113.7")).toEqual([]);
  const full = Array.from({ length: 8 }, (_, i) => `10.0.0.${i}:47470`);
  expect(await put(full, "203.0.113.7")).toEqual(full);
});

it("pairs a board with a spare the host opened ahead, once, without a notice", async () => {
  const account = nextIP + 1000;
  const token = await signIn(account, "owner");
  const { id, hostToken } = await register(account, "owner");
  const listen = await open(`/v1/hosts/${id}/listen`, hostToken);
  const spare = await open(`/v1/hosts/${id}/spare/${crypto.randomUUID()}`, hostToken);
  expect(await refusal(await upgrade(`/v1/hosts/${id}/spare/${crypto.randomUUID()}`, token))).toEqual(WRONG_SESSION);

  const board = await open(`/v1/hosts/${id}/connect`, token);
  board.ws.send(frame(1, 2, 3));
  expect(bytes(await spare.next())).toEqual([1, 2, 3]);
  spare.ws.send(frame(4));
  expect(bytes(await board.next())).toEqual([4]);

  // The spare is taken: the next board is announced on the line.
  await open(`/v1/hosts/${id}/connect`, token);
  expect(JSON.parse((await listen.next()) as string)).toHaveProperty("connect");
});

it("ends a board's session after 90 days, and never a host's", async () => {
  const account = nextIP + 1000;
  const token = await signIn(account, "owner");
  const { id, hostToken } = await register(account, "owner");
  await env.DB.prepare("UPDATE sessions SET created_at = created_at - 91 * 24 * 3600").run();
  expect((await call("GET", "/v1/account", { token })).status).toBe(401);
  expect((await call("PUT", `/v1/hosts/${id}`, { token: hostToken, body: HOST })).status).toBe(200);
});

it("signs every board of the account out at once, and leaves its hosts", async () => {
  const account = nextIP + 1000;
  const [one, two] = [await signIn(account, "owner"), await signIn(account, "owner")];
  const other = await signIn(account + 1, "other");
  const { id, hostToken } = await register(account, "owner");
  expect(await refusal(await call("POST", "/v1/logout/boards", { token: hostToken }))).toEqual(WRONG_SESSION);
  expect((await call("POST", "/v1/logout/boards", { token: one })).status).toBe(200);
  for (const token of [one, two]) expect((await call("GET", "/v1/account", { token })).status).toBe(401);
  expect((await call("GET", "/v1/account", { token: other })).status).toBe(200);
  expect((await call("PUT", `/v1/hosts/${id}`, { token: hostToken, body: HOST })).status).toBe(200);
});

const chunkId = (n: number) => n.toString(16).padStart(64, "0");
const putChunk = (token: string, id: string, data: Uint8Array) =>
  exports.default.fetch(new Request(`${ORIGIN}/v1/vault/chunks/${id}`, { method: "PUT", headers: { Authorization: `Bearer ${token}` }, body: data }));
const getVault = async (token: string) => {
  const response = await call("GET", "/v1/vault", { token });
  return [response.status, await response.json()];
};
const have = async (token: string, ids: string[]) => (await (await call("POST", "/v1/vault/have", { token, body: { ids } })).json()) as { missing: string[] };
const putVault = async (token: string, version: number, manifest: string, chunks: string[]) => {
  const response = await call("PUT", "/v1/vault", { token, body: { version, manifest, chunks } });
  return [response.status, await response.json()];
};

it("keeps a vault: chunks, which are missing, a manifest, and both read back", async () => {
  const account = nextIP + 1000;
  const token = await signIn(account, "owner");
  expect(await getVault(token)).toEqual([404, { error: "no_vault" }]);
  const [a, b] = [chunkId(1), chunkId(2)];
  expect(await have(token, [a, b, a])).toEqual({ missing: [a, b] });
  expect((await putChunk(token, a, new Uint8Array([1, 2, 3]))).status).toBe(200);
  expect(await have(token, [a, b])).toEqual({ missing: [b] });
  expect((await putChunk(token, b, new Uint8Array([4]))).status).toBe(200);
  expect(await putVault(token, 0, btoa("sealed one"), [a, b])).toEqual([200, { version: 1 }]);
  expect(await getVault(token)).toEqual([200, { version: 1, manifest: btoa("sealed one") }]);
  const chunk = await call("GET", `/v1/vault/chunks/${a}`, { token });
  expect([...new Uint8Array(await chunk.arrayBuffer())]).toEqual([1, 2, 3]);
  expect((await call("GET", `/v1/vault/chunks/${chunkId(3)}`, { token })).status).toBe(404);

  // Compare and set: a writer that didn't see version 1 changes nothing.
  expect(await putVault(token, 0, btoa("late"), [a, b])).toEqual([409, { error: "stale" }]);
  expect(await putVault(token, 2, btoa("late"), [a, b])).toEqual([409, { error: "stale" }]);
  expect(await getVault(token)).toEqual([200, { version: 1, manifest: btoa("sealed one") }]);

  // A new manifest drops the chunks it doesn't name.
  expect(await putVault(token, 1, btoa("sealed two"), [b])).toEqual([200, { version: 2 }]);
  expect(await have(token, [a, b])).toEqual({ missing: [a] });
  expect((await call("GET", `/v1/vault/chunks/${a}`, { token })).status).toBe(404);
});

it("deletes more unreferenced chunks than one statement can bind", async () => {
  const account = nextIP + 1000;
  const token = await signIn(account, "owner");
  const ids = Array.from({ length: 250 }, (_, i) => chunkId(i + 1));
  await env.DB.batch(ids.map((id) => env.DB.prepare("INSERT INTO vault_chunks (account_id, id, size, data) VALUES (?, ?, 1, ?)").bind(account, id, new Uint8Array([0]))));
  expect(await putVault(token, 0, btoa("m"), [ids[7], ids[7]])).toEqual([200, { version: 1 }]);
  expect((await have(token, ids)).missing).toHaveLength(249);
});

it("lets a host's session read the vault but not write it", async () => {
  const account = nextIP + 1000;
  const token = await signIn(account, "owner");
  const { hostToken } = await register(account, "owner");
  const id = chunkId(9);
  expect((await putChunk(token, id, new Uint8Array([9]))).status).toBe(200);
  expect(await putVault(token, 0, btoa("m"), [id])).toEqual([200, { version: 1 }]);

  expect(await getVault(hostToken)).toEqual([200, { version: 1, manifest: btoa("m") }]);
  expect(await have(hostToken, [id])).toEqual({ missing: [] });
  expect((await call("GET", `/v1/vault/chunks/${id}`, { token: hostToken })).status).toBe(200);
  expect(await refusal(await putChunk(hostToken, chunkId(10), new Uint8Array([1])))).toEqual(WRONG_SESSION);
  expect(await refusal(await call("PUT", "/v1/vault", { token: hostToken, body: { version: 1, manifest: btoa("x"), chunks: [] } }))).toEqual(WRONG_SESSION);
  expect(await getVault(token)).toEqual([200, { version: 1, manifest: btoa("m") }]);
});

it("shows one account's vault to no other", async () => {
  const account = nextIP + 1000;
  const token = await signIn(account, "owner");
  const other = await signIn(account + 1, "other");
  const id = chunkId(5);
  expect((await putChunk(token, id, new Uint8Array([5]))).status).toBe(200);
  expect(await putVault(token, 0, btoa("m"), [id])).toEqual([200, { version: 1 }]);
  expect(await getVault(other)).toEqual([404, { error: "no_vault" }]);
  expect(await have(other, [id])).toEqual({ missing: [id] });
  expect((await call("GET", `/v1/vault/chunks/${id}`, { token: other })).status).toBe(404);
  // Its own vault starts at 0 and leaves the first one's chunks alone.
  expect(await putVault(other, 0, btoa("n"), [])).toEqual([200, { version: 1 }]);
  expect(await have(token, [id])).toEqual({ missing: [] });
});

it("holds the vault to its limits", async () => {
  const account = nextIP + 1000;
  const token = await signIn(account, "owner");
  for (const bad of ["ab", chunkId(0xab).toUpperCase(), `${chunkId(1)}0`]) {
    expect((await putChunk(token, bad, new Uint8Array([1]))).status).toBe(400);
  }
  expect(await refusal(await putChunk(token, chunkId(1), new Uint8Array(1_100_001)))).toEqual([413, { error: "too_large" }, null]);
  expect((await putChunk(token, chunkId(1), new Uint8Array(1_100_000))).status).toBe(200);
  expect((await call("POST", "/v1/vault/have", { token, body: { ids: Array(5001).fill(chunkId(1)) } })).status).toBe(400);
  expect((await call("POST", "/v1/vault/have", { token, body: { ids: ["nope"] } })).status).toBe(400);
  expect((await call("PUT", "/v1/vault", { token, body: { version: 0, manifest: btoa("m"), chunks: Array(20_001).fill(chunkId(1)) } })).status).toBe(400);
  expect((await call("PUT", "/v1/vault", { token, body: { version: 0, manifest: "not base64!", chunks: [] } })).status).toBe(400);
  const big = "A".repeat(2_000_004); // 1,500,003 bytes decoded
  expect(await putVault(token, 0, big, [])).toEqual([413, { error: "too_large" }]);

  // 512 MiB in all, counted from what is stored; replacing a chunk needs no extra room.
  await env.DB.prepare("UPDATE vault_chunks SET size = ? WHERE account_id = ?").bind(512 * 1024 * 1024 - 10, account).run();
  expect((await putChunk(token, chunkId(1), new Uint8Array(100))).status).toBe(200);
  await env.DB.prepare("UPDATE vault_chunks SET size = ? WHERE account_id = ?").bind(512 * 1024 * 1024 - 10, account).run();
  expect(await refusal(await putChunk(token, chunkId(2), new Uint8Array(11)))).toEqual([413, { error: "vault_full" }, null]);
  expect((await putChunk(token, chunkId(2), new Uint8Array(10))).status).toBe(200);
});

it("refuses a manifest naming a chunk it doesn't hold, and keeps the old one", async () => {
  const token = await signIn(nextIP + 1000, "owner");
  const [a, b] = [chunkId(1), chunkId(2)];
  expect((await putChunk(token, a, new Uint8Array([1]))).status).toBe(200);
  expect(await putVault(token, 0, btoa("first"), [b])).toEqual([409, { error: "missing_chunks", missing: [b] }]);
  expect(await getVault(token)).toEqual([404, { error: "no_vault" }]);
  expect(await putVault(token, 0, btoa("first"), [a])).toEqual([200, { version: 1 }]);
  expect(await putVault(token, 1, btoa("second"), [a, b])).toEqual([409, { error: "missing_chunks", missing: [b] }]);
  expect(await getVault(token)).toEqual([200, { version: 1, manifest: btoa("first") }]);
  expect(await have(token, [a])).toEqual({ missing: [] });
});

it("lets no writer undo another's: the second from the same base is stale and deletes nothing", async () => {
  const account = nextIP + 1000;
  const [one, two] = [await signIn(account, "owner"), await signIn(account, "owner")];
  const [base, mine, theirs] = [chunkId(1), chunkId(2), chunkId(3)];
  for (const id of [base, mine, theirs]) expect((await putChunk(one, id, new Uint8Array([1]))).status).toBe(200);
  expect(await putVault(one, 0, btoa("base"), [base])).toEqual([200, { version: 1 }]);
  for (const id of [mine, theirs]) expect((await putChunk(one, id, new Uint8Array([1]))).status).toBe(200);

  // Both start from version 1; the first wins with its chunk, the second names only its own.
  expect(await putVault(one, 1, btoa("one"), [base, mine])).toEqual([200, { version: 2 }]);
  expect(await putVault(two, 1, btoa("two"), [base, theirs])).toEqual([409, { error: "stale" }]);
  expect(await getVault(two)).toEqual([200, { version: 2, manifest: btoa("one") }]);
  // Its loss deleted nothing: every chunk the winner names is there. (Its own one the winner
  // didn't name went with the winner's write: it uploads it again.)
  expect(await have(one, [base, mine])).toEqual({ missing: [] });
  // Reading again and repeating on version 2 works.
  expect((await putChunk(two, theirs, new Uint8Array([1]))).status).toBe(200);
  expect(await putVault(two, 2, btoa("two"), [base, mine, theirs])).toEqual([200, { version: 3 }]);
});

it("deletes nothing for a write that loses the race, even at the version the winner reached", async () => {
  const account = nextIP + 1000;
  const token = await signIn(account, "owner");
  const [kept, extra] = [chunkId(1), chunkId(2)];
  for (const id of [kept, extra]) expect((await putChunk(token, id, new Uint8Array([1]))).status).toBe(200);
  expect(await putVault(token, 0, btoa("v1"), [kept, extra])).toEqual([200, { version: 1 }]);
  // At version 1 already: a writer still on 0 would land at 1 too, and must not delete.
  expect(await putVault(token, 0, btoa("late"), [kept])).toEqual([409, { error: "stale" }]);
  expect(await have(token, [kept, extra])).toEqual({ missing: [] });
});

const framed = (chunks: [string, Uint8Array][]) => {
  const parts = chunks.flatMap(([id, data]) => {
    const length = new Uint8Array(4);
    new DataView(length.buffer).setUint32(0, data.length);
    return [new TextEncoder().encode(id), length, data];
  });
  const body = new Uint8Array(parts.reduce((sum, part) => sum + part.length, 0));
  parts.reduce((at, part) => (body.set(part, at), at + part.length), 0);
  return body;
};
const unframed = (body: Uint8Array) => {
  const chunks: [string, number[]][] = [];
  for (let at = 0; at < body.length; ) {
    const length = new DataView(body.buffer, body.byteOffset + at + 64, 4).getUint32(0);
    chunks.push([new TextDecoder().decode(body.subarray(at, at + 64)), [...body.subarray(at + 68, at + 68 + length)]]);
    at += 68 + length;
  }
  return chunks;
};
const putChunks = (token: string, body: Uint8Array) =>
  exports.default.fetch(new Request(`${ORIGIN}/v1/vault/chunks`, { method: "POST", headers: { Authorization: `Bearer ${token}` }, body }));
const getChunks = async (token: string, ids: string[]) => {
  const response = await call("POST", "/v1/vault/chunks/get", { token, body: { ids } });
  return unframed(new Uint8Array(await response.arrayBuffer()));
};

it("stores and hands out many chunks per request, in the order asked", async () => {
  const account = nextIP + 1000;
  const token = await signIn(account, "owner");
  const { hostToken } = await register(account, "owner");
  const [a, b, c] = [chunkId(1), chunkId(2), chunkId(3)];
  expect((await putChunks(token, framed([[a, new Uint8Array([1, 2])], [b, new Uint8Array([3])]]))).status).toBe(200);
  expect(await have(token, [a, b, c])).toEqual({ missing: [c] });
  // A host reads the batch, unknown ids left out, but can't write one.
  expect(await getChunks(hostToken, [b, c, a])).toEqual([[b, [3]], [a, [1, 2]]]);
  expect(await refusal(await putChunks(hostToken, framed([[c, new Uint8Array([4])]])))).toEqual(WRONG_SESSION);
  expect(await have(token, [c])).toEqual({ missing: [c] });
  // Another account gets none of them.
  expect(await getChunks(await signIn(account + 1, "other"), [a, b])).toEqual([]);
});

it("holds batches of chunks to their limits", async () => {
  const account = nextIP + 1000;
  const token = await signIn(account, "owner");
  expect(await refusal(await putChunks(token, new Uint8Array(8 * 1024 * 1024 + 1)))).toEqual([413, { error: "too_large" }, null]);
  expect(await refusal(await putChunks(token, framed([[chunkId(1), new Uint8Array(1_100_001)]])))).toEqual([413, { error: "too_large" }, null]);
  const cut = framed([[chunkId(1), new Uint8Array(10)]]).subarray(0, 70);
  expect((await putChunks(token, cut)).status).toBe(400);
  expect((await putChunks(token, framed([["x".repeat(64), new Uint8Array(1)]]))).status).toBe(400);
  expect((await call("POST", "/v1/vault/chunks/get", { token, body: { ids: Array(201).fill(chunkId(1)) } })).status).toBe(400);
  expect(await have(token, [chunkId(1)])).toEqual({ missing: [chunkId(1)] });

  // A reply stops before 8 MiB: eight chunks of 1,100,000 bytes come back seven, then the rest.
  const ids = Array.from({ length: 8 }, (_, i) => chunkId(i + 10));
  for (const id of ids) expect((await putChunk(token, id, new Uint8Array(1_100_000).fill(1))).status).toBe(200);
  const first = await getChunks(token, ids);
  expect(first.map(([id]) => id)).toEqual(ids.slice(0, 7));
  expect((await getChunks(token, ids.slice(7))).map(([id]) => id)).toEqual(ids.slice(7));

  // 512 MiB in all applies to a batch too.
  await env.DB.prepare("UPDATE vault_chunks SET size = ? WHERE account_id = ? AND id = ?").bind(512 * 1024 * 1024 - 7 * 1_100_000, account, ids[0]).run();
  expect(await refusal(await putChunks(token, framed([[chunkId(99), new Uint8Array(1)]])))).toEqual([413, { error: "vault_full" }, null]);
});

async function catalogCall(method: "GET" | "PUT", token: string, body?: unknown): Promise<[number, unknown]> {
  const response = await call(method, "/v1/catalog", { token, body });
  return [response.status, await response.json()];
}

it("keeps the catalog with a version, refusing a stale write", async () => {
  const account = nextIP + 1000;
  const token = await signIn(account, "owner");
  const other = await signIn(account, "owner");
  expect(await catalogCall("GET", token)).toEqual([404, { error: "no_catalog" }]);
  expect(await catalogCall("PUT", token, { version: 0, document: btoa("a") })).toEqual([200, { version: 1 }]);
  // A second board that read nothing, or read version 1 after it moved on, gets `stale`.
  expect(await catalogCall("PUT", other, { version: 0, document: btoa("b") })).toEqual([409, { error: "stale" }]);
  expect(await catalogCall("PUT", other, { version: 1, document: btoa("b") })).toEqual([200, { version: 2 }]);
  expect(await catalogCall("PUT", token, { version: 1, document: btoa("c") })).toEqual([409, { error: "stale" }]);
  expect(await catalogCall("GET", token)).toEqual([200, { version: 2, document: btoa("b") }]);
  expect((await catalogCall("PUT", token, { version: 2, document: "" }))[0]).toBe(400);
  expect((await catalogCall("PUT", token, { version: -1, document: btoa("x") }))[0]).toBe(400);
  expect((await catalogCall("PUT", token, { version: 2, document: btoa("x".repeat(1_000_001)) }))[0]).toBe(413);
  expect(await catalogCall("GET", await signIn(account + 1, "other"))).toEqual([404, { error: "no_catalog" }]);
});

it("lets a host's session read the catalog but not write it", async () => {
  const account = nextIP + 1000;
  const token = await signIn(account, "owner");
  const { hostToken } = await register(account, "owner");
  expect(await catalogCall("PUT", token, { version: 0, document: btoa("a") })).toEqual([200, { version: 1 }]);
  expect(await catalogCall("GET", hostToken)).toEqual([200, { version: 1, document: btoa("a") }]);
  expect(await catalogCall("PUT", hostToken, { version: 1, document: btoa("x") })).toEqual([403, { error: "wrong_session" }]);
  expect((await call("GET", "/v1/catalog")).status).toBe(401);
});

it("keeps an avatar per organization, versioned on its own", async () => {
  const account = nextIP + 1000;
  const token = await signIn(account, "owner");
  const { hostToken } = await register(account, "owner");
  const org = "6F9619FF-8B86-D011-B42D-00C04FC964FF";
  const path = `/v1/catalog/avatars/${org}`;
  const ask = async (method: string, who: string, body?: unknown): Promise<[number, unknown]> => {
    const response = await call(method, path, { token: who, body });
    return [response.status, await response.json()];
  };
  expect(await ask("GET", token)).toEqual([404, { error: "no_avatar" }]);
  expect(await ask("PUT", token, { version: 0, image: btoa("png") })).toEqual([200, { version: 1 }]);
  expect(await ask("PUT", token, { version: 0, image: btoa("other") })).toEqual([409, { error: "stale" }]);
  expect(await ask("GET", hostToken)).toEqual([200, { version: 1, image: btoa("png") }]);
  expect(await ask("PUT", hostToken, { version: 1, image: btoa("x") })).toEqual([403, { error: "wrong_session" }]);
  expect((await ask("PUT", token, { version: 1, image: btoa("x".repeat(64 * 1024 + 1)) }))[0]).toBe(413);
  expect((await ask("PUT", token, { version: 1, image: 5 }))[0]).toBe(400);
  // Removed: the version stays, so a writer behind can't bring the old image back.
  expect(await ask("PUT", token, { version: 1, image: null })).toEqual([200, { version: 2 }]);
  expect(await ask("GET", token)).toEqual([200, { version: 2, image: null }]);
  const listed = await call("GET", "/v1/catalog/avatars", { token });
  expect(await listed.json()).toEqual([{ organization: org.toLowerCase(), version: 2 }]);
  expect(await (await call("GET", "/v1/catalog/avatars", { token: await signIn(account + 1, "other") })).json()).toEqual([]);
});
