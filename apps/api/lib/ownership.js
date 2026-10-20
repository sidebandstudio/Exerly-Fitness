// Which rows belong to an account, table by table. Account deletion and the
// data export both read this map, and a test fails if a table in the schema
// registry is missing from it, so a new table can't be forgotten.
//
// keys: columns that identify the owner. A row is the account's when any key
//       matches: account_id or id holds the account ID, email its email
//       address, userId the legacy AI owner ID.
// export: false for internal records (credentials, receipts, the change feed)
//         that are deleted with the account but are not the person's data.
// omit: columns never exported.
// single: one row per account, exported as an object (or null) under this key.

const OWNERSHIP = {
  users: { keys: ['id'], export: false },
  account_identities: { keys: ['account_id'], omit: ['subject'] },
  sessions: { keys: ['account_id'], export: false },
  personal_access_tokens: { keys: ['account_id'], export: false },
  password_resets: { keys: ['account_id'], export: false },
  webhooks: { keys: ['account_id'], omit: ['secret'] },
  operations: { keys: ['account_id'], export: false },
  sync_cursors: { keys: ['account_id'], export: false },
  sync_changes: { keys: ['account_id'], export: false },
  documents: { keys: ['account_id'] },
  onboarding_drafts: { keys: ['account_id'] },
  diary_days: { keys: ['account_id', 'email'] },
  target_versions: { keys: ['account_id', 'email'] },
  measurements: { keys: ['account_id'] },
  activities: { keys: ['account_id', 'email'] },
  food: { keys: ['account_id', 'email'] },
  sleep: { keys: ['account_id', 'email'] },
  weights: { keys: ['account_id', 'email'] },
  water: { keys: ['account_id', 'email'] },
  goals: { keys: ['email'], single: 'goals' },
  programs: { keys: ['email'], single: 'program' },
  checkins: { keys: ['email'] },
  library_foods: { keys: ['email'] },
  recipes: { keys: ['email'] },
  workouts: { keys: ['email'] },
  ai_plans: { keys: ['email', 'userId'] },
  ai_errors: { keys: ['email', 'userId'], export: false },
  // Shared caches and counters with no personal data.
  provider_budgets: { keys: [] },
  barcode_cache: { keys: [] },
  auth_nonces: { keys: [] },
};

/** One filter per owner key, for a user row. */
function ownerFilters(collection, user) {
  const values = { id: user.id, account_id: user.id, userId: user.id, email: user.email };
  return OWNERSHIP[collection].keys
    .filter((key) => values[key] != null)
    .map((key) => ({ [key]: String(values[key]) }));
}

module.exports = { OWNERSHIP, ownerFilters };
