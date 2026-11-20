// A provider's signing keys (its JWKS), cached in isolate memory.
//
// - Fresh for the response's Cache-Control max-age, clamped to 5 minutes .. 24 hours, or for
//   `defaultMaxAgeMs` without one (Apple sends none).
// - A kid the fresh set lacks refetches at most once a minute, so tokens with made-up kids
//   can't turn into a flood of fetches. A stale set refetches at most every 10 seconds.
// - When a refetch fails, keys up to 24 hours past their freshness keep verifying: Apple and
//   Google publish a new key well before they sign with it. Past that, or before the first
//   successful fetch, the lookup is "unavailable".
// - Concurrent callers share one fetch.
// Only RSA keys for RS256 signatures are kept; anything else in the set is skipped.
import { isRecord } from "./http";

export const MIN_MAX_AGE_MS = 5 * 60 * 1000;
export const MAX_MAX_AGE_MS = 24 * 60 * 60 * 1000;
export const REFETCH_INTERVAL_MS = 60 * 1000;
export const RETRY_INTERVAL_MS = 10 * 1000;
export const STALE_GRACE_MS = 24 * 60 * 60 * 1000;
const FETCH_TIMEOUT_MS = 5000;

export type KeyLookup = CryptoKey | "unknown_kid" | "unavailable";

export type JwksFetcher = (url: string) => Promise<Response>;

const defaultFetcher: JwksFetcher = (url) =>
  fetch(url, { headers: { accept: "application/json" }, signal: AbortSignal.timeout(FETCH_TIMEOUT_MS) });

export class JwksCache {
  #keys = new Map<string, CryptoKey>();
  #freshUntilMs = Number.NEGATIVE_INFINITY;
  #lastAttemptMs = Number.NEGATIVE_INFINITY;
  #inflight: Promise<boolean> | undefined;

  constructor(
    readonly url: string,
    readonly defaultMaxAgeMs: number,
    readonly fetcher: JwksFetcher = defaultFetcher,
  ) {}

  async key(kid: string, nowMs: number): Promise<KeyLookup> {
    const fresh = nowMs < this.#freshUntilMs;
    const known = this.#keys.get(kid);
    if (fresh && known !== undefined) return known;
    if (this.#inflight !== undefined) await this.#inflight;
    else if (nowMs - this.#lastAttemptMs >= (fresh ? REFETCH_INTERVAL_MS : RETRY_INTERVAL_MS)) await this.#refresh(nowMs);
    if (nowMs >= this.#freshUntilMs + STALE_GRACE_MS) return "unavailable";
    return this.#keys.get(kid) ?? "unknown_kid";
  }

  #refresh(nowMs: number): Promise<boolean> {
    this.#inflight ??= this.#load(nowMs).finally(() => {
      this.#inflight = undefined;
    });
    return this.#inflight;
  }

  async #load(nowMs: number): Promise<boolean> {
    this.#lastAttemptMs = nowMs;
    try {
      const response = await this.fetcher(this.url);
      if (!response.ok) return false;
      const body: unknown = await response.json();
      const listed = isRecord(body) ? body.keys : undefined;
      if (!Array.isArray(listed)) return false;
      const keys = new Map<string, CryptoKey>();
      for (const entry of listed) {
        const imported = await importRsaKey(entry);
        if (imported !== null) keys.set(imported.kid, imported.key);
      }
      this.#keys = keys;
      this.#freshUntilMs = nowMs + maxAge(response.headers.get("cache-control"), this.defaultMaxAgeMs);
      return true;
    } catch {
      return false;
    }
  }
}

function maxAge(cacheControl: string | null, fallbackMs: number): number {
  const seconds = /(?:^|,)\s*max-age=(\d{1,9})\s*(?:,|$)/i.exec(cacheControl ?? "")?.[1];
  const ms = seconds === undefined ? fallbackMs : Number(seconds) * 1000;
  return Math.min(MAX_MAX_AGE_MS, Math.max(MIN_MAX_AGE_MS, ms));
}

async function importRsaKey(entry: unknown): Promise<{ kid: string; key: CryptoKey } | null> {
  if (!isRecord(entry)) return null;
  const { kty, kid, n, e, alg, use } = entry;
  if (kty !== "RSA" || typeof kid !== "string" || kid.length === 0 || kid.length > 128) return null;
  if (typeof n !== "string" || typeof e !== "string") return null;
  if (alg !== undefined && alg !== "RS256") return null;
  if (use !== undefined && use !== "sig") return null;
  try {
    const key = await crypto.subtle.importKey(
      "jwk",
      { kty: "RSA", n, e, alg: "RS256", ext: true },
      { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
      false,
      ["verify"],
    );
    return { kid, key };
  } catch {
    return null;
  }
}
