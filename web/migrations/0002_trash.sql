-- Trashing a call keeps its files and hides it; restoring clears this. A daily cron
-- deletes calls that have sat in the trash for 30 days.
ALTER TABLE calls ADD COLUMN trashed_at INTEGER;
CREATE INDEX calls_trashed ON calls (trashed_at);
