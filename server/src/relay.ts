import { DurableObject } from "cloudflare:workers";

const ACCEPT_TIMEOUT_MS = 15_000;
const BUFFER_LIMIT = 1 << 20;
// A browser on the board opens several connections to a host at once (see "The channel").
const MAX_CHANNELS = 64;
const SEEN_INTERVAL_MS = 60_000;
// A host replaces a spare it opened two minutes ago: one older than this may be on its way out.
const SPARE_MS = 100_000;
const OPEN = 1;

type Attachment =
  | { role: "listen"; host: string }
  // `spare`: opened by the host ahead of any board, since then; a board takes it once.
  | { role: "host"; host: string; channel: string; spare?: number }
  // `deadline` is set until the host accepts; `buffered` counts the bytes held meanwhile.
  | { role: "board"; host: string; channel: string; deadline?: number; buffered: number };

/** The relay of one host: its `listen` socket and the channels boards open to it. */
export class HostRelay extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    // Messages a board sends before the host accepts live in storage, so hibernation can't lose them.
    ctx.storage.sql.exec(
      "CREATE TABLE IF NOT EXISTS buffer (seq INTEGER PRIMARY KEY AUTOINCREMENT, channel TEXT NOT NULL, data NOT NULL)",
    );
    // Answered by the runtime without waking the object. It applies to every socket here, channels included.
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  /** The Worker has already authenticated the caller and checked the host's owner. */
  async fetch(request: Request): Promise<Response> {
    const [, host, action, channel] = new URL(request.url).pathname.split("/");
    const { 0: client, 1: server } = new WebSocketPair();
    const refuse = (code: number, reason: string) => {
      // Accepted first so the client can read the close code.
      server.accept();
      server.close(code, reason);
    };

    if (action === "listen") {
      for (const old of this.ctx.getWebSockets("listen")) if (old.readyState === OPEN) old.close(4409, "replaced");
      this.ctx.acceptWebSocket(server, ["listen"]);
      server.serializeAttachment({ role: "listen", host } satisfies Attachment);
      await this.seen(host, true, true);
    } else if (action === "connect") {
      const listener = this.listener();
      if (!listener) refuse(4404, "host offline");
      else if (this.ctx.getWebSockets("board").length >= MAX_CHANNELS) refuse(4429, "too many channels");
      else if (this.spare()) {
        // Waiting already: the board is through without the host opening anything.
        const spare = this.spare()!;
        const taken = spare.deserializeAttachment() as { channel: string };
        spare.serializeAttachment({ role: "host", host, channel: taken.channel } satisfies Attachment);
        this.ctx.acceptWebSocket(server, ["board", taken.channel]);
        server.serializeAttachment({ role: "board", host, channel: taken.channel, buffered: 0 } satisfies Attachment);
      } else {
        const channel = crypto.randomUUID();
        const deadline = Date.now() + ACCEPT_TIMEOUT_MS;
        this.ctx.acceptWebSocket(server, ["board", channel]);
        server.serializeAttachment({ role: "board", host, channel, deadline, buffered: 0 } satisfies Attachment);
        listener.send(JSON.stringify({ connect: channel }));
        await this.arm();
      }
    } else if (action === "spare") {
      if (this.ctx.getWebSockets(channel).length) return new Response(null, { status: 409 });
      this.ctx.acceptWebSocket(server, ["spare", channel]);
      server.serializeAttachment({ role: "host", host, channel, spare: Date.now() } satisfies Attachment);
    } else {
      const board = this.pending().find(([ws]) => this.ctx.getTags(ws).includes(channel))?.[0];
      if (!board) return new Response(null, { status: 404 });
      board.serializeAttachment({ role: "board", host, channel, buffered: 0 } satisfies Attachment);
      this.ctx.acceptWebSocket(server, ["host", channel]);
      server.serializeAttachment({ role: "host", host, channel } satisfies Attachment);
      const held = this.ctx.storage.sql.exec("SELECT data FROM buffer WHERE channel = ? ORDER BY seq", channel).toArray();
      for (const row of held) server.send(row.data as string | ArrayBuffer);
      this.discard(channel);
      await this.arm();
    }
    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    const a = ws.deserializeAttachment() as Attachment;
    // Forward before any await: an await would let the next message overtake this one.
    if (a.role !== "listen") {
      const peer = this.ctx.getWebSockets(a.channel).find((other) => other !== ws && other.readyState === OPEN);
      if (peer) peer.send(message);
      else if (a.role === "board" && a.deadline !== undefined) {
        const size = typeof message === "string" ? new TextEncoder().encode(message).length : message.byteLength;
        const buffered = a.buffered + size;
        if (buffered > BUFFER_LIMIT) {
          this.discard(a.channel);
          ws.close(1009, "too much sent before the host accepted");
          return;
        }
        this.ctx.storage.sql.exec("INSERT INTO buffer (channel, data) VALUES (?, ?)", a.channel, message);
        ws.serializeAttachment({ ...a, buffered } satisfies Attachment);
      }
    }
    if (a.role !== "board") await this.seen(a.host, true, false);
  }

  async webSocketClose(ws: WebSocket): Promise<void> {
    const a = ws.deserializeAttachment() as Attachment;
    // Completes the closing handshake; throws when the runtime already did, or after an error.
    try {
      ws.close(1000);
    } catch {}
    if (a.role === "listen") {
      // A replaced socket closes after its successor opened: the host is still online.
      if (!this.listener()) await this.seen(a.host, false, true);
      return;
    }
    this.discard(a.channel);
    for (const peer of this.ctx.getWebSockets(a.channel)) {
      if (peer !== ws && peer.readyState === OPEN) peer.close(1000, "peer closed");
    }
    await this.arm();
  }

  webSocketError(ws: WebSocket): Promise<void> {
    return this.webSocketClose(ws);
  }

  /** Closes the boards whose host did not accept in time. */
  async alarm(): Promise<void> {
    const now = Date.now();
    for (const [ws, deadline] of this.pending()) {
      if (deadline > now) continue;
      this.discard((ws.deserializeAttachment() as { channel: string }).channel);
      ws.close(4408, "host did not accept");
    }
    await this.arm();
  }

  /**
   * A pass for one direct connection to the host, told to it on its `listen` socket; undefined
   * when the host is offline. The server keeps no copy: the host checks it.
   */
  async ticket(): Promise<string | undefined> {
    const listener = this.listener();
    if (!listener) return undefined;
    const bytes = crypto.getRandomValues(new Uint8Array(32));
    const ticket = btoa(String.fromCharCode(...bytes));
    listener.send(JSON.stringify({ ticket }));
    return ticket;
  }

  /** The host was deleted: drop every socket it has. */
  async forget(): Promise<void> {
    for (const ws of this.ctx.getWebSockets()) if (ws.readyState === OPEN) ws.close(4404, "host forgotten");
    this.ctx.storage.sql.exec("DELETE FROM buffer");
    await this.arm();
  }

  /** The open boards still waiting for the host, each with its deadline. */
  private pending(): [WebSocket, number][] {
    return this.ctx.getWebSockets("board").flatMap((ws): [WebSocket, number][] => {
      const a = ws.deserializeAttachment() as Attachment;
      return a.role === "board" && a.deadline !== undefined && ws.readyState === OPEN ? [[ws, a.deadline]] : [];
    });
  }

  /** Keeps the alarm on the earliest deadline, or off when no board waits. */
  private async arm(): Promise<void> {
    const deadlines = this.pending().map(([, deadline]) => deadline);
    if (deadlines.length) await this.ctx.storage.setAlarm(Math.min(...deadlines));
    else await this.ctx.storage.deleteAlarm();
  }

  /** A connection the host opened ahead, not taken yet and young enough to still be there. */
  private spare(): WebSocket | undefined {
    const now = Date.now();
    return this.ctx.getWebSockets("spare").find((ws) => {
      const a = ws.deserializeAttachment() as Attachment;
      return ws.readyState === OPEN && a.role === "host" && a.spare !== undefined && now - a.spare < SPARE_MS;
    });
  }

  private listener(): WebSocket | undefined {
    return this.ctx.getWebSockets("listen").find((ws) => ws.readyState === OPEN);
  }

  private discard(channel: string): void {
    this.ctx.storage.sql.exec("DELETE FROM buffer WHERE channel = ?", channel);
  }

  /** Writes the host's presence to D1: always when `force`, else at most once a minute. */
  private async seen(host: string, online: boolean, force: boolean): Promise<void> {
    const now = Date.now();
    if (!force && now - (this.ctx.storage.kv.get<number>("seen") ?? 0) < SEEN_INTERVAL_MS) return;
    this.ctx.storage.kv.put("seen", now);
    await this.env.DB.prepare("UPDATE hosts SET online = ?, last_seen = ? WHERE id = ?")
      .bind(online ? 1 : 0, Math.floor(now / 1000), host)
      .run();
  }
}
