declare namespace Cloudflare {
  interface Env {
    HOSTS: DurableObjectNamespace;
    INVITES: DurableObjectNamespace;
    GUEST_CONNECT_LIMIT: RateLimit;
    HOST_CONNECT_LIMIT: RateLimit;
    PING_LIMIT: RateLimit;
    USAGE: AnalyticsEngineDataset;
    ASSETS: Fetcher;
  }
}
