// herdrup-accounts: HerdrUp's optional accounts (herdrup#698, epic #696). Sign-in with Apple or
// Google and sessions (step 1); devices, bound by proof of possession of their guest key, and
// the short-lived statements hosts check (step 2); sync of non-secret settings (step 3);
// account deletion, with Apple's revoke and server-to-server notifications (step 4); the web
// sign-in flow for the desktop and the web guest, with its handoff, cookie and CORS (step 5);
// browser approval for owner access, protocol approve-v1, and pairing an app device with the
// owner's machines, pair-v1 (src/approvals.ts), with pair-request pushes (src/push.ts).
// Log lines carry only endpoint and outcome (src/http.ts): never tokens, nonces, provider user
// ids or their hashes, emails, account, session or device ids, device keys, host ids, IPs,
// bodies or URLs.
import { appleSigner } from "./apple";
import {
  handleBrowserSelf,
  handleClaim,
  handleCreateRequest,
  handleFinish,
  handleGetRequest,
  handleListRequests,
  handlePairSelf,
  handlePutEnvelope,
  handlePutPairEnvelope,
  handleReveal,
  handleWithdrawals,
} from "./approvals";
import { handleAccountDelete, handleDeleteStart } from "./deletion";
import { handleAppleNotification } from "./apple_notify";
import { handleAccount, handleNonce, handleRefresh, handleSignIn, handleSignOut } from "./auth";
import { cleanup } from "./cleanup";
import { handleChallenge, handleDevice, handleEnrol, handleListDevices } from "./devices";
import type { Env } from "./env";
import { errorResponse, json, log, type Endpoint } from "./http";
import { handlePushCapability } from "./push";
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
  const list = ["native_sign_in", "devices", "statements", "sync", "delete", "web_approve", "approval_expiry_final", "pair_v1"];
  // The iOS client's own Google sign-in (ASWebAuthenticationSession + PKCE), which needs only its client id.
  if (set(env.GOOGLE_IOS_CLIENT_ID)) list.push("native_sign_in_google");
  const webApple = set(env.APPLE_WEB_CLIENT_ID);
  const webGoogle = set(env.GOOGLE_WEB_CLIENT_ID) && set(env.GOOGLE_WEB_CLIENT_SECRET);
  if (webApple) list.push("web_sign_in_apple");
  if (webGoogle) list.push("web_sign_in_google");
  // The desktop's deletion, confirmed by a web sign-in (POST /v1/account/delete/start), for the
  // providers whose web flow runs: the app offers it for the provider the account signed in with.
  if (webApple || webGoogle) list.push("web_delete");
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
  "/v1/account/delete/start": { methods: ["POST"], endpoint: "/v1/account/delete/start" },
  "/v1/apple/notifications": { methods: ["POST"], endpoint: "/v1/apple/notifications" },
  "/v1/devices/challenge": { methods: ["POST"], endpoint: "/v1/devices/challenge" },
  "/v1/devices": { methods: ["GET", "POST"], endpoint: "/v1/devices" },
  "/v1/devices/self/push": { methods: ["PUT", "DELETE"], endpoint: "/v1/devices/self/push" },
  "/v1/statements": { methods: ["POST"], endpoint: "/v1/statements" },
  "/v1/sync": { methods: ["GET", "POST"], endpoint: "/v1/sync" },
  "/v1/approvals": { methods: ["GET", "POST"], endpoint: "/v1/approvals" },
  "/v1/browsers/self": { methods: ["GET"], endpoint: "/v1/browsers/self" },
  "/v1/pairs/self": { methods: ["GET"], endpoint: "/v1/pairs/self" },
  "/v1/withdrawals": { methods: ["GET"], endpoint: "/v1/withdrawals" },
  "/.well-known/jwks.json": { methods: ["GET"], endpoint: "/.well-known/jwks.json" },
};

// Device and request ids are 16 random bytes in base64url.
const ID_PATHS: { pattern: RegExp; route: Route }[] = [
  { pattern: /^\/v1\/devices\/([A-Za-z0-9_-]{22})$/, route: { methods: ["PATCH", "DELETE"], endpoint: "/v1/devices/:id" } },
  { pattern: /^\/v1\/approvals\/([A-Za-z0-9_-]{22})$/, route: { methods: ["GET"], endpoint: "/v1/approvals/:id" } },
  { pattern: /^\/v1\/approvals\/([A-Za-z0-9_-]{22})\/claim$/, route: { methods: ["POST"], endpoint: "/v1/approvals/:id/claim" } },
  { pattern: /^\/v1\/approvals\/([A-Za-z0-9_-]{22})\/reveal$/, route: { methods: ["POST"], endpoint: "/v1/approvals/:id/reveal" } },
  { pattern: /^\/v1\/approvals\/([A-Za-z0-9_-]{22})\/finish$/, route: { methods: ["POST"], endpoint: "/v1/approvals/:id/finish" } },
  { pattern: /^\/v1\/approvals\/([A-Za-z0-9_-]{22})\/envelope$/, route: { methods: ["PUT"], endpoint: "/v1/approvals/:id/envelope" } },
  { pattern: /^\/v1\/browsers\/([A-Za-z0-9_-]{22})\/envelope$/, route: { methods: ["PUT"], endpoint: "/v1/browsers/:id/envelope" } },
];

