# herdrup-accounts

`herdrup-accounts` is the Cloudflare Worker behind HerdrUp's optional accounts (herdrup#698,
epic #696), on `accounts.herdrup.app` with a D1 database. Signing in is optional: signed out,
HerdrUp works exactly as before, and plain guest invites never touch this Worker.

It signs people in with Apple or Google and keeps their sessions (step 1), binds each device's
guest key to the account and signs the short-lived statements hosts check (step 2), syncs
non-secret settings between the account's devices (step 3), and deletes accounts, revoking
Sign in with Apple and following Apple's server-to-server notifications (step 4).
It is a separate Worker from `herdrup-guest`: it holds personal data, its own secrets and its
own deploys, so a bug or rollback here can't drop a guest session.

## API

| Call | Body | Answer |
|---|---|---|
| `GET /v1/health` | | `{ok, version, features: [...]}` (below) |
| `POST /v1/auth/nonce` | | `{nonce, expires_unix}`: valid 10 minutes, spent by one sign-in |
| `POST /v1/auth/apple` | `{id_token, nonce, platform}` | `{account_id, created, access_token, access_expires_in, refresh_token, refresh_expires_in}` |
| `POST /v1/auth/google` | same | same, plus `display_hint` (the Google email, for the device to show) |
| `POST /v1/auth/refresh` | `{refresh_token}`; from the web guest, its cookie | a new token pair; the web guest gets `{account_id, access_token, access_expires_in}` and the rotated cookie |
| `POST /v1/auth/signout` | `Authorization: Bearer <access>`; from the web guest, its cookie | 204 (the web guest's cookie is cleared) |
| `GET /v1/auth/web/start` | `?provider=apple\|google&client=app&platform=<not web>&handoff_challenge=<S256>`, or exactly `?provider=…&client=web` (any other parameter, `handoff_challenge` included, is a 400) | 303 to Apple or Google |
| `POST /v1/auth/web/apple/callback`, `GET /v1/auth/web/google/callback` | from the provider | 303 to `herdrup://account#code=…` or `https://guest.herdrup.app/web/?account=1` (`…#error=` / `?account_error=` on failure) |
| `POST /v1/auth/handoff` | exactly `{code, handoff_verifier}` (no `platform` or `device_name`: the platform was given at start, and devices are named when they enrol) | the same as a native sign-in |
| `GET /v1/account` | `Authorization: Bearer <access>` | `{account_id, created_ms}` |
| `POST /v1/account/delete` | bearer; `{provider, id_token, nonce, authorization_code?}` from a fresh sign-in, or `{handoff_code, handoff_verifier}` from the desktop's web confirmation | `{deleted: true, manual_revoke}` |
| `POST /v1/account/delete/start` | bearer; `{provider, handoff_challenge}` | `{start_url, expires_in: 300}`; the browser opens `start_url` and comes back to `herdrup://account#delete_code=…` (or `#delete_error=…`) |
| `POST /v1/apple/notifications` | `{payload: <Apple's JWS>}` | 204 |
| `POST /v1/devices/challenge` | bearer | `{challenge_id, server_pub, salt, account_id, expires_in}`: 60 s, one use |
| `POST /v1/devices` | bearer; `{challenge_id, device_pub, mac, name, platform}` | 201 `{device}` (200 when the key is already the account's) |
| `GET /v1/devices` | bearer | `{devices: [{id, name, platform, device_pub, created_ms, current, access?}]}`; a browser's `access` is `{state: "waiting"\|"approved"\|"expired", scope?, expires_ms?}` |
| `PATCH /v1/devices/<id>` | bearer; `{name}` | `{device}` |
| `DELETE /v1/devices/<id>` | bearer | 204; that device's sessions end. Any device of the account may remove any other. A browser that had owner access leaves a withdrawal |
| `POST /v1/statements` | bearer; `{hosts: [host_id, … ≤ 50]}` | `{statements: [{host, jws}], exp}` |
| `GET /v1/sync?since=<rev>`, `GET /v1/sync?cursor=<cursor>` | bearer | `{rev, changes: [item, … ≤ 500], more, cursor?, now_ms}`; `410 reset_required`. `now_ms` is D1's clock in ms, read in the page's batch before its rows, on every page |
| `POST /v1/sync` | bearer; `{changes: [{collection, id, base_rev?, deleted?, body?}, … ≤ 100], not_after?}` | `{rev, applied: [{collection, id, rev}], conflicts: [{collection, id, server}], now_ms}`; `409 expired` when D1's clock at the write is past `not_after` (ms, service clock, ≤ 24 h ahead): the whole push writes nothing. Without `not_after`, as before |
| `POST /v1/approvals` | bearer, browser; `{commit}`, or an app device (pair-v1); `{kind: "pair", commit, ssh_pub}` | 201 `{id, expires_in: 600}`; replaces the requester's request; `403 not_a_browser`, `403 not_native` (a browser asking to pair), `429 too_many_requests`. A pair request alerts the account's other iOS devices (`PUT /v1/devices/self/push`) |
| `GET /v1/approvals` | bearer, approver | `{requests: [{id, browser: {device_id, device_pub, name, platform, created_ms}, commit, claimed: "no"\|"you"\|"other", expires_in}]}`: browser requests only |
| `GET /v1/approvals?kind=pair` | bearer, approver | `{requests: [{id, kind: "pair", device: {device_id, device_pub, name, platform, created_ms}, commit, ssh_pub, claimed, expires_in}]}`: other app devices' pair requests |
| `GET /v1/approvals?kind=any` | bearer, approver | both lists in one: pair requests as above, browser requests with `kind: "browser"` added |
| `POST /v1/approvals/<id>/claim` | bearer, approver; `{nonce_t}` | `{state: "claimed"}`; `409 already_claimed`, `403 own_request` |
| `GET /v1/approvals/<id>` | bearer, the requester or an approver | `{state: "waiting"\|"claimed"\|"revealed"\|"denied"\|"approved"\|"expired"\|"cancelled" (pair only), expires_in, outcome_stored?: true, approver?: {device_pub, name}, nonce_t?, nonce_b?}`, and for a pair request `kind: "pair", commit, ssh_pub, device: {device_id, device_pub, name, platform}`; `expired` is stored before it is answered, so it is final. `outcome_stored: true` comes with every `expired`, `approved`, `denied` or `cancelled` read from the stored row and never while the request is pending; a Worker that predates it never sends it, so treat a state as final only from a read that carries it |
| `POST /v1/approvals/<id>/reveal` | bearer, the requester; `{nonce_b}` | `{state: "revealed"}`; `409 not_claimed`, `400 reveal_mismatch` (the request ends) |
| `POST /v1/approvals/<id>/finish` | bearer, the claimant; `{outcome: "approved", scope, expires_ms, seq, sealed}`, for a pair request `{outcome: "approved", seq (≥ 1), sealed}`, or `{outcome: "denied"}` | `{state}`; `409 not_revealed`, `409 stale_seq` |
| `PUT /v1/approvals/<id>/envelope` | bearer, a pair request's claimant; `{seq, sealed}` | `{seq}`, for 10 minutes after an approved finish; `410 expired`, `410 cancelled`, `409 not_approved`, `409 stale_seq` |
| `POST /v1/approvals/<id>/cancel` | bearer, a pair request's requester, before the finish | `{state: "cancelled"}`; every later step answers `410 cancelled`; `409 already_finished` |
| `PUT /v1/browsers/<device_id>/envelope` | bearer, an approver the browser verified; `{scope, expires_ms, seq, sealed}` | `{seq}`; `403 not_approver`, `409 stale_seq` |
| `GET /v1/browsers/self` | bearer, browser | `{access?: {state, scope?, expires_ms?}, envelopes: [{approver_pub, seq, sealed}]}` |
| `GET /v1/pairs/self` | bearer, app device | `{request?: {id, state, expires_in, outcome_stored?}, envelopes: [{request_id, ssh_pub, approver_pub, approver_name, seq, sealed}]}`; `403 not_native` |
| `PUT /v1/devices/self/push` | bearer, iOS or iPadOS device; `{capability: "hpr1.…"}` (PushRelay device capability) | 204; `403 not_ios` |
| `DELETE /v1/devices/self/push` | bearer, iOS or iPadOS device | 204 |
| `GET /v1/withdrawals` | bearer, approver | `{withdrawals: [{device_pub, fingerprint, created_ms}]}` |
| `GET /.well-known/jwks.json` | | `{keys, revoked_kids}`, `Cache-Control: public, max-age=3600` |

`platform` is one of `ios`, `ipados`, `macos`, `windows`, `linux`, `web`. Errors are
`{"error": "<code>"}`; a refused ID token adds `reason` (`wrong_audience`, `expired`, …).

**Features.** `GET /v1/health` lists what the live Worker can do. The apps ship separately, so
they show a feature only when it is listed. The names are stable; a name is never reused for
something else.

| Feature | Listed when |
|---|---|
| `native_sign_in`, `devices`, `statements`, `sync`, `delete`, `web_approve`, `approval_expiry_final`, `pair_v1` | always (this build); `web_approve` is the browser approval (approve-v1); `approval_expiry_final` says a reported `expired` is stored and final: no finish that started earlier commits after it; `pair_v1` is pairing an app device by code (DESIGN.md §13) with pair-request pushes |
| `native_sign_in_google` | `GOOGLE_IOS_CLIENT_ID` is set: the iOS app may offer its own Google sign-in (ASWebAuthenticationSession + PKCE against the iOS client), which needs no secret |
| `web_sign_in_apple` | `APPLE_WEB_CLIENT_ID` is set |
| `web_sign_in_google` | `GOOGLE_WEB_CLIENT_ID` and `GOOGLE_WEB_CLIENT_SECRET` are both set |
| `web_delete` | `web_sign_in_apple` or `web_sign_in_google` is listed: the desktop may confirm a deletion through the web flow |
| `apple_revoke` | `APPLE_SIWA_P8` and `APPLE_KEY_ID` are both set and the key parses (the revoke's own loader); otherwise deletion answers `manual_revoke: true` for Apple |

Each flag only says whether something is configured. No value of a var or secret is returned.

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
`__Host-hu_flow` cookie: one secret per browser, shared by all its pending sign-ins and never
cleared by a callback, so two sign-ins in one browser don't break each other. It then sends the
browser to Apple (Services ID, `form_post`, no scope)
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

CORS allows exactly that origin, with credentials, on the calls the page makes (by route and
method): health, refresh, signout, account, devices, statements, sync, and the browser's side of
approval (`POST /v1/approvals`, `GET /v1/approvals/<id>`, `…/reveal`, `GET /v1/browsers/self`;
not the approver's list, claim, finish, envelope or withdrawals). It never allows `*`. Without
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

All values are unpadded base64url, and `device_pub` must be canonical (43 characters whose
re-encoding is the input; any other spelling of the same 32 bytes is `400 bad_request`), so a key
has one spelling everywhere. `test/vectors/enrol-v1.json` pins this for the app, desktop
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

**Browser approval** (protocol `approve-v1`; DESIGN.md §12). A browser (a device with platform
`web`) asks one of the account's other devices, the approver, to let it reach the owner's
machines. Each side commits before it learns the other's randomness, and both compute a 4-digit
code over both keys, which the user types on the approver:

```
commit = SHA-256("herdrup-approve-v1|commit" ‖ 0x00 ‖ B ‖ nonce_b)
h      = SHA-256("herdrup-approve-v1|sas"    ‖ 0x00 ‖ B ‖ T ‖ nonce_b ‖ nonce_t)
code   = uint32_be(h[0..4]) mod 10000, 4 digits, zero-padded
```

1. The browser posts `commit` (no code shown yet).
2. The approver claims the request with `nonce_t`; the service records the approver from the
   session's device, never from the body.
3. The browser reads `T` and `nonce_t`, then reveals `nonce_b`; the service refuses (and ends
   the request) when it doesn't open the commit. The browser shows the code.
4. The approver reads `nonce_b`, checks the commit itself, and approves only when the typed code
   matches. It writes the grants on each machine over SSH and finishes with the machine list
   sealed to the browser (X25519 between the two keys, HKDF-SHA256, AES-256-GCM with `seq` in the
   AAD), plus the scope and expiry it granted.

Every binary field is unpadded base64url. Each step runs once, in order, within 10 minutes; a
new request replaces the browser's live one. The service never sees the code, stores the
envelope as sent and returns it only to that browser (`GET /v1/browsers/self`), and accepts an
envelope only with a higher `seq` per approver. A finish (or envelope) is one D1 batch: a
failure leaves the request as it was, so the approver can retry, and the shown access changes
only with the envelope. It can't grant anything: grants exist only on
the machines, and the `access` state Devices shows is what the approver reported.
`test/vectors/approve-v1.json` is herdrup-desktop's vector (`internal/account/testdata/approve-v1-local.json`),
which the tests regenerate byte for byte.

The first claim of a browser's request marks its device (an approver may write grants from then
on); a later request or the approver's removal doesn't clear the mark. Removing a marked browser
records a **withdrawal** of its key
for 35 days: approvers read `GET /v1/withdrawals` and remove its grants from their machines, and
no statement is issued for that key on the account meanwhile (`403 device_withdrawn`), even if the
browser signs in and enrols again, until an approver approves it again by code.

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

**Deletion.** The app confirms with a fresh sign-in, with the same provider and a fresh nonce.
The ID token must belong to the session's own account (`403 wrong_account`). Then every row of
the account goes in one D1 batch: sync items, devices, sessions and their spent refresh tokens,
challenges, pending web-sign-in handoffs, approval requests, browser access, envelopes and
withdrawals, identities and the account. Every token of the account fails from then on, and no
statement is issued again.

The desktop never holds an ID token, so it confirms in the browser instead (DESIGN.md §6.6). It
asks `POST /v1/account/delete/start` for a single-use ticket URL, bound to its session and
account, valid 5 minutes. The web sign-in at that URL must be an identity already linked to the
account (`#delete_error=wrong_account` otherwise; it never makes an account). It hands back a
delete code, single use and valid 5 minutes, that only this session redeems, with the verifier
behind its challenge: `POST /v1/account/delete {handoff_code, handoff_verifier}`. For Apple, the
sign-in's authorization code is kept (sealed under the delete code) for the revoke. Sign-in and
delete codes live in separate tables and never stand in for each other.

For Apple, the sign-in's `authorization_code` is then exchanged and its refresh token revoked at
`appleid.apple.com`, with the ID token's `aud` as `client_id` and a 5-minute ES256 client secret
the Worker signs from `APPLE_SIWA_P8`. Nothing is undone when Apple doesn't confirm.
`manual_revoke: true` says the revoke didn't happen (no code, no key, or Apple refused), and the
app shows Settings → Apple Account → Sign in with Apple → HerdrUp → Stop using.

Apple's `consent-revoked` and `account-deleted` notifications delete the account the same way,
after their JWS checks out (Apple's keys, `iss`, `aud` = one of our Apple client ids). An event
from before the identity signed in deletes nothing. `test/deletion.test.ts` checks that deletion
covers every table the migrations create.

## Privacy

- **Stored:** an account id (16 random bytes) with its creation time and last-seen day; for each
  sign-in identity, `HMAC-SHA256(key, "<provider>|<sub>")`, never the provider's user id itself;
  each session's SHA-256 token hashes, platform and times, and the SHA-256 of each refresh token
  **Never stored:** names, emails, ID tokens, tokens in the clear.
- **Devices:** each device's id, public key, name, platform, creation time and the day of its
  last statement. Host ids and statements are never stored.
- **Sync:** the allowlisted fields of each synced item (DESIGN.md §5), its revision and the time
  the server stored it, plus tombstones of deleted items for 90 days. Item bodies are never logged.
- **Browser approval:** each browser's request (commit, nonces, approver) for up to an hour, the
  scope and expiry an approver reported, the sealed envelopes (ciphertext the service can't
  open), and the key and fingerprint of a removed browser for 35 days.
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
  Approval requests go an hour after they start (10 minutes after they finish), withdrawals after
  35 days, and a browser's access and envelopes with the device.
  Deleting the account (in the app, or Apple's revoke notification) removes all of it at once;
  Apple's tokens are never stored.
  D1 Time Travel keeps point-in-time history for 7 days on Workers Free (30 on Paid).

## Limits

| Binding | Key | Limit | Covers |
|---|---|---|---|
| `AUTH_IP_LIMIT` | `CF-Connecting-IP` | 20 / 60 s | nonce, sign-in, refresh; checked before the body is read |
| `ACCOUNT_LIMIT` | account id | 240 / 60 s | every authenticated call |
| `STATEMENT_LIMIT` | account id | 30 / 60 s | `/v1/statements`, on top of `ACCOUNT_LIMIT` |
| `ENROL_LIMIT` | account id | 10 / 60 s | device challenge and enrolment, on top of `ACCOUNT_LIMIT` |
| `SYNC_WRITE_LIMIT` | account id | 30 / 60 s | `POST /v1/sync`, on top of `ACCOUNT_LIMIT` |
| `DELETE_IP_LIMIT` | `CF-Connecting-IP` | 5 / 60 s | account deletion and Apple notifications; checked before any other work |
| `APPROVAL_LIMIT` | account id | 30 / 60 s | every approval route (`/v1/approvals…`, `/v1/browsers/…`, `/v1/withdrawals`), on top of `ACCOUNT_LIMIT`. Also at most 10 approval requests per account per hour (`429 too_many_requests`) and 20 envelopes per browser |

Bodies are capped at 8 KB for sign-in, deletion and Apple notifications, 2 KB for devices, 4 KB
for statements and approval steps, 24 KB for `finish` and envelopes (a sealed envelope at most
16 KB) and 256 KB for sync pushes; ID tokens at 4 KB; 50 hosts per statement call.

## Configuration

| Name | Kind | Value |
|---|---|---|
| `DB` | D1 | `herdrup-accounts`, EU jurisdiction, id in `wrangler.toml` |
| `APPLE_APP_CLIENT_ID` | var | `com.jerryfane.herdr` |
| `APPLE_WEB_CLIENT_ID` | var | `com.jerryfane.herdr.signin` (the Services ID) |
| `APPLE_TEAM_ID` | var | `FXQ5Z9HHY6` |
| `APPLE_KEY_ID` | var | the Sign in with Apple key's Key ID (10 characters), filled in by the owner |
| `APPLE_SIWA_P8` | secret | the Sign in with Apple key: the `.p8` file as downloaded. Signs the client secrets for Apple's revoke; without it (or its Key ID) deletion still deletes and answers `manual_revoke: true` |
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
npx wrangler dev         # local Worker; src/index.ts must export only its handler (VERSION is in src/version.ts)
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

For step 4 (no migration):

1. Set `APPLE_KEY_ID` in `wrangler.toml`.
2. Put the key straight from the downloaded file:
   `npx wrangler secret put APPLE_SIWA_P8 < AuthKey_<KeyID>.p8`.
3. Deploy. This adds the `DELETE_IP_LIMIT` binding (namespace `6986`).
4. Register `https://accounts.herdrup.app/v1/apple/notifications` as the server-to-server
   notification endpoint of `com.jerryfane.herdr` (DESIGN.md §10).

If the key is ever exposed, revoke it in Apple Developer → Keys, make a new one, and put the
new `.p8` and Key ID.

For step 5's Worker part:

1. Apply the migrations (`0004_web_flows.sql`).
2. Check that `GOOGLE_WEB_CLIENT_SECRET` is set (`npx wrangler secret list`); it was pasted at
   the first deploy.
3. Deploy.
4. Check that the Services ID's return URL is `https://accounts.herdrup.app/v1/auth/web/apple/callback`
   and the Google web client's redirect is `https://accounts.herdrup.app/v1/auth/web/google/callback`
   (DESIGN.md §10).

For the desktop's web deletion: apply the migrations (`0005_web_delete.sql`), then deploy. No new
secret, var or binding.

For browser approval (approve-v1): apply the migrations (`0006_browser_access.sql`), then
deploy. It adds the `APPROVAL_LIMIT` binding (namespace `6987`) and needs no secret or var.
From this build on, enrolment refuses a non-canonical `device_pub`. Before deploying, check that
no stored key is non-canonical (the answer should be `0`); if any are, decide what to do with
them before rewriting rows:

```sh
npx wrangler d1 execute herdrup-accounts --remote --command "SELECT COUNT(*) FROM devices WHERE length(device_pub) <> 43 OR substr(device_pub, 43, 1) NOT IN ('A','E','I','M','Q','U','Y','c','g','k','o','s','w','0','4','8')"
```

For the stored approval expiry (`approval_expiry_final`): apply the migrations
(`0007_approval_expiry.sql`, which rebuilds `approval_requests` with the same rows so
`outcome` may be `expired`), then deploy. No new secret, var or binding. The migration also works
with the previous build, so apply it first.

For pair-v1 (`pair_v1`): apply the migrations (`0008_pair.sql`, which rebuilds
`approval_requests` with the same rows, its new columns defaulting every row to a browser
request, and an `outcome` that may also be `cancelled`, and adds the `push_capabilities` table),
then deploy. It adds the var `PUSH_RELAY_URL` (`https://push.herdrup.app`) and needs no secret
or binding. The migration also works with the previous build, so apply it first.

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
