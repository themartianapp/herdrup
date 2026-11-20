-- herdrup-accounts, migration 0004 (herdrup#698, step 5): the web sign-in flow for
-- herdrup-desktop and the web guest (DESIGN.md §2.3, §2.6).

-- One sign-in in progress, from GET /v1/auth/web/start to its provider's callback, 10 minutes
-- at most. Taken (deleted) by the callback that names its state, whatever the outcome, so a
-- state works once.
--   state_hash         SHA-256 hex of the state sent to the provider.
--   browser_hash       SHA-256 hex of the __Host-hu_flow cookie set on the browser that
--                      started the flow; the callback must come from that browser.
--   nonce              the sign-in nonce (src/nonce.ts) the ID token must carry.
--   pkce_verifier      Google only: the PKCE verifier for the code exchange.
--   handoff_challenge  client = 'app' only: S256 of the app's handoff verifier.
CREATE TABLE web_flows (
  state_hash TEXT PRIMARY KEY,
  provider TEXT NOT NULL CHECK (provider IN ('apple', 'google')),
  client TEXT NOT NULL CHECK (client IN ('app', 'web')),
  platform TEXT NOT NULL,
  browser_hash TEXT NOT NULL,
  nonce TEXT NOT NULL,
  pkce_verifier TEXT,
  handoff_challenge TEXT,
  exp_ms INTEGER NOT NULL,
  CHECK ((client = 'app') = (handoff_challenge IS NOT NULL)),
  CHECK ((provider = 'google') = (pkce_verifier IS NOT NULL))
) STRICT, WITHOUT ROWID;

CREATE INDEX web_flows_exp ON web_flows (exp_ms);

-- A finished sign-in waiting for the app (client = 'app') to redeem it with
-- POST /v1/auth/handoff, 2 minutes at most, once. code_hash is the SHA-256 hex of the code in
-- herdrup://account#code=…; handoff_challenge is S256 of the verifier only the app holds.
-- display_hint (Google's email, for the app to show) is sealed with a key derived from the
-- code itself, so the table never holds it readably.
CREATE TABLE handoffs (
  code_hash TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
  handoff_challenge TEXT NOT NULL,
  platform TEXT NOT NULL,
  created INTEGER NOT NULL CHECK (created IN (0, 1)),
  display_hint TEXT,
  exp_ms INTEGER NOT NULL
) STRICT, WITHOUT ROWID;

CREATE INDEX handoffs_exp ON handoffs (exp_ms);
CREATE INDEX handoffs_account ON handoffs (account_id);
