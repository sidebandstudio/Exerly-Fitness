-- What an Undo did, so replaying it answers the same. After an Undo, a
-- receipt's rows are only the deletions a later restore may bring back.

ALTER TABLE restores ADD COLUMN outcome jsonb;
CREATE INDEX restores_undone ON restores (account_id, undone_at);
