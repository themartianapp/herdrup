import { env } from "cloudflare:test";
import { beforeAll, describe, expect, it } from "vitest";
import { b64url, fromB64url } from "../src/bytes";
import { JwksCache, MIN_MAX_AGE_MS, REFETCH_INTERVAL_MS, RETRY_INTERVAL_MS, STALE_GRACE_MS } from "../src/jwks";
import { serviceKeys } from "../src/keys";
import { issueNonce, NONCE_TTL_MS, openNonce } from "../src/nonce";
import { generateSigningKey, type SigningKey } from "./providers";

// The JWKS cache and the nonces, with an explicit clock: every lookup takes the time it runs
// at, so nothing here waits.

const URL = "https://keys.example/jwks";
const T0 = 1_800_000_000_000;

let first: SigningKey;
let second: SigningKey;

beforeAll(async () => {
  [first, second] = await Promise.all([generateSigningKey("k1"), generateSigningKey("k2")]);
});

/** A fetcher answering from `published`, or failing while it is null; it counts its calls. */
function fakeFetcher(cacheControl: string | null = "max-age=3600") {
  const state = {
    calls: 0,
    published: [first.publicJwk] as JsonWebKey[] | null,
    fetcher: async (url: string): Promise<Response> => {
      expect(url).toBe(URL);
      state.calls++;
      if (state.published === null) return new Response("down", { status: 503 });
      const headers: Record<string, string> = { "content-type": "application/json" };
      if (cacheControl !== null) headers["cache-control"] = cacheControl;
      return new Response(JSON.stringify({ keys: state.published }), { headers });
    },
  };
  return state;
}

describe("JwksCache", () => {
  it("fetches once and serves known kids from memory while fresh", async () => {
    const source = fakeFetcher();
    const cache = new JwksCache(URL, 3_600_000, source.fetcher);
    expect(await cache.key("k1", T0)).toBeInstanceOf(CryptoKey);
    expect(await cache.key("k1", T0 + 3_599_000)).toBeInstanceOf(CryptoKey);
    expect(source.calls).toBe(1);
  });

  it("refetches an unknown kid at most once a minute", async () => {
    const source = fakeFetcher();
    const cache = new JwksCache(URL, 3_600_000, source.fetcher);
    await cache.key("k1", T0);
    expect(await cache.key("nope", T0 + 1000)).toBe("unknown_kid");
    expect(await cache.key("nope", T0 + 2000)).toBe("unknown_kid");
    expect(source.calls).toBe(1);
    source.published = [first.publicJwk, second.publicJwk];
    expect(await cache.key("k2", T0 + 30_000)).toBe("unknown_kid");
    expect(source.calls).toBe(1);
    expect(await cache.key("k2", T0 + REFETCH_INTERVAL_MS)).toBeInstanceOf(CryptoKey);
    expect(source.calls).toBe(2);
  });

  it("refetches once the max-age passes, clamped to at least 5 minutes", async () => {
    const source = fakeFetcher("public, max-age=10");
    const cache = new JwksCache(URL, 3_600_000, source.fetcher);
    await cache.key("k1", T0);
    await cache.key("k1", T0 + MIN_MAX_AGE_MS - 1);
    expect(source.calls).toBe(1);
    await cache.key("k1", T0 + MIN_MAX_AGE_MS);
    expect(source.calls).toBe(2);
  });

  it("uses the default max-age without Cache-Control", async () => {
    const source = fakeFetcher(null);
    const cache = new JwksCache(URL, 600_000, source.fetcher);
    await cache.key("k1", T0);
    await cache.key("k1", T0 + 599_999);
    expect(source.calls).toBe(1);
    await cache.key("k1", T0 + 600_000);
    expect(source.calls).toBe(2);
  });

  it("is unavailable until a first fetch succeeds, retrying every 10 seconds", async () => {
    const source = fakeFetcher();
    source.published = null;
    const cache = new JwksCache(URL, 3_600_000, source.fetcher);
    expect(await cache.key("k1", T0)).toBe("unavailable");
    expect(await cache.key("k1", T0 + RETRY_INTERVAL_MS - 1)).toBe("unavailable");
    expect(source.calls).toBe(1);
    source.published = [first.publicJwk];
    expect(await cache.key("k1", T0 + RETRY_INTERVAL_MS)).toBeInstanceOf(CryptoKey);
    expect(source.calls).toBe(2);
  });

  it("keeps verifying with stale keys for 24 hours while refetches fail", async () => {
    const source = fakeFetcher();
    const cache = new JwksCache(URL, 3_600_000, source.fetcher);
    await cache.key("k1", T0);
    source.published = null;
    const freshUntil = T0 + 3_600_000;
    expect(await cache.key("k1", freshUntil)).toBeInstanceOf(CryptoKey);
    expect(await cache.key("k1", freshUntil + STALE_GRACE_MS - 1)).toBeInstanceOf(CryptoKey);
    expect(await cache.key("k1", freshUntil + STALE_GRACE_MS)).toBe("unavailable");
  });

  it("shares one fetch between concurrent lookups", async () => {
    const source = fakeFetcher();
    const cache = new JwksCache(URL, 3_600_000, source.fetcher);
    const keys = await Promise.all([cache.key("k1", T0), cache.key("k1", T0), cache.key("k1", T0)]);
    expect(keys.every((key) => key instanceof CryptoKey)).toBe(true);
    expect(source.calls).toBe(1);
  });

  it("skips keys that are not RS256 signing keys", async () => {
    const source = fakeFetcher();
    source.published = [
      { ...first.publicJwk, kid: "enc", use: "enc" },
      { ...first.publicJwk, kid: "ps", alg: "PS256" },
      { kty: "EC", crv: "P-256", x: "AA", y: "AA", kid: "ec" },
      { ...first.publicJwk, kid: "" },
      second.publicJwk,
    ];
    const cache = new JwksCache(URL, 3_600_000, source.fetcher);
    expect(await cache.key("k2", T0)).toBeInstanceOf(CryptoKey);
    for (const kid of ["enc", "ps", "ec"]) expect(await cache.key(kid, T0)).toBe("unknown_kid");
  });
});

describe("nonces", () => {
  it("open while unexpired and only with this service's key", async () => {
    const key = (await serviceKeys(env.ACCOUNT_HMAC_KEY)!).nonce;
    const other = (await serviceKeys(btoa("another-32-byte-key-for-tests!!!"))!).nonce;
    const { nonce, expiresUnix } = await issueNonce(key, T0);
    expect(nonce).toMatch(/^[A-Za-z0-9_-]{54}$/);
    expect(expiresUnix).toBe(Math.floor((T0 + NONCE_TTL_MS) / 1000));
    expect(await openNonce(key, nonce, T0 + NONCE_TTL_MS - 1000)).toBe(expiresUnix * 1000);
    expect(await openNonce(key, nonce, T0 + NONCE_TTL_MS)).toBeNull();
    expect(await openNonce(other, nonce, T0)).toBeNull();
  });

  it("can't be extended by editing the expiry", async () => {
    const key = (await serviceKeys(env.ACCOUNT_HMAC_KEY)!).nonce;
    const bytes = fromB64url((await issueNonce(key, T0)).nonce)!;
    new DataView(bytes.buffer).setBigUint64(0, BigInt(Math.floor(T0 / 1000) + 86_400));
    expect(await openNonce(key, b64url(bytes), T0 + NONCE_TTL_MS)).toBeNull();
  });
});
