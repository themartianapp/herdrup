// Stand-ins for Apple and Google: an RSA key each, generated once per isolate, published at
// the providers' real JWKS URLs through a fetch spy (the Worker runs in the tests' isolate),
// and a signer for ID tokens. Nothing reaches the network: any other fetch throws.
import { vi } from "vitest";
import { b64url, utf8 } from "../src/bytes";

export const APPLE_JWKS_URL = "https://appleid.apple.com/auth/keys";
export const GOOGLE_JWKS_URL = "https://www.googleapis.com/oauth2/v3/certs";

export interface SigningKey {
  kid: string;
  privateKey: CryptoKey;
  publicJwk: JsonWebKey & { kid: string };
}

export async function generateSigningKey(kid: string): Promise<SigningKey> {
  // workers-types gives generateKey and exportKey union results; an RSA pair and a "jwk"
  // export always produce these shapes.
  const pair = (await crypto.subtle.generateKey(
    { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
    true,
    ["sign", "verify"],
  )) as CryptoKeyPair;
  const exported = (await crypto.subtle.exportKey("jwk", pair.publicKey)) as JsonWebKey;
  return { kid, privateKey: pair.privateKey, publicJwk: { kty: "RSA", n: exported.n, e: exported.e, alg: "RS256", use: "sig", kid } };
}

export function compactJws(header: Record<string, unknown>, payload: Record<string, unknown>, signature: Uint8Array): string {
  return `${b64url(utf8(JSON.stringify(header)))}.${b64url(utf8(JSON.stringify(payload)))}.${b64url(signature)}`;
}

/** An RS256 ID token signed by `key`; `header` overrides or adds header fields. */
export async function signIdToken(key: SigningKey, payload: Record<string, unknown>, header: Record<string, unknown> = {}): Promise<string> {
  const head = b64url(utf8(JSON.stringify({ alg: "RS256", kid: key.kid, typ: "JWT", ...header })));
  const body = b64url(utf8(JSON.stringify(payload)));
  const signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key.privateKey, utf8(`${head}.${body}`));
  return `${head}.${body}.${b64url(new Uint8Array(signature))}`;
}

export interface Providers {
  apple: SigningKey;
  google: SigningKey;
  /** A key no JWKS publishes. */
  stranger: SigningKey;
}

export const APPLE_TOKEN_URL = "https://appleid.apple.com/auth/token";
export const APPLE_REVOKE_URL = "https://appleid.apple.com/auth/revoke";

/** A form the Worker posted to Apple's token or revoke endpoint. */
export interface AppleCall {
  url: string;
  form: Record<string, string>;
}

/**
 * Apple's /auth/token and /auth/revoke as the tests set them up: every call is recorded, and
 * `respond` answers it (by default a token exchange gives a refresh token and a revoke 200).
 */
export const appleRest: { calls: AppleCall[]; respond: (call: AppleCall) => Response | Promise<Response> } = {
  calls: [],
  respond: defaultAppleResponse,
};

export function defaultAppleResponse(call: AppleCall): Response {
  if (call.url === APPLE_TOKEN_URL) {
    return Response.json({ access_token: "test-access", token_type: "Bearer", expires_in: 3600, refresh_token: `refresh-for-${call.form.code}`, id_token: "x" });
  }
  return new Response(null, { status: 200 });
}

export function resetAppleRest(): void {
  appleRest.calls = [];
  appleRest.respond = defaultAppleResponse;
}

let providers: Promise<Providers> | undefined;

/** The isolate's provider keys, and the fetch spy that publishes them and stands in for Apple's REST endpoints. */
export function fakeProviders(): Promise<Providers> {
  providers ??= (async () => {
    const keys: Providers = {
      apple: await generateSigningKey("apple-test-1"),
      google: await generateSigningKey("google-test-1"),
      stranger: await generateSigningKey("stranger-1"),
    };
    const published: Record<string, JsonWebKey[]> = {
      [APPLE_JWKS_URL]: [keys.apple.publicJwk],
      [GOOGLE_JWKS_URL]: [keys.google.publicJwk],
    };
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = input instanceof Request ? input.url : input.toString();
      if (url === APPLE_TOKEN_URL || url === APPLE_REVOKE_URL) {
        const request = new Request(url, init);
        if (request.method !== "POST" || request.headers.get("content-type") !== "application/x-www-form-urlencoded") {
          throw new Error(`unexpected request to Apple: ${request.method} ${request.headers.get("content-type")}`);
        }
        // The form is ASCII (URL-encoded), so decoding its bytes as UTF-8 is exact.
        const form = new TextDecoder().decode(await request.arrayBuffer());
        const call = { url, form: Object.fromEntries(new URLSearchParams(form)) };
        appleRest.calls.push(call);
        return appleRest.respond(call);
      }
      const listed = published[url];
      if (listed === undefined) throw new Error(`unexpected fetch in a test: ${url}`);
      return new Response(JSON.stringify({ keys: listed }), {
        headers: { "content-type": "application/json", "cache-control": "public, max-age=21600" },
      });
    });
    return keys;
  })();
  return providers;
}
