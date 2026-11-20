-- herdrup-accounts, migration 0002 (herdrup#698, step 2): devices and their enrolment.

-- A device is one install's guest key: the X25519 public key (32 bytes, base64url, 43
-- characters) it proves in every Noise IK handshake with a host. Its private half never leaves
-- the device. A key belongs to one account at a time. last_statement_day is the UTC day number
-- of the last statement issued for it, written at most once a day.
CREATE TABLE devices (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
  device_pub TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  platform TEXT NOT NULL,
  created_ms INTEGER NOT NULL,
  last_statement_day INTEGER NOT NULL DEFAULT 0
) STRICT;

CREATE INDEX devices_account ON devices (account_id, created_ms);

-- The device a session enrolled, set once. Removing the device ends the sessions bound to it.
ALTER TABLE sessions ADD COLUMN device_id TEXT REFERENCES devices (id) ON DELETE CASCADE;

CREATE INDEX sessions_device ON sessions (device_id);

-- A pending enrolment: the Worker's ephemeral X25519 private key (PKCS8, base64url) and salt
-- for one session, for 60 seconds. Taken (deleted) by the enrolment that uses it, whatever
-- its outcome.
CREATE TABLE enrol_challenges (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
  session_id TEXT NOT NULL REFERENCES sessions (id) ON DELETE CASCADE,
  server_pkcs8 TEXT NOT NULL,
  salt TEXT NOT NULL,
  exp_ms INTEGER NOT NULL
) STRICT;

CREATE INDEX enrol_challenges_exp ON enrol_challenges (exp_ms);
CREATE INDEX enrol_challenges_session ON enrol_challenges (session_id);
