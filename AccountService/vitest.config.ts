import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";
import { unstable_readConfig } from "wrangler";

// Tests run inside workerd against the real Worker and a local D1 database with
// migrations/ applied (test/setup.ts), as GuestRelay's do. The exceptions:
// - The rate-limit bindings: test/setup.ts replaces each with a per-key counter holding the
//   limit configured in wrangler.toml, which only resets between tests, because the local
//   bindings reset on the wall clock's minute (GuestRelay #724).
// - Apple's and Google's key sets: the Worker runs in the tests' isolate, so the tests answer
//   its JWKS fetches with keys they generate (test/providers.ts). Nothing reaches the network.
// ACCOUNT_HMAC_KEY is a Worker secret in production, and the Google client ids are filled in
// by the owner; the tests set fixed ones.

// Typed here: wrangler's declarations import its Config type from a package it bundles.
const ratelimits: { name: string; simple: { limit: number } }[] = unstable_readConfig({ config: "./wrangler.toml" }).ratelimits;

export default defineConfig(async () => ({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.toml" },
      miniflare: {
        bindings: {
          ACCOUNT_HMAC_KEY: "dGVzdC1hY2NvdW50LWhtYWMta2V5LTAxMjM0NTY3ODk=",
          GOOGLE_IOS_CLIENT_ID: "test-ios.apps.googleusercontent.com",
          GOOGLE_WEB_CLIENT_ID: "test-web.apps.googleusercontent.com",
        },
      },
    }),
  ],
  test: {
    include: ["test/**/*.test.ts"],
    testTimeout: 20_000,
    setupFiles: ["test/setup.ts"],
    provide: {
      rateLimits: Object.fromEntries(ratelimits.map(({ name, simple }) => [name, simple.limit])),
      migrations: await readD1Migrations("./migrations"),
    },
  },
}));
