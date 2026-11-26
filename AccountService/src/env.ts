export interface Env {
  DB: D1Database;
  AUTH_IP_LIMIT?: RateLimit;
  ACCOUNT_LIMIT?: RateLimit;
  STATEMENT_LIMIT?: RateLimit;
  ENROL_LIMIT?: RateLimit;
  SYNC_WRITE_LIMIT?: RateLimit;
  APPROVAL_LIMIT?: RateLimit;
  DELETE_IP_LIMIT?: RateLimit;
  /** 32 random bytes, standard base64 (wrangler secret). See src/keys.ts. */
  ACCOUNT_HMAC_KEY?: string;
  APPLE_APP_CLIENT_ID?: string;
  APPLE_WEB_CLIENT_ID?: string;
  /** Sign in with Apple's key (the .p8 file, PKCS8 PEM; wrangler secret), its Key ID and the Team ID (vars). See src/apple.ts. */
  APPLE_SIWA_P8?: string;
  APPLE_KEY_ID?: string;
  APPLE_TEAM_ID?: string;
  GOOGLE_IOS_CLIENT_ID?: string;
  GOOGLE_WEB_CLIENT_ID?: string;
  /** Statement signing keys, two slots for rotation (src/signing.ts): Ed25519 PKCS8 DER, standard base64 (wrangler secrets). */
  STATEMENT_KEY_A?: string;
  STATEMENT_KEY_B?: string;
  /** Each slot's kid; a slot is published only with both its key and its kid. */
  STATEMENT_KID_A?: string;
  STATEMENT_KID_B?: string;
  /** "A" or "B": the slot that signs. */
  STATEMENT_ACTIVE?: string;
  /** Comma-separated kids that are never used or published again, and are listed as revoked. */
  STATEMENT_REVOKED_KIDS?: string;
  /** The Google web client's secret (wrangler secret), for the web flow's code exchange. Unset: the Google web flow answers 503. */
  GOOGLE_WEB_CLIENT_SECRET?: string;
  /** The web guest's origin (var): the only CORS origin, and where the web flow returns to. */
  WEB_ORIGIN?: string;
  /** PushRelay's base URL (var), for pair-request alerts (src/push.ts). Unset: no pushes are sent. */
  PUSH_RELAY_URL?: string;
}
