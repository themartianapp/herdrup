declare namespace Cloudflare {
  interface Env {
    DB: D1Database;
    AUTH_IP_LIMIT: RateLimit;
    ACCOUNT_LIMIT: RateLimit;
    STATEMENT_LIMIT: RateLimit;
    ENROL_LIMIT: RateLimit;
    SYNC_WRITE_LIMIT: RateLimit;
    DELETE_IP_LIMIT: RateLimit;
    ACCOUNT_HMAC_KEY: string;
    APPLE_APP_CLIENT_ID: string;
    APPLE_WEB_CLIENT_ID: string;
    APPLE_SIWA_P8?: string;
    APPLE_KEY_ID: string;
    APPLE_TEAM_ID: string;
    GOOGLE_IOS_CLIENT_ID: string;
    GOOGLE_WEB_CLIENT_ID: string;
    STATEMENT_KEY_A?: string;
    STATEMENT_KEY_B?: string;
    STATEMENT_KID_A: string;
    STATEMENT_KID_B: string;
    STATEMENT_ACTIVE: string;
    STATEMENT_REVOKED_KIDS: string;
    GOOGLE_WEB_CLIENT_SECRET?: string;
    WEB_ORIGIN: string;
  }
}
