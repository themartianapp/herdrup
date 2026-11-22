-- herdrup-accounts, migration 0006: browser approval for owner access, protocol approve-v1
-- (DESIGN.md §12). A browser (a device with platform 'web') asks one of the account's other
-- devices to let it reach the owner's machines; that device approves by the 4-digit code and
-- writes the grants on each machine over SSH. These tables are a display cache and a mailbox,
-- never authority: the machines' grants decide, and the service can't create or widen one.

-- One approval request per browser, live 10 minutes. The row stays after its outcome
-- (approved or denied) for 10 more minutes, so both sides can read it, and until an hour after
-- its window started, so the hourly cap still counts it. Single use: each step runs once, in
-- order (claim → reveal → finish), each guarded by the inserting or updating statement.
--   commit              SHA-256("herdrup-approve-v1|commit" ‖ 0x00 ‖ B ‖ nonce_b), base64url.
--   approver_device_id  the claimant, taken from its session's device, never from a body.
--   nonce_t, nonce_b    32 bytes each, base64url, set once by the claim and the reveal.
--   outcome             NULL while live; 'approved' or 'denied' once finished. A reveal that
--                       doesn't open the commit ends the request as 'denied'.
--   starts, starts_ms   how many requests this browser made in the hour window that began at
--                       starts_ms (the per-account hourly cap sums them).
CREATE TABLE approval_requests (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
  browser_device_id TEXT NOT NULL UNIQUE REFERENCES devices (id) ON DELETE CASCADE,
  "commit" TEXT NOT NULL,
  approver_device_id TEXT REFERENCES devices (id) ON DELETE CASCADE,
  nonce_t TEXT,
  nonce_b TEXT,
  outcome TEXT CHECK (outcome IN ('approved', 'denied')),
  created_ms INTEGER NOT NULL,
  exp_ms INTEGER NOT NULL,
  starts INTEGER NOT NULL,
  starts_ms INTEGER NOT NULL,
  CHECK ((nonce_t IS NULL) = (approver_device_id IS NULL)),
  CHECK (nonce_b IS NULL OR nonce_t IS NOT NULL)
) STRICT;

CREATE INDEX approval_requests_account ON approval_requests (account_id, created_ms);
CREATE INDEX approval_requests_approver ON approval_requests (approver_device_id);
CREATE INDEX approval_requests_exp ON approval_requests (exp_ms);

-- The latest scope and expiry an approver reported for a browser: what Devices shows.
CREATE TABLE browser_access (
  device_id TEXT PRIMARY KEY REFERENCES devices (id) ON DELETE CASCADE,
  account_id TEXT NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
  scope TEXT NOT NULL CHECK (scope IN ('chat', 'terminal')),
  expires_ms INTEGER NOT NULL,
  approved_ms INTEGER NOT NULL,
  updated_ms INTEGER NOT NULL
) STRICT, WITHOUT ROWID;

CREATE INDEX browser_access_account ON browser_access (account_id);

-- The machine list each verified approver sealed for a browser (approve-v1 envelope):
-- unpadded base64url of iv ‖ AES-256-GCM, opaque here, and returned only to that browser.
-- seq only grows per (browser, approver).
CREATE TABLE browser_envelopes (
  device_id TEXT NOT NULL REFERENCES devices (id) ON DELETE CASCADE,
  approver_pub TEXT NOT NULL,
  account_id TEXT NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
  seq INTEGER NOT NULL,
  sealed TEXT NOT NULL,
  updated_ms INTEGER NOT NULL,
  PRIMARY KEY (device_id, approver_pub)
) STRICT, WITHOUT ROWID;

CREATE INDEX browser_envelopes_account ON browser_envelopes (account_id);

-- When a request of this browser was first claimed: from then on its approver may have written
-- grants for the browser's key on machines. On the device row, so neither a replacement request
-- (which clears the claim) nor the approver's removal (which deletes the request) loses it.
ALTER TABLE devices ADD COLUMN approval_claimed_ms INTEGER;

-- A browser whose request was ever claimed (approval_claimed_ms set), removed from Devices, for
-- 35 days, longer than any grant: approvers sweep its grants from their machines, and no
-- statement is issued for its key on this account meanwhile, even if it signs in and enrols
-- again, until an approver approves it again. device_pub is the canonical base64url every
-- devices row holds (enrolment refuses any other spelling). fingerprint is herdr's ("SHA256:xxxx·…").
CREATE TABLE withdrawals (
  account_id TEXT NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
  device_pub TEXT NOT NULL,
  fingerprint TEXT NOT NULL,
  created_ms INTEGER NOT NULL,
  exp_ms INTEGER NOT NULL,
  PRIMARY KEY (account_id, device_pub)
) STRICT, WITHOUT ROWID;

CREATE INDEX withdrawals_exp ON withdrawals (exp_ms);
