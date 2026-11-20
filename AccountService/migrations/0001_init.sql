-- herdrup-accounts, migration 0001 (herdrup#698, step 1 of the account service): accounts,
-- their sign-in identities, sessions and spent sign-in nonces. Devices, statements and sync
-- add their own tables in later migrations.

-- One row per account. last_seen_day is the UTC day number (ms / 86,400,000) of the last
-- sign-in or refresh, written at most once a day; the hourly cleanup deletes accounts not
-- seen for 24 months.
CREATE TABLE accounts (
  id TEXT PRIMARY KEY,
  created_ms INTEGER NOT NULL,
  last_seen_day INTEGER NOT NULL
) STRICT;

CREATE INDEX accounts_last_seen ON accounts (last_seen_day);

-- A provider's user, by HMAC-SHA256(ACCOUNT_HMAC_KEY subkey, "<provider>|<sub>") in hex. The
-- provider's own user id and any email are never stored.
CREATE TABLE identities (
  provider TEXT NOT NULL CHECK (provider IN ('apple', 'google')),
  subject_hash TEXT NOT NULL,
  account_id TEXT NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
  created_ms INTEGER NOT NULL,
  PRIMARY KEY (provider, subject_hash)
) STRICT, WITHOUT ROWID;

CREATE INDEX identities_account ON identities (account_id);

-- One row per session family: every rotation of its refresh token updates this row.
-- Hashes are SHA-256 hex of the tokens' 32 random bytes.
CREATE TABLE sessions (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
  access_hash TEXT NOT NULL,
  access_exp_ms INTEGER NOT NULL,
  refresh_hash TEXT NOT NULL,
  refresh_exp_ms INTEGER NOT NULL,
  platform TEXT NOT NULL,
  created_ms INTEGER NOT NULL
) STRICT;

CREATE INDEX sessions_account ON sessions (account_id, created_ms);
CREATE INDEX sessions_refresh_exp ON sessions (refresh_exp_ms);

-- Every refresh token a session rotated away, by SHA-256 hex, until the token's own expiry
-- (exp_ms): presenting any of them again revokes the session (theft). Past that expiry the
-- token is refused as expired anyway, so the hourly cleanup drops the row.
CREATE TABLE spent_refresh_tokens (
  session_id TEXT NOT NULL REFERENCES sessions (id) ON DELETE CASCADE,
  token_hash TEXT NOT NULL,
  exp_ms INTEGER NOT NULL,
  PRIMARY KEY (session_id, token_hash)
) STRICT, WITHOUT ROWID;

CREATE INDEX spent_refresh_tokens_exp ON spent_refresh_tokens (exp_ms);

-- Nonces already spent on a sign-in, by SHA-256 hex, until they would have expired anyway.
CREATE TABLE used_nonces (
  nonce_hash TEXT PRIMARY KEY,
  exp_ms INTEGER NOT NULL
) STRICT, WITHOUT ROWID;

CREATE INDEX used_nonces_exp ON used_nonces (exp_ms);
