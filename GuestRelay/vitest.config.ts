import { cloudflareTest } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";
import { unstable_readConfig } from "wrangler";

// Tests run inside workerd against the real Worker, Durable Objects, assets and R2 bucket
// declared in wrangler.toml. The rate-limit bindings are the exception: test/setup.ts
// replaces each with a per-key counter holding the limit configured in wrangler.toml, which
// only resets between tests, because the local bindings reset on the wall clock's minute
// (#724). The harness is @cloudflare/vitest-plugin, not @cloudflare/vitest-pool-workers,
// whose SELF.fetch got slower with every request a test file made (workers-sdk#15446), so
// the tests at the end of relay.test.ts timed out on a loaded host. Nothing waits on the
// clock; a test's time is its round trips and its Durable Object writes, which are SQLite
// files under the OS temp directory: on a loaded disk each new object's first write costs
// ~60 ms and an fsync can stall for seconds, so the timeout only bounds a hang (a frame
// or close that never comes). scripts/*.test.mjs read the file tree, so they run under
// node --test instead (npm test runs both). CRASH_ADMIN_TOKEN is a Worker secret in
// production; the tests set a fixed one.

// Typed here: wrangler's declarations import its Config type from a package it bundles.
const ratelimits: { name: string; simple: { limit: number } }[] = unstable_readConfig({ config: "./wrangler.toml" }).ratelimits;

export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.toml" },
      miniflare: { bindings: { CRASH_ADMIN_TOKEN: "test-admin-token-0123456789abcdefghijklmnop" } },
    }),
  ],
  test: {
    include: ["test/**/*.test.ts"],
    testTimeout: 20_000,
    setupFiles: ["test/setup.ts"],
    provide: { rateLimits: Object.fromEntries(ratelimits.map(({ name, simple }) => [name, simple.limit])) },
  },
});
