// herdrup-accounts: HerdrUp's optional accounts (herdrup#698, epic #696). This first step
// signs people in with Apple or Google and keeps their sessions. Devices, statements for
// hosts, sync and account deletion follow in later steps.
// Log lines carry only endpoint and outcome (src/http.ts): never tokens, nonces, provider
// user ids or their hashes, emails, account or session ids, IPs, bodies or URLs.
import { handleAccount, handleNonce, handleRefresh, handleSignIn, handleSignOut } from "./auth";
import { cleanup } from "./cleanup";
import type { Env } from "./env";
import { errorResponse, json, log, type Endpoint } from "./http";

export const VERSION = "0.1.0";

const ROUTES: Record<string, { method: string; endpoint: Exclude<Endpoint, "cron"> }> = {
  "/v1/health": { method: "GET", endpoint: "/v1/health" },
  "/v1/auth/nonce": { method: "POST", endpoint: "/v1/auth/nonce" },
  "/v1/auth/apple": { method: "POST", endpoint: "/v1/auth/apple" },
  "/v1/auth/google": { method: "POST", endpoint: "/v1/auth/google" },
  "/v1/auth/refresh": { method: "POST", endpoint: "/v1/auth/refresh" },
  "/v1/auth/signout": { method: "POST", endpoint: "/v1/auth/signout" },
  "/v1/account": { method: "GET", endpoint: "/v1/account" },
};

export async function handleRequest(request: Request, env: Env): Promise<Response> {
  const route = ROUTES[new URL(request.url).pathname];
  if (route === undefined) return errorResponse(404, "not_found");
  if (request.method !== route.method) return errorResponse(405, "method_not_allowed", { Allow: route.method });
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
