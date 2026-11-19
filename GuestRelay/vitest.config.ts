import { cloudflareTest } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

// Tests run inside workerd against the real Worker, Durable Object, assets, R2 bucket and
// rate-limit bindings declared in wrangler.toml. scripts/*.test.mjs read the file tree, so
// they run under node --test instead (npm test runs both). CRASH_ADMIN_TOKEN is a Worker
// secret in production; the tests set a fixed one.
export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.toml" },
      miniflare: { bindings: { CRASH_ADMIN_TOKEN: "test-admin-token-0123456789abcdefghijklmnop" } },
    }),
  ],
  test: { include: ["test/**/*.test.ts"] },
});
