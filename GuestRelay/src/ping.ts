// The anonymous daily usage ping (usage-ping contract, 2026-11-02): one Analytics Engine
// data point per accepted ping, holding the random install id, the client and its version.
// Nothing about a ping is logged: not its body, IP, headers or outcome. Only a missing
// binding or an internal error logs, and then only endpoint and outcome.
import { errorResponse, log, readCapped, type Env } from "./relay";

/** Largest ping body. The contract's body is under 200 bytes. */
export const MAX_PING_BYTES = 512;

export const PING_APPS = ["ios", "ipados", "macos-catalyst", "desktop-macos", "desktop-linux", "desktop-windows"] as const;

const PING_KEYS = ["app", "build", "install", "v", "version"];
// 16 random bytes as b64url without padding.
const INSTALL = /^[A-Za-z0-9_-]{22}$/;
const VERSION_OR_BUILD = /^[0-9A-Za-z._-]{1,32}$/;

interface Ping {
  install: string;
  app: string;
  version: string;
  build: string;
}

/** `POST /v1/ping`: 204 once the data point is written, 400 for anything but the exact schema. */
export async function handlePing(request: Request, env: Env): Promise<Response> {
  const endpoint = "/v1/ping";
  if (request.method !== "POST") return errorResponse(405, "method_not_allowed", { Allow: "POST" });
  try {
    if (env.PING_LIMIT === undefined || env.USAGE === undefined) {
      log({ endpoint, outcome: "not_configured" });
      return errorResponse(500, "not_configured");
    }
    // Its own per-IP budget, checked before the body is read, so pings never spend the
    // host or guest connect limits.
    const ip = request.headers.get("CF-Connecting-IP") ?? "unknown";
    if (!(await env.PING_LIMIT.limit({ key: ip })).success) return errorResponse(429, "rate_limited");
    const body = await readCapped(request, MAX_PING_BYTES);
    const ping = body === null ? null : parsePing(body);
    if (ping === null) return errorResponse(400, "bad_request");
    env.USAGE.writeDataPoint({ indexes: [ping.install], blobs: [ping.app, ping.version, ping.build], doubles: [1] });
    return new Response(null, { status: 204 });
  } catch {
    // The error itself is deliberately not logged: it may echo request content.
    log({ endpoint, outcome: "internal_error" });
    return errorResponse(500, "internal_error");
  }
}

/** The ping, or null unless the body is exactly the contract's JSON object. */
function parsePing(body: ArrayBuffer): Ping | null {
  let value: unknown;
  try {
    value = JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(body));
  } catch {
    return null;
  }
  if (typeof value !== "object" || value === null || Array.isArray(value)) return null;
  const fields = value as Record<string, unknown>;
  if (Object.keys(fields).sort().join() !== PING_KEYS.join()) return null;
  const { v, install, app, version, build } = fields;
  if (v !== 1) return null;
  if (typeof install !== "string" || !INSTALL.test(install)) return null;
  if (typeof app !== "string" || !(PING_APPS as readonly string[]).includes(app)) return null;
  if (typeof version !== "string" || !VERSION_OR_BUILD.test(version)) return null;
  if (typeof build !== "string" || !VERSION_OR_BUILD.test(build)) return null;
  return { install, app, version, build };
}
