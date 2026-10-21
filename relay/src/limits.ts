/** Abuse limits for one relay. Values come from Worker vars. */

export interface Limits {
  maxSessions: number;
  maxPerIp: number;
  newPerIpPerHour: number;
  sessionTtlMs: number;
  idleMs: number;
  waitMs: number;
  maxFrame: number;
  maxBytes: number;
}

const defaults: Limits = {
  maxSessions: 128,
  maxPerIp: 8,
  newPerIpPerHour: 30,
  sessionTtlMs: 2 * 60 * 60 * 1000,
  idleMs: 15 * 60 * 1000,
  waitMs: 30 * 60 * 1000,
  maxFrame: 64 * 1024,
  maxBytes: 64 * 1024 * 1024,
};

function clamp(raw: string | undefined, fallback: number, min: number, max: number): number {
  if (raw === undefined || raw === "") return fallback;
  const n = Number(raw);
  if (!Number.isInteger(n) || n < min || n > max) return fallback;
  return n;
}

export function readLimits(env: {
  MAX_SESSIONS?: string;
  MAX_PER_IP?: string;
  NEW_PER_IP_PER_HOUR?: string;
  SESSION_TTL_MS?: string;
  IDLE_MS?: string;
  WAIT_MS?: string;
  MAX_FRAME?: string;
  MAX_BYTES?: string;
}): Limits {
  return {
    maxSessions: clamp(env.MAX_SESSIONS, defaults.maxSessions, 1, 10_000),
    maxPerIp: clamp(env.MAX_PER_IP, defaults.maxPerIp, 1, 1_000),
    newPerIpPerHour: clamp(env.NEW_PER_IP_PER_HOUR, defaults.newPerIpPerHour, 1, 10_000),
    sessionTtlMs: clamp(env.SESSION_TTL_MS, defaults.sessionTtlMs, 1_000, 24 * 60 * 60 * 1000),
    idleMs: clamp(env.IDLE_MS, defaults.idleMs, 1_000, 24 * 60 * 60 * 1000),
    waitMs: clamp(env.WAIT_MS, defaults.waitMs, 1_000, 24 * 60 * 60 * 1000),
    maxFrame: clamp(env.MAX_FRAME, defaults.maxFrame, 16, 1024 * 1024),
    maxBytes: clamp(env.MAX_BYTES, defaults.maxBytes, 1024, 1024 * 1024 * 1024),
  };
}

export const statusOk = 0;
export const statusBusy = 1;

export type Role = "host" | "guest";

export function parseRole(raw: string | null): Role | null {
  if (raw === "host" || raw === "guest") return raw;
  return null;
}

export function otherRole(role: Role): Role {
  switch (role) {
    case "host":
      return "guest";
    case "guest":
      return "host";
    default: {
      const neverRole: never = role;
      return neverRole;
    }
  }
}

/** `/v1/` plus 16 lowercase hex chars (8 bytes). The relay id, not the secret. */
export function parseSessionId(pathname: string): string | null {
  const match = /^\/v1\/([0-9a-f]{16})$/.exec(pathname);
  return match ? match[1] : null;
}
