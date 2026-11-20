// herdrup-accounts: HerdrUp's optional accounts (herdrup#698, epic #696). Sign-in with Apple or
// Google and sessions (step 1); devices, bound by proof of possession of their guest key, and
// the short-lived statements hosts check (step 2); sync of non-secret settings (step 3);
// account deletion, with Apple's revoke and server-to-server notifications (step 4); the web
// sign-in flow for the desktop and the web guest, with its handoff, cookie and CORS (step 5).
// Log lines carry only endpoint and outcome (src/http.ts): never tokens, nonces, provider user
// ids or their hashes, emails, account, session or device ids, device keys, host ids, IPs,
// bodies or URLs.
import { appleSigner } from "./apple";
import { handleAccountDelete } from "./deletion";
import { handleAppleNotification } from "./apple_notify";
import { handleAccount, handleNonce, handleRefresh, handleSignIn, handleSignOut } from "./auth";
import { cleanup } from "./cleanup";
import { handleChallenge, handleDevice, handleEnrol, handleListDevices } from "./devices";
import type { Env } from "./env";
import { errorResponse, json, log, type Endpoint } from "./http";
import { handleJwks, handleStatements } from "./statements";
import { handlePull, handlePush } from "./sync";
import { corsHeaders, preflight } from "./browser";
import { handleAppleCallback, handleGoogleCallback, handleHandoff, handleWebStart } from "./web";
import { VERSION } from "./version";

// This module exports only its handler: `wrangler dev` refuses an entry module with other exports.

/**
 * What this Worker can do right now, for `GET /v1/health`: the apps ship separately, so they show
 * a feature only when the live Worker lists it. The names are a stable contract (README "API").
 * Each flag is a boolean fact about the configuration; no value of a var or secret is ever
 * returned.
 */
async function features(env: Env): Promise<string[]> {
  const set = (value: string | undefined) => (value?.trim() ?? "").length > 0;
  const list = ["native_sign_in", "devices", "statements", "sync", "delete"];
  if (set(env.APPLE_WEB_CLIENT_ID)) list.push("web_sign_in_apple");
  if (set(env.GOOGLE_WEB_CLIENT_ID) && set(env.GOOGLE_WEB_CLIENT_SECRET)) list.push("web_sign_in_google");
  // The same loader the revoke uses: the key must be present and parse, with a valid Key ID.
  if ((await appleSigner(env)) !== null) list.push("apple_revoke");
  return list;
}

type RoutedEndpoint = Exclude<Endpoint, "cron">;

interface Route {
  methods: string[];
  endpoint: RoutedEndpoint;
}

const ROUTES: Record<string, Route> = {
  "/v1/health": { methods: ["GET"], endpoint: "/v1/health" },
  "/v1/auth/nonce": { methods: ["POST"], endpoint: "/v1/auth/nonce" },
  "/v1/auth/apple": { methods: ["POST"], endpoint: "/v1/auth/apple" },
  "/v1/auth/google": { methods: ["POST"], endpoint: "/v1/auth/google" },
  "/v1/auth/web/start": { methods: ["GET"], endpoint: "/v1/auth/web/start" },
  "/v1/auth/web/apple/callback": { methods: ["POST"], endpoint: "/v1/auth/web/apple/callback" },
  "/v1/auth/web/google/callback": { methods: ["GET"], endpoint: "/v1/auth/web/google/callback" },
  "/v1/auth/handoff": { methods: ["POST"], endpoint: "/v1/auth/handoff" },
  "/v1/auth/refresh": { methods: ["POST"], endpoint: "/v1/auth/refresh" },
  "/v1/auth/signout": { methods: ["POST"], endpoint: "/v1/auth/signout" },
  "/v1/account": { methods: ["GET"], endpoint: "/v1/account" },
  "/v1/account/delete": { methods: ["POST"], endpoint: "/v1/account/delete" },
  "/v1/apple/notifications": { methods: ["POST"], endpoint: "/v1/apple/notifications" },
  "/v1/devices/challenge": { methods: ["POST"], endpoint: "/v1/devices/challenge" },
  "/v1/devices": { methods: ["GET", "POST"], endpoint: "/v1/devices" },
  "/v1/statements": { methods: ["POST"], endpoint: "/v1/statements" },
  "/v1/sync": { methods: ["GET", "POST"], endpoint: "/v1/sync" },
  "/.well-known/jwks.json": { methods: ["GET"], endpoint: "/.well-known/jwks.json" },
};

