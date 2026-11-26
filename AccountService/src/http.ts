// Responses, the log line and capped body reads, as in GuestRelay/src/relay.ts.
// Log lines carry only endpoint and outcome: never tokens, nonces, provider user ids or their
// hashes, emails, account or session ids, IPs, request bodies or URLs.

export type Endpoint =
  | "/v1/health"
  | "/v1/auth/nonce"
  | "/v1/auth/web/start"
  | "/v1/auth/web/apple/callback"
  | "/v1/auth/web/google/callback"
  | "/v1/auth/handoff"
  | "/v1/auth/apple"
  | "/v1/auth/google"
  | "/v1/auth/refresh"
  | "/v1/auth/signout"
  | "/v1/account"
  | "/v1/account/delete"
  | "/v1/account/delete/start"
  | "/v1/apple/notifications"
  | "/v1/devices/challenge"
  | "/v1/devices"
  | "/v1/devices/:id"
  | "/v1/devices/self/push"
  | "/v1/statements"
  | "/v1/sync"
  | "/v1/approvals"
  | "/v1/approvals/:id"
  | "/v1/approvals/:id/claim"
  | "/v1/approvals/:id/reveal"
  | "/v1/approvals/:id/finish"
  | "/v1/approvals/:id/envelope"
  | "/v1/approvals/:id/cancel"
  | "/v1/browsers/:id/envelope"
  | "/v1/browsers/self"
  | "/v1/pairs/self"
  | "/v1/withdrawals"
  | "/.well-known/jwks.json"
  | "cron";

export interface LogLine {
  endpoint: Endpoint;
  outcome: string;
}

export function log(line: LogLine): void {
  console.log(JSON.stringify(line));
}

/** Every answer is private to its caller: tokens must never sit in a shared cache. */
export function json(status: number, body: unknown, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store", ...headers },
  });
}

export function errorResponse(status: number, code: string, headers: Record<string, string> = {}): Response {
  return json(status, { error: code }, headers);
}

/** The request body, or null once it passes `max` bytes (declared or streamed). */
export async function readCapped(request: Request, max: number): Promise<ArrayBuffer | null> {
  if (Number(request.headers.get("Content-Length") ?? 0) > max) return null;
  if (request.body === null) return new ArrayBuffer(0);
  const body = new Uint8Array(max);
  let length = 0;
  const reader = request.body.getReader();
  for (;;) {
    const { done, value } = await reader.read();
    if (done) return body.slice(0, length).buffer;
    if (length + value.byteLength > max) {
      await reader.cancel();
      return null;
    }
    body.set(value, length);
    length += value.byteLength;
  }
}

/** A plain JSON object, so its fields can be read as `unknown` and checked one by one. */
export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** A JSON object body of at most `max` bytes, or the error to answer with. */
export async function readJsonObject(request: Request, max: number): Promise<Record<string, unknown> | Response> {
  const body = await readCapped(request, max);
  if (body === null) return errorResponse(413, "too_large");
  try {
    const parsed: unknown = JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(body));
    if (isRecord(parsed)) return parsed;
  } catch {
    // Not UTF-8 or not JSON: the same answer as any other malformed body.
  }
  return errorResponse(400, "bad_request");
}
