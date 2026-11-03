# herdrup-push

`herdrup-push` is the Cloudflare Worker that lets App Store and TestFlight builds of
HerdrUp receive push notifications without each user holding an APNs key
(herdrup#277). The publisher's APNs `.p8` key lives only in an encrypted Worker
secret.

1. The app gets an APNs device token (or a Live Activity push token) and calls
   `/v1/enroll`. The relay returns an opaque sealed capability.
2. The app passes the capability to the Herdr daemon, next to the raw token.
3. The daemon calls `/v1/send` with the capability and an APNs payload. The relay
   opens the capability, signs an ES256 provider token and forwards the push to
   APNs.

It serves the single bundle `com.jerryfane.herdr`. Alerts use the topic
`com.jerryfane.herdr`, and Live Activities use
`com.jerryfane.herdr.push-type.liveactivity`.

## Privacy

Notifications show the message text, so that text passes through the relay on its
way to APNs. **It is never stored or logged.** The relay keeps no database. Log
lines carry only the endpoint, the outcome, the APNs status and the APNs reason.
They never include tokens, capabilities or payload contents.

## Endpoints

All bodies are JSON. Any other method or path returns 404.

| Endpoint | Request | Responses |
| --- | --- | --- |
| `GET /v1/health` | none | 200 `{"ok":true,"version":"…"}` |
| `POST /v1/enroll` | `{"kind":"device"\|"activity","token":"<hex>","environment":"production"\|"sandbox"}`, max 2 KB | 200 `{"capability":"hpr1.…"}`; 400 `invalid_request`; 429 `rate_limited` |
| `POST /v1/send` | `{"capability","push_type":"alert"\|"liveactivity","priority":10\|5,"expiration"?,"collapse_id"?,"payload":{"aps":{…}}}`, max 8 KB | 200 `{"status":200,"apns_id":…}`; 410 when APNs says the token is gone (410 or `BadDeviceToken`); 502 for other APNs failures; 400 `invalid_request` / `invalid_capability` / `payload_too_large`; 429 `rate_limited` |

Token rules:
- A `device` token is 64–200 hex characters.
- An `activity` token is 32–256 hex characters, so its sealed capability stays within the daemon's 512-character limit.

`alert` needs a `device` capability, and `liveactivity` needs an `activity`
capability. The serialized `payload` can be at most 4096 bytes.

A missing or malformed secret returns 500 `{"error":"not_configured"}`.

A capability is `hpr1.` followed by base64url of `nonce || AES-256-GCM(ciphertext+tag)`.
It is sealed with `RELAY_SEAL_KEY` and the additional authenticated data `hpr1`.
If you rotate that key, every enrolled device has to enroll again.

## Secrets and bindings

| Secret | Value |
| --- | --- |
| `APNS_KEY_P8` | PEM text of the APNs `.p8` key |
| `APNS_KEY_ID` | Key ID of that key |
| `APNS_TEAM_ID` | Apple team ID |
| `RELAY_SEAL_KEY` | base64 of 32 random bytes (`openssl rand -base64 32`) |

`wrangler.toml` declares two rate-limit bindings:
- `ENROLL_LIMIT`: 20 per 60 s, keyed by the `CF-Connecting-IP` header.
- `SEND_LIMIT`: 120 per 60 s, keyed by the SHA-256 of the capability.

## Develop and deploy

```sh
cd PushRelay
npm install
npm test                 # vitest; APNs is mocked
npm run typecheck

wrangler secret put APNS_KEY_P8 < AuthKey_XXXXXXXXXX.p8
wrangler secret put APNS_KEY_ID
wrangler secret put APNS_TEAM_ID
openssl rand -base64 32 | wrangler secret put RELAY_SEAL_KEY
wrangler deploy
```

The `herdrup-push` Worker serves two custom domains: `push.herdrup.app` (current, the
app's default since 2026-11-02) and `push.herdrup.themartian.app` (the earlier name;
keep it attached, because herdr machines configured before then still send to it). Attach
them in the dashboard (Workers → herdrup-push → Settings → Domains & Routes) or with
`routes = [{ pattern = "push.herdrup.app", custom_domain = true }, { pattern =
"push.herdrup.themartian.app", custom_domain = true }]`.

APNs accepts HTTP/2 only. Deployed Workers reach it through Cloudflare's proxy,
which speaks HTTP/2. Local `wrangler dev` (workerd) speaks only HTTP/1.1, so
`/v1/send` returns 502 locally even with valid secrets (workerd#4841). Test real
delivery against the deployed Worker.
