-- herdrup-accounts, migration 0008: pair-v1 (DESIGN.md §13). A signed-in app device (not a
-- browser) asks another of the account's app devices to add its new SSH key S to the owner's
-- machines. It is approve-v1's request with S bound into the commit and the code, so the
-- requests share approval_requests: the same steps, guards, expiry and hourly cap. A row's kind
-- says which protocol it runs. 'browser' is approve-v1, and every existing row is one.
--
-- A pair request carries S (ssh_pub) from its creation. The approver's sealed machine list
-- (seq, sealed) is written by the finish and replaced only by a higher seq. Its requester may
-- cancel it before the finish (outcome 'cancelled', pair requests only). The service never sees
-- machine addresses or per-machine results.
--
-- SQLite can't change a CHECK in place, so the table is rebuilt, as in 0007, with the same rows
-- and indexes, the new columns, and a CHECK that also allows 'cancelled'. Nothing references
-- approval_requests.
ALTER TABLE approval_requests RENAME TO approval_requests_0007;

CREATE TABLE approval_requests (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
  browser_device_id TEXT NOT NULL UNIQUE REFERENCES devices (id) ON DELETE CASCADE,
  "commit" TEXT NOT NULL,
  approver_device_id TEXT REFERENCES devices (id) ON DELETE CASCADE,
  nonce_t TEXT,
  nonce_b TEXT,
  outcome TEXT CHECK (outcome IN ('approved', 'denied', 'expired', 'cancelled')),
  created_ms INTEGER NOT NULL,
  exp_ms INTEGER NOT NULL,
  starts INTEGER NOT NULL,
  starts_ms INTEGER NOT NULL,
  kind TEXT NOT NULL DEFAULT 'browser' CHECK (kind IN ('browser', 'pair')),
  ssh_pub TEXT,
  seq INTEGER,
  sealed TEXT,
  CHECK ((nonce_t IS NULL) = (approver_device_id IS NULL)),
  CHECK (nonce_b IS NULL OR nonce_t IS NOT NULL),
  CHECK ((ssh_pub IS NOT NULL) = (kind = 'pair')),
  CHECK (seq IS NULL OR (kind = 'pair' AND seq >= 1)),
  CHECK ((sealed IS NULL) = (seq IS NULL)),
  CHECK (outcome IS NOT 'cancelled' OR kind = 'pair')
) STRICT;

INSERT INTO approval_requests
  (id, account_id, browser_device_id, "commit", approver_device_id, nonce_t, nonce_b, outcome, created_ms, exp_ms, starts, starts_ms)
SELECT id, account_id, browser_device_id, "commit", approver_device_id, nonce_t, nonce_b, outcome, created_ms, exp_ms, starts, starts_ms
  FROM approval_requests_0007;

-- The old table's indexes go with it; then they are made again on the new one.
DROP TABLE approval_requests_0007;

CREATE INDEX approval_requests_account ON approval_requests (account_id, created_ms);
CREATE INDEX approval_requests_approver ON approval_requests (approver_device_id);
CREATE INDEX approval_requests_exp ON approval_requests (exp_ms);

-- One PushRelay device capability (hpr1.…) per iOS device, for pair-request alerts. It is
-- opaque here: PushRelay alone can open it. It goes with its device, and is cleared when the
-- relay answers 410 (APNs says the token is gone).
CREATE TABLE push_capabilities (
  device_id TEXT PRIMARY KEY REFERENCES devices (id) ON DELETE CASCADE,
  account_id TEXT NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
  capability TEXT NOT NULL,
  updated_ms INTEGER NOT NULL
) STRICT;

CREATE INDEX push_capabilities_account ON push_capabilities (account_id);