// A device id is 16 random bytes in base64url.
const DEVICE_PATH = /^\/v1\/devices\/([A-Za-z0-9_-]{22})$/;
const DEVICE_ROUTE: Route = { methods: ["PATCH", "DELETE"], endpoint: "/v1/devices/:id" };

/**
 * The endpoints the web guest's page calls: CORS for WEB_ORIGIN only (src/browser.ts). Health is
 * one: the page reads its features to decide whether to offer sign-in.
 */
const WEB_GUEST_ENDPOINTS: ReadonlySet<RoutedEndpoint> = new Set([
  "/v1/health",
  "/v1/auth/refresh",
  "/v1/auth/signout",
  "/v1/account",
  "/v1/devices/challenge",
  "/v1/devices",
  "/v1/devices/:id",
  "/v1/statements",
  "/v1/sync",
]);

/** handleRequest, with CORS preflights and headers on the web guest's endpoints. */
async function serve(request: Request, env: Env): Promise<Response> {
  const { pathname } = new URL(request.url);
  const route = DEVICE_PATH.test(pathname) ? DEVICE_ROUTE : ROUTES[pathname];
  if (route === undefined || !WEB_GUEST_ENDPOINTS.has(route.endpoint)) return handleRequest(request, env);
  if (request.method === "OPTIONS") return preflight(request, env, route.methods);
  const response = await handleRequest(request, env);
  for (const [name, value] of Object.entries(corsHeaders(request, env))) response.headers.set(name, value);
  return response;
}

async function handleRequest(request: Request, env: Env): Promise<Response> {
  const { pathname } = new URL(request.url);
  const deviceId = DEVICE_PATH.exec(pathname)?.[1];
  const route = deviceId === undefined ? ROUTES[pathname] : DEVICE_ROUTE;
  if (route === undefined) return errorResponse(404, "not_found");
  if (!route.methods.includes(request.method)) return errorResponse(405, "method_not_allowed", { Allow: route.methods.join(", ") });
  const now = Date.now();
  try {
    switch (route.endpoint) {
      case "/v1/health":
        return json(200, { ok: true, version: VERSION, features: await features(env) });
      case "/v1/auth/nonce":
        return await handleNonce(request, env, now);
      case "/v1/auth/apple":
        return await handleSignIn(request, env, "apple", now);
      case "/v1/auth/google":
        return await handleSignIn(request, env, "google", now);
      case "/v1/auth/web/start":
        return await handleWebStart(request, env, now);
      case "/v1/auth/web/apple/callback":
        return await handleAppleCallback(request, env, now);
      case "/v1/auth/web/google/callback":
        return await handleGoogleCallback(request, env, now);
      case "/v1/auth/handoff":
        return await handleHandoff(request, env, now);
      case "/v1/auth/refresh":
        return await handleRefresh(request, env, now);
      case "/v1/auth/signout":
        return await handleSignOut(request, env, now);
      case "/v1/account":
        return await handleAccount(request, env, now);
      case "/v1/account/delete":
        return await handleAccountDelete(request, env, now);
      case "/v1/apple/notifications":
        return await handleAppleNotification(request, env, now);
      case "/v1/devices/challenge":
        return await handleChallenge(request, env, now);
      case "/v1/devices":
        return request.method === "GET" ? await handleListDevices(request, env, now) : await handleEnrol(request, env, now);
      case "/v1/devices/:id":
        return await handleDevice(request, env, deviceId ?? "", now);
      case "/v1/statements":
        return await handleStatements(request, env, now);
      case "/v1/sync":
        return request.method === "GET" ? await handlePull(request, env, now) : await handlePush(request, env, now);
      case "/.well-known/jwks.json":
        return await handleJwks(env);
    }
  } catch {
    // The error itself is deliberately not logged: it may echo request content.
    log({ endpoint: route.endpoint, outcome: "internal_error" });
    return errorResponse(500, "internal_error");
  }
}

export default {
  fetch(request: Request, env: Env): Promise<Response> {
    return serve(request, env);
  },
  async scheduled(controller: ScheduledController, env: Env): Promise<void> {
    try {
      await cleanup(env.DB, controller.scheduledTime);
    } catch {
      log({ endpoint: "cron", outcome: "internal_error" });
    }
  },
} satisfies ExportedHandler<Env>;
