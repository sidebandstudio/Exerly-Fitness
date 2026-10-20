const { createHash } = require('node:crypto');
const store = require('../data');
const { badRequest, conflict } = require('./errors');
const { requireUser } = require('./users');

function canonicalJSON(value) {
  if (Array.isArray(value)) return `[${value.map(canonicalJSON).join(',')}]`;
  if (value && typeof value === 'object') {
    return `{${Object.keys(value)
      .sort()
      .map((k) => `${JSON.stringify(k)}:${canonicalJSON(value[k])}`)
      .join(',')}}`;
  }
  return JSON.stringify(value);
}

// Operation receipts are kept for years. A fast hash of a body holding a
// password would let anyone with the database test guesses against it.
const PASSWORD_FIELDS = ['password', 'currentPassword', 'newPassword'];
function withoutPasswords(body) {
  if (!body || typeof body !== 'object' || Array.isArray(body)) return body ?? null;
  const copy = { ...body };
  for (const field of PASSWORD_FIELDS) delete copy[field];
  return copy;
}

// Keep acknowledgement and data in the same transaction. Responses leave the
// process only after commit; a lost response can be read again with the same key.
// Operation keys are retained until account deletion, including old offline work.
async function executeMutation(req, res, fn) {
  const key = req.get('Idempotency-Key');
  if (key && !/^[a-zA-Z0-9._:-]{8,128}$/.test(key)) {
    throw badRequest(
      'Idempotency-Key must contain 8 to 128 letters, digits, dots, colons, underscores or hyphens'
    );
  }
  const fingerprint = createHash('sha256')
    .update(
      canonicalJSON({
        method: req.method,
        path: req.originalUrl,
        body: withoutPasswords(req.body),
        revision: req.get('If-Match') ?? null,
      })
    )
    .digest('hex');
  const originalJSON = res.json;
  let replayed = false;
  let output;
  // Concurrent first uses of a key can race the unique index. A new
  // transaction then observes the winning committed operation.
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      output = await store.transaction(async () => {
        const user = await requireUser(req.user.email);
        const owner = { account_id: user.id, key };
        if (key) {
          const previous = await store.findOne('operations', owner);
          if (previous) {
            if (previous.fingerprint !== fingerprint) {
              throw conflict('This operation key was already used with different content');
            }
            replayed = true;
            return { status: previous.status, body: previous.response };
          }
        }
        let captured;
        res.json = function (body) {
          captured = { status: res.statusCode, body: JSON.parse(JSON.stringify(body)) };
          return this;
        };
        try {
          await fn(req, res);
        } finally {
          res.json = originalJSON;
        }
        if (!captured) throw new Error('Mutation must return a JSON acknowledgement');
        if (captured.status >= 400) {
          // Roll back handlers that return validation failures after a write.
          const error = new Error('Mutation rejected');
          error.mutationResponse = captured;
          throw error;
        }
        if (key) {
          // A handler can keep secrets out of the stored receipt (res.locals.receipt).
          const receipt = res.locals.receipt ? res.locals.receipt(captured.body) : captured.body;
          await store.insert('operations', {
            ...owner,
            fingerprint,
            status: captured.status,
            response: receipt,
            created_at: new Date(),
          });
        }
        return captured;
      });
      break;
    } catch (error) {
      if (error.mutationResponse) {
        output = error.mutationResponse;
        break;
      }
      if (!store.isRetryable(error) || attempt === 2) throw error;
      res.statusCode = 200;
    }
  }
  res.set('Idempotency-Replayed', String(replayed));
  res.status(output.status);
  return originalJSON.call(res, output.body);
}

module.exports = { executeMutation, canonicalJSON };
