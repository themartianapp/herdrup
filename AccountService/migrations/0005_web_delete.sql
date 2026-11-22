-- herdrup-accounts, migration 0005 (herdrup#698): deleting an account from the web flow
-- (DESIGN.md §6.6). herdrup-desktop signs in through the browser and never holds an ID token,
-- so it confirms a deletion with a fresh web sign-in instead.

-- A deletion's web sign-in, asked for by an authenticated session (POST /v1/account/delete/start)
-- and taken by the browser's GET /v1/auth/web/start?purpose=delete&ticket=…, 5 minutes at most,
-- once. ticket_hash is the SHA-256 hex of the ticket in the start URL; handoff_challenge is S256
-- of the verifier only the app holds.
CREATE TABLE delete_tickets (
  ticket_hash TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
  session_id TEXT NOT NULL REFERENCES sessions (id) ON DELETE CASCADE,
  provider TEXT NOT NULL CHECK (provider IN ('apple', 'google')),
  handoff_challenge TEXT NOT NULL,
  exp_ms INTEGER NOT NULL
) STRICT, WITHOUT ROWID;

CREATE INDEX delete_tickets_exp ON delete_tickets (exp_ms);
CREATE INDEX delete_tickets_account ON delete_tickets (account_id);
CREATE INDEX delete_tickets_session ON delete_tickets (session_id);

-- A web flow is a sign-in or a deletion's confirmation. A deletion's flow carries the account
-- and session that asked for it; its callback never makes an account or a session.
ALTER TABLE web_flows ADD COLUMN purpose TEXT NOT NULL DEFAULT 'sign_in' CHECK (purpose IN ('sign_in', 'delete'));
ALTER TABLE web_flows ADD COLUMN account_id TEXT REFERENCES accounts (id) ON DELETE CASCADE;
ALTER TABLE web_flows ADD COLUMN session_id TEXT REFERENCES sessions (id) ON DELETE CASCADE;

CREATE INDEX web_flows_account ON web_flows (account_id);
CREATE INDEX web_flows_session ON web_flows (session_id);

-- A confirmed deletion waiting for the app: POST /v1/account/delete {handoff_code,
-- handoff_verifier} from the same session redeems it, within 5 minutes, once. Its own table, so a
-- sign-in handoff code can never delete and a delete code can never sign in.
--   provider, subject_hash  the identity the confirmation signed in as.
--   client_id               the ID token's audience (the Services ID or the Google web client):
--                           the client Apple issued the authorization code to.
--   apple_code              Apple only: the sign-in's authorization code, for the revoke,
--                           sealed (AES-GCM) under a key derived from the handoff code, so the
--                           table never holds it readably.
CREATE TABLE delete_handoffs (
  code_hash TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
  session_id TEXT NOT NULL REFERENCES sessions (id) ON DELETE CASCADE,
  provider TEXT NOT NULL CHECK (provider IN ('apple', 'google')),
  subject_hash TEXT NOT NULL,
  client_id TEXT NOT NULL,
  handoff_challenge TEXT NOT NULL,
  apple_code TEXT,
  exp_ms INTEGER NOT NULL
) STRICT, WITHOUT ROWID;

CREATE INDEX delete_handoffs_exp ON delete_handoffs (exp_ms);
CREATE INDEX delete_handoffs_account ON delete_handoffs (account_id);
CREATE INDEX delete_handoffs_session ON delete_handoffs (session_id);
