-- Password reset codes. Only an HMAC of each code is stored, keyed with the
-- server secret and the account, so a copy of this table can't be used to
-- reset anyone. A code works once, for a short time, and a few wrong guesses
-- use it up. See routes/auth.js.

CREATE TABLE password_resets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  seq bigint GENERATED ALWAYS AS IDENTITY,
  account_id uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  code_hash text NOT NULL,
  attempts integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  used_at timestamptz
);
CREATE INDEX password_resets_account ON password_resets (account_id);
