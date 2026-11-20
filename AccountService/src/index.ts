// herdrup-accounts: HerdrUp's optional accounts (herdrup#698, epic #696). Sign-in with Apple or
// Google and sessions (step 1); devices, bound by proof of possession of their guest key, and
// the short-lived statements hosts check (step 2); sync of non-secret settings (step 3).
// Account deletion follows.
// Log lines carry only endpoint and outcome (src/http.ts): never tokens, nonces, provider user
// ids or their hashes, emails, account, session or device ids, device keys, host ids, IPs,
// bodies or URLs.
import { handleAccount, handleNonce, handleRefresh, handleSignIn, handleSignOut } from "./auth";
import { cleanup } from "./cleanup";
import { handleChallenge, handleDevice, handleEnrol, handleListDevices } from "./devices";
import type { Env } from "./env";
import { errorResponse, json, log, type Endpoint } from "./http";
import { handleJwks, handleStatements } from "./statements";
import { handlePull, handlePush } from "./sync";

export const VERSION = "0.3.0";

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
  "/v1/auth/refresh": { methods: ["POST"], endpoint: "/v1/auth/refresh" },
  "/v1/auth/signout": { methods: ["POST"], endpoint: "/v1/auth/signout" },
  "/v1/account": { methods: ["GET"], endpoint: "/v1/account" },
  "/v1/devices/challenge": { methods: ["POST"], endpoint: "/v1/devices/challenge" },
  "/v1/devices": { methods: ["GET", "POST"], endpoint: "/v1/devices" },
  "/v1/statements": { methods: ["POST"], endpoint: "/v1/statements" },
  "/v1/sync": { methods: ["GET", "POST"], endpoint: "/v1/sync" },
  "/.well-known/jwks.json": { methods: ["GET"], endpoint: "/.well-known/jwks.json" },
};

// A device id is 16 random bytes in base64url.
const DEVICE_PATH = /^\/v1\/devices\/([A-Za-z0-9_-]{22})$/;
const DEVICE_ROUTE: Route = { methods: ["PATCH", "DELETE"], endpoint: "/v1/devices/:id" };

export async function handleRequest(request: Request, env: Env): Promise<Response> {
  const { pathname } = new URL(request.url);
  const deviceId = DEVICE_PATH.exec(pathname)?.[1];
  const route = deviceId === undefined ? ROUTES[pathname] : DEVICE_ROUTE;
  if (route === undefined) return errorResponse(404, "not_found");
  if (!route.methods.includes(request.method)) return errorResponse(405, "method_not_allowed", { Allow: route.methods.join(", ") });
  const now = Date.now();
  try {
    switch (route.endpoint) {
      case "/v1/health":
        return json(200, { ok: true, version: VERSION });
      case "/v1/auth/nonce":
        return await handleNonce(request, env, now);
      case "/v1/auth/apple":
        return await handleSignIn(request, env, "apple", now);
      case "/v1/auth/google":
        return await handleSignIn(request, env, "google", now);
      case "/v1/auth/refresh":
        return await handleRefresh(request, env, now);
      case "/v1/auth/signout":
        return await handleSignOut(request, env, now);
      case "/v1/account":
        return await handleAccount(request, env, now);
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
    return handleRequest(request, env);
  },
  async scheduled(controller: ScheduledController, env: Env): Promise<void> {
    try {
      await cleanup(env.DB, controller.scheduledTime);
    } catch {
      log({ endpoint: "cron", outcome: "internal_error" });
    }
  },
} satisfies ExportedHandler<Env>;
