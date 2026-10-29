import { DurableObject } from "cloudflare:workers";
import { handleCode, ShareCodes } from "./codes";
import {
  otherRole,
  parseRole,
  parseSessionId,
  readLimits,
  statusBusy,
  statusOk,
  type Limits,
  type Role,
} from "./limits";

export { ShareCodes };

export interface Env {
  SESSION: DurableObjectNamespace<ShareSession>;
  GATE: DurableObjectNamespace<RelayGate>;
  CODES: DurableObjectNamespace<ShareCodes>;
  ALLOW_TEST_HOOKS?: string;
  MAX_SESSIONS?: string;
  MAX_PER_IP?: string;
  NEW_PER_IP_PER_HOUR?: string;
  SESSION_TTL_MS?: string;
  IDLE_MS?: string;
  WAIT_MS?: string;
  MAX_FRAME?: string;
  MAX_BYTES?: string;
}

interface Admit {
  ok: boolean;
  reason: string;
}

interface Attachment {
  role: Role;
  gen: number;
  greeted: boolean;
}

interface Meta {
  host_gen: number;
  guest_gen: number;
  created: number;
  bytes: number;
  paired: number;
  last_byte: number;
  session_id: string;
}

function log(event: string, fields: Record<string, string | number | boolean>): void {
  console.log(JSON.stringify({ service: "share-relay", event, ...fields }));
}

function bytesOf(message: ArrayBuffer | string): Uint8Array | null {
  if (typeof message === "string") return null;
  return new Uint8Array(message);
}

/**
 * Counts live sessions so one client cannot open unbounded Durable Objects.
 * The session id is stored; the invite secret is not.
 */
export class RelayGate extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.blockConcurrencyWhile(async () => {
      this.ctx.storage.sql.exec(`
        CREATE TABLE IF NOT EXISTS sessions (
          id TEXT PRIMARY KEY,
          ip TEXT NOT NULL,
          created INTEGER NOT NULL,
          active INTEGER NOT NULL
        )
      `);
      this.ctx.storage.sql.exec(`
        CREATE TABLE IF NOT EXISTS hits (
          ip TEXT NOT NULL,
          at INTEGER NOT NULL
        )
      `);
    });
  }

  async admit(ip: string, sessionId: string): Promise<Admit> {
    const limits = readLimits(this.env);
    const now = Date.now();
    this.ctx.storage.sql.exec("DELETE FROM sessions WHERE created < ?", now - limits.sessionTtlMs);
    this.ctx.storage.sql.exec("DELETE FROM hits WHERE at < ?", now - 60 * 60 * 1000);

    const existing = this.ctx.storage.sql
      .exec<{ id: string }>("SELECT id FROM sessions WHERE id = ?", sessionId)
      .toArray();
    if (existing.length > 0) {
      this.ctx.storage.sql.exec("UPDATE sessions SET active = 1 WHERE id = ?", sessionId);
      return { ok: true, reason: "" };
    }

    const active = this.ctx.storage.sql
      .exec<{ n: number }>("SELECT COUNT(*) AS n FROM sessions WHERE active = 1")
      .one().n;
    if (active >= limits.maxSessions) return { ok: false, reason: "full" };

    const mine = this.ctx.storage.sql
      .exec<{ n: number }>("SELECT COUNT(*) AS n FROM sessions WHERE active = 1 AND ip = ?", ip)
      .one().n;
    if (mine >= limits.maxPerIp) return { ok: false, reason: "ip" };

    const recent = this.ctx.storage.sql
      .exec<{ n: number }>("SELECT COUNT(*) AS n FROM hits WHERE ip = ?", ip)
      .one().n;
    if (recent >= limits.newPerIpPerHour) return { ok: false, reason: "rate" };

    this.ctx.storage.sql.exec(
      "INSERT INTO sessions (id, ip, created, active) VALUES (?, ?, ?, 1)",
      sessionId,
      ip,
      now,
    );
    this.ctx.storage.sql.exec("INSERT INTO hits (ip, at) VALUES (?, ?)", ip, now);
    return { ok: true, reason: "" };
  }

  async release(sessionId: string): Promise<void> {
    this.ctx.storage.sql.exec("UPDATE sessions SET active = 0 WHERE id = ?", sessionId);
  }

  async forget(sessionId: string): Promise<void> {
    this.ctx.storage.sql.exec("DELETE FROM sessions WHERE id = ?", sessionId);
  }

  /** Test-only. Production vars do not set ALLOW_TEST_HOOKS. */
  async reset(): Promise<void> {
    if (this.env.ALLOW_TEST_HOOKS !== "1") throw new Error("disabled");
    this.ctx.storage.sql.exec("DELETE FROM sessions");
    this.ctx.storage.sql.exec("DELETE FROM hits");
  }
}

/**
 * One share. Forwards binary WebSocket frames between the host and the guest.
 * Payloads stay opaque: this object never inspects them.
 */
