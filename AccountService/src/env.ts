export interface Env {
  DB: D1Database;
  AUTH_IP_LIMIT?: RateLimit;
  ACCOUNT_LIMIT?: RateLimit;
  /** 32 random bytes, standard base64 (wrangler secret). See src/keys.ts. */
  ACCOUNT_HMAC_KEY?: string;
  APPLE_APP_CLIENT_ID?: string;
  APPLE_WEB_CLIENT_ID?: string;
  GOOGLE_IOS_CLIENT_ID?: string;
  GOOGLE_WEB_CLIENT_ID?: string;
}