/** The route for a path, and the id it names, if any. */
function resolve(pathname: string): { route: Route; id: string } | undefined {
  const fixed = ROUTES[pathname];
  if (fixed !== undefined) return { route: fixed, id: "" };
  for (const { pattern, route } of ID_PATHS) {
    const id = pattern.exec(pathname)?.[1];
    if (id !== undefined) return { route, id };
  }
  return undefined;
}

/**
 * The calls the web guest's page makes, by route and method: CORS for WEB_ORIGIN only
 * (src/browser.ts). Health is one: the page reads its features to decide whether to offer
 * sign-in. Of the approval routes, only the browser's side is (create, read, reveal, self); the
 * approver's (list, claim, finish, envelope, withdrawals) is not.
 */
const WEB_GUEST_CALLS: Partial<Record<RoutedEndpoint, string[]>> = {
  "/v1/health": ["GET"],
  "/v1/auth/refresh": ["POST"],
  "/v1/auth/signout": ["POST"],
  "/v1/account": ["GET"],
  "/v1/devices/challenge": ["POST"],
  "/v1/devices": ["GET", "POST"],
  "/v1/devices/:id": ["PATCH", "DELETE"],
  "/v1/statements": ["POST"],
  "/v1/sync": ["GET", "POST"],
  "/v1/approvals": ["POST"],
  "/v1/approvals/:id": ["GET"],
  "/v1/approvals/:id/reveal": ["POST"],
  "/v1/browsers/self": ["GET"],
};

/** handleRequest, with CORS preflights and headers on the web guest's calls. */
async function serve(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
  const route = resolve(new URL(request.url).pathname)?.route;
  const methods = route === undefined ? undefined : WEB_GUEST_CALLS[route.endpoint];
  if (methods === undefined) return handleRequest(request, env, ctx);
  if (request.method === "OPTIONS") return preflight(request, env, methods);
  const response = await handleRequest(request, env, ctx);
  if (!methods.includes(request.method)) return response;
  for (const [name, value] of Object.entries(corsHeaders(request, env))) response.headers.set(name, value);
  return response;
}

async function handleRequest(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
  const resolved = resolve(new URL(request.url).pathname);
  if (resolved === undefined) return errorResponse(404, "not_found");
  const { route, id } = resolved;
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
      case "/v1/account/delete/start":
        return await handleDeleteStart(request, env, now);
      case "/v1/apple/notifications":
        return await handleAppleNotification(request, env, now);
      case "/v1/devices/challenge":
        return await handleChallenge(request, env, now);
      case "/v1/devices":
        return request.method === "GET" ? await handleListDevices(request, env, now) : await handleEnrol(request, env, now);
      case "/v1/devices/:id":
        return await handleDevice(request, env, id, now);
      case "/v1/devices/self/push":
        return await handlePushCapability(request, env, now);
      case "/v1/statements":
        return await handleStatements(request, env, now);
      case "/v1/sync":
        return request.method === "GET" ? await handlePull(request, env, now) : await handlePush(request, env, now);
      case "/v1/approvals":
        return request.method === "GET" ? await handleListRequests(request, env, now) : await handleCreateRequest(request, env, ctx, now);
      case "/v1/approvals/:id":
        return await handleGetRequest(request, env, id, now);
      case "/v1/approvals/:id/claim":
        return await handleClaim(request, env, id, now);
      case "/v1/approvals/:id/reveal":
        return await handleReveal(request, env, id, now);
      case "/v1/approvals/:id/finish":
        return await handleFinish(request, env, id, now);
      case "/v1/approvals/:id/envelope":
        return await handlePutPairEnvelope(request, env, id, now);
      case "/v1/browsers/:id/envelope":
        return await handlePutEnvelope(request, env, id, now);
      case "/v1/browsers/self":
        return await handleBrowserSelf(request, env, now);
      case "/v1/pairs/self":
        return await handlePairSelf(request, env, now);
      case "/v1/withdrawals":
        return await handleWithdrawals(request, env, now);
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
  fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    return serve(request, env, ctx);
  },
  async scheduled(controller: ScheduledController, env: Env): Promise<void> {
    try {
      await cleanup(env.DB, controller.scheduledTime);
    } catch {
      log({ endpoint: "cron", outcome: "internal_error" });
    }
  },
} satisfies ExportedHandler<Env>;
