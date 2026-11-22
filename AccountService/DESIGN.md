# HerdrUp accounts, step 2: the account service (#698)

Written 19 Nov 2026 for https://github.com/themartianapp/herdrup/issues/698, part of epic #696
(siblings #699, #700, #701; herdr side jerryfane/herdr#440). Approved by the owner on 19 Nov
(§11); PR #744 builds step 1 (§9) and was revised after review on 19 Nov (§2.4, §2.5, §1.3).

The design is based on this code: herdrup `adca1d8` (GuestRelay/, PushRelay/, App/, Sources/HerdrKit, project.yml),
herdr `0ed26ed` (src/guest/store.rs, src/guest/link/), herdrup-desktop `8db42a1`
(src/webguest/identity.ts, internal/guest, vendor mygo Secrets), and herdrup-web (content/privacy.txt).

Owner decisions this design follows (16 Nov): secrets stay on the device (option A); guests keep plain
invite links, and signing in adds "on all my devices"; the owner revokes once per person; mockup picks
1B, 2A, 3B, 4B.

---

## 0. Summary

- A new Worker, `herdrup-accounts`, on `accounts.herdrup.app`, with a D1 database. It lives in
  `AccountService/` next to `GuestRelay/` and `PushRelay/`. It has the same rules as the relay:
  logs off, no request URLs, tokens or emails in logs, and per-IP rate limits checked before any work.
- Sign-in uses Apple (native `ASAuthorization` in the iOS/iPadOS app and in the same app on Mac;
  Services ID web flow for herdrup-desktop and the web guest) and Google (OIDC: a native iOS
  client with PKCE, plus the web client for desktop and web). The Worker verifies the ID token
  against the provider's JWKS. It keeps only a keyed hash of the provider `sub`, never an email.
- Sessions use opaque tokens: a 1-hour access token, and a 90-day refresh token that rotates on
  every use. The refresh token lives in the Keychain (this device only), the OS credential store
  on desktop, or an HttpOnly cookie on the web.
- A device is its existing guest X25519 key, which is never synced. Enrolment proves possession
  with an X25519 challenge, so it also works with the web guest's non-extractable WebCrypto key.
- Statements are 10-minute Ed25519 JWS saying "device key D belongs to account X, for host H".
  `sub` is a pairwise id per host. Hosts fetch the public keys from `/.well-known/jwks.json` and
  cache them, and rotation goes by `kid`. Removing a device stops its statements, and its access
  ends within 10 minutes.
- On herdr: `GuestRecord.account` and `GuestRecord.devices`; the hello gains `account` (the
  statement); revoke by person; a host-side refresh of the statement. The relay changes only its
  web CSP.
- Sync (option A) covers servers, prompts, allowlisted settings, app-side pins and hides, and the
  guest's share list. Each item is server-ordered last-writer-wins, settings go one item per key,
  deletes leave tombstones, and the server checks every item against an allowlist schema.
  Secrets are never uploaded.
- Deletion runs in the app and removes every D1 row at once. Apple's `/auth/revoke` runs with a
  fresh authorization code, so no Apple tokens are ever stored. Shares bound to the account drop
  on hosts within 10 minutes.
- At the expected size it fits Cloudflare's free tier. Usage passes the free tier at roughly
  2–3k daily active signed-in devices; then Workers Paid ($5/month) is needed (§1.4).
- The work is 8 PRs (§9). Only the owner can do the items in §10. The owner's decisions (19 Nov) are in §11.

---

## 1. Deployment

### 1.1 A separate Worker

| | `herdrup-guest` (exists) | `herdrup-accounts` (new) |
|---|---|---|
| Domain | `guest.herdrup.app` (+ old themartian name) | `accounts.herdrup.app` |
| Holds | Ciphertext pipes, sealed invite blobs, crash reports | Personal data: account ids, devices, sync items |
| Storage | Durable Objects (SQLite), R2 | D1 `herdrup-accounts` |
| Secrets | `CRASH_ADMIN_TOKEN` | HMAC root key, statement signing key, Google client secret, Apple client secrets |
| If it is down | Guest access stops | Plain invites and connected hosts keep working; only sign-in, sync and new statements stop |

Why it is separate from `herdrup-guest`:

1. **Blast radius.** A bug or rollback in accounts must not drop live guest sessions. The relay
   README notes that a rollback can't cross a Durable Object migration, so the relay's deploys
   should stay rare.
2. **Different data, different rules.** The relay has a strong claim: it "never sees plaintext".
   D1 with personal data and the Apple key do not belong in the Worker that pipes those streams.
   Keeping them apart keeps each claim simple and each secret set small, so each Worker has the
   least privilege it needs.
3. **"Signed out, nothing changes".** Plain invites must work with the account service offline.
   With two Workers this holds by construction.
4. **Precedent.** `herdrup-push` is already its own Worker. Small helpers (`readCapped`, `log`,
   `json`) are copied, not shared through a package, as PushRelay does.

The web guest is served from `guest.herdrup.app/web/`. `accounts.herdrup.app` is the same site
(`herdrup.app`), so the web guest can use a SameSite cookie for its refresh token (§2.5).

### 1.2 Layout and bindings (sketch)

```
AccountService/
  wrangler.toml            name = "herdrup-accounts", routes accounts.herdrup.app (custom_domain)
  migrations/0001_init.sql
  src/index.ts             router + scheduled() cleanup
  src/jwt.ts src/jwks.ts   compact JWS parse/verify (RS256 in, EdDSA out), JWKS cache
  src/auth/{apple,google,web,sessions}.ts
  src/devices.ts src/statements.ts src/sync.ts src/deletion.ts src/apple_notify.ts
  test/…                   vitest-pool-workers, as GuestRelay
```

`wrangler.toml` copies the relay's rules:

- `logpush = false`.
- `[observability] enabled = false`, with logs, `invocation_logs` and traces all off. The web
  sign-in callback carries `code` and `state` in its URL or body, just as invite links carry
  their secret.
- `[[d1_databases]] binding = "DB"`.
- `[[ratelimits]]` with namespaces `6981`–`6986` (§8).
- `[triggers] crons = ["17 * * * *"]`: one hourly cleanup. The free plan allows 5 cron triggers
  per account, and the guest relay uses none.
- `[vars]`, all public: `APPLE_APP_CLIENT_ID = "com.jerryfane.herdr"`,
  `APPLE_WEB_CLIENT_ID` (the Services ID), `APPLE_TEAM_ID = "FXQ5Z9HHY6"`, `APPLE_KEY_ID`,
  `GOOGLE_IOS_CLIENT_ID`, `GOOGLE_WEB_CLIENT_ID`, `STATEMENT_KID_A`, `STATEMENT_KID_B`,
  `STATEMENT_ACTIVE` (`A` or `B`), `STATEMENT_REVOKED_KIDS` (comma list, §3.4),
  `WEB_ORIGIN = "https://guest.herdrup.app"`.

### 1.3 D1 schema (0001)

| Table | Columns (PK first) | Notes |
|---|---|---|
| `accounts` | `id` (22-char b64url of 16 random bytes), `created_ms`, `last_seen_day`, `sync_rev`, `sync_floor`, `sync_items`, `sync_bytes`, `sync_tombstones` | `last_seen_day` is written at most once a day; the `sync_*` counters are kept by triggers (§5.5, migration 0003) |
| `identities` | `(provider, subject_hash)`, `account_id`, `created_ms` | `subject_hash = HMAC-SHA256(K_subject, provider‖sub)`; a raw `sub` is never stored |
| `devices` | `id`, `account_id`, `device_pub` (32 B, UNIQUE), `name` (≤64), `platform` (enum), `created_ms`, `last_statement_day` | A device key belongs to at most one account |
| `sessions` | `id`, `account_id`, `device_id` (nullable until enrolment), `access_hash`, `access_exp_ms`, `refresh_hash`, `refresh_exp_ms`, `platform`, `created_ms` | Token hashes are SHA-256 of 32 random bytes; one row is one session family (§2.5) |
| `spent_refresh_tokens` | `(session_id, token_hash)`, `exp_ms` | Every refresh token the session rotated away, until that token's own expiry; reuse of any of them revokes the session (§2.5) |
| `used_nonces` | `nonce_hash`, `exp_ms` | Single use of sign-in nonces |
| `enrol_challenges` | `id`, `account_id`, `session_id`, `server_pkcs8`, `salt`, `exp_ms` | 60 s; bound to the session that asked; deleted when used |
| `web_flows` | `state_hash`, `provider`, `client` (app\|web), `platform`, `browser_hash`, `nonce`, `pkce_verifier`, `handoff_challenge`, `exp_ms` | 10 min; taken by its callback (migration 0004, §2.6) |
| `handoffs` | `code_hash`, `account_id`, `handoff_challenge`, `platform`, `created`, `display_hint` (sealed), `exp_ms` | 2 min, single use (§2.6) |
| `sync_items` | `(account_id, collection, item_id)`, `rev`, `updated_ms`, `deleted`, `body` (JSON) | Unique index `(account_id, rev)` |
| `sync_usage` | `(account_id, collection)`, `items` | Live items per collection, against its cap (§5.5) |

Every table that holds account data has an `account_id` column. That makes deletion one batch
(§6), and a test can sweep every table for leftovers.

The hourly cron deletes expired nonces, challenges, flows, handoffs and sessions, plus
tombstones older than 90 days. It also deletes accounts not seen for 24 months (owner decision, §11).

### 1.4 Free-tier limits and expected usage

| Limit (Workers Free) | Value | Our use |
|---|---|---|
| Worker requests | 100,000/day **account-wide** (relay, push and accounts together) | ~25/day per active signed-in device (below) |
| CPU per request | 10 ms | RS256 verify, Ed25519 sign and X25519 run natively in WebCrypto at well under 1 ms. JWKS stay cached. |
| D1 rows read / written | 5 M / 100 k per day | A request reads 1–3 rows. Writes are refresh rotations, sync pushes and sign-ins. |
| D1 size | 500 MB per database (Free), 10 GB (Paid) | ~60 KB per typical account, so ~8k accounts; the 1 MB per-account cap is the worst case |
| D1 queries per invocation | 50 (Free) | Deletion and sync push use `db.batch()`, which counts as one query |
| Time Travel | 7 days (Free), 30 days (Paid) | Deleted rows stay in point-in-time backups this long. The privacy policy says so (§7). |

Expected requests for each active signed-in device per day:

| Call | Count |
|---|---|
| Access-token refresh | ~3 |
| Sync pull on foreground | ~10 |
| Sync push | ~3 |
| Statement batches | ~6 (one per connect, or every ~8 min while a guest share is live) |
| Account screen | ~1 |
| **Total** | **≈ 25** |

At 1,000 daily active devices that is ~25k requests a day, which leaves room for the relay
under 100k. **The trigger to buy Workers Paid ($5/month: 10M requests, 10 GB D1)** is any of:

- requests above 70k/day account-wide for a week;
- the D1 database above 400 MB;
- daily writes above 70k.

The Worker publishes no counters. The owner reads them from the Cloudflare dashboard, with the
same Account Analytics token the relay README uses.

---

## 2. Sign in

### 2.1 Flows per platform

| Platform | Apple | Google |
|---|---|---|
| iOS / iPadOS app; the same app on Mac ("Designed for iPad", same bundle id `com.jerryfane.herdr`) | Native `ASAuthorizationAppleIDProvider`, `requestedScopes = []`, `nonce` from the Worker. ID token `aud` = `com.jerryfane.herdr`. | `ASWebAuthenticationSession` + PKCE against the Google **iOS client** (custom scheme `com.googleusercontent.apps.<id>:/oauth2redirect`). The app exchanges the code at Google (an iOS client has no secret). ID token `aud` = iOS client id. No Google SDK. |
| herdrup-desktop (macOS, Windows, Linux) | Web flow through the Worker (§2.3). Callback to `herdrup://account#code=…`. | Same web flow, with the Google **web client**. |
| Web guest (`guest.herdrup.app/web`) | Web flow; the session lands in an HttpOnly cookie | Same |

Scopes:

- **Apple:** none. We never receive a name or email from Apple, so Hide My Email and the private
  relay address don't matter. We never send email.
- **Google:** `openid email`. The email exists only so the app can show "Signed in as
  …@gmail.com" to people with several Google accounts. The Worker passes it to the client once,
  as `display_hint`, and never stores or logs it (§11).

### 2.2 Native token sign-in

1. `POST /v1/auth/nonce` returns `{nonce, exp}`. The nonce is stateless:
   `b64url(exp_s ‖ 16 random bytes ‖ HMAC(K_nonce, exp_s ‖ random)[0..16])`, valid 10 minutes.
2. The app passes `nonce` to Apple (`request.nonce`) or Google (the `nonce` auth parameter).
3. `POST /v1/auth/apple` or `/v1/auth/google` with `{id_token, nonce, device_name, platform}`.
4. The Worker verifies the token (§2.4) and consumes the nonce by inserting its hash into
   `used_nonces`. A conflict means a replay, answered `401 nonce_used`.
5. It finds the account by `identities(provider, subject_hash)` or creates one (`created: true`
   in the response), then opens a session (§2.5).

### 2.3 Web and desktop flow through the Worker

1. The desktop makes a random `handoff_verifier` and opens
   `GET /v1/auth/web/start?provider=apple|google&client=app&platform=<its platform>&handoff_challenge=S256(verifier)`
   in the system browser. The web guest navigates at the top level to
   `GET /v1/auth/web/start?provider=apple|google&client=web`, with nothing else: it gets no
   handoff, and a `handoff_challenge` or `platform` with `client=web` is refused (`400`), not
   ignored.
2. The Worker stores a `web_flows` row: `state`, `nonce`, the Google PKCE verifier and the
   handoff challenge. It then redirects:
   - Apple: `https://appleid.apple.com/auth/authorize?client_id=<Services ID>&redirect_uri=https://accounts.herdrup.app/v1/auth/web/apple/callback&response_type=code%20id_token&response_mode=form_post&state&nonce`.
     There is no `scope`. The `id_token` arrives in the `form_post`, so **no Apple client
     secret is needed to sign in**.
   - Google: `https://accounts.google.com/o/oauth2/v2/auth?client_id=<web client>&redirect_uri=https://accounts.herdrup.app/v1/auth/web/google/callback&response_type=code&scope=openid%20email&state&nonce&code_challenge(S256)`.
     The Worker exchanges the code at `https://oauth2.googleapis.com/token` with the client
     secret and PKCE verifier, keeps only the `id_token`, and drops the access token.
3. The callback looks up and deletes the `state` row, verifies the ID token (§2.4), and finds or
   creates the account.
   - `client=app`: the Worker stores a `handoffs` row and redirects to
     `herdrup://account#code=<32 B>`. The client then calls
     `POST /v1/auth/handoff {code, handoff_verifier}`. If another app grabbed the custom-scheme
     URL, it still can't redeem the code without the verifier.
   - `client=web`: the Worker sets the refresh cookie (§2.5) and redirects to
     `https://guest.herdrup.app/web/?account=1`.

The desktop already handles `herdrup://pair#` and `herdrup://guest-invite#` links
(app/desk_pairing.go, docs/DESIGN.md §pairing), so `herdrup://account#` is one more route there.
§2.6 has the details step 5 settled.

### 2.4 Verifying ID tokens in the Worker

These steps apply to both providers:

- Accept only a compact JWS with 3 parts, `alg = RS256`, and a `kid` present. Reject `none`,
  HS*, and any other `alg` before looking up a key.
- **JWKS:**
  - Apple: `https://appleid.apple.com/auth/keys`. Google: `https://www.googleapis.com/oauth2/v3/certs`.
  - Cache in isolate memory and in `caches.default` keyed by the URL. Google: for the response's
    `Cache-Control: max-age`. Apple: 1 hour.
  - An unknown `kid` refetches once, at most once a minute per isolate, then fails with
    `401 token_invalid`.
  - Keys are imported with `crypto.subtle.importKey("jwk", …, {name: "RSASSA-PKCS1-v1_5", hash: "SHA-256"})`.
- **Time:** `exp > now − 60 s`, `iat ≤ now + 60 s`, `iat ≥ now − 10 min`.
- **`nonce`:** equals the nonce we issued; the HMAC is valid; it has not expired and has not
  been used.
- **`sub`:** non-empty, 255 characters at most.

| Claim | Apple | Google |
|---|---|---|
| `iss` | `https://appleid.apple.com` | `https://accounts.google.com` or `accounts.google.com` |
| `aud` | `com.jerryfane.herdr` (native) or the Services ID (web) | `GOOGLE_IOS_CLIENT_ID` or `GOOGLE_WEB_CLIENT_ID` |
| Also | `nonce_supported` ignored; `email`/`is_private_email` never requested | `azp`, when present, is checked on its own against our client ids, not against `aud`: Google's cross-client flow gives `aud` = web client, `azp` = iOS client ([docs](https://developers.google.com/identity/openid-connect/openid-connect#obtainuserinfo)); `email` read only for `display_hint` |

The Services ID is grouped under the primary App ID `com.jerryfane.herdr`, so the same person
gets the same Apple `sub` natively and on the web. Google `sub` is the same across our two clients.

What we store: only `subject_hash = HMAC-SHA256(K_subject, "apple|" + sub)` (or `"google|"`).
A dump of D1 can't be joined against Google user ids. Apple's server notifications carry the raw
`sub`; we hash it the same way to find the account. `K_subject` comes from the root secret
`ACCOUNT_HMAC_KEY` through HKDF and must be backed up (§10): losing it orphans every account.

### 2.5 Sessions

| | Access token | Refresh token |
|---|---|---|
| Format | `a1.<session id 22>.<secret 43>`; the secret is 32 random bytes, b64url | `r1.<session id>.<secret 43>` |
| Lifetime | 1 hour | 90 days, sliding; rotated on every use |
| Server keeps | SHA-256 of the secret; lookup by session id; constant-time compare | Same, plus the hashes of every refresh token rotated away (`spent_refresh_tokens`) |
| Sent as | `Authorization: Bearer` | `POST /v1/auth/refresh` body (apps) or cookie (web) |

- **Rotation and reuse:** a refresh returns a new pair. The rotation is **one D1 batch**, which
  is a transaction, so it happens in the database and never in isolate memory:
  1. `INSERT INTO spent_refresh_tokens SELECT id, refresh_hash, refresh_exp_ms FROM sessions WHERE id = :sid AND refresh_hash = :old AND refresh_exp_ms > :now`;
  2. `UPDATE sessions SET refresh_hash = :new, access_hash = …, … WHERE id = :sid AND refresh_hash = :old AND refresh_exp_ms > :now RETURNING account_id`;
  3. mark the account seen today, found through the session's new hash.

  If any statement fails, none of them happened: the presented token still works and a retry
  succeeds. (Rotating first and touching the account in a second write would leave a spent
  token and no new pair when the second write failed.)
  - If two requests race with the same refresh token, D1 runs them one at a time: the first
    rotates it; the second finds it spent.
  - Any request that presents **any** refresh token the session ever rotated away (not only
    the last one), including the loser of such a race, counts as **theft**: the whole session
    family (the session row, so every rotation of it and its access token; the spent rows go
    with it) is deleted, and the answer is `401 session_revoked`. There is no grace window.
    Remembering only the previous hash would let an attacker who rotates twice replay the
    oldest token without tripping revocation.
  - Spent hashes are kept until the spent token's own expiry (90 days from when it was
    issued); after that it would be refused as expired anyway, so the hourly cleanup drops it.
    At ~3 refreshes a day that is under 300 rows (~30 KB) per active session.
  - Clients therefore refresh single-flight: one refresh in flight per process, and other
    callers wait for its result.
  - A refresh token that is neither current nor spent, or names an unknown session, gets
    `401 invalid_token` and changes nothing (it can't be told apart from garbage).
- **New accounts** are created with `last_seen_day` = today in the creating statement itself,
  so the hourly cleanup can't delete an account between its creation and its first session.
- **Revocation:**
  - Sign-out deletes the session row.
  - "Remove device" (account screen, 4B) deletes the device row and every session bound to it.
  - Deletion deletes everything.
  - The next request fails at once: every authenticated request reads its session row, which is
    one PK read, cheap within 5M reads a day.
- **Storage:**
  - **iOS/iPadOS/Mac app:** Keychain, service `dev.herdr.account`, account `refresh`,
    `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, `kSecAttrSynchronizable = false`,
    access group `$(AppIdentifierPrefix)com.jerryfane.herdr` (already in App/Herdr.entitlements).
    The access token stays in memory only. Same checked-status discipline as
    `KeychainCredentialStore` in App/SavedHosts.swift.
  - **herdrup-desktop:** `mygo.Secrets.Set("account-refresh", …)`: macOS Keychain, Windows
    Credential Manager, Secret Service on Linux. Without a store (`ErrUnsupported`), the app asks
    the user to sign in at each launch rather than writing a file.
  - **Web guest:** cookie `__Host-hu_refresh` with `Secure; HttpOnly; SameSite=Strict; Path=/`,
    on `accounts.herdrup.app`. The page fetches with `credentials: "include"`. CORS allows
    exactly `https://guest.herdrup.app` with credentials. The old relay domain is a different
    site, so web sign-in is offered only on `guest.herdrup.app`. The access token stays in memory.
- **Apple credential state:** at launch the iOS app calls `getCredentialState(forUserID:)` and
  observes `credentialRevokedNotification`. When the state is revoked, it signs out locally.

### 2.6 Decided in step 5, the Worker part (20 Nov)

PR 5's Worker half (`src/web.ts`, `src/browser.ts`, `migrations/0004_web_flows.sql`) settles these.

**Start.** `GET /v1/auth/web/start` takes exactly these parameters, and anything else is
`400 bad_request`:

- `provider=apple|google`;
- `client=app` with `platform` (any §2.5 platform but `web`) and `handoff_challenge`, the
  43-character b64url SHA-256 of the app's verifier;
- or `client=web` with nothing else, because the web guest's session lands in its cookie. A
  `handoff_challenge` or `platform` here is refused, not ignored, so a client that thinks it
  will get a handoff finds out at once.

It answers `303` to the provider. `AUTH_IP_LIMIT` covers start, both callbacks and the handoff.

- The Google web flow needs `GOOGLE_WEB_CLIENT_SECRET`. Without it, start answers
  `503 provider_not_configured` and logs `not_configured`. Apple's web flow needs no secret and
  is unaffected.
- `client=web` also needs `WEB_ORIGIN` (`https://guest.herdrup.app`, a var).

**The flow is bound to its browser.** Each browser holds one flow secret, `__Host-hu_flow` (32
random bytes; `Secure; HttpOnly; SameSite=None; Path=/; Max-Age=600`). Every flow it starts stores
the secret's hash in `web_flows.browser_hash`, and the callback must present it.

- **One secret per browser, not per flow** (PR 5 review, P2). A start reuses the secret the
  browser already holds and only renews its Max-Age; it makes a new one only when there is none
  or it is malformed. No callback clears it, success or failure; it ends with its Max-Age. So a
  desktop sign-in and a web guest sign-in pending in one browser both finish, in either order,
  and a failed or cancelled one breaks no other.
- Reusing a presented value is safe: only this Worker can set a `__Host-` cookie for its own
  host, so another site or a herdrup.app sibling can't plant one.

- This stops a login-CSRF: a page can't make the victim's browser finish the attacker's flow,
  which would sign the web guest into the attacker's account and sync the victim's share list
  there.
- The cookie has to be `SameSite=None` because Apple's callback is a cross-site `form_post`. It
  is a top-level navigation, so third-party-cookie blocking doesn't apply.
- A flow secret alone does nothing: it only works together with a state this Worker issued to
  the same browser, within 10 minutes and once.

**A state works once.** The callback takes the row with `DELETE … RETURNING`, so a second
callback with the same state is refused. A state of the other provider is refused too.

- An unknown, reused or malformed state gets a plain `400 state_invalid`, because nothing tells
  us which client to return to.
- Once the flow is found, every failure returns the browser to its client with an error code:
  `herdrup://account#error=<code>`, or `https://guest.herdrup.app/web/?account_error=<code>`.
- The codes are `flow_expired`, `browser_mismatch`, `cancelled`, `provider_error`,
  `exchange_failed`, `provider_not_configured`, `token_invalid`, `nonce_invalid` and `nonce_used`.

**ID tokens.** The flow's nonce is a normal sign-in nonce (§2.2), stored in the row and spent at
the callback (`proveIdentity`, the same check as a native sign-in).

- The audience must be the provider's **web** client only: the Services ID, or the Google web
  client. A token minted for a native client is refused here.
- Google's code is exchanged with the client secret and the PKCE verifier (5 s timeout). Only
  `id_token` is read from the answer. The access token is never read, stored, logged or passed on.

**Handoff.** The code is 32 random bytes, and `handoffs` keeps its SHA-256.

- `POST /v1/auth/handoff` takes exactly `{code, handoff_verifier}`. It takes no `platform` or
  `device_name`: the platform was fixed at start and is bound to the code, and a device is named
  when it enrols (`POST /v1/devices {…, name, platform}`, §3), exactly as after a native sign-in
  (whose body is `{id_token, nonce, platform}`). Any other field, or a missing or malformed code
  or verifier (RFC 7636: 43–128 characters), is `400` and doesn't spend the code.
- Otherwise the attempt spends the code whatever the verifier: `401 invalid_verifier`, then
  `invalid_code`. So a grabbed code can't be tried twice. A code past its 2 minutes is
  `401 code_expired`.
- The session opens only at redemption, with the start's `platform`. The answer is the same as a
  native sign-in's: tokens, `created`, and `display_hint` for Google.
- **The display hint is never stored readably.** Google's email waits in `handoffs.display_hint`
  sealed with AES-GCM, under a key derived by HKDF from the code. Only the `herdrup://` URL
  carries the code, so D1 and its Time Travel copies never hold the email (§2.1, §11).
- The web guest gets no display hint.

**The web guest's cookie.** After a `client=web` sign-in, the callback sets `__Host-hu_refresh`:
`Max-Age=7776000` (90 days, renewed with every rotation), `Path=/; Secure; HttpOnly;
SameSite=Strict`. It then redirects to `https://guest.herdrup.app/web/?account=1`. Setting it on a
cross-site top-level navigation is allowed; the guest page's own fetches are same-site, so they
carry it.

- `POST /v1/auth/refresh` from `Origin: https://guest.herdrup.app` uses the cookie, ignores the
  body, and answers `{account_id, access_token, access_expires_in}` with the rotated cookie. The
  refresh token never reaches the page.
- A refused cookie (expired, unknown, or reused, which revokes the session as in §2.5) is cleared.
- `POST /v1/auth/signout` from that origin ends the cookie's session, even with an expired access
  token, and clears the cookie. It always answers `204`.
- From any other origin, these endpoints ignore the cookie and work as for the apps. Other
  herdrup.app origins are the same site, so they would carry the cookie: the Origin check keeps
  them out.

**CORS.** Only `https://guest.herdrup.app`, always with `Access-Control-Allow-Credentials: true`
and `Vary: Origin`, and never `*`.

- It covers only the endpoints the web guest calls: `/v1/health` (the page reads its features to
  decide whether to offer sign-in), refresh, signout, `/v1/account`, the device endpoints,
  `/v1/statements` and `/v1/sync`. Their error answers carry it too, so the page can read a 401.
  Health gets the same headers as the rest, `Allow-Credentials: true` included: one rule for the
  one origin, and health reads no cookie either way.
- Preflights: from the web guest, for a method the route takes, `204` with
  `Allow-Methods` (the route's), `Allow-Headers: authorization, content-type` and `Max-Age: 600`.
  Anything else gets `403` with no CORS headers.
- Every other endpoint has no CORS, so a preflight gets `405`.

**Account deletion on the web guest** isn't offered. It needs a fresh ID token and nonce
(§6.1), which the cookie flow never gives the page, so the apps delete.

---

## 3. Devices and statements

### 3.1 What a device is

A device is one install's **existing guest key**: the X25519 static key the guest proves in every
Noise IK handshake. It lives in:

- `GuestIdentity` in Sources/HerdrKit/GuestIdentity.swift (Keychain, this device only);
- `internal/guest/identity.go` on desktop;
- `src/webguest/identity.ts` on the web (a non-extractable WebCrypto key where X25519 exists).

It is never synced and never replaced: replacing it would sever existing shares. The account
service only records its public half. Hosts already authenticate exactly this key, so no second
key type is needed.

### 3.2 Enrolment with proof of possession

An X25519 key can't sign, so possession is proved with a key agreement:

1. `POST /v1/devices/challenge` (authenticated). The Worker generates an ephemeral X25519 pair
   `e/E` and a 32-byte `salt`, stores a row valid for 60 s, and returns
   `{challenge_id, server_pub: E, salt, account_id}`.
2. The device computes:
   - `k = X25519(d, E)`; abort if it is all zero;
   - `mk = HKDF-SHA256(ikm = k, salt, info = "herdrup account enrol v1", 32)`;
   - `mac = HMAC-SHA256(mk, "herdrup-enrol-v1|" + account_id + "|" + b64url(D) + "|" + challenge_id)`.

   On the web, `deriveBits` with the non-extractable key does the same; on iOS,
   `Curve25519.KeyAgreement.PrivateKey.sharedSecretFromKeyAgreement`.
3. `POST /v1/devices {challenge_id, device_pub: D, mac, name, platform}`. The Worker deletes the
   challenge (it must belong to the calling session and be unexpired), computes `X25519(e, D)`,
   checks the MAC in constant time, and inserts the device.
   - The session gets `device_id`, **once**: a session that already has a device can't enrol
     another key (`409 session_has_device`), so a stolen access token can't bind the thief's
     key. Enrolling the session's own key again is idempotent.
   - If `D` already belongs to this account (a new sign-in on the same install), the session
     is bound to that existing device (200).
   - If `D` belongs to another account: `409 device_in_other_account`. The app offers to sign out
     of that account first; a key belongs to one account at a time.
   - At most 20 devices per account (`403 too_many_devices`), checked in the inserting
     statement itself so two enrolments can't both pass the count.
   - Insert and bind are one D1 batch (a transaction), and the insert also requires the
     session to still exist without a device. Nothing is undone afterwards: once committed,
     the device may already belong to another session of the account (a new sign-in on the
     same install adopts it), so a compensating delete could sign that session out. A session
     that signed out meanwhile gets `401 invalid_token`; the device stays (#752 review).
   - Removing a device (`DELETE /v1/devices/<id>`) deletes the sessions bound to it.

This uses the WebCrypto `X25519` that workerd has supported since 2023, and the same algorithm in
all three clients. A shared test vector file covers it (§9).

### 3.3 The statement

A compact JWS:

```
header  {"alg":"EdDSA","typ":"herdrup-device+jwt","kid":"2026-11a"}
payload {"v":1,
         "iss":"https://accounts.herdrup.app",
         "aud":"<host_id>",                       // 22-char b64url, from the invite
         "sub":"<pairwise account id for this host>",
         "dev":"<b64url X25519 device public key>",
         "iat":1795000000, "exp":1795000600}      // 10 minutes
```

- **Pairwise `sub`:** `b64url(HMAC-SHA256(K_pairwise, account_id ‖ "|" ‖ host_id))[0..22]`,
  where `K_pairwise` = HKDF(`ACCOUNT_HMAC_KEY`, "pairwise v1"). Two owners can't tell they share
  a guest, and a host learns nothing that links to another host.
  - The Worker stores no host ids: the client sends the host ids it needs, and the Worker
    computes the subs and forgets them.
  - `aud` = host id also stops a statement for host A from being used at host B. Replay at the
    same host is harmless: Noise IK proves possession of `dev`.
- **Issue:** `POST /v1/statements {hosts: [host_id ≤ 50]}` (authenticated, the session must have
  a `device_id`) returns `{statements: [{host, jws}], exp}`. The `dev` is always the session's
  own device, so a stolen access token mints statements that are useless without the device key.
  Each issue reads the device row; the device is removed → its sessions are already gone
  (`401`), and a session whose device row is missing gets `403 device_removed`.
- **Algorithm:** Ed25519 via `crypto.subtle.sign("Ed25519", …)`. The key is a PKCS8 Worker secret
  in one of two slots, `STATEMENT_KEY_A` / `STATEMENT_KEY_B`, each with its kid
  (`STATEMENT_KID_A` / `STATEMENT_KID_B`); `STATEMENT_ACTIVE` names the slot that signs. The
  statement is ~420 bytes and fits easily in a Noise message-1 payload (herdr `MAX_PLAINTEXT` ≈ 64 KB).
- **Clients cache** each host's statement and ask again when less than 2 minutes remain, or
  before a connect.

### 3.4 Publishing keys, rotation, revocation

- `GET /.well-known/jwks.json` returns
  `{"keys":[{"kty":"OKP","crv":"Ed25519","x":"…","kid":"2026-11a","use":"sig","alg":"EdDSA"}, …], "revoked_kids":[…]}`,
  with `Cache-Control: public, max-age=3600`. It lists every slot that has a key and a kid not
  in `STATEMENT_REVOKED_KIDS`, the active one first, so during a rotation both keys are
  published. `test/vectors/statement-v1.json` holds golden statements for herdr's tests.
- **Hosts** (herdr):
  - fetch it on first need: an account-bound share exists, or a hello carries a statement;
  - cache it on disk at `<config>/guest/account_keys.json` with `fetched_ms`;
  - treat it as fresh for 1 hour;
  - on an unknown `kid`, refetch at most once per 5 minutes;
  - if the fetch fails, keep using cached keys for **existing** devices (`device_pub` and
    devices already in `GuestRecord.devices`) for up to 7 days. Statements still expire in
    10 minutes, so stale keys can't extend anyone's access.
  - **refuse NEW account devices** (a statement for a key not yet on the share) whenever the
    JWKS couldn't be refreshed in the last hour. Adding a device needs keys at most 1 hour old;
    the refusal is `account_keys_stale`, and the client retries later.
- **Planned rotation** (two slots, so no key ever leaves Cloudflare; README "Rotate the statement key"):
  1. Put the new key and its kid in the idle slot: it is published at once, but doesn't sign.
     Wait at least 2 hours, so the hosts' 1-hour cache has picked it up.
  2. Switch `STATEMENT_ACTIVE` to that slot.
  3. Keep the old key published for 1 hour (more than the 10-minute statement life), then
     delete its secret.
- **Emergency rotation (compromise):**
  1. Generate a new key in the idle slot and switch `STATEMENT_ACTIVE` to it at once.
  2. Delete the old key's secret and add its kid to `STATEMENT_REVOKED_KIDS`, which the JWKS
     lists as a top-level `"revoked_kids"`, e.g. `{"keys":[…], "revoked_kids":["2026-11a"]}`.
     A revoked kid is never published or used to sign, even if its slot is still active. The
     list is kept for at least 30 days.
     in the same JWKS, e.g. `{"keys":[…], "revoked_kids":["2026-11a"]}`. The list is kept for
     at least 30 days.
  3. A host that sees a kid in `revoked_kids` deletes that key from its disk cache and never
     accepts it again, even if an older cached copy says otherwise.
  4. A host that can reach the service picks this up within its 1-hour cache, or at once on its
     next refetch for the new kid.
  5. A host that can't reach the service keeps its old keys, but by the rule above it accepts
     **no new devices** after an hour without a refresh. An attacker holding the old key could
     only mint statements for keys already on the share, and Noise IK still requires that
     device's private key, so the stale key buys them nothing.
- **Revocation within minutes:**
  - A device removed from the account (by the guest, or by deletion) gets no new statements, and
    the one it holds expires in **≤ 10 minutes**.
  - The host checks the statement at admission, and ends an account-bound session at the
    statement's `exp` (+60 s skew) unless the client sent a fresh statement in-band (§4).
  - Revocation by the owner on the host is immediate, as today.

### 3.5 Trust the hosts give the service (stated plainly)

Whoever controls the statement signing keys and `ACCOUNT_HMAC_KEY` can enrol a device into **any
account-bound share**. Plain invites are not affected. To bound this:

1. Account binding is per share, chosen by the guest (2A). The host owner can turn it off
   (`[guest] accounts = false`).
2. Every device a person adds shows on the owner's 4B page, gets an audit entry
   (`device_added`), and triggers an owner push "Alice added a device".
3. The signing key is only a Worker secret: it is never copied out, and it is rotated on any
   suspicion.

---

## 4. herdr side (summary; work in jerryfane/herdr#440)

Today a share is single-use and binds one device: `InviteRecord.used_by` holds the guest id, and
`GuestRecord.device_pub` holds the redeeming device's X25519 key (src/guest/store.rs). `admit_in`
handles two hellos: `{v:1, invite_id, secret, device}` for a new guest, and
`{v:1, guest_id?}` for a returning one.

**Store changes** (`GuestRecord`, all `#[serde(default)]`, so old files load):

- `account: Option<String>`: the pairwise `sub`; `None` means a plain share, as today.
- `devices: Vec<AccountDevice { device_pub, fingerprint, device, added_ms, last_seen_ms, removed: bool }>`:
  the later devices. `device_pub` stays the redeeming device.

**Admission:**

| Hello | Rule |
|---|---|
| Redemption `{v:1, invite_id, secret, device, account: <jws>}` | Verify the statement (§3.4 keys; `iss`; `aud == own host_id`; `dev ==` the Noise device key; `exp`/`iat` ±60 s). Then redeem as today and set `account = sub`. Without `account`: plain, as today ("Only this device"). |
| Returning, record has `account` | **Always** needs a valid statement with `sub == record.account` and `dev ==` Noise key. `dev` is `device_pub`, or an `AccountDevice` that isn't `removed`, or a new key, which is added to `devices` (audit `device_added`, owner push). |
| Returning, record without `account` | Unchanged: `device_pub` match only. |

- Requiring the statement for every device of an account-bound share is what makes "remove device
  from my account" and account deletion reach the host.
- The returning hello keeps `guest_id` as a selector, never as authority, as `admit_returning`
  says today.
- **Statement refresh in the session:** a new frame `{"t":"account.refresh","account":"<jws>"}`.
  The host checks it as above and moves the session's deadline to the new `exp`. Missing the
  deadline closes the session with `statement_expired`, and the client reconnects with a fresh
  statement.

**Owner API and CLI:**

- `guest.list` adds `account_bound`, `person` (the `sub`, or the device fingerprint for plain
  shares) and `devices[]`.
- `guest.revoke` gains a target `{person}`: it revokes every `GuestRecord` with that account and
  closes their sessions (`revoke_live`). That is "revoke once per person".
- A new `guest.remove_device {guest_id, fingerprint}` lets the owner drop one device; it marks
  the device `removed`, so a statement can't bring it back.
- CLI: `herdr guest revoke --person <id>`.

**Capability:** herdr adds `"acct":1` to the v1 invite payload when it supports this. The app
shows 2A ("Add to my account" / "Only this device") only for such invites, and plain Accept
otherwise.

**Config:** `[guest] accounts = true` (default on, §11) and
`account_issuer = "https://accounts.herdrup.app"`. The JWKS fetch reuses the rustls HTTPS
`send`/`exchange` helper in src/guest/link/invite.rs, generalised to return a body; Ed25519
verification uses `ring::signature::ED25519` (ring 0.17 is already a dependency). The Cargo.toml
comment that documents the guest link's outbound TLS exception gains `accounts.herdrup.app`.

**Relay changes:** no Worker code changes. The statement travels inside Noise, so the relay never
sees it. The only change is `GuestRelay/public/_headers`, plus the CSP meta tag in the web bundle:
add `https://accounts.herdrup.app` to `connect-src` for the web guest. `form-action 'none'` stays,
because sign-in is a top-level navigation, not a form post.

---

## 5. What syncs (option A)

### 5.1 Collections

| Collection | Item id | Fields (allowlist, the server rejects any other key) | Caps |
|---|---|---|---|
| `hosts` | `SavedHost.id` (UUID) | `nickname` ≤64, `host` ≤253, `port` 1–65535, `username` ≤64, `auth_kind` (`key`\|`password`), `label` ≤64 | 200 items |
| `prompts` | UUID | `title` ≤128, `text` ≤8 KB, `order` | 500 items |
| `settings` | the settings key | `value`: bool, number or string ≤256, for **allowlisted keys only** (the list is in §5.5). Device-shaped keys such as `ui.sidebarWidth`, `hasSeenGesturesHelp` and `gram.setupCardDismissed` stay local. | 300 items |
| `agent_prefs` | `<host item id>/<agent key>` | `pinned`, `hidden`, `order` | 1000 items |
| `shares` (guest side, #700) | `<host_id>/<guest_id>` | `relay` URL, `host_id`, `node_pub` (public), `guest_id`, `agent_name`, `owner_name`, `machine_label`, `share_gram` | 500 items |

- Agent folders and stars already live on the herdr server (`agent_groups`, herdrup#552), so they
  already follow the host. `agent_prefs` covers only what the app keeps locally.
- A synced host shows **"Pair this device"** on a new device (`herdr pair`). Its key or password
  is entered on that device and never leaves it.
- A synced share opens on a new device through §4 (statement plus `guest_id` selector).
  `guest_id` is a selector, `node_pub` is public, and the single-use invite secret was consumed
  at redemption, so the share list holds nothing secret.

### 5.2 Format and limits

- An item is `{collection, id, rev, updated_ms, deleted, body}`. The body is the JSON of the
  allowlisted fields. The server re-serialises it from the validated fields, the way crash.ts
  does.
- Limits: 16 KB per item; 2,000 items and 1 MB per account. A push carries at most 100 changes
  and 256 KB (`413 too_large`, `403 quota`).
- `GET /v1/sync?since=<rev>` returns `{rev, changes[], more, cursor?}`, at most 500 per page; the next
  page is `GET /v1/sync?cursor=<cursor>`. A client more than 90 days behind gets `410 reset_required`,
  and then does a full pull and merge (§5.5 says exactly when).
- `POST /v1/sync {changes: [{collection, id, base_rev?, deleted?, body?}]}` returns
  `{rev, applied[], conflicts[]}`.

### 5.3 Conflict rule

The server orders writes per item; this is better than trusting device clocks:

- Each accepted write takes the next account `sync_rev`, in one D1 batch. Last write to reach
  the server wins.
- Settings are **one item per key**, so two devices changing different settings never clobber
  each other. That is the "or better" over whole-document last-writer-wins.
- An optional `base_rev` lets the editing UI (host editor, prompt editor) detect a concurrent
  edit. A mismatch lands in `conflicts[]` with the server copy, and the app shows it.
  Background pushes omit `base_rev`.
- A delete leaves a tombstone (`deleted = 1`, body null), kept 90 days, so offline devices learn
  of it.

### 5.4 NEVER uploaded

| Never | Where it lives today |
|---|---|
| SSH private keys | Keychain `dev.herdr.credentials` |
| SSH passwords | Keychain `dev.herdr.credentials.password` |
| Pairing secrets and codes (`herdr pair`), `PairingKey` | App Keychain / memory |
| Host-key pins | `KeychainHostKeyPolicy` (device-local trust on first use; syncing would spread a bad pin) |
| Guest device private keys | `GuestIdentity` Keychain; desktop identity file; web IndexedDB |
| Invite links and secrets, relay secrets | Single use / host only |
| Push relay capabilities, APNs device tokens | `PushRelayEnroller` |
| Account session and refresh tokens; Apple/Google tokens | Keychain / credential store / cookie |
| Claude account logins (`AccountLogin`) | Host config homes |
| Terminal contents, transcripts, Grams, attachments | Never leave the host or device path |

Three things enforce this:

1. The server schema is an allowlist: an unknown key gets `400`.
2. The client sync encoders are their own types, built from these fields only. They are never
   `Codable` wrappers of the stores, which can hold secrets.
3. A client test rejects any payload containing `-----BEGIN`, `ssh-` key blobs, or strings that
   look like 32-byte b64url secrets in a non-id field.

### 5.5 Decided in step 3 (20 Nov)

The design left these open; PR 3 (`src/sync.ts`, `migrations/0003_sync.sql`) settles them.

**Synced settings keys.** Exactly these, each with its own check; any other key is `400`:

| Key | Value |
|---|---|
| `terminal.fontSize`, `guest.terminal.fontSize`, `chat.fontSize` | number 6–72 |
| `ui.fontScale` | number 0.5–3 |
| `ui.theme` | `system`, `light` or `dark` (the apps have no theme switch yet; this reserves the key) |
| `guest.ownerName` | string ≤64 code points, no control characters |
| `notify.<name>` (`<name>` = a letter, then ≤47 letters or digits) | bool |

`previews.javascript` stays local: it is a per-device safety switch, and syncing it would turn
script on for a device that never chose it.

**Field rules.** Strings are well-formed UTF-16 with no control characters (prompt `text` may
hold tabs and line breaks), counted in code points (`text` in UTF-8 bytes):

- `hosts`: `host` (required, no whitespace) and `username` (required, non-empty); `port` an integer.
- `prompts`: `text` required and non-empty.
- `order` (prompts, agent_prefs): any finite number within ±2^53, so a client can insert between two.
- `shares`: `relay`, `host_id`, `node_pub` and `guest_id` are required. `host_id` and `guest_id` are
  22-character b64url and must equal the two halves of the item id. `node_pub` is 43-character b64url.
  `relay` is an `http(s)` URL of ≤256 characters with no credentials, query, fragment, or path
  segment that is (or percent-decodes to) `i`, so an invite link can't be stored in it. The server
  stores only its canonical form, origin plus path without a trailing slash, so dot segments
  (`/i/<id>/../..`) can't carry an invite path past the check. `@` in the path is allowed.
  `agent_name` and `machine_label` are ≤128,
  `owner_name` ≤64.
- Item ids: `hosts`, `prompts` and the host half of an `agent_prefs` id are **lowercase** UUIDs
  (Swift clients send `uuidString.lowercased()`). The agent half is 1–128 code points.
- The `16 KB` item limit applies to the re-serialised body (`413 too_large`).

**Refusals.** A bad change refuses the whole push with
`400 {"error":"invalid_item","index":<i>,"field":"<key>"}`, where `field` names the unknown or
invalid key (`id`, `collection`, `body`, …). The same item twice in one push is `400` too. Other
malformed bodies and query strings are `400 bad_request`.

**One push, one transaction.** A push is one D1 batch. If it would pass a cap, it rolls back
whole (`403 quota`). Its deletes run before its writes, so swapping one item for another at a cap
works whatever order the client lists them in. The caps are `CHECK` constraints on counters
that triggers keep (`accounts.sync_items`, `sync_bytes`, and `sync_usage.items` per collection),
so two devices pushing at once can't pass them either. The 1 MB counts the stored bodies' UTF-8
bytes. The cost: each item written also updates its `accounts` and `sync_usage` rows, so about
3 D1 rows are written per item. A first upload of 2,000 items is about 6k of the 100k free daily
writes, and a usual push of a few items is about 10 (§1.4).

**Answers.** `applied[]` is `{collection, id, rev}`. A write identical to the stored item isn't
written again and keeps its `rev`. Deleting an item the server doesn't hold writes nothing and
reports `rev: 0`. `conflicts[]` is `{collection, id, server}`, where `server` is the stored item
(perhaps a tombstone) or null. `base_rev: 0` means "create only". `base_rev` is compared with the
stored revision, tombstones included.

**Paging.** `since` defaults to 0, and `since=0` is a full pull. When `more` is true, the answer
also carries `cursor`. The client sends it back unchanged (`?cursor=<cursor>`) for the next page,
and stores the last page's `rev` as its next `since`. A cursor is `<position>.<base>`:

- `position` is the last revision sent.
- `base` is the revision up to which the caller's copy is known complete. That is `since` for an
  incremental pull, and for a full pull the account's `sync_rev` when the pull began.

**When a reset is required.** This is decided by revision, not by the clock. Each account keeps
`sync_floor`, the highest revision of any tombstone pruned so far. A pull is refused with
`410 reset_required` in two cases:

- `max(position, base) < sync_floor`, or
- either value is past `sync_rev`, which means another history, for example a restored database.

Why this is safe: a tombstone the caller could still need has a revision above
`max(position, base)`. Either the caller hasn't paged past it yet, or it was written during a full
pull to delete an item already sent. Pruning such a tombstone lifts the floor to its revision or
above, so the caller is refused instead of missing the delete. This has three consequences:

- A plain `since=N` below the floor is refused, because `base = N`.
- A full pull pages past a floor that already existed when it began, however many pages it takes
  (PR 3 review, P1: 600 live items plus a newer pruned tombstone).
- A full pull is refused partway only when a prune during it could hide the delete of an item it
  already sent.

A full pull doesn't list tombstones that were pruned while it ran. That is why a full pull is a
replace: the client drops every local item the pull didn't list as live. Writes that land during
a full pull get revisions above `position`, so later pages deliver them. A device that is 90 days
behind but missed no pruned delete still catches up normally.

**Tombstones.** The hourly cron prunes tombstones older than 90 days (by the server's
`updated_ms`). Each push also keeps only the newest 2,000 tombstones per account, so
create-and-delete loops can't grow D1 without bound. Either way the floor rises.

**Rate limits.** `SYNC_WRITE_LIMIT` (30/min) covers `POST` only. Pulls count against `ACCOUNT_LIMIT` alone.

**Who may sync.** Any session of the account. Unlike statements, sync doesn't need an enrolled
device, because nothing it returns is bound to a device key.

---

## 6. Account deletion

### 6.1 In the app (Guideline 5.1.1(v))

On the account screen: **Delete account**, a confirm step, then a fresh sign-in with the same
provider. The fresh sign-in is the confirmation, and for Apple it also yields the authorization
code needed to revoke. Then:

`POST /v1/account/delete {provider, id_token, nonce, authorization_code?}`

1. Verify the ID token (§2.4); its `subject_hash` must belong to the session's account.
2. **Apple only:**
   - Exchange `authorization_code` at `https://appleid.apple.com/auth/token`
     (`grant_type=authorization_code`, `client_id` = the token's `aud`,
     `client_secret` = the client-secret JWT for that `client_id`).
   - Immediately `POST https://appleid.apple.com/auth/revoke` with `client_id`, `client_secret`,
     `token=<refresh_token>`, `token_type_hint=refresh_token`.

   We never store Apple tokens. If the exchange or revoke fails, the deletion still goes ahead
   (TN3194), and the app shows Apple's manual path: Settings → Apple Account → Sign in with
   Apple → HerdrUp → Stop using.
3. Delete everything in one `db.batch()`, matched on `account_id`: `sync_items`, `sync_usage`,
   `enrol_challenges`, `handoffs`, `sessions` (and their `spent_refresh_tokens`), `devices`, `identities`,
   then `accounts` (§6.5 has the exact list and how it is kept complete).
4. The app clears its Keychain account items and statement cache, and returns to signed out.
   Local copies of hosts and prompts stay on the device, as they did before sign-in. The
   confirm screen says so.

### 6.2 The Apple client secret

- The client-secret JWT is ES256 with header `{alg: ES256, kid: <Key ID>}` and payload
  `{iss: FXQ5Z9HHY6, iat, exp ≤ iat + 15,777,000 s (6 months), aud: "https://appleid.apple.com", sub: <client_id>}`.
- There is **one per client_id**: `com.jerryfane.herdr` (native codes) and the Services ID (web
  codes).
- It needs: the **Sign in with Apple private key (.p8)**, its **Key ID**, and the **Team ID
  `FXQ5Z9HHY6`**.

Where the .p8 lives (owner decision, 19 Nov): **a Worker secret**, `APPLE_SIWA_P8`, which the
owner pastes once with `wrangler secret put APPLE_SIWA_P8`. The Worker signs a 5-minute client
secret for the matching `client_id` when it needs one (at deletion). Nothing runs on a schedule,
and the keyring is not involved. If the key is ever exposed: revoke it in Apple Developer →
Keys, create a new one, and paste the new .p8 and Key ID.

### 6.3 Apple server-to-server notifications

`POST /v1/apple/notifications` is registered on the App ID. The Worker verifies the JWS against
Apple's JWKS (`iss`, `aud` ∈ our client ids), hashes `events.sub`, and:

- `consent-revoked` or `account-deleted` → the same deletion as §6.1, without the Apple revoke,
  because the user already did that (TN3194).
- `email-*` → ignored (we hold no email).

### 6.4 What deletion stops

- D1 rows: gone at once. Point-in-time backups (D1 Time Travel) age them out within 7 days on
  Free, 30 days on Paid.
- Devices: gone, so no new statements. Sessions: gone, so every token fails on its next request.
- **Shares bound to the account:** every device's statement expires within 10 minutes, so the
  host closes account-bound sessions at the deadline and refuses new ones. The `GuestRecord`
  stays on the host until the owner removes it. The 4B page shows the person as not seen since…
- Plain shares (from "Only this device") are not bound to the account and keep working.

### 6.5 Decided in step 4 (20 Nov)

PR 4 (`src/deletion.ts`, `src/apple.ts`, `src/apple_notify.ts`) settles these.

**The call.** `POST /v1/account/delete` takes a bearer access token and
`{provider, id_token, nonce, authorization_code?}`, and answers `200 {deleted: true, manual_revoke}`.

- The fresh sign-in is checked like a sign-in (`proveIdentity`, shared with §2.4): the nonce
  was issued by this Worker and is spent here, and the token carries it.
- Its identity must belong to the session's own account. Otherwise the answer is
  `403 wrong_account`, and nothing is spent but the nonce.
- `authorization_code` is Apple only: printable ASCII, ≤1,024 characters. A code with Google
  is `400`.
- Order of checks: `DELETE_IP_LIMIT` per IP before anything else, then the session and
  `ACCOUNT_LIMIT`, then the body.

**Delete first, revoke after.** The deletion is one D1 batch, which is a transaction. Apple's
revoke runs after it, and nothing is ever compensated or undone.

- `manual_revoke: true` covers every case where Apple didn't confirm the revoke: no code, an
  unusable `APPLE_SIWA_P8` or `APPLE_KEY_ID`, an exchange or revoke refused, no refresh token in
  the answer, a network error, or a 5 s timeout.
- In all those cases the account is already gone.
- A missing or unusable key also logs `not_configured`, so the owner can see it.

**Which client_id.** The code is exchanged and revoked with the `aud` of the same sign-in's ID
token: `com.jerryfane.herdr` for native codes, the Services ID for web codes. A web code's
exchange also sends `redirect_uri` = the Services ID's return URL.

**The client secret.** It is signed per call and lives 5 minutes (`exp = iat + 300`). Header
`{alg: ES256, kid: APPLE_KEY_ID}`; payload
`{iss: APPLE_TEAM_ID, iat, exp, aud: "https://appleid.apple.com", sub: client_id}`; a raw 64-byte
r‖s signature, as JOSE wants. `APPLE_SIWA_P8` is the `.p8` exactly as downloaded (PKCS8 PEM).
`APPLE_TEAM_ID` and `APPLE_KEY_ID` are vars and must be 10 upper-case letters or digits. The
imported key is cached per isolate.

**Every table is covered.** `ACCOUNT_TABLES` lists the tables with an `account_id` column. A test
reads every `CREATE TABLE` from the migrations' own SQL and checks that the list is exactly the
tables with that column. Every other table must be named in the test with how deletion covers it:

| Table | How deletion covers it |
|---|---|
| `accounts` | its own row, by `id` |
| `spent_refresh_tokens` | by the account's session ids, in the same batch |
| `used_nonces` | nothing to delete: it holds only hashes and expiries, nothing that names an account |
| `web_flows` | a sign-in's flow has no account yet (`account_id` NULL) and goes at its callback or after 10 minutes (§2.6); a deletion's confirmation flow carries its account and is deleted with it (§6.6) |

A new table therefore fails the test until it is handled. The batch deletes children first, so
it never depends on `ON DELETE CASCADE`.

**Racing calls.** Any request already past authentication either commits before the deletion
batch or finds the account gone:

- A sync push writes through `INSERT … SELECT … FROM accounts` (§5.5), so it writes nothing once
  the account is gone, and answers `401 invalid_token`.
- A full pull's next page answers `401` too.

**Notifications.** `POST /v1/apple/notifications {payload}` answers `204` whether or not an
account matched, so it never says who has an account.

- The JWS is checked with the same RS256 verifier and Apple JWKS cache as ID tokens.
- `iss` must be `https://appleid.apple.com`. The bare `appleid.apple.com` is accepted too.
- `aud` must be one of our two Apple client ids.
- `iat` must not be in the future; `exp`, when present, must not have passed.
- `events` may be a JSON string, as Apple sends it, or an object, as in Apple's samples.
- `consent-revoked` and `account-deleted` delete the account. Every other type is acknowledged
  and ignored.
- **Replay guard:** a deleting event must be strictly after the identity's `created_ms`, or it
  deletes nothing, so an old or delayed revoke can't delete an account the person made since.
  - `event_time` in milliseconds is compared exactly; there is no slack.
  - `event_time` in seconds (a value below 10^12, as in Apple's samples), or `iat` when
    `event_time` is missing, counts from the start of its second. So an event in the same second
    as the sign-up deletes nothing.
  - On a tie or any doubt nothing is deleted; the person can still delete in the app
    (PR 4 review, P2).
- Bad tokens answer `401 token_invalid` with a `reason`, and Apple's unreachable keys answer `503`.
- `DELETE_IP_LIMIT` (5/min per IP) covers notifications as §8 says. Apple sends from few IPs, but
  at our size that is far below 5 a minute. If a §1.4 growth trigger fires, give notifications
  their own limit.

### 6.6 Deleting from the desktop: the web confirmation (22 Nov)

herdrup-desktop signs in through the browser (§2.3), so it never holds an ID token and can't
send `{id_token, nonce}`. It confirms a deletion with a fresh **web** sign-in instead, bound to the
account and session that ask. The health feature `web_delete` says the Worker offers this; it is
listed when either provider's web flow is configured.

1. **Ticket.** `POST /v1/account/delete/start` with the session's bearer token and
   `{provider: "apple"|"google", handoff_challenge}`, where the challenge is S256 (43-character
   b64url) of a verifier the app keeps. The answer is
   `200 {start_url, expires_in: 300}`, with
   `start_url = https://accounts.herdrup.app/v1/auth/web/start?purpose=delete&ticket=<32 B>`.
   - The ticket is stored as a hash in `delete_tickets`, with the account, the session, the
     provider and the challenge, for 5 minutes. The URL carries the ticket, never an access
     token, because it goes through the system browser.
   - The provider is the one the account signed in with. `503 provider_not_configured` when that
     provider's web flow can't run (Google without its secret).
   - `DELETE_IP_LIMIT` per IP, then the session and `ACCOUNT_LIMIT`.
2. **Browser.** The app opens `start_url`. The start takes the ticket (single use: a second open is
   `400 ticket_invalid`; past 5 minutes it goes to `herdrup://account#delete_error=flow_expired`).
   It then runs the same web flow as a sign-in (§2.3, §2.6): the provider's web client, a nonce,
   PKCE for Google, the browser's `__Host-hu_flow` binding, one state, 10 minutes. The
   `web_flows` row carries `purpose = 'delete'` with the ticket's account and session. The start
   takes exactly `purpose=delete&ticket=…`; anything else is a 400.
3. **Callback.** The ID token is verified as in a sign-in (web audience, the flow's nonce, spent).
   A deletion's callback **never makes an account or a session**:
   - The identity must already be linked to the ticket's account. Otherwise the browser goes to
     `herdrup://account#delete_error=wrong_account`.
   - Otherwise it gets a delete code (32 B), and the browser goes to
     `herdrup://account#delete_code=<code>`.
   - The code waits in `delete_handoffs` for 5 minutes, bound to the account, the session, the
     identity (provider and subject hash), the client id (the token's `aud`) and the challenge.
   - For Apple, the form_post's authorization code is kept with it for the revoke. It is sealed
     with AES-GCM under a key derived from the delete code, so D1 never holds it readably.
   - Every other failure goes to `herdrup://account#delete_error=<code>`, with the codes of §2.6
     (`cancelled`, `token_invalid`, `browser_mismatch`, …).
4. **Delete.** `POST /v1/account/delete` with the same session's bearer token and exactly
   `{handoff_code, handoff_verifier}`, in place of `{provider, id_token, nonce, authorization_code?}`.
   - The code is taken first, so it is spent by any outcome: `401 invalid_code` (unknown or spent),
     `401 code_expired`, `401 invalid_verifier`, or `403 wrong_account` (another account, another
     session, or the identity no longer the account's).
   - Then comes the same deletion as §6.1: one batch, then Apple's revoke with the kept code and
     the Services ID as `client_id`. The answer is `200 {deleted: true, manual_revoke}`, as
     before.
   - Malformed bodies, or a body mixing both proofs, are `400` and spend nothing.

**Sign-in and delete codes are separate.** They live in separate tables (`handoffs`,
`delete_handoffs`), and each redemption reads only its own. A sign-in code is `invalid_code` at
`/v1/account/delete` and still works for its sign-in. A delete code is `invalid_code` at
`/v1/auth/handoff`, opens no session, and still works for its deletion. The desktop tells them
apart by the fragment key: `#code=` or `#delete_code=`.

**Cleanup.** Tickets, deletion flows and codes are deleted with their session (sign-out, refresh
reuse) or account, and by the hourly cron past their expiry. Deletion's table sweep (§6.5)
covers `delete_tickets`, `delete_handoffs` and `web_flows`, which now has `account_id`.
Migration `0005_web_delete.sql`.

---

## 7. Privacy and policy (#701)

### 7.1 herdrup.app/legal/privacy (herdrup-web `content/privacy.txt`)

| Section | Change |
|---|---|
| The short version | "herdrup has no accounts" becomes: "Accounts are optional. Without one nothing changes. With one, we keep your server list, saved prompts, settings and shared agents in sync, never your keys or passwords." Our servers' list of jobs gains a fifth item: optional accounts. |
| **New: Accounts** | Sign in with Apple or Google. We keep a keyed hash of the provider's user id, never your name or email. For Google we read your email once to show it on your device, and do not keep it. We keep the devices you sign in on (name, platform, a public device key), and the synced items listed above. We never upload SSH keys, passwords, pairing secrets or device private keys. |
| **New: Deleting your account** | In the app, with immediate deletion; backups age out within 30 days; Apple sign-in access is revoked; shares bound to the account stop within minutes. Accounts unused for 24 months are deleted. |
| Guest sharing | When a guest adds a share to their account, the host owner's machine learns an account id unique to that machine and the names of the guest's devices. |
| Service providers | Add Apple and Google as sign-in providers, and Cloudflare D1 storage. |
| Your choices | Replace "Because we do not know who you are, we cannot look up data about you" with: signed out we can't; signed in, you can see and delete everything in the app. |

### 7.2 App Store privacy labels

Add the rows below. Existing rows (usage count, crash data) stay. Tracking: **No**.

| Data type | Collected | Linked to user | Purpose |
|---|---|---|---|
| Identifiers → User ID | Yes (the hashed provider id and our account id) | Yes | App Functionality |
| Identifiers → Device ID | Yes (the device public key) | Yes | App Functionality |
| User Content → Other User Content | Yes (server list, prompts, settings, share list) | Yes | App Functionality |
| Contact Info → Email Address | **No**: read on the device for display; the server handles it in real time and does not keep it | — | — |

Review notes (#701): Sign in with Apple sits next to Google (Guideline 4.8). Add a Google test
account for App Review, kept in the keyring with the other review credentials, and say where
Delete account is.

---

## 8. Abuse, sizes, logging

Rate limits use Workers Rate Limiting bindings. Each is checked before the body is read, as in
relay.ts and crash.ts.

| Binding | Key | Limit | Covers |
|---|---|---|---|
| `AUTH_IP_LIMIT` (6981) | IP | 20 / 60 s | nonce, native sign-in, web start/callback, handoff, refresh |
| `ACCOUNT_LIMIT` (6982) | account id | 120 / 60 s | Every authenticated call |
| `STATEMENT_LIMIT` (6983) | account id | 30 / 60 s | `/v1/statements` |
| `SYNC_WRITE_LIMIT` (6984) | account id | 30 / 60 s | `POST /v1/sync` |
| `ENROL_LIMIT` (6985) | account id | 10 / 60 s | Challenge and enrol |
| `DELETE_IP_LIMIT` (6986) | IP | 5 / 60 s | Delete, Apple notifications |
| `APPROVAL_LIMIT` (6987) | account id | 30 / 60 s | Every browser-approval route (§12) |

Fixed caps:

- 20 devices and 1 MB / 2,000 sync items per account; host cap of 10 devices per share.
- Body caps through `readCapped`: auth 8 KB, enrol 2 KB, statements 4 KB, sync 256 KB,
  Apple notification 8 KB, approval steps 4 KB, approval finish and envelopes 24 KB.
- New accounts can't come from nowhere: each needs a fresh provider-signed token, and
  `AUTH_IP_LIMIT` bounds the rate.

Logging copies the relay's rule:

- One JSON line, `{endpoint, outcome, code?}`, and only for `not_configured`, `internal_error`
  and rate-limit refusals. The error object is never logged.
- **Never logged:** tokens, codes, nonces, `state`, email, `sub` or its hash, account / device /
  session ids, device keys, host ids, IPs, user agents, request bodies or URLs.
- Workers Logs, traces and Logpush are off in `wrangler.toml`.

**Health and features (step 5).** `GET /v1/health` answers `{ok, version, features}`. The apps
ship separately from the Worker, so an app offers a feature only when the live Worker lists it.
The names are a stable contract:

- `native_sign_in`, `devices`, `statements`, `sync`, `delete`, `web_approve` (browser
  approval, §12) and `approval_expiry_final` (a reported `expired` is final, §12.2) are always
  listed.
- `native_sign_in_google` is listed when `GOOGLE_IOS_CLIENT_ID` is set. It tells the iOS app it
  may offer native Google sign-in (ASWebAuthenticationSession with PKCE against the iOS client,
  then `POST /v1/auth/google`), which needs no client secret. `web_sign_in_google` doesn't cover
  it: that one is the web client plus its secret.
- `web_sign_in_apple` is listed when `APPLE_WEB_CLIENT_ID` is set.
- `web_sign_in_google` is listed when both `GOOGLE_WEB_CLIENT_ID` and `GOOGLE_WEB_CLIENT_SECRET`
  are set.
- `web_delete` is listed when `web_sign_in_apple` or `web_sign_in_google` is: the desktop may
  confirm a deletion through the web flow (§6.6) for a provider whose web flow is listed.
- `apple_revoke` is listed when `APPLE_SIWA_P8` and `APPLE_KEY_ID` are set and the key parses,
  checked by the same loader the revoke uses (§6.5).

Each flag is a boolean fact about the configuration: health never returns a var's or secret's
value. Health takes no rate limit and touches no D1 row. Parsing the key happens once per isolate
(cached). The web guest reads it cross-origin, so it carries CORS for `https://guest.herdrup.app`
(§2.6).

`VERSION` lives in `src/version.ts`, not in the entry module: `wrangler dev` refuses an entry
module that exports anything but its handler.

---

## 9. Phasing into PRs

| # | Repo | PR | Tests |
|---|---|---|---|
| 1 | herdrup | **Worker skeleton + native auth** (built 19 Nov). `AccountService/`, migration 0001, `/v1/health`, nonce, Apple/Google ID-token sign-in, sessions (refresh, rotation, reuse revokes the family, sign-out), `/v1/account`, rate limits, logging rules, hourly cleanup, README with deploy/rollback like GuestRelay's, CI job "Account service (Linux)". | `@cloudflare/vitest-plugin` in workerd with a local D1; test-generated RSA keys served by a fetch spy at the real JWKS URLs; per-key counter rate limits (no clock windows). Cases: good tokens (both Apple audiences, both Google clients); wrong `iss`/`aud`/`azp`; expired / future / too-old `iat`; `alg: none`/HS256/`crit`; unknown `kid`; bad signature; nonce mismatch, forgery, expiry, reuse; refresh rotation, reuse revokes, racing refreshes; per-IP and per-account limits; no stored sub/email/token; logs hold only endpoint and outcome; JWKS cache timing with an explicit clock. |
| 2 | herdrup | **Devices + statements** (built 20 Nov). Challenge/enrol, device list/rename/remove, `/v1/statements`, `/.well-known/jwks.json`, two-slot rotation vars, migration `0002_devices.sql`, `STATEMENT_LIMIT` and `ENROL_LIMIT`. | X25519 PoP vectors in `AccountService/test/vectors/enrol-v1.json` (made with Node's crypto, RFC 7748 key pairs), shared with the iOS, Go and TS clients; low-order points rejected; 409 for another account; one device per session; device cap; removal stops statements; pairwise `sub` stable per host, different across hosts and accounts; golden `statement-v1.json` (RFC 8032 test key) that herdr's tests reuse; JWKS during rotation and after a revocation. |
| 3 | herdrup | **Sync** (built 20 Nov). `GET`/`POST /v1/sync`, schemas per collection, caps, tombstones, `reset_required`, migration `0003_sync.sql`, `SYNC_WRITE_LIMIT`; open points settled in §5.5. | Ordering and last-writer-wins; per-key settings don't clobber; `base_rev` conflict; unknown field → 400; caps → 413/403; tombstone pruning; full-reset path. |
| 4 | herdrup | **Deletion + Apple revoke + notifications** (built 20 Nov). `/v1/account/delete`, client secret signed in the Worker from `APPLE_SIWA_P8`, `/v1/apple/notifications`, `DELETE_IP_LIMIT`; open points settled in §6.5. | Table sweep: no row with the `account_id` remains in any table; client-secret JWT claims and ES256 signature checked against a generated P-256 key; revoke called with the client_id matching the token `aud`; revoke failure still deletes and returns `manual_revoke: true`; notification JWS verify (bad sig, wrong `aud`); `consent-revoked` deletes. |
| 5 | herdrup + herdrup-desktop | **Web sign-in flow + sign-in UI (1B) + sync client (#699).** Worker (built 20 Nov; open points settled in §2.6): `/v1/auth/web/start`, the Apple `form_post` and Google callbacks, handoff with PKCE, the web refresh cookie and CORS for `guest.herdrup.app` (moved here from PR1, next to their only clients), migration `0004_web_flows.sql`. Apps: HerdrKit `AccountClient`, `AccountSession` (Keychain), `DeviceEnroller`, `StatementCache`, `SyncEngine` (Linux-testable, protocols like `GuestKeyStore`); onboarding 1B with Apple + Google; account screen (devices, sign-out, delete); desktop `internal/account` + `herdrup://account#`; web guest sign-in. | Worker: web `state` reuse, handoff without/with wrong verifier, CORS only for `guest.herdrup.app`, cookie flags. HerdrKit unit tests with URLProtocol stubs (single-flight refresh, 401 → re-auth, PoP vector); sync merge tests; encoder test that payloads hold no secret patterns; UI test for 1B with a mock server; Go tests for the handoff and Secrets fallback; web guest vitest for the cookie flow. |
| 6 | jerryfane/herdr (#440) | **Account-bound shares on the host.** Statement verify (ring Ed25519), JWKS cache, `GuestRecord.account`/`devices`, hello `account`, in-band refresh, `guest.revoke {person}`, `guest.remove_device`, `acct:1` in invites, config switch. | Golden statements from PR 2; expired / wrong `aud` / wrong `dev` / unknown `kid` → refetch / stale-JWKS grace; plain shares unchanged (old `guests.json` loads); account-bound device without statement refused; new device added + audit; removed device refused with a valid statement; revoke by person closes live sessions; session closed at the statement deadline. |
| 7 | herdrup + herdrup-desktop | **2A + 4B (#700).** Invite screen with "Add to my account" / "Only this device" (only for `acct:1`), share list from `shares` sync, owner page per person (devices, shares, revoke once, remove device). Relay CSP `connect-src`. | UI tests for 2A both paths and for old invites (plain Accept); 4B grouping by `person`; revoke-once calls `guest.revoke {person}`; GuestRelay `npm test` covers the `_headers` CSP. |
| 8 | herdrup-web + App Store Connect | **Policy + labels + review notes (#701).** | Site build; a reviewer reads the policy diff against §7. |

PRs 1–4 can merge without any owner credentials: tests use generated keys. **Deploying** PR 1
needs the "first PR" items in §10.

---

## 10. Owner setup checklist

**[PR1]** = needed before the first deploy. **[later: PRn]** = needed before that PR ships.
Nothing here is done by an agent; no secrets have been created.

### Apple Developer (team FXQ5Z9HHY6)

1. **[PR1] Services ID** (for the web and desktop flows):
   1. Certificates, Identifiers & Profiles → Identifiers → + → Services IDs.
   2. Description "HerdrUp sign-in"; Identifier **`com.jerryfane.herdr.signin`** (recommended).
   3. Enable *Sign in with Apple* → Configure:
      - Primary App ID: `com.jerryfane.herdr`.
      - Domains: `accounts.herdrup.app`.
      - Return URLs: `https://accounts.herdrup.app/v1/auth/web/apple/callback`.
   4. Save.
   - Copy the Services ID → `wrangler.toml` `APPLE_WEB_CLIENT_ID` (public).
2. **[PR1 for the native path; required before PR5 ships] App ID capability:**
   1. Identifiers → `com.jerryfane.herdr` → enable **Sign in with Apple** ("Enable as a primary
      App ID") → Save.
   2. Regenerate the **"Herdrup App Store"** profile and the development profile; the old ones
      become invalid.
   - project.yml has no separate Mac target: the Mac app is the same iOS binary ("Designed for
     iPad", `SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD: YES`). The widget, notification-service and
     share extensions (`.widgets`, `.notificationservice`, `.share`) do **not** need it.
   - PR5 adds `com.apple.developer.applesignin = [Default]` to App/Herdr.entitlements.
3. **[later: PR4] Sign in with Apple key:**
   1. Keys → + → name "HerdrUp Sign in with Apple" → enable *Sign in with Apple* → Configure →
      Primary App ID `com.jerryfane.herdr` → Save → Continue → Register.
   2. **Download the .p8** (once only) and copy the **Key ID**.
   - Key ID → `wrangler.toml` `APPLE_KEY_ID` (public).
   - .p8 → Worker secret, pasted once and straight from the file:
     `npx wrangler secret put APPLE_SIWA_P8 < AuthKey_<KeyID>.p8`. Never paste it into chat or a repo.
   - Delete the downloaded file afterwards.
4. **[later: PR4] Server-to-server notifications:** Identifiers → `com.jerryfane.herdr` →
   Sign in with Apple → Edit → Server-to-Server Notification Endpoint:
   `https://accounts.herdrup.app/v1/apple/notifications`.

### Google Cloud

5. **[PR1] Project and consent screen: DONE** (19 Nov; owner decision: the existing Google Cloud
   project **`themartianapp`**, app name **TheMartian**, now In production):
   1. Project `themartianapp` → Google Auth Platform → **Branding**:
      - App name TheMartian, support email, logo;
      - App domain `https://herdrup.app`;
      - Privacy policy `https://herdrup.app/legal/privacy`; Terms `https://herdrup.app/legal/terms`;
      - Authorized domain `herdrup.app`.
   2. **Audience:** External → **Publish app** (In production).
   3. **Data access:** scopes `openid` and `.../auth/userinfo.email` only. Both are non-sensitive,
      so no Google security review is needed; a logo needs brand verification.
6. **[PR1] iOS client: DONE** (19 Nov), in project `themartianapp`: bundle ID
   `com.jerryfane.herdr`, team ID `FXQ5Z9HHY6`.
   - Client ID `552913387875-ujv6unveo5qtmmbnapogekc5jl8h6olk.apps.googleusercontent.com`, in
     `wrangler.toml` `GOOGLE_IOS_CLIENT_ID` (PR1). PR5 puts it in the app config and adds its
     reversed form `com.googleusercontent.apps.552913387875-ujv6unveo5qtmmbnapogekc5jl8h6olk` as a
     URL scheme next to `herdrup` in project.yml.
   - There is no secret.
7. **[PR1] Web client: DONE** (19 Nov), in project `themartianapp`, redirect URI
   `https://accounts.herdrup.app/v1/auth/web/google/callback`.
   - Client ID `552913387875-0te8j0cm9tmt5ifai9m8nlc1igdhi844.apps.googleusercontent.com`, in
     `wrangler.toml` `GOOGLE_WEB_CLIENT_ID` (PR1).
   - **Client secret:** nobody else has read it. The owner pastes it into the Worker secret
     `GOOGLE_WEB_CLIENT_SECRET` at the first deploy (`npx wrangler secret put GOOGLE_WEB_CLIENT_SECRET`).
     PR5's web flow is the first code that reads it.

### Cloudflare (the account that holds `herdrup.app` and `herdrup-guest`)

8. **[PR1] D1 in the EU jurisdiction: DONE** (19 Nov, 08:20Z via the Cloudflare API): name
   `herdrup-accounts`, `database_id = b045413f-9d97-4568-a2aa-3fb7ab87ba28`, jurisdiction `eu`,
   already in `AccountService/wrangler.toml` (PR1). Left before the first deploy:
   `npx wrangler d1 migrations apply herdrup-accounts --remote`.
9. **[PR1] Custom domain:** nothing manual. The `routes = [{ pattern = "accounts.herdrup.app",
   custom_domain = true }]` entry attaches it on the first `wrangler deploy`, as for
   `guest.herdrup.app`. The `herdrup.app` zone must be on the same account.
10. **[PR1] Root HMAC key**, the one secret that must never be lost:
    ```sh
    openssl rand -base64 32 | tr -d '\n' \
      | tee >(npx wrangler secret put ACCOUNT_HMAC_KEY) \
      | keyring set --store <the keyring store> --file /dev/stdin HERDRUP_ACCOUNTS_HMAC_KEY
    ```
    Same value in both places, never printed. Losing it orphans every account and changes every
    pairwise id.
11. **[later: PR2] Statement signing key:** generated straight into the Worker, slot A. No copy
    is needed: if it is lost, rotate.
    ```sh
    openssl genpkey -algorithm ed25519 -outform DER | base64 | tr -d '\n' | npx wrangler secret put STATEMENT_KEY_A
    ```
    The public JWK for `jwks.json` is derived by the Worker from the key. `wrangler.toml` already
    sets `STATEMENT_ACTIVE = "A"` and `STATEMENT_KID_A = "2026-11a"`. Also apply migration
    `0002_devices.sql` before deploying PR2.
12. **[later: PR4]** Nothing beyond step 3: the Worker signs the Apple client secrets itself
    from `APPLE_SIWA_P8`.
13. **[before PR5 ships] Plan:** confirm Workers Free is acceptable, or move to Workers Paid when
    a §1.4 trigger fires.

### Where each value goes

| Value | Secret? | Goes to |
|---|---|---|
| Team ID `FXQ5Z9HHY6`, App ID `com.jerryfane.herdr` | No | `wrangler.toml` vars (already known) |
| Services ID | No | `APPLE_WEB_CLIENT_ID` var |
| SIWA Key ID | No | `APPLE_KEY_ID` var |
| SIWA .p8 | **Yes** | Worker secret `APPLE_SIWA_P8` (pasted once) |
| Google iOS client ID | No | `GOOGLE_IOS_CLIENT_ID` var (`552913387875-ujv6unveo5qtmmbnapogekc5jl8h6olk.apps.googleusercontent.com`) + app config |
| Google web client ID | No | `GOOGLE_WEB_CLIENT_ID` var (`552913387875-0te8j0cm9tmt5ifai9m8nlc1igdhi844.apps.googleusercontent.com`) |
| Google web client secret | **Yes** | Worker secret `GOOGLE_WEB_CLIENT_SECRET`, pasted by the owner at the first deploy |
| D1 `database_id` | No | `wrangler.toml` |
| `ACCOUNT_HMAC_KEY` | **Yes** | keyring `HERDRUP_ACCOUNTS_HMAC_KEY` + Worker secret |
| `STATEMENT_KEY_A`, `STATEMENT_KEY_B` | **Yes** | Worker secrets only (two rotation slots) |
| Google review test account | **Yes** | keyring, App Store Connect review notes |

---

## 11. Owner decisions (19 Nov)

The owner approved the design. Items 1, 7, 9 and 10 are his explicit choices; the rest are the
recommended defaults he accepted.

1. **Sign in with Apple .p8:** a Cloudflare Worker secret (`APPLE_SIWA_P8`) that the owner
   pastes once. No keyring service, no scheduled job.
2. **Cloudflare plan:** stay on Free now. Move to Workers Paid ($5/month) when a §1.4 trigger
   fires (requests > 70k/day, D1 > 400 MB, or writes > 70k/day).
3. **Pairwise account ids per host:** yes. Owners can't correlate guests across machines;
   revoke-once is per host anyway.
4. **Email:** Google with `openid email`, shown on the device only, never stored or logged.
   No scopes for Apple.
5. **Linking Apple and Google into one account:** not in v1. The `identities` table already
   allows several per account, so an explicit "Add Google to this account" can come later.
   Never merge by email.
6. **Statement lifetime:** 10 minutes.
7. **A guest's account adds a device to a share:** allowed without approval; the owner gets an
   audit entry and a push ("Alice added a device").
8. **herdr `[guest] accounts`:** on by default, with the switch to turn it off per machine.
9. **Accounts unused for 24 months:** deleted by the hourly cron, and the privacy policy says so.
   There is no email to warn people first.
10. **D1 location:** EU jurisdiction (`--jurisdiction eu`), fixed at creation.
11. **Host-key pins:** not synced; they stay device-local trust on first use.
12. **Services ID identifier:** `com.jerryfane.herdr.signin`.

---

## 12. Browser approval for owner access (approve-v1, 22 Nov)

Built from the web owner access wire plan (`herdrup-accounts-mockups/web-owner/WIRE-PLAN.md`
§2, approved 22 Nov, with the owner's decisions and clarifications at its end). This is step A1:
the account service's side. Code: `src/approvals.ts`, migration `0006_browser_access.sql`.

### 12.1 What the service is, and isn't

A browser (a device with platform `web`, enrolled with `POST /v1/devices` as before) asks one of
the account's other devices, the approver, to let it reach the owner's machines. The approver
writes a grant on each machine over SSH (`owner_access.add` in herdr). The service is a
**mailbox and a display cache, never authority**: it can't create or widen a grant, and the
state Devices shows (`waiting` / `approved` / `expired`) is only what the approver reported.
Machines bind each grant to the browser's Noise key **and** a fresh statement for the account,
so removing the browser from Devices ends its access on every online machine within about 11
minutes (§12.4).

### 12.2 Commit, then reveal

B is the browser's X25519 device key, T the approver's. Byte strings are fixed-length; labels
are ASCII followed by `0x00`; every binary field on the wire is **unpadded base64url** (a
32-byte value is exactly 43 characters, canonical).

```
commit = SHA-256("herdrup-approve-v1|commit" ‖ 0x00 ‖ B ‖ nonce_b)
h      = SHA-256("herdrup-approve-v1|sas"    ‖ 0x00 ‖ B ‖ T ‖ nonce_b ‖ nonce_t)
code   = uint32_be(h[0..4]) mod 10000, 4 digits, zero-padded
```

1. B makes `nonce_b` and posts `commit` (`POST /v1/approvals`). It shows no code yet.
2. T lists requests (`GET /v1/approvals`), makes `nonce_t` and claims one
   (`POST /v1/approvals/<id>/claim`). The service records T from the session's device row,
   never from the body.
3. B reads T's key and `nonce_t` (`GET /v1/approvals/<id>`), then reveals `nonce_b`
   (`…/reveal`). The service checks it opens the commit; a mismatch is `400 reveal_mismatch` and
   ends the request (`denied`). B shows the code.
4. T reads `nonce_b` (only the claimant gets it), checks the commit itself, and computes the code.
5. The user **types** the browser's 4 digits on T (owner decision 3, 22 Nov). T approves only on
   a match and finishes (`…/finish`) with the scope and expiry it granted and the sealed machine
   list (§12.3), or denies.

Neither side can steer the code after it sees the other's randomness, so a service that swaps B
or T makes the two codes match with probability 10⁻⁴ per attempt, and each attempt needs a
person to type a code. What the service enforces for that argument:

- each step runs once, in order (claim → reveal → finish), guarded in the updating statement:
  a second claim is `409 already_claimed`, a second reveal `409 already_revealed`, a second
  finish `409 already_finished`; a reveal before the claim is `409 not_claimed`; approval before
  the reveal is `409 not_revealed`;
- only the claimant finishes; a browser sees only its own request; another account's devices
  see nothing (`404`);
- a browser can't claim (`403 not_an_approver`) and an approver can't ask (`403 not_a_browser`);
- a request lives 10 minutes (`410 expired` after), and a new request replaces the browser's
  live one (one per browser);
- **a reported expiry is final.** Every read of approval state (`GET /v1/approvals/<id>`, the
  approver's list, Devices, `GET /v1/browsers/self`, and each step before it acts) first stores
  `outcome = 'expired'` for the account's live requests past their 10 minutes, in the same batch
  as the read, and answers from the row as it is afterwards. Every step's update requires
  `outcome IS NULL`, the finish's single-use gate included, so a finish or deny that started
  before the expiry (its clock read earlier, its Worker run slow) is refused with `410 expired`
  once the expiry is stored, and writes no envelope or access. The apps may treat a reported
  `expired` as final once health lists `approval_expiry_final` (migration
  `0007_approval_expiry.sql` lets `outcome` hold it);
- `APPROVAL_LIMIT` (30 / 60 s per account, every route, on top of `ACCOUNT_LIMIT`) and at most
  10 requests per account per hour (`429 too_many_requests`), counted in fixed hour windows per
  browser and summed over the account in the inserting statement.

The finished request stays readable for 10 minutes (`approved` or `denied`), so both sides
learn the outcome. The row is kept until its hour window ends, so the cap still counts it; the
hourly cron deletes it after both.

### 12.3 The sealed machine list

```
ikm    = X25519(t, B) = X25519(b, T)          (abort if all zero)
k      = HKDF-SHA256(ikm, salt = B ‖ T, info = "herdrup-approve-v1|envelope", 32)
aad    = "herdrup-approve-v1|envelope" ‖ 0x00 ‖ B ‖ T ‖ uint64_be(seq)
sealed = b64url(iv(12) ‖ AES-256-GCM(k, iv, aad, json))
```

The service stores `sealed` as sent (at most 16 KB, at least iv and tag) in `browser_envelopes`,
one per (browser, approver key), at most 20 per browser, and returns it only to that browser
(`GET /v1/browsers/self`). `seq` only grows per approver (`409 stale_seq`). Renewals and machine
changes come with `PUT /v1/browsers/<id>/envelope` from an approver whose envelope the browser
already holds (`403 not_approver` otherwise: another device runs the code flow first).

Each write of a report is one D1 batch (one transaction), and the access Devices shows moves
only with the envelope. For `finish`, the batch is the single-use gate on the request, the
envelope, the access, the request's `approved` mark and the withdrawal's removal. Each
statement after the gate runs only when the one before it changed a row (`changes() = 1`). A
failure anywhere leaves the request `revealed`, so the approver can retry. A report that loses
the seq race changes nothing, the shown access included.

`test/vectors/approve-v1.json` is herdrup-desktop's vector (`internal/account/testdata/approve-v1-local.json`
on its `accounts/web-approve` branch, from the RFC 7748 §6.1 keys). `test/approvals.test.ts`
regenerates it in TypeScript from the same inputs and asserts the file byte for byte (commit
`lX5iWjsh…`, code `7218`, an envelope sealed at seq 7).

### 12.4 Removal and withdrawals

Device removal is unchanged (owner decision 5, 22 Nov): any signed-in device, browsers
included, removes any device. Removing a browser deletes its sessions, request, access and
envelopes (`ON DELETE CASCADE`).

The first claim of a browser's request marks its device row (`devices.approval_claimed_ms`),
in the claim's own batch: from then on its approver may have written grants for the key. The
mark is independent of the request row. A replacement request (which clears the claim) doesn't
clear it, and neither does removing the approver (which deletes the request). When a marked
browser is removed, the same batch records a **withdrawal** of its key for 35 days, longer than
any grant, with herdr's fingerprint (`SHA256:xxxx·xxxx·xxxx·xxxx`).

**One spelling per key.** Enrolment accepts a device key only in canonical unpadded base64url:
43 characters whose re-encoding is the input (`400 bad_request` otherwise). Each 32-byte key
has four base64url spellings (the last character's two unused bits). Without this, a removed
browser could enrol its withdrawn key again under another spelling and get statements. Every
stored key (`devices`, and from them `withdrawals` and `browser_envelopes`) is therefore
canonical, so comparing the strings compares the keys.

- Approvers read `GET /v1/withdrawals` and remove the key's grants from their machines.
- **No statement is issued for a withdrawn key on the account** (`403 device_withdrawn`),
  even after the browser signs in and enrols the same key again (a stolen browser profile may
  hold a live Google or Apple login). A removed device already gets none (`403 device_removed`).
  Statements are what the machines check, so this is what ends access everywhere.
- An approval by code of that key, on the device it enrolled again, clears the withdrawal.

### 12.5 Data

| Table | Holds |
|---|---|
| `approval_requests` | one row per browser: commit, approver, nonces, outcome, expiry, the hour window's count |
| `browser_access` | the latest scope and expiry an approver reported |
| `browser_envelopes` | the sealed envelopes, opaque |
| `withdrawals` | removed browsers' keys and fingerprints, 35 days |

All four carry `account_id` and are in `ACCOUNT_TABLES`, so account deletion sweeps them.
