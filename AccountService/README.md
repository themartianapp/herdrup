# herdrup-accounts

`herdrup-accounts` is the Cloudflare Worker behind HerdrUp's optional accounts (herdrup#698,
epic #696), on `accounts.herdrup.app` with a D1 database. Signing in is optional: signed out,
HerdrUp works exactly as before, and plain guest invites never touch this Worker.

This first step signs people in with Apple or Google and keeps their sessions. Later steps add
devices and the statements hosts check, sync of non-secret settings, and account deletion.
It is a separate Worker from `herdrup-guest`: it holds personal data, its own secrets and its
own deploys, so a bug or rollback here can't drop a guest session.

## API

| Call | Body | Answer |
|---|---|---|
| `GET /v1/health` | | `{ok, version}` |
| `POST /v1/auth/nonce` | | `{nonce, expires_unix}`: valid 10 minutes, spent by one sign-in |
| `POST /v1/auth/apple` | `{id_token, nonce, platform}` | `{account_id, created, access_token, access_expires_in, refresh_token, refresh_expires_in}` |
| `POST /v1/auth/google` | same | same, plus `display_hint` (the Google email, for the device to show) |
| `POST /v1/auth/refresh` | `{refresh_token}` | a new token pair |
| `POST /v1/auth/signout` | `Authorization: Bearer <access>` | 204 |
| `GET /v1/account` | `Authorization: Bearer <access>` | `{account_id, created_ms}` |

`platform` is one of `ios`, `ipados`, `macos`, `windows`, `linux`, `web`. Errors are
`{"error": "<code>"}`; a refused ID token adds `reason` (`wrong_audience`, `expired`, …).

**Sign-in.** The app gets a nonce, passes it unchanged to Apple (`ASAuthorizationAppleIDRequest.nonce`,
no scopes) or Google (the `nonce` parameter, scopes `openid email`), and posts the ID token
with the same nonce. The Worker checks the token against the provider's published keys:

- signature: RS256 only, key by `kid` from `https://appleid.apple.com/auth/keys` or
  `https://www.googleapis.com/oauth2/v3/certs`, cached in memory (src/jwks.ts);
- `iss`; `aud` is one of our client ids (Apple: the App ID and the Services ID; Google: the iOS
  and web client ids); Google's `azp`, when present, equals `aud`;
- `exp` not passed, `iat` not in the future and at most 10 minutes old (60 s skew);
- `nonce` equals the one posted, which this Worker issued, hasn't expired and wasn't spent.

**Sessions.** `a1.<session>.<secret>` access tokens last 1 hour; `r1.<session>.<secret>` refresh
tokens 90 days from their last use. Each refresh rotates both in one conditional D1 `UPDATE`,
so when two refreshes race with the same token the first wins and the second finds a token
already rotated away. Presenting a rotated-away refresh token is treated as theft: the whole
session ends, for every holder. Clients must refresh one at a time.

## Privacy

- **Stored:** an account id (16 random bytes) with its creation time and last-seen day; for each
  sign-in identity, `HMAC-SHA256(key, "<provider>|<sub>")`, never the provider's user id itself;
  each session's SHA-256 token hashes, platform and times; the SHA-256 of spent nonces until they
  expire. **Never stored:** names, emails, ID tokens, tokens in the clear.
- **Email:** Apple is asked for nothing. Google's email is read from the ID token and handed back
  once as `display_hint`, then dropped.
- **Logs:** a log line is `{endpoint, outcome}`, written only for `not_configured`,
  `rate_limited`, `keys_unavailable` and `internal_error`. Never tokens, nonces, provider ids or
  their hashes, emails, account or session ids, IPs, bodies or URLs. `wrangler.toml` turns off
  Workers Logs (including invocation logs), traces and Logpush.
- **Retention:** spent nonces go at their expiry, sessions when their refresh token expires,
  and accounts not seen for 24 months, with their identities and sessions (hourly cron).
  D1 Time Travel keeps point-in-time history for 7 days on Workers Free (30 on Paid).

## Limits

| Binding | Key | Limit | Covers |
|---|---|---|---|
| `AUTH_IP_LIMIT` | `CF-Connecting-IP` | 20 / 60 s | nonce, sign-in, refresh; checked before the body is read |
| `ACCOUNT_LIMIT` | account id | 120 / 60 s | sign-out, `/v1/account` |

Bodies are capped at 8 KB and ID tokens at 4 KB.

## Configuration

| Name | Kind | Value |
|---|---|---|
| `DB` | D1 | `herdrup-accounts`, EU jurisdiction, id in `wrangler.toml` |
| `APPLE_APP_CLIENT_ID` | var | `com.jerryfane.herdr` |
| `APPLE_WEB_CLIENT_ID` | var | `com.jerryfane.herdr.signin` (the Services ID) |
| `GOOGLE_IOS_CLIENT_ID`, `GOOGLE_WEB_CLIENT_ID` | var | from Google Cloud; while both are empty Google sign-in answers 500 `not_configured` |
| `ACCOUNT_HMAC_KEY` | secret | 32 random bytes, standard base64 |

`ACCOUNT_HMAC_KEY` keys the nonces and the identity hashes. **Losing it orphans every account**
(no sign-in finds its account again), so keep a copy outside Cloudflare. Never rotate it in
place.

## Develop and deploy

Needs Node 22 or later.

```sh
cd AccountService
npm ci
npm test                 # vitest in workerd: local D1, generated Apple/Google keys, no network
npm run typecheck
npx wrangler deploy --dry-run --outdir /tmp/accounts-dry   # bundle check only
```

Before the first deploy, once:

```sh
npx wrangler d1 migrations apply herdrup-accounts --remote
openssl rand -base64 32 | tr -d '\n' | npx wrangler secret put ACCOUNT_HMAC_KEY   # and keep a copy (above)
```

Then fill in the Google client ids in `wrangler.toml` and `npx wrangler deploy`. The deploy
attaches `accounts.herdrup.app` (`custom_domain = true`); the `herdrup.app` zone must be on the
deploying account. Later migrations go through `wrangler d1 migrations apply … --remote` before
the deploy that needs them.

## Rollback

- **Bad code:** `npx wrangler deployments list`, then `npx wrangler rollback <version-id>`.
  A rollback across a migration needs the old code to tolerate the new schema; migrations only
  add, so it does.
- **Take accounts offline:** detach `accounts.herdrup.app` in Workers → herdrup-accounts →
  Settings → Domains & Routes. Apps stay signed in locally and retry; guest access and plain
  invites are unaffected.
- **Restore data:** `npx wrangler d1 time-travel restore herdrup-accounts --timestamp <time>`
  (within the Time Travel window).
