// Pair-request alerts through PushRelay (DESIGN.md §13.4):
//
//   PUT    /v1/devices/self/push   iOS device  {capability: "hpr1.…"} → 204
//   DELETE /v1/devices/self/push   iOS device  → 204
//
// The iOS app enrols its APNs token with PushRelay (push.herdrup.app, /v1/enroll) itself and
// stores the sealed device capability here, one per device. It is opaque to this service:
// only PushRelay opens it, so no APNs token is ever stored here. When an app device asks to be
// paired, each other iOS device of the account that stored one gets an alert through
// PushRelay's /v1/send. A 410 from the relay (APNs says the token is gone) clears it.
// Pushes are fire-and-forget (ctx.waitUntil): a failure never fails the request that sent them,
// and the approver still finds the request on its next list.
import { openAccountRequest } from "./auth";
import type { Env } from "./env";
import { errorResponse, log, readJsonObject } from "./http";

/** The platforms the iOS app runs on: the only devices with an APNs token. */
export const PUSH_PLATFORMS = ["ios", "ipados"];
/** PushRelay's own limit on a capability (MAX_CAPABILITY_LENGTH in PushRelay/src/relay.ts). */
export const MAX_CAPABILITY_LENGTH = 512;
const MAX_PUSH_BODY_BYTES = 1024;
export const PAIR_REQUEST_CATEGORY = "pair_request";

const noContent = (): Response => new Response(null, { status: 204, headers: { "cache-control": "no-store" } });

export async function handlePushCapability(request: Request, env: Env, nowMs: number): Promise<Response> {
  const principal = await openAccountRequest(request, env, "/v1/devices/self/push", nowMs);
  if (principal instanceof Response) return principal;
  if (principal.deviceId === null) return errorResponse(403, "device_required");
  const device = await env.DB.prepare("SELECT platform FROM devices WHERE id = ? AND account_id = ?")
    .bind(principal.deviceId, principal.accountId)
    .first<{ platform: string }>();
  if (device === null) return errorResponse(403, "device_removed");
  if (!PUSH_PLATFORMS.includes(device.platform)) return errorResponse(403, "not_ios");
  if (request.method === "DELETE") {
    await env.DB.prepare("DELETE FROM push_capabilities WHERE device_id = ?").bind(principal.deviceId).run();
    return noContent();
  }
  const body = await readJsonObject(request, MAX_PUSH_BODY_BYTES);
  if (body instanceof Response) return body;
  const { capability } = body;
  if (typeof capability !== "string" || capability.length > MAX_CAPABILITY_LENGTH || !/^hpr1\.[A-Za-z0-9_-]+$/.test(capability)) {
    return errorResponse(400, "bad_request");
  }
  await env.DB.prepare(
    `INSERT INTO push_capabilities (device_id, account_id, capability, updated_ms) VALUES (?, ?, ?, ?)
     ON CONFLICT (device_id) DO UPDATE SET capability = excluded.capability, updated_ms = excluded.updated_ms`,
  )
    .bind(principal.deviceId, principal.accountId, capability, nowMs)
    .run();
  return noContent();
}

/**
 * Alerts every other iOS device of the account that stored a capability: "‹name› wants to pair
 * with your machines", category pair_request, the request id under `request_id`. APNs drops it
 * once the request is over (`expiresMs`). Never throws: it runs after the answer is sent.
 */
export async function sendPairRequestPushes(
  env: Env,
  accountId: string,
  requester: { id: string; name: string },
  requestId: string,
  expiresMs: number,
): Promise<void> {
  const relay = env.PUSH_RELAY_URL?.trim() ?? "";
  if (relay.length === 0) return;
  try {
    const { results } = await env.DB.prepare(
      `SELECT p.device_id, p.capability FROM push_capabilities p JOIN devices d ON d.id = p.device_id
        WHERE p.account_id = ? AND p.device_id <> ? AND d.platform IN (SELECT value FROM json_each(?))`,
    )
      .bind(accountId, requester.id, JSON.stringify(PUSH_PLATFORMS))
      .all<{ device_id: string; capability: string }>();
    const payload = {
      aps: { alert: { body: `${requester.name} wants to pair with your machines` }, sound: "default", category: PAIR_REQUEST_CATEGORY },
      request_id: requestId,
    };
    await Promise.all(
      results.map(async ({ device_id: deviceId, capability }) => {
        try {
          const response = await fetch(new URL("/v1/send", relay), {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({ capability, push_type: "alert", priority: 10, expiration: Math.floor(expiresMs / 1000), payload }),
          });
          if (response.status === 410) {
            // Only the capability that was sent: the device may have stored a new one meanwhile.
            await env.DB.prepare("DELETE FROM push_capabilities WHERE device_id = ? AND capability = ?").bind(deviceId, capability).run();
            log({ endpoint: "/v1/approvals", outcome: "push_gone" });
          } else if (!response.ok) {
            log({ endpoint: "/v1/approvals", outcome: "push_failed" });
          }
        } catch {
          log({ endpoint: "/v1/approvals", outcome: "push_failed" });
        }
      }),
    );
  } catch {
    log({ endpoint: "/v1/approvals", outcome: "push_failed" });
  }
}
