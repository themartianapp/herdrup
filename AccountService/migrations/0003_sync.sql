-- herdrup-accounts, migration 0003 (herdrup#698, step 3): sync of non-secret settings
-- (DESIGN.md §5). src/sync.ts validates every item against its collection's allowlist before
-- it gets here; this schema keeps the order of writes and the per-account caps.

-- Per account:
--   sync_rev         the last revision handed out; every write to sync_items takes the next one.
--   sync_floor       the highest revision of any tombstone pruned so far. A client whose cursor
--                    is below it may have missed a delete and must reset (410 reset_required).
--   sync_items       live items (tombstones excluded), at most 2,000.
--   sync_bytes       UTF-8 bytes of the live items' bodies, at most 1 MB.
--   sync_tombstones  tombstones kept; a push trims them to the newest 2,000.
-- The triggers below keep the counters; a write that would pass a cap fails its CHECK, which
-- rolls back the whole push (403 quota).
ALTER TABLE accounts ADD COLUMN sync_rev INTEGER NOT NULL DEFAULT 0;
ALTER TABLE accounts ADD COLUMN sync_floor INTEGER NOT NULL DEFAULT 0;
ALTER TABLE accounts ADD COLUMN sync_items INTEGER NOT NULL DEFAULT 0 CONSTRAINT sync_quota_items CHECK (sync_items <= 2000);
ALTER TABLE accounts ADD COLUMN sync_bytes INTEGER NOT NULL DEFAULT 0 CONSTRAINT sync_quota_bytes CHECK (sync_bytes <= 1048576);
ALTER TABLE accounts ADD COLUMN sync_tombstones INTEGER NOT NULL DEFAULT 0;

-- One row per synced item. body is the JSON the Worker re-serialised from the item's validated
-- fields; a tombstone (deleted = 1) has none. updated_ms is the server's clock at the write.
CREATE TABLE sync_items (
  account_id TEXT NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
  collection TEXT NOT NULL CHECK (collection IN ('hosts', 'prompts', 'settings', 'agent_prefs', 'shares')),
  item_id TEXT NOT NULL,
  rev INTEGER NOT NULL,
  updated_ms INTEGER NOT NULL,
  deleted INTEGER NOT NULL CHECK (deleted IN (0, 1)),
  body TEXT,
  CHECK ((deleted = 1) = (body IS NULL)),
  PRIMARY KEY (account_id, collection, item_id)
) STRICT, WITHOUT ROWID;

-- Pulls page through an account's items in revision order; revisions never repeat.
CREATE UNIQUE INDEX sync_items_rev ON sync_items (account_id, rev);
-- Tombstones: trimmed per account by revision, pruned by the hourly cron by age.
CREATE INDEX sync_items_tombstone_rev ON sync_items (account_id, rev) WHERE deleted = 1;
CREATE INDEX sync_items_tombstone_age ON sync_items (updated_ms) WHERE deleted = 1;

-- Live items per collection, against each collection's cap.
CREATE TABLE sync_usage (
  account_id TEXT NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
  collection TEXT NOT NULL,
  items INTEGER NOT NULL CONSTRAINT sync_quota_collection CHECK (
    items <= CASE collection
      WHEN 'hosts' THEN 200
      WHEN 'prompts' THEN 500
      WHEN 'settings' THEN 300
      WHEN 'agent_prefs' THEN 1000
      WHEN 'shares' THEN 500
      ELSE 0
    END
  ),
  PRIMARY KEY (account_id, collection)
) STRICT, WITHOUT ROWID;

CREATE TRIGGER sync_items_insert AFTER INSERT ON sync_items
BEGIN
  UPDATE accounts SET
    sync_rev = max(sync_rev, NEW.rev),
    sync_items = sync_items + (NEW.deleted = 0),
    sync_bytes = sync_bytes + COALESCE(length(CAST(NEW.body AS BLOB)), 0),
    sync_tombstones = sync_tombstones + NEW.deleted
  WHERE id = NEW.account_id;
  INSERT OR IGNORE INTO sync_usage (account_id, collection, items) VALUES (NEW.account_id, NEW.collection, 0);
  UPDATE sync_usage SET items = items + (NEW.deleted = 0)
  WHERE account_id = NEW.account_id AND collection = NEW.collection;
END;

-- The key columns never change: a write replaces an item's revision, time, state and body.
CREATE TRIGGER sync_items_update AFTER UPDATE ON sync_items
BEGIN
  UPDATE accounts SET
    sync_rev = max(sync_rev, NEW.rev),
    sync_items = sync_items + (NEW.deleted = 0) - (OLD.deleted = 0),
    sync_bytes = sync_bytes + COALESCE(length(CAST(NEW.body AS BLOB)), 0) - COALESCE(length(CAST(OLD.body AS BLOB)), 0),
    sync_tombstones = sync_tombstones + NEW.deleted - OLD.deleted
  WHERE id = NEW.account_id;
  UPDATE sync_usage SET items = items + (NEW.deleted = 0) - (OLD.deleted = 0)
  WHERE account_id = NEW.account_id AND collection = NEW.collection;
END;

-- Pruning removes tombstones only; an account's deletion removes everything, and then these
-- updates find no row.
CREATE TRIGGER sync_items_delete AFTER DELETE ON sync_items
BEGIN
  UPDATE accounts SET
    sync_items = sync_items - (OLD.deleted = 0),
    sync_bytes = sync_bytes - COALESCE(length(CAST(OLD.body AS BLOB)), 0),
    sync_tombstones = sync_tombstones - OLD.deleted
  WHERE id = OLD.account_id;
  UPDATE sync_usage SET items = items - (OLD.deleted = 0)
  WHERE account_id = OLD.account_id AND collection = OLD.collection;
END;
