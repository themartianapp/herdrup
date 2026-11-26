-- herdrup-accounts, migration 0008: pair-v1 (DESIGN.md §13). A signed-in app device (not a
-- browser) asks another of the account's app devices to add its new SSH key S to the owner's
-- machines. It is approve-v1's request with S bound into the commit and the code, so the
-- requests share approval_requests: the same steps, guards, expiry and hourly cap. A row's kind
-- says which protocol it runs. 'browser' is approve-v1, and every existing row is one.
--
-- A pair request carries S (ssh_pub) from its creation. The approver's sealed machine list
-- (seq, sealed) is written by the finish and replaced only by a higher seq. The service never
-- sees machine addresses or per-machine results.
ALTER TABLE approval_requests ADD COLUMN kind TEXT NOT NULL DEFAULT 'browser' CHECK (kind IN ('browser', 'pair'));
ALTER TABLE approval_requests ADD COLUMN ssh_pub TEXT CHECK ((ssh_pub IS NOT NULL) = (kind = 'pair'));
ALTER TABLE approval_requests ADD COLUMN seq INTEGER CHECK (seq IS NULL OR (kind = 'pair' AND seq >= 1));
ALTER TABLE approval_requests ADD COLUMN sealed TEXT CHECK ((sealed IS NULL) = (seq IS NULL));

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
