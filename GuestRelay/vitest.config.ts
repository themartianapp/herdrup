import { cloudflareTest } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

// Tests run inside workerd against the real Worker, Durable Object, assets and
// rate-limit binding declared in wrangler.toml. scripts/*.test.mjs read the file tree, so
// they run under node --test instead (npm test runs both).
export default defineConfig({
  plugins: [cloudflareTest({ wrangler: { configPath: "./wrangler.toml" } })],
  test: { include: ["test/**/*.test.ts"] },
});
