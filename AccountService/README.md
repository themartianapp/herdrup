# herdrup-accounts

`herdrup-accounts` is the Cloudflare Worker behind HerdrUp's optional accounts (herdrup#698,
epic #696), on `accounts.herdrup.app` with a D1 database. Signing in is optional: signed out,
HerdrUp works exactly as before, and plain guest invites never touch this Worker.

It signs people in with Apple or Google and keeps their sessions (step 1), binds each device's
guest key to the account and signs the short-lived statements hosts check (step 2), and syncs
non-secret settings between the account's devices (step 3). Account deletion comes next.
It is a separate Worker from `herdrup-guest`: it holds personal data, its own secrets and its
own deploys, so a bug or rollback here can't drop a guest session.

## API

| Call | Body | Answer |
|---|---|---|
| `GET /v1/health` | | `{ok, version}` |
| `POST /v1/auth/nonce` | | `{nonce, expires_unix}`: valid 10 minutes, spent by one sign-in |
| `POST /v1/auth/apple` | `{id_token, nonce, platform}` | `{account_id, created, access_token, access_expires_in, refresh_token, refresh_expires_in}` |
| `POST /v1/auth/google` | same | same, plus `display_hint` (the Google email, for the device to show) |
| `POST /v1/auth/refresh` | `{refresh_token}`; from the web guest, its cookie | a new token pair; the web guest gets `{account_id, access_token, access_expires_in}` and the rotated cookie |
| `POST /v1/auth/signout` | `Authorization: Bearer <access>`; from the web guest, its cookie | 204 (the web guest's cookie is cleared) |
| `GET /v1/auth/web/start` | `?provider=apple\|google&client=app&platform=…&handoff_challenge=…`, or `&client=web` | 303 to Apple or Google |
| `POST /v1/auth/web/apple/callback`, `GET /v1/auth/web/google/callback` | from the provider | 303 to `herdrup://account#code=…` or `https://guest.herdrup.app/web/?account=1` (`…#error=` / `?account_error=` on failure) |
| `POST /v1/auth/handoff` | `{code, handoff_verifier}` | the same as a native sign-in |
| `GET /v1/account` | `Authorization: Bearer <access>` | `{account_id, created_ms}` |
| `POST /v1/devices/challenge` | bearer | `{challenge_id, server_pub, salt, account_id, expires_in}`: 60 s, one use |
| `POST /v1/devices` | bearer; `{challenge_id, device_pub, mac, name, platform}` | 201 `{device}` (200 when the key is already the account's) |
| `GET /v1/devices` | bearer | `{devices: [{id, name, platform, device_pub, created_ms, current}]}` |
| `PATCH /v1/devices/<id>` | bearer; `{name}` | `{device}` |
| `DELETE /v1/devices/<id>` | bearer | 204; that device's sessions end |
| `POST /v1/statements` | bearer; `{hosts: [host_id, … ≤ 50]}` | `{statements: [{host, jws}], exp}` |
| `GET /v1/sync?since=<rev>`, `GET /v1/sync?cursor=<cursor>` | bearer | `{rev, changes: [item, … ≤ 500], more, cursor?}`; `410 reset_required` |
| `POST /v1/sync` | bearer; `{changes: [{collection, id, base_rev?, deleted?, body?}, … ≤ 100]}` | `{rev, applied: [{collection, id, rev}], conflicts: [{collection, id, server}]}` |
| `GET /.well-known/jwks.json` | | `{keys, revoked_kids}`, `Cache-Control: public, max-age=3600` |

`platform` is one of `ios`, `ipados`, `macos`, `windows`, `linux`, `web`. Errors are
`{"error": "<code>"}`; a refused ID token adds `reason` (`wrong_audience`, `expired`, …).

**Sign-in.** The app gets a nonce, passes it unchanged to Apple (`ASAuthorizationAppleIDRequest.nonce`,
no scopes) or Google (the `nonce` parameter, scopes `openid email`), and posts the ID token
with the same nonce. The Worker checks the token against the provider's published keys:

- signature: RS256 only, key by `kid` from `https://appleid.apple.com/auth/keys` or
  `https://www.googleapis.com/oauth2/v3/certs`, cached in memory (src/jwks.ts);
- `iss`; `aud` is one of our client ids (Apple: the App ID and the Services ID; Google: the iOS
  and web client ids); `azp`, when present, is also one of our client ids, checked on its own
  (Google's cross-client flow has `aud` = web client, `azp` = iOS client);
- `exp` not passed, `iat` not in the future and at most 10 minutes old (60 s skew);
- `nonce` equals the one posted, which this Worker issued, hasn't expired and wasn't spent.

**Sessions.** `a1.<session>.<secret>` access tokens last 1 hour; `r1.<session>.<secret>` refresh
tokens 90 days from their last use. A refresh is one D1 batch (a transaction): it records the
old refresh token as spent, rotates both tokens and marks the account seen, or does none of
these. When two refreshes race with the same token the first wins and the second finds it
spent. Presenting any refresh token the session ever rotated away is treated as theft: the
whole session ends, for every holder. Clients must refresh one at a time. The design behind
this Worker and the steps after it is in [DESIGN.md](DESIGN.md).

**Web sign-in** (herdrup-desktop and the web guest; DESIGN.md §2.3, §2.6). The client opens
`/v1/auth/web/start` in a browser. The Worker keeps the flow (state, nonce, Google's PKCE
verifier, the app's handoff challenge) for 10 minutes and binds it to that browser with the
`__Host-hu_flow` cookie. It then sends the browser to Apple (Services ID, `form_post`, no scope)
or Google (web client, `openid email`, PKCE).

The callback takes the flow, so each state works once, and checks the browser. It then verifies
the ID token, which must carry the flow's nonce and name the web client. Google's code is
exchanged with `GOOGLE_WEB_CLIENT_SECRET`, and only the `id_token` is read: the access token is
dropped unread. Then:

- **App** (`client=app`): the browser goes to `herdrup://account#code=<code>`. The app redeems
  the code once, within 2 minutes, with `POST /v1/auth/handoff` and the verifier behind its
  challenge. A grabbed URL is useless without the verifier.
- **Web guest** (`client=web`): the callback sets `__Host-hu_refresh`
  (`HttpOnly; Secure; SameSite=Strict; Path=/`, 90 days) and returns to
  `https://guest.herdrup.app/web/?account=1`. From then on the page refreshes and signs out with
  that cookie; the refresh token itself never reaches the page. The cookie counts only on
  requests with `Origin: https://guest.herdrup.app`.

CORS allows exactly that origin, with credentials, on the endpoints the page calls: refresh,
signout, account, devices, statements, sync. It never allows `*`. Without
`GOOGLE_WEB_CLIENT_SECRET`, the Google web flow answers `503 provider_not_configured`, and
Apple's still works.

**Devices.** A device is one install's guest key: the X25519 key it already proves to hosts in
every Noise IK handshake. Only its public half is sent, and the device proves it holds the
private half against a fresh challenge key E and salt:

```
k   = X25519(d, E)                                   refuse an all-zero k (low-order key)
mk  = HKDF-SHA256(ikm = k, salt, info = "herdrup account enrol v1", 32 bytes)
mac = HMAC-SHA256(mk, "herdrup-enrol-v1|" + account_id + "|" + device_pub + "|" + challenge_id)
```

All values are unpadded base64url. `test/vectors/enrol-v1.json` pins this for the app, desktop
and web clients. A session enrols one device, once, so a stolen access token can't bind the
thief's key; a key belongs to one account at a time (`409 device_in_other_account`); an account
has at most 20 devices (`403 too_many_devices`). Removing a device ends the sessions bound to it.

**Statements.** A statement says "device key D belongs to account X" to one host, for 10
minutes: a compact JWS with header `{"alg":"EdDSA","typ":"herdrup-device+jwt","kid"}` and
payload `{v:1, iss:"https://accounts.herdrup.app", aud:<host_id>, sub, dev:<device_pub>, iat, exp}`.
`sub` is the account's id for that host alone (the first 22 base64url characters of an HMAC of
account id and host id), so hosts can't tell they share a guest; host ids are never stored.
`dev` is always the session's own device. Hosts verify the signature against
`/.well-known/jwks.json`, check `aud` against their own host id, `dev` against the Noise key and
the times with 60 s skew. `test/vectors/statement-v1.json` holds golden statements for herdr's
tests. A removed device gets no new statements, so its access ends within 10 minutes.

**Sync.** An item is `{collection, id, rev, updated_ms, deleted, body}`. The collections are
`hosts`, `prompts`, `settings` (one item per key), `agent_prefs` and `shares`. Each has an
allowlist schema in `src/sync.ts`; DESIGN.md §5.1 and §5.5 list the fields, ids and synced
settings keys. Any other field, a malformed value or a key that isn't synced refuses the whole
push with `400 {"error":"invalid_item","index","field"}`. The stored body is re-serialised from
the validated fields. Secrets (keys, passwords, pins, invite links, tokens) have no field to
travel in.

- **Order:** every write takes the account's next revision in the push's one D1 batch, so the
  last write to reach the server wins. A pull returns the items changed after `since`, in
  revision order. While `more` is true, send the answer's opaque `cursor` back
  (`?cursor=<cursor>`) for the next page. The last page's `rev` is the next `since`.
- **Conflicts:** a change with `base_rev` is written only while the item is still at that
  revision (`0` = create only). Otherwise it is listed in `conflicts[]` with the server's copy.
  Background pushes leave `base_rev` out.
- **Deletes** leave a tombstone (`deleted: true`, `body: null`). The hourly cron prunes
  tombstones after 90 days, and a push keeps the newest 2,000 per account. A pull that may have
  missed a pruned delete, or whose cursor is newer than the account, gets `410 reset_required`.
  The client then pulls from 0 and drops what the server doesn't list. A full pull pages past a
  floor that was already there when it began (DESIGN.md §5.5).
- **Caps:** 16 KB per item and 100 changes or 256 KB per push (`413 too_large`). Per account:
  2,000 live items, 1 MB of bodies, and 200 hosts, 500 prompts, 300 settings, 1,000 agent
  prefs and 500 shares (`403 quota`). A push that would pass a cap rolls back whole.

## Privacy

- **Stored:** an account id (16 random bytes) with its creation time and last-seen day; for each
  sign-in identity, `HMAC-SHA256(key, "<provider>|<sub>")`, never the provider's user id itself;
  each session's SHA-256 token hashes, platform and times, and the SHA-256 of each refresh token
  **Never stored:** names, emails, ID tokens, tokens in the clear.
- **Devices:** each device's id, public key, name, platform, creation time and the day of its
  last statement. Host ids and statements are never stored.
- **Sync:** the allowlisted fields of each synced item (DESIGN.md §5), its revision and the time
  the server stored it, plus tombstones of deleted items for 90 days. Item bodies are never logged.
- **Email:** Apple is asked for nothing. Google's email is read from the ID token and handed back
  once as `display_hint`, then dropped. In the desktop's web sign-in it waits up to 2 minutes
  for the handoff, sealed under a key only the `herdrup://` code opens, so D1 never holds it
  readably.
- **Web sign-in:** each flow keeps hashes of its state and browser cookie, its nonce and
  Google's PKCE verifier for 10 minutes, and each handoff a code hash for 2 minutes. Both go at
  first use or expiry (hourly cron). Google's access token is never stored.
- **Logs:** a log line is `{endpoint, outcome}`, written only for `not_configured`,
  `rate_limited`, `keys_unavailable` and `internal_error`. Never tokens, nonces, provider ids or
  their hashes, emails, account, session or device ids, device keys, host ids, IPs, bodies or
  URLs. `wrangler.toml` turns off Workers Logs (including invocation logs), traces and Logpush.
- **Retention:** spent nonces, spent refresh tokens and enrolment challenges go at their own
  expiry, sessions when their refresh token expires, sync tombstones after 90 days, and accounts
  not seen for 24 months, with their identities, sessions, devices and sync items (hourly cron).
  D1 Time Travel keeps point-in-time history for 7 days on Workers Free (30 on Paid).

## Limits

| Binding | Key | Limit | Covers |
|---|---|---|---|
| `AUTH_IP_LIMIT` | `CF-Connecting-IP` | 20 / 60 s | nonce, sign-in, refresh; checked before the body is read |
| `ACCOUNT_LIMIT` | account id | 120 / 60 s | every authenticated call |
| `STATEMENT_LIMIT` | account id | 30 / 60 s | `/v1/statements`, on top of `ACCOUNT_LIMIT` |
| `ENROL_LIMIT` | account id | 10 / 60 s | device challenge and enrolment, on top of `ACCOUNT_LIMIT` |
| `SYNC_WRITE_LIMIT` | account id | 30 / 60 s | `POST /v1/sync`, on top of `ACCOUNT_LIMIT` |

Bodies are capped at 8 KB for sign-in, 2 KB for devices, 4 KB for statements and 256 KB for
sync pushes; ID tokens at 4 KB; 50 hosts per statement call.

## Configuration

| Name | Kind | Value |
|---|---|---|
| `DB` | D1 | `herdrup-accounts`, EU jurisdiction, id in `wrangler.toml` |
| `APPLE_APP_CLIENT_ID` | var | `com.jerryfane.herdr` |
| `APPLE_WEB_CLIENT_ID` | var | `com.jerryfane.herdr.signin` (the Services ID) |
| `GOOGLE_IOS_CLIENT_ID` | var | `552913387875-ujv6unveo5qtmmbnapogekc5jl8h6olk.apps.googleusercontent.com` (Google Cloud project `themartianapp`; bundle `com.jerryfane.herdr`, team `FXQ5Z9HHY6`) |
| `GOOGLE_WEB_CLIENT_ID` | var | `552913387875-0te8j0cm9tmt5ifai9m8nlc1igdhi844.apps.googleusercontent.com` (same project; redirect `https://accounts.herdrup.app/v1/auth/web/google/callback`) |
| `ACCOUNT_HMAC_KEY` | secret | 32 random bytes, standard base64 |
| `GOOGLE_WEB_CLIENT_SECRET` | secret | the web client's secret, pasted by the owner. The Google web sign-in's code exchange needs it; while unset that flow answers 503 and Apple's still works |
| `STATEMENT_KEY_A`, `STATEMENT_KEY_B` | secret | Ed25519 statement signing keys, PKCS8 DER in standard base64; two slots for rotation |
| `STATEMENT_KID_A`, `STATEMENT_KID_B` | var | each slot's kid (`[A-Za-z0-9._-]{1,32}`); `STATEMENT_KID_A = "2026-11a"` |
| `STATEMENT_ACTIVE` | var | `A` or `B`: the slot that signs |
| `STATEMENT_REVOKED_KIDS` | var | comma-separated kids never used or published again (after a compromise) |
| `WEB_ORIGIN` | var | `https://guest.herdrup.app`: the only CORS origin, and where the web guest's sign-in returns |

`ACCOUNT_HMAC_KEY` keys the nonces, the identity hashes and the per-host account ids. **Losing
it orphans every account** (no sign-in finds its account again, and every host sees new ids),
so keep a copy outside Cloudflare. Never rotate it in place.

A statement key slot is published in the JWKS once it has both its key and its kid, unless the
kid is revoked. The statement keys are generated straight into the Worker and never copied: a
lost key is rotated, never restored.

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
npx wrangler secret put GOOGLE_WEB_CLIENT_SECRET                                  # paste it when asked
openssl genpkey -algorithm ed25519 -outform DER | base64 | tr -d '\n' | npx wrangler secret put STATEMENT_KEY_A
```

Then `npx wrangler deploy`. The deploy
attaches `accounts.herdrup.app` (`custom_domain = true`); the `herdrup.app` zone must be on the
deploying account. Later migrations go through `wrangler d1 migrations apply … --remote` before
the deploy that needs them.

For step 2 on a Worker that already runs step 1: apply the migrations (`0002_devices.sql`), put
`STATEMENT_KEY_A` as above, then deploy.

For step 3: apply the migrations (`0003_sync.sql`), then deploy. It adds the `SYNC_WRITE_LIMIT`
binding (namespace `6984`) and needs no secret.

For step 5's Worker part:

1. Apply the migrations (`0004_web_flows.sql`).
2. Check that `GOOGLE_WEB_CLIENT_SECRET` is set (`npx wrangler secret list`); it was pasted at
   the first deploy.
3. Deploy.
4. Check that the Services ID's return URL is `https://accounts.herdrup.app/v1/auth/web/apple/callback`
   and the Google web client's redirect is `https://accounts.herdrup.app/v1/auth/web/google/callback`
   (DESIGN.md §10).

### Rotate the statement key

Hosts cache the JWKS for an hour and statements live 10 minutes. With slot A active:

1. **Publish the next key** in the idle slot: set `STATEMENT_KID_B` (e.g. `2027-05a`) in
   `wrangler.toml`, deploy, then
   `openssl genpkey -algorithm ed25519 -outform DER | base64 | tr -d '\n' | npx wrangler secret put STATEMENT_KEY_B`.
   Both keys are published; A still signs.
2. **After at least 2 hours**, set `STATEMENT_ACTIVE = "B"` and deploy. B signs; A stays
   published, so statements it signed still verify.
3. **After at least 1 more hour**, `npx wrangler secret delete STATEMENT_KEY_A` and clear
   `STATEMENT_KID_A`. The next rotation goes back the other way.

**After a compromise** (or a suspected one), do steps 1 and 2 at once, delete the old key, and
add its kid to `STATEMENT_REVOKED_KIDS`; keep it listed for at least 30 days. Hosts drop a
revoked kid as soon as they see the list, and a host that can't refresh the JWKS for an hour
accepts no new devices (DESIGN.md §3.4).

## Rollback

- **Bad code:** `npx wrangler deployments list`, then `npx wrangler rollback <version-id>`.
  A rollback across a migration needs the old code to tolerate the new schema; migrations only
  add, so it does.
- **Take accounts offline:** detach `accounts.herdrup.app` in Workers → herdrup-accounts →
  Settings → Domains & Routes. Apps stay signed in locally and retry; guest access and plain
  invites are unaffected.
- **Restore data:** `npx wrangler d1 time-travel restore herdrup-accounts --timestamp <time>`
  (within the Time Travel window). Sync clients whose cursor is then ahead of their account get
  `410 reset_required` and pull everything again.