export class ShareSession extends DurableObject<Env> {
  private hostGen = 0;
  private guestGen = 0;
  private created = 0;
  private bytes = 0;
  private paired = false;
  private lastByte = 0;
  private sessionId = "";

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.blockConcurrencyWhile(async () => {
      this.ctx.storage.sql.exec(`
        CREATE TABLE IF NOT EXISTS meta (
          id INTEGER PRIMARY KEY CHECK (id = 1),
          host_gen INTEGER NOT NULL,
          guest_gen INTEGER NOT NULL,
          created INTEGER NOT NULL,
          bytes INTEGER NOT NULL,
          paired INTEGER NOT NULL,
          last_byte INTEGER NOT NULL,
          session_id TEXT NOT NULL
        )
      `);
      const rows = this.ctx.storage.sql
        .exec<Meta>("SELECT host_gen, guest_gen, created, bytes, paired, last_byte, session_id FROM meta WHERE id = 1")
        .toArray();
      const row = rows[0];
      if (row) {
        this.hostGen = row.host_gen;
        this.guestGen = row.guest_gen;
        this.created = row.created;
        this.bytes = row.bytes;
        this.paired = row.paired !== 0;
        this.lastByte = row.last_byte;
        this.sessionId = row.session_id;
      }
    });
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const role = parseRole(url.searchParams.get("role"));
    if (!role) return new Response("role", { status: 400 });
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      return new Response("websocket required", { status: 426 });
    }
    const sessionId = parseSessionId(url.pathname) ?? "";
    if (!sessionId) return new Response("session", { status: 400 });

    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];

    if (role === "guest" && this.current("guest")) {
      this.ctx.acceptWebSocket(server);
      server.send(new Uint8Array([statusBusy]));
      server.close(1008, "busy");
      return new Response(null, { status: 101, webSocket: client });
    }

    this.ensureMeta(sessionId);
    const gen = this.bump(role);
    for (const old of this.ctx.getWebSockets(role)) old.close(4000, "replaced");
    const attachment: Attachment = { role, gen, greeted: false };
    this.ctx.acceptWebSocket(server, [role]);
    server.serializeAttachment(attachment);
    this.maybePair();
    await this.schedule();
    log("join", { session: sessionId.slice(0, 8), role, gen });
    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(ws: WebSocket, message: ArrayBuffer | string): Promise<void> {
    const payload = bytesOf(message);
    if (!payload) {
      ws.close(1003, "binary");
      return;
    }
    const limits = readLimits(this.env);
    if (payload.byteLength > limits.maxFrame) {
      ws.close(1009, "frame");
      return;
    }
    const att = this.attachment(ws);
    if (!att || att.gen !== this.genOf(att.role) || !att.greeted) return;
    const peer = this.current(otherRole(att.role));
    const peerAtt = peer ? this.attachment(peer) : null;
    if (!peer || !peerAtt?.greeted) return;
    this.bytes += payload.byteLength;
    this.lastByte = Date.now();
    if (this.bytes > limits.maxBytes) {
      log("cap", { session: this.sessionId.slice(0, 8), bytes: this.bytes });
      await this.shutdown("bytes");
      return;
    }
    this.persist();
    peer.send(message);
    await this.schedule();
  }

  async webSocketClose(ws: WebSocket, code: number, reason: string, wasClean: boolean): Promise<void> {
    void ws;
    void wasClean;
    log("close", { session: this.sessionId.slice(0, 8), code, reason });
    if (!this.current("host") && !this.current("guest") && this.sessionId) {
      this.paired = false;
      this.persist();
      await this.env.GATE.getByName("global").release(this.sessionId);
      await this.schedule();
    }
  }

  async webSocketError(ws: WebSocket, error: unknown): Promise<void> {
    log("ws-error", { session: this.sessionId.slice(0, 8), message: error instanceof Error ? error.message : "error" });
    try {
      ws.close(1011, "error");
    } catch {
      // Already closed.
    }
  }

  /** Test hook. Moves this session's clock so the next alarm shuts it down. */
  async forceDeadline(createdAt: number): Promise<void> {
    if (this.env.ALLOW_TEST_HOOKS !== "1") throw new Error("disabled");
    this.created = createdAt;
    this.lastByte = createdAt;
    this.paired = false;
    this.persist();
    await this.schedule();
  }

  async alarm(): Promise<void> {
    const limits = readLimits(this.env);
    const now = Date.now();
    if (this.created !== 0 && now >= this.created + limits.sessionTtlMs) {
      await this.shutdown("expired");
      return;
    }
    if (this.paired && this.lastByte !== 0 && now >= this.lastByte + limits.idleMs) {
      await this.shutdown("idle");
      return;
    }
    if (!this.paired && this.created !== 0 && now >= this.created + limits.waitMs) {
      await this.shutdown("wait");
      return;
    }
    await this.schedule();
  }

  private ensureMeta(sessionId: string): void {
    if (this.created !== 0) {
      if (!this.sessionId) this.sessionId = sessionId;
      return;
    }
    const now = Date.now();
    this.created = now;
    this.lastByte = now;
    this.sessionId = sessionId;
    this.persist();
  }

  private bump(role: Role): number {
    if (role === "host") this.hostGen += 1;
    else this.guestGen += 1;
    this.persist();
    return this.genOf(role);
  }

  private genOf(role: Role): number {
    switch (role) {
      case "host":
        return this.hostGen;
      case "guest":
        return this.guestGen;
      default: {
        const neverRole: never = role;
        return neverRole;
      }
    }
  }

  private attachment(ws: WebSocket): Attachment | null {
    const value = ws.deserializeAttachment() as Attachment | null;
    if (!value || (value.role !== "host" && value.role !== "guest")) return null;
    return value;
  }

  private current(role: Role): WebSocket | null {
    const gen = this.genOf(role);
    for (const ws of this.ctx.getWebSockets(role)) {
      const att = this.attachment(ws);
      if (att && att.gen === gen && ws.readyState === WebSocket.OPEN) return ws;
    }
    return null;
  }

  /** Status byte is the first frame on each socket, and only once both roles are here. */
  private maybePair(): void {
    const host = this.current("host");
    const guest = this.current("guest");
    if (!host || !guest) return;
    this.greet(host);
    this.greet(guest);
    if (!this.paired) {
      this.paired = true;
      this.lastByte = Date.now();
      this.persist();
      log("pair", { session: this.sessionId.slice(0, 8) });
    }
  }

  private greet(ws: WebSocket): void {
    const att = this.attachment(ws);
    if (!att || att.greeted) return;
    ws.send(new Uint8Array([statusOk]));
    att.greeted = true;
    ws.serializeAttachment(att);
  }

  private persist(): void {
    this.ctx.storage.sql.exec("DELETE FROM meta WHERE id = 1");
    this.ctx.storage.sql.exec(
      `INSERT INTO meta (id, host_gen, guest_gen, created, bytes, paired, last_byte, session_id)
       VALUES (1, ?, ?, ?, ?, ?, ?, ?)`,
      this.hostGen,
      this.guestGen,
      this.created,
      this.bytes,
      this.paired ? 1 : 0,
      this.lastByte,
      this.sessionId,
    );
  }

  private async schedule(): Promise<void> {
    if (this.created === 0) return;
    const limits = readLimits(this.env);
    const hard = this.created + limits.sessionTtlMs;
    const soft = this.paired ? this.lastByte + limits.idleMs : this.created + limits.waitMs;
    await this.ctx.storage.setAlarm(Math.min(hard, soft));
  }

  private async shutdown(reason: string): Promise<void> {
    log("shutdown", { session: this.sessionId.slice(0, 8), reason, bytes: this.bytes });
    for (const ws of this.ctx.getWebSockets()) {
      try {
        ws.close(4001, reason);
      } catch {
        // Already closed.
      }
    }
    const id = this.sessionId;
    this.created = 0;
    this.paired = false;
    this.bytes = 0;
    this.ctx.storage.sql.exec("DELETE FROM meta");
    if (id) await this.env.GATE.getByName("global").forget(id);
  }
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (request.method === "GET" && (url.pathname === "/" || url.pathname === "/health")) {
      return Response.json({ ok: true, service: "youneek-share-relay" });
    }
    const codePath = /^\/v1\/code\/([A-Za-z0-9-]{6,8})$/.exec(url.pathname);
    if (codePath) {
      const ip = request.headers.get("CF-Connecting-IP") ?? "local";
      try {
        return await handleCode(request, env, codePath[1], ip);
      } catch (err) {
        log("error", { message: err instanceof Error ? err.message : "unknown" });
        return new Response("relay error", { status: 500 });
      }
    }
    const sessionId = parseSessionId(url.pathname);
    if (!sessionId) return new Response("not found", { status: 404 });
    if (request.method !== "GET") return new Response("method", { status: 405 });
    const role = parseRole(url.searchParams.get("role"));
    if (!role) return new Response("role", { status: 400 });
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      return new Response("websocket required", { status: 426 });
    }

    const ip = request.headers.get("CF-Connecting-IP") ?? "local";
    try {
      const admitted = await env.GATE.getByName("global").admit(ip, sessionId);
      if (!admitted.ok) {
        log("reject", { session: sessionId.slice(0, 8), reason: admitted.reason });
        return new Response(admitted.reason, { status: 429 });
      }
      // The original request keeps the WebSocket upgrade. The session id is the path.
      return await env.SESSION.getByName(sessionId).fetch(request);
    } catch (err) {
      log("error", { message: err instanceof Error ? err.message : "unknown" });
      return new Response("relay error", { status: 500 });
    }
  },
} satisfies ExportedHandler<Env>;
