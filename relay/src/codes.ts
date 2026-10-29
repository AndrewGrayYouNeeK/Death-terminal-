/** Short join codes. One Durable Object holds every live code. */

import { DurableObject } from "cloudflare:workers";

export interface CodeEnv {
  CODES: DurableObjectNamespace<ShareCodes>;
  ALLOW_TEST_HOOKS?: string;
}

export const codeAlphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
const codeTtlMs = 60 * 60 * 1000;
const codeMaxUses = 8;
const codePutsPerHour = 30;
const codeGetsPerHour = 60;
const codeCap = 1024;

export interface CodeRecord {
  host: string;
  port: number;
  secret: string;
  relay: string;
}

export function normalizeCode(raw: string): string | null {
  let out = "";
  for (const ch of raw.toUpperCase()) {
    if (ch === "-" || ch === " " || ch === "\t") continue;
    if (!codeAlphabet.includes(ch)) return null;
    out += ch;
  }
  if (out.length !== 6) return null;
  return out;
}

function parseBody(text: string): CodeRecord | null {
  let data: unknown;
  try {
    data = JSON.parse(text);
  } catch {
    return null;
  }
  if (typeof data !== "object" || data === null) return null;
  const rec = data as Record<string, unknown>;
  if (typeof rec.host !== "string" || rec.host.length === 0 || rec.host.length > 63) return null;
  if (typeof rec.port !== "number" || !Number.isInteger(rec.port) || rec.port < 1 || rec.port > 65535) return null;
  if (typeof rec.secret !== "string" || !/^[0-9a-f]{32}$/.test(rec.secret)) return null;
  if (typeof rec.relay !== "string" || rec.relay.length > 120) return null;
  if (rec.host.includes("\"") || rec.relay.includes("\"")) return null;
  return { host: rec.host, port: rec.port, secret: rec.secret, relay: rec.relay };
}

/**
 * Maps a 6-character code to the invite. TTL is one hour. Each code can be
 * read a handful of times (a flaky guest retries) and is then deleted.
 */
export class ShareCodes extends DurableObject<CodeEnv> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.blockConcurrencyWhile(async () => {
      this.ctx.storage.sql.exec(`
        CREATE TABLE IF NOT EXISTS codes (
          code TEXT PRIMARY KEY,
          host TEXT NOT NULL,
          port INTEGER NOT NULL,
          secret TEXT NOT NULL,
          relay TEXT NOT NULL,
          created INTEGER NOT NULL,
          uses INTEGER NOT NULL,
          ip TEXT NOT NULL
        )
      `);
      this.ctx.storage.sql.exec(`
        CREATE TABLE IF NOT EXISTS hits (
          ip TEXT NOT NULL,
          kind TEXT NOT NULL,
          at INTEGER NOT NULL
        )
      `);
    });
  }

  async put(ip: string, code: string, body: string): Promise<Response> {
    const rec = parseBody(body);
    if (!rec) return new Response("bad code", { status: 400 });
    const now = Date.now();
    this.sweep(now);
    const hit = this.hits(ip, "put", now);
    if (hit >= codePutsPerHour) return new Response("rate", { status: 429 });
    const existing = this.ctx.storage.sql
      .exec<{ code: string }>("SELECT code FROM codes WHERE code = ?", code)
      .toArray();
    if (existing.length > 0) return new Response("taken", { status: 409 });
    const n = this.ctx.storage.sql.exec<{ n: number }>("SELECT COUNT(*) AS n FROM codes").one().n;
    if (n >= codeCap) return new Response("full", { status: 429 });
    this.ctx.storage.sql.exec(
      "INSERT INTO codes (code, host, port, secret, relay, created, uses, ip) VALUES (?, ?, ?, ?, ?, ?, 0, ?)",
      code,
      rec.host,
      rec.port,
      rec.secret,
      rec.relay,
      now,
      ip,
    );
    this.ctx.storage.sql.exec("INSERT INTO hits (ip, kind, at) VALUES (?, 'put', ?)", ip, now);
    return Response.json(rec, { status: 201 });
  }

  async get(ip: string, code: string): Promise<Response> {
    const now = Date.now();
    this.sweep(now);
    const hit = this.hits(ip, "get", now);
    if (hit >= codeGetsPerHour) return new Response("rate", { status: 429 });
    this.ctx.storage.sql.exec("INSERT INTO hits (ip, kind, at) VALUES (?, 'get', ?)", ip, now);
    const rows = this.ctx.storage.sql
      .exec<{ host: string; port: number; secret: string; relay: string; uses: number }>(
        "SELECT host, port, secret, relay, uses FROM codes WHERE code = ?",
        code,
      )
      .toArray();
    const row = rows[0];
    if (!row) return new Response("not found", { status: 404 });
    const uses = row.uses + 1;
    if (uses >= codeMaxUses) {
      this.ctx.storage.sql.exec("DELETE FROM codes WHERE code = ?", code);
    } else {
      this.ctx.storage.sql.exec("UPDATE codes SET uses = ? WHERE code = ?", uses, code);
    }
    return Response.json({ host: row.host, port: row.port, secret: row.secret, relay: row.relay });
  }

  async reset(): Promise<void> {
    if (this.env.ALLOW_TEST_HOOKS !== "1") throw new Error("disabled");
    this.ctx.storage.sql.exec("DELETE FROM codes");
    this.ctx.storage.sql.exec("DELETE FROM hits");
  }

  private sweep(now: number): void {
    this.ctx.storage.sql.exec("DELETE FROM codes WHERE created < ?", now - codeTtlMs);
    this.ctx.storage.sql.exec("DELETE FROM hits WHERE at < ?", now - codeTtlMs);
  }

  private hits(ip: string, kind: string, now: number): number {
    return this.ctx.storage.sql
      .exec<{ n: number }>("SELECT COUNT(*) AS n FROM hits WHERE ip = ? AND kind = ? AND at >= ?", ip, kind, now - codeTtlMs)
      .one().n;
  }
}

export function handleCode(request: Request, env: CodeEnv, rawCode: string, ip: string): Promise<Response> {
  const code = normalizeCode(rawCode);
  if (!code) return Promise.resolve(new Response("bad code", { status: 400 }));
  const book = env.CODES.getByName("global");
  if (request.method === "PUT") {
    return request.text().then((body) => book.put(ip, code, body));
  }
  if (request.method === "GET") return book.get(ip, code);
  return Promise.resolve(new Response("method", { status: 405 }));
}
