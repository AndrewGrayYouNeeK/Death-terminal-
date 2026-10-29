import { runDurableObjectAlarm } from "cloudflare:test";
import { env, exports } from "cloudflare:workers";
import { afterEach, describe, expect, it } from "vitest";
import { readLimits } from "../src/limits";

const worker = exports.default;

function sessionId(n: number): string {
  return n.toString(16).padStart(16, "0");
}

async function connect(id: string, role: "host" | "guest"): Promise<WebSocket> {
  const response = await worker.fetch(`https://relay.youneek.xyz/v1/${id}?role=${role}`, {
    headers: { Upgrade: "websocket" },
  });
  expect(response.status).toBe(101);
  const ws = response.webSocket;
  if (!ws) throw new Error("missing webSocket");
  ws.accept();
  return ws;
}

function nextMessage(ws: WebSocket): Promise<unknown> {
  return new Promise((resolve, reject) => {
    const onMessage = (event: MessageEvent): void => {
      cleanup();
      resolve(event.data);
    };
    const onClose = (): void => {
      cleanup();
      reject(new Error("closed"));
    };
    const cleanup = (): void => {
      ws.removeEventListener("message", onMessage);
      ws.removeEventListener("close", onClose);
    };
    ws.addEventListener("message", onMessage);
    ws.addEventListener("close", onClose);
  });
}

async function asBytes(data: unknown): Promise<Uint8Array> {
  if (data instanceof ArrayBuffer) return new Uint8Array(data);
  if (ArrayBuffer.isView(data)) {
    const view = data as ArrayBufferView;
    return new Uint8Array(view.buffer, view.byteOffset, view.byteLength);
  }
  if (typeof data === "string") return Uint8Array.from(data, (c) => c.charCodeAt(0));
  if (data instanceof Blob) return new Uint8Array(await data.arrayBuffer());
  throw new Error(`expected binary, got ${typeof data}`);
}

describe("share relay", () => {
  afterEach(async () => {
    await env.GATE.getByName("global").reset();
    await env.CODES.getByName("global").reset();
  });

  it("reads limits and rejects a bad path", async () => {
    const limits = readLimits({ MAX_SESSIONS: "3", MAX_FRAME: "nope" });
    expect(limits.maxSessions).toBe(3);
    expect(limits.maxFrame).toBe(64 * 1024);

    const health = await worker.fetch("https://relay.youneek.xyz/health");
    expect(health.status).toBe(200);
    expect(await health.json()).toEqual({ ok: true, service: "youneek-share-relay" });

    const missing = await worker.fetch("https://relay.youneek.xyz/v1/zz");
    expect(missing.status).toBe(404);
    const role = await worker.fetch("https://relay.youneek.xyz/v1/0123456789abcdef?role=nope", {
      headers: { Upgrade: "websocket" },
    });
    expect(role.status).toBe(400);
  });

  it("forwards opaque frames both ways and does not admit a second guest", async () => {
    const id = sessionId(1);
    const host = await connect(id, "host");
    const hostStatus = nextMessage(host);
    const guest = await connect(id, "guest");
    const [hostFirst, guestFirst] = await Promise.all([hostStatus, nextMessage(guest)]);
    expect(Array.from(await asBytes(hostFirst))).toEqual([0]);
    expect(Array.from(await asBytes(guestFirst))).toEqual([0]);

    const marker = new Uint8Array([0, 1, 2, 255, ..."TOP-SECRET-PLAINTEXT".split("").map((c) => c.charCodeAt(0))]);
    const guestGot = nextMessage(guest);
    host.send(marker);
    expect(Array.from(await asBytes(await guestGot))).toEqual(Array.from(marker));

    const back = new Uint8Array([9, 8, 7]);
    const hostGot = nextMessage(host);
    guest.send(back);
    expect(Array.from(await asBytes(await hostGot))).toEqual([9, 8, 7]);

    const busyResponse = await worker.fetch(`https://relay.youneek.xyz/v1/${id}?role=guest`, {
      headers: { Upgrade: "websocket" },
    });
    expect(busyResponse.status).toBe(101);
    const busy = busyResponse.webSocket;
    if (!busy) throw new Error("missing webSocket");
    busy.accept();
    expect(Array.from(await asBytes(await nextMessage(busy)))).toEqual([1]);

    const still = nextMessage(guest);
    host.send(new Uint8Array([4]));
    expect(Array.from(await asBytes(await still))).toEqual([4]);

    host.close(1000, "done");
    guest.close(1000, "done");
  });

  it("rejects a second session once the cap is full", async () => {
    const host = await connect(sessionId(2), "host");
    const denied = await worker.fetch(`https://relay.youneek.xyz/v1/${sessionId(3)}?role=host`, {
      headers: { Upgrade: "websocket" },
    });
    expect(denied.status).toBe(429);
    expect(await denied.text()).toBe("full");
    host.close(1000, "done");
  });

  it("closes an oversized frame", async () => {
    const id = sessionId(4);
    const host = await connect(id, "host");
    const hostStatus = nextMessage(host);
    const guest = await connect(id, "guest");
    await Promise.all([hostStatus, nextMessage(guest)]);
    const closed = new Promise<number>((resolve) => {
      guest.addEventListener("close", (event) => resolve((event as CloseEvent).code));
    });
    guest.send(new Uint8Array(1500));
    expect(await closed).toBe(1009);
    host.close(1000, "done");
  });

  it("expires a host that never gets a guest", async () => {
    const id = sessionId(5);
    const host = await connect(id, "host");
    const closed = new Promise<number>((resolve) => {
      host.addEventListener("close", (event) => resolve((event as CloseEvent).code));
    });
    const stub = env.SESSION.getByName(id);
    await stub.forceDeadline(1);
    const ran = await runDurableObjectAlarm(stub);
    if (!ran) {
      // The alarm was already due and the runtime ran it.
    }
    expect(await closed).toBe(4001);
  });

  it("maps a short code to the invite, then stops after repeated lookups", async () => {
    const body = JSON.stringify({
      host: "192.0.2.1",
      port: 9,
      secret: "00112233445566778899aabbccddeeff",
      relay: "wss://relay.youneek.xyz",
    });
    const put = await worker.fetch("https://youneek-share-relay.youneekartifacts.workers.dev/v1/code/K7Q-4MZ", {
      method: "PUT",
      body,
    });
    expect(put.status).toBe(201);
    const got = await worker.fetch("https://youneek-share-relay.youneekartifacts.workers.dev/v1/code/k7q4mz");
    expect(got.status).toBe(200);
    expect(await got.json()).toEqual({
      host: "192.0.2.1",
      port: 9,
      secret: "00112233445566778899aabbccddeeff",
      relay: "wss://relay.youneek.xyz",
    });
    const clash = await worker.fetch("https://youneek-share-relay.youneekartifacts.workers.dev/v1/code/K7Q4MZ", {
      method: "PUT",
      body,
    });
    expect(clash.status).toBe(409);
    const bad = await worker.fetch("https://youneek-share-relay.youneekartifacts.workers.dev/v1/code/K7Q-4M0", {
      method: "PUT",
      body,
    });
    expect(bad.status).toBe(400);
    for (let i = 0; i < 7; i += 1) {
      const again = await worker.fetch("https://youneek-share-relay.youneekartifacts.workers.dev/v1/code/K7Q4MZ");
      expect(again.status).toBe(200);
    }
    const gone = await worker.fetch("https://youneek-share-relay.youneekartifacts.workers.dev/v1/code/K7Q4MZ");
    expect(gone.status).toBe(404);
  });
});
