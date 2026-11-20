import { applyD1Migrations, env, type D1Migration } from "cloudflare:test";
import { beforeEach, inject } from "vitest";

declare module "vitest" {
  export interface ProvidedContext {
    /** Each rate-limit binding in wrangler.toml and its configured limit (vitest.config.ts). */
    rateLimits: Record<string, number>;
    /** migrations/, read in Node by vitest.config.ts. */
    migrations: D1Migration[];
  }
}

/**
 * Stands in for a Workers Rate Limiting binding, as in GuestRelay/test/setup.ts. The local
 * one counts in windows aligned to the wall clock, so a test whose requests straddle a
 * minute would see its count reset half way. This one counts per key, as the real one does,
 * but its window never ends: only reset() clears it, before each test.
 */
class CountingRateLimit implements RateLimit {
  readonly #counts = new Map<string, number>();

  constructor(readonly max: number) {}

  async limit({ key }: RateLimitOptions): Promise<RateLimitOutcome> {
    const count = this.#counts.get(key) ?? 0;
    if (count >= this.max) return { success: false };
    this.#counts.set(key, count + 1);
    return { success: true };
  }

  reset(): void {
    this.#counts.clear();
  }
}

// The Worker reads its bindings from this same env object, so it sees these counters.
const limiters = Object.entries(inject("rateLimits")).map(([name, max]) => {
  const limiter = new CountingRateLimit(max);
  (env as unknown as Record<string, RateLimit>)[name] = limiter;
  return limiter;
});

// Applying is idempotent: d1_migrations records what already ran.
await applyD1Migrations(env.DB, inject("migrations"));

beforeEach(() => {
  for (const limiter of limiters) limiter.reset();
});
