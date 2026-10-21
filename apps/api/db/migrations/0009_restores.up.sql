-- What each restore of an export's older tables added: the table, row ID and a
-- fingerprint of every row, so Undo removes exactly those rows and only while
-- they are unchanged. See lib/portability.js.

CREATE TABLE restores (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  seq bigint GENERATED ALWAYS AS IDENTITY,
  account_id uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  rows jsonb NOT NULL,
  created_at timestamptz NOT NULL,
  undone_at timestamptz
);
CREATE INDEX restores_account ON restores (account_id);
