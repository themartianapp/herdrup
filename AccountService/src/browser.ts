// What the browser-facing endpoints share (DESIGN.md §2.5, §2.6): the cookies, and CORS for the
// web guest.
//
// Cookies, all host-only (__Host-: Secure, Path=/, no Domain) and HttpOnly:
//   __Host-hu_refresh  the web guest's refresh token. SameSite=Strict: guest.herdrup.app and
//                      accounts.herdrup.app are one site, so the guest's fetches carry it and
//                      no other site's do. Max-Age is the refresh token's own lifetime, renewed
//                      at every rotation.
//   __Host-hu_flow     one secret per browser that binds its pending web sign-ins to it. Every
//                      flow it starts within the cookie's life binds to the same value; each
//                      start renews Max-Age to the 10 minutes a flow lives. No callback clears
//                      it, so one sign-in never breaks another. SameSite=None, because Apple's
//                      callback is a cross-site POST (form_post) and a Lax cookie wouldn't come.
//
// CORS: exactly WEB_ORIGIN (https://guest.herdrup.app), with credentials, on the endpoints the
// web guest calls; never `*`, never another origin. Cookie-authenticated calls also require
// that Origin, so another herdrup.app origin (same site, so the Strict cookie would come along)
// can't use the cookie either.
import type { Env } from "./env";
import { REFRESH_TTL_MS } from "./sessions";

export const REFRESH_COOKIE = "__Host-hu_refresh";
export const FLOW_COOKIE = "__Host-hu_flow";
export const FLOW_TTL_MS = 10 * 60 * 1000;

/** The value of cookie `name` in the request, or null. */
export function readCookie(request: Request, name: string): string | null {
  for (const part of (request.headers.get("Cookie") ?? "").split(";")) {
    const eq = part.indexOf("=");
    if (eq > 0 && part.slice(0, eq).trim() === name) return part.slice(eq + 1).trim();
  }
  return null;
}

const ATTRIBUTES = "Path=/; Secure; HttpOnly";

export const refreshCookie = (token: string): string =>
  `${REFRESH_COOKIE}=${token}; Max-Age=${REFRESH_TTL_MS / 1000}; ${ATTRIBUTES}; SameSite=Strict`;
export const clearRefreshCookie = (): string => `${REFRESH_COOKIE}=; Max-Age=0; ${ATTRIBUTES}; SameSite=Strict`;
export const flowCookie = (value: string): string => `${FLOW_COOKIE}=${value}; Max-Age=${FLOW_TTL_MS / 1000}; ${ATTRIBUTES}; SameSite=None`;

/** The configured web guest origin, or null while WEB_ORIGIN is unset. */
export function webOrigin(env: Env): string | null {
  const origin = env.WEB_ORIGIN?.trim() ?? "";
  return /^https:\/\/[a-z0-9.-]+$/.test(origin) ? origin : null;
}

/** Whether the request comes from the web guest's page. */
export function fromWebGuest(request: Request, env: Env): boolean {
  const origin = webOrigin(env);
  return origin !== null && request.headers.get("Origin") === origin;
}

/** The headers that let the web guest's page read an answer, for `request` from the web guest; none otherwise. */
export function corsHeaders(request: Request, env: Env): Record<string, string> {
  return fromWebGuest(request, env)
    ? { "Access-Control-Allow-Origin": webOrigin(env) ?? "", "Access-Control-Allow-Credentials": "true", Vary: "Origin" }
    : { Vary: "Origin" };
}

/** The answer to a CORS preflight for a route taking `methods`: allowed only from the web guest, for those methods. */
export function preflight(request: Request, env: Env, methods: string[]): Response {
  const method = request.headers.get("Access-Control-Request-Method") ?? "";
  if (!fromWebGuest(request, env) || !methods.includes(method)) {
    return new Response(null, { status: 403, headers: { Vary: "Origin", "cache-control": "no-store" } });
  }
  return new Response(null, {
    status: 204,
    headers: {
      ...corsHeaders(request, env),
      "Access-Control-Allow-Methods": methods.join(", "),
      "Access-Control-Allow-Headers": "authorization, content-type",
      "Access-Control-Max-Age": "600",
      "cache-control": "no-store",
    },
  });
}
