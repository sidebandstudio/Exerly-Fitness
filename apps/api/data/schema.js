// Collection registry shared by both storage drivers.
//
// One definition per collection drives: the Mongoose schema in the Mongo driver,
// the CREATE TABLE in the SQLite driver, and the JSON-column list both use to
// (de)serialize object fields. Adding a field here is the only edit needed for
// it to exist in both modes.
//
// `collection` is the physical Mongo collection name. It is pinned explicitly
// because Mongoose's pluralizer produced the existing production names
// (Food -> 'foods', Sleep -> 'sleeps', AIPlan -> 'aiplans') and renaming them
// would orphan live data.

const t = {
  str: 'string',
  num: 'number',
  bool: 'boolean',
  date: 'date',
  json: 'json',
};

const collections = {
  sync_cursors: {
    collection: 'synccursors',
    fields: { account_id: t.str, sequence: t.num },
    indexes: [{ keys: { account_id: 1 }, unique: true }],
  },
  sync_changes: {
    collection: 'syncchanges',
    fields: {
      account_id: t.str,
      sequence: t.num,
      kind: t.str,
      entity_id: t.str,
      server_id: t.str,
      revision: t.num,
      deleted: t.bool,
      payload: t.json,
      created_at: t.date,
    },
    indexes: [{ keys: { account_id: 1, sequence: 1 }, unique: true }],
  },
  sessions: {
    collection: 'sessions',
    fields: {
      account_id: t.str,
      session_id: t.str,
      refresh_hash: t.str,
      previous_refresh_hash: t.str,
      previous_operation: t.str,
      generation: t.num,
      credentials_version: t.num,
      device_name: t.str,
      created_at: t.date,
      updated_at: t.date,
      expires_at: t.date,
      revoked_at: t.date,
    },
    indexes: [{ keys: { session_id: 1 }, unique: true }, { keys: { account_id: 1 } }],
  },
  provider_budgets: {
    collection: 'providerbudgets',
    fields: { key: t.str, count: t.num, blocked_until: t.date, created_at: t.date },
    indexes: [{ keys: { key: 1 }, unique: true }],
  },
  operations: {
    collection: 'operations',
    fields: {
      account_id: t.str,
      key: t.str,
      fingerprint: t.str,
      status: t.num,
      response: t.json,
      created_at: t.date,
    },
    indexes: [{ keys: { account_id: 1, key: 1 }, unique: true }],
  },
  onboarding_drafts: {
    collection: 'onboardingdrafts',
    fields: {
      account_id: t.str,
      schema_version: t.num,
      revision: t.num,
      last_valid_step: t.num,
      answers: t.json,
      updated_at: t.date,
    },
    indexes: [{ keys: { account_id: 1 }, unique: true }],
  },
  diary_days: {
    collection: 'diarydays',
    fields: {
      email: t.str,
      account_id: t.str,
      entry_date: t.str,
      status: t.str,
      note: t.str,
      revision: t.num,
      updated_at: t.date,
    },
    indexes: [{ keys: { email: 1, entry_date: 1 }, unique: true }],
  },
  target_versions: {
    collection: 'targetversions',
    fields: {
      email: t.str,
      account_id: t.str,
      effective_date: t.str,
      targets: t.json,
      reason: t.str,
      checkin_id: t.str,
      created_at: t.date,
    },
    indexes: [{ keys: { email: 1, effective_date: 1, created_at: -1 } }],
  },
  users: {
    collection: 'users',
    fields: {
      name: t.str,
      email: t.str,
      hash: t.str,
      profile: t.json,
      preferences_revision: t.num,
      preferences_updated_at: t.date,
      is_admin: t.bool,
      created_at: t.date,
      onboardingCompleted: t.bool,
      onboarding_version: t.num,
      onboarding_completed_at: t.date,
      credentials_version: t.num,
      email_verified_at: t.date,
      age: t.num,
      gender: t.str,
      height: t.num,
      weight: t.num,
      goal: t.str,
      experienceLevel: t.str,
      workoutDaysPerWeek: t.num,
      equipmentAccess: t.str,
      timezone: t.str,
      unitSystem: t.str,
      aiCreditsRemaining: t.num,
      aiDailyCreditsUsed: t.num,
      aiLastCreditReset: t.date,
      aiDailyResetDate: t.date,
    },
    indexes: [{ keys: { email: 1 }, unique: true }],
  },

  measurements: {
    collection: 'measurements',
    fields: {
      account_id: t.str,
      client_id: t.str,
      type: t.str,
      value: t.num,
      unit: t.str,
      entered_value: t.num,
      entered_unit: t.str,
      entry_date: t.str,
      timezone: t.str,
      note: t.str,
      source: t.str,
      revision: t.num,
      deleted_at: t.date,
      created_at: t.date,
      updated_at: t.date,
    },
    indexes: [
      { keys: { account_id: 1, client_id: 1 }, unique: true },
      { keys: { account_id: 1, entry_date: 1 } },
    ],
  },

  activities: {
    collection: 'activities',
    fields: {
      email: t.str,
      account_id: t.str,
      client_id: t.str,
      identity_key: t.str,
      revision: t.num,
      revision_locked: t.bool,
      deleted_at: t.date,
      updated_at: t.date,
      activity: t.str,
      duration_min: t.num,
      calories: t.num,
      intensity: t.str,
      type: t.str,
      entry_date: t.str,
      created_at: t.date,
    },
    indexes: [
      { keys: { email: 1, entry_date: 1 } },
      { keys: { identity_key: 1 }, unique: true, sparse: true },
    ],
  },

  food: {
    collection: 'foods',
    fields: {
      email: t.str,
      account_id: t.str,
      client_id: t.str,
      revision: t.num,
      revision_locked: t.bool,
      deleted_at: t.date,
      updated_at: t.date,
      name: t.str,
      calories: t.num,
      protein: t.num,
      carbs: t.num,
      fat: t.num,
      fiber: t.num,
      sugar: t.num,
      sodium: t.num,
      saturated_fat: t.num,
      // Quantity model: one entry is `servings` x the per-serving macros the
      // client sent. Macro columns above are already multiplied out (the totals
      // actually eaten) so every aggregate stays a plain SUM.
      servings: t.num,
      serving_size: t.str,
      serving_unit: t.str,
      nutrition_snapshot: t.json,
      entered_quantity: t.json,
      nutrition_basis: t.json,
      source: t.str,
      meal_type: t.str,
      barcode: t.str,
      brand: t.str,
      food_id: t.str,
      entry_date: t.str,
      logged_at: t.date,
      created_at: t.date,
    },
    indexes: [
      { keys: { email: 1, entry_date: 1 } },
      { keys: { barcode: 1 }, sparse: true },
      { keys: { account_id: 1, client_id: 1 }, unique: true, sparse: true },
    ],
  },

  sleep: {
    collection: 'sleeps',
    fields: {
      email: t.str,
      account_id: t.str,
      client_id: t.str,
      identity_key: t.str,
      revision: t.num,
      revision_locked: t.bool,
      deleted_at: t.date,
      updated_at: t.date,
      hours: t.num,
      quality: t.str,
      bedtime: t.str,
      wake_time: t.str,
      entry_date: t.str,
      created_at: t.date,
    },
    indexes: [
      { keys: { email: 1, entry_date: 1 } },
      { keys: { identity_key: 1 }, unique: true, sparse: true },
    ],
  },

  weights: {
    collection: 'weights',
    fields: {
      account_id: t.str,
      revision: t.num,
      revision_locked: t.bool,
      deleted_at: t.date,
      updated_at: t.date,
      email: t.str,
      // Always kilograms on the wire and at rest. Display units are a client concern.
      weight_kg: t.num,
      body_fat_pct: t.num,
      note: t.str,
      source: t.str, // manual | healthkit | import
      entry_date: t.str,
      created_at: t.date,
    },
    indexes: [{ keys: { email: 1, entry_date: 1 }, unique: true }],
  },

  goals: {
    collection: 'goals',
    fields: {
      email: t.str,
      daily_calories: t.num,
      protein_g: t.num,
      carbs_g: t.num,
      fat_g: t.num,
      fiber_g: t.num,
      weekly_workouts: t.num,
      daily_steps: t.num,
      weekly_weight: t.num,
      sleep_hours: t.num,
      water_ml: t.num,
      updated_at: t.date,
    },
    indexes: [{ keys: { email: 1 }, unique: true }],
  },

  programs: {
    collection: 'programs',
    fields: {
      email: t.str,
      goal_type: t.str, // lose | maintain | gain
      target_mode: t.str,
      // Target rate of body-mass change, kg per week. Negative for a deficit.
      rate_kg_per_week: t.num,
      target_weight_kg: t.num,
      protein_strategy: t.str, // low | moderate | high
      fat_strategy: t.str,
      diet_type: t.str, // balanced | low_carb | low_fat | keto
      // Latest computed targets, refreshed at check-in.
      calories: t.num,
      protein_g: t.num,
      carbs_g: t.num,
      fat_g: t.num,
      expenditure: t.num,
      expenditure_confidence: t.str, // estimated | low | medium | high
      last_checkin_date: t.str,
      active: t.bool,
      created_at: t.date,
      updated_at: t.date,
    },
    indexes: [{ keys: { email: 1 }, unique: true }],
  },

  checkins: {
    collection: 'checkins',
    fields: {
      email: t.str,
      entry_date: t.str,
      expenditure: t.num,
      expenditure_confidence: t.str,
      mean_intake: t.num,
      trend_weight_kg: t.num,
      trend_change_kg: t.num,
      days_logged: t.num,
      window_days: t.num,
      calories: t.num,
      protein_g: t.num,
      carbs_g: t.num,
      fat_g: t.num,
      previous_calories: t.num,
      note: t.str,
      created_at: t.date,
    },
    indexes: [{ keys: { email: 1, entry_date: 1 }, unique: true }],
  },

  // The user's personal food library: custom entries, barcode scans they kept,
  // and search results they reused. `use_count` drives the "recents" ordering.
  library_foods: {
    collection: 'libraryfoods',
    fields: {
      email: t.str,
      name: t.str,
      brand: t.str,
      barcode: t.str,
      calories: t.num,
      protein: t.num,
      carbs: t.num,
      fat: t.num,
      fiber: t.num,
      sugar: t.num,
      sodium: t.num,
      saturated_fat: t.num,
      serving_size: t.str,
      serving_unit: t.str,
      serving_grams: t.num,
      nutrition_basis: t.json,
      portions: t.json,
      missing_nutrients: t.json,
      fetched_at: t.date,
      region: t.str,
      source: t.str, // custom | barcode | fatsecret | openfoodfacts | recipe
      is_favorite: t.bool,
      use_count: t.num,
      last_used: t.date,
      created_at: t.date,
    },
    indexes: [{ keys: { email: 1, name: 1 } }, { keys: { email: 1, last_used: -1 } }],
  },

  recipes: {
    collection: 'recipes',
    fields: {
      email: t.str,
      name: t.str,
      // [{ name, calories, protein, carbs, fat, fiber, sugar, servings }]
      ingredients: t.json,
      servings: t.num,
      note: t.str,
      created_at: t.date,
      updated_at: t.date,
    },
    indexes: [{ keys: { email: 1, name: 1 } }],
  },

  workouts: {
    collection: 'workouts',
    fields: {
      email: t.str,
      name: t.str,
      exercises: t.json,
      created_at: t.date,
      updated_at: t.date,
    },
    indexes: [{ keys: { email: 1 } }],
  },

  water: {
    collection: 'waters',
    fields: {
      account_id: t.str,
      revision: t.num,
      email: t.str,
      entry_date: t.str,
      ml: t.num,
      updated_at: t.date,
    },
    indexes: [{ keys: { email: 1, entry_date: 1 }, unique: true }],
  },

  ai_plans: {
    collection: 'aiplans',
    fields: {
      email: t.str,
      userId: t.str,
      type: t.str,
      prompt: t.str,
      response: t.str,
      applied: t.bool,
      createdAt: t.date,
    },
    indexes: [{ keys: { email: 1, createdAt: -1 } }],
  },

  ai_errors: {
    collection: 'aierrors',
    fields: {
      email: t.str,
      userId: t.str,
      sessionId: t.str,
      errorType: t.str,
      errorCode: t.str,
      errorMessage: t.str,
      errorDetails: t.json,
      userAgent: t.str,
      ipAddress: t.str,
      requestData: t.json,
      responseData: t.json,
      stackTrace: t.str,
      severity: t.str,
      status: t.str,
      adminNotes: t.str,
      resolvedBy: t.str,
      resolvedAt: t.date,
      created_at: t.date,
      updated_at: t.date,
    },
    indexes: [{ keys: { created_at: -1 } }, { keys: { status: 1 } }],
  },

  // Sign in with Apple and any later external identity. Migration 0002.
  account_identities: {
    collection: 'accountidentities',
    fields: {
      account_id: t.str,
      provider: t.str,
      subject: t.str,
      email: t.str,
      created_at: t.date,
      last_used_at: t.date,
    },
    indexes: [{ keys: { provider: 1, subject: 1 }, unique: true }, { keys: { account_id: 1 } }],
  },

  auth_nonces: {
    collection: 'authnonces',
    fields: { nonce_hash: t.str, created_at: t.date },
    indexes: [{ keys: { nonce_hash: 1 }, unique: true }, { keys: { created_at: 1 } }],
  },

  // ExerlyCore entities synced as documents. Migration 0003.
  documents: {
    collection: 'documents',
    fields: {
      account_id: t.str,
      kind: t.str,
      document_id: t.str,
      revision: t.num,
      payload: t.json,
      deleted_at: t.date,
      created_at: t.date,
      updated_at: t.date,
    },
    indexes: [{ keys: { account_id: 1, kind: 1, document_id: 1 }, unique: true }],
  },

  // Personal access tokens. Migration 0004.
  personal_access_tokens: {
    collection: 'personalaccesstokens',
    fields: {
      account_id: t.str,
      name: t.str,
      token_hash: t.str,
      prefix: t.str,
      scopes: t.json,
      created_at: t.date,
      last_used_at: t.date,
      expires_at: t.date,
      revoked_at: t.date,
    },
    indexes: [{ keys: { token_hash: 1 }, unique: true }, { keys: { account_id: 1 } }],
  },

  // Password reset codes, hashed. Migration 0008.
  password_resets: {
    collection: 'passwordresets',
    fields: {
      account_id: t.str,
      code_hash: t.str,
      attempts: t.num,
      created_at: t.date,
      expires_at: t.date,
      used_at: t.date,
    },
    indexes: [{ keys: { account_id: 1 } }],
  },

  // Webhooks. Migration 0007.
  webhooks: {
    collection: 'webhooks',
    fields: {
      account_id: t.str,
      token_id: t.str,
      url: t.str,
      secret: t.str,
      created_at: t.date,
      delivered_sequence: t.num,
      next_attempt_at: t.date,
      failures: t.num,
      last_delivery_at: t.date,
      last_error: t.str,
      disabled_at: t.date,
    },
    indexes: [{ keys: { account_id: 1 } }],
  },

  barcode_cache: {
    collection: 'barcodecaches',
    fields: {
      barcode: t.str,
      name: t.str,
      brand: t.str,
      calories: t.num,
      protein: t.num,
      carbs: t.num,
      fat: t.num,
      fiber: t.num,
      sugar: t.num,
      sodium: t.num,
      saturated_fat: t.num,
      serving_size: t.str,
      nutrition_basis: t.json,
      portions: t.json,
      missing_nutrients: t.json,
      region: t.str,
      source: t.str,
      fetched_at: t.date,
      expires_at: t.date,
    },
    indexes: [{ keys: { barcode: 1 }, unique: true }],
  },
};

const JSON_FIELDS = Object.fromEntries(
  Object.entries(collections).map(([name, def]) => [
    name,
    Object.entries(def.fields)
      .filter(([, type]) => type === t.json)
      .map(([field]) => field),
  ])
);

const DATE_FIELDS = Object.fromEntries(
  Object.entries(collections).map(([name, def]) => [
    name,
    Object.entries(def.fields)
      .filter(([, type]) => type === t.date)
      .map(([field]) => field),
  ])
);

function assertCollection(name) {
  if (!Object.prototype.hasOwnProperty.call(collections, name)) {
    throw new Error(`Unknown collection: ${name}`);
  }
  return collections[name];
}

module.exports = { types: t, collections, JSON_FIELDS, DATE_FIELDS, assertCollection };
