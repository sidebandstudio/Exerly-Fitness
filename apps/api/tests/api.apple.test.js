// Sign in with Apple, with identity tokens signed by a local test key. Apple's
// servers are never contacted.

const test = require('node:test');
const assert = require('node:assert/strict');
const { generateKeyPairSync, randomBytes } = require('node:crypto');
const jwt = require('jsonwebtoken');
const { startServer, signUp } = require('./helpers/server');
const apple = require('../lib/apple');

const { privateKey, publicKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
const KID = 'test-key';
let api;

test.before(async () => {
  apple.publicKey = async (kid) => (kid === KID ? publicKey : null);
  api = await startServer();
});
test.after(async () => {
  await api.close();
});

function credential(
  claims = {},
  { nonce = randomBytes(16).toString('hex'), key = privateKey, header = {} } = {}
) {
  const identityToken = jwt.sign(
    {
      iss: 'https://appleid.apple.com',
      aud: 'com.exerly.fitness',
      sub: `001234.${randomBytes(8).toString('hex')}.0001`,
      nonce: apple.sha256(nonce),
      email: `${randomBytes(5).toString('hex')}@privaterelay.appleid.com`,
      email_verified: 'true',
      exp: Math.floor(Date.now() / 1000) + 600,
      ...claims,
    },
    key,
    { algorithm: 'RS256', keyid: KID, ...header }
  );
  return { identityToken, nonce };
}

const signIn = (body) => api.post('/auth/apple', { timezone: 'Europe/London', ...body });

test('a new Apple user gets an account and a session; a returning one gets the same account', async () => {
  const sub = '001234.synthetic.0001';
  const first = await signIn({
    ...credential({ sub, email: 'Person@PrivateRelay.AppleID.com' }),
    name: 'Synthetic Person',
  });
  assert.equal(first.status, 201, JSON.stringify(first.body));
  assert.equal(first.body.created, true);
  assert.ok(first.body.token && first.body.refreshToken);
  assert.equal(first.body.user.email, 'person@privaterelay.appleid.com');
  assert.equal(first.body.user.name, 'Synthetic Person');
  assert.equal(first.body.user.timezone, 'Europe/London');

  const me = await api.get('/api/me', { token: first.body.token });
  assert.equal(me.status, 200);

  const again = await signIn({ ...credential({ sub }), name: 'Someone Else' });
  assert.equal(again.status, 200);
  assert.equal(again.body.created, false);
  assert.equal(again.body.user._id, first.body.user._id);
  assert.equal(again.body.user.name, 'Synthetic Person');

  // The account has no password, so password sign-in fails cleanly.
  const login = await api.post('/login', {
    email: 'person@privaterelay.appleid.com',
    password: 'anything-at-all',
  });
  assert.equal(login.status, 401);
});

test('rejects replayed, foreign, expired, forged and mismatched tokens', async () => {
  const replayed = credential();
  assert.equal((await signIn(replayed)).status, 201);
  assert.equal((await signIn(replayed)).status, 401);

  const cases = {
    wrongAudience: credential({ aud: 'com.someone.else' }),
    wrongIssuer: credential({ iss: 'https://evil.example' }),
    expired: credential({ exp: Math.floor(Date.now() / 1000) - 3600 }),
    unknownKey: (() => {
      const c = credential();
      return {
        ...c,
        identityToken: jwt.sign(jwt.decode(c.identityToken), privateKey, {
          algorithm: 'RS256',
          keyid: 'other',
        }),
      };
    })(),
    otherSigner: credential(
      {},
      { key: generateKeyPairSync('rsa', { modulusLength: 2048 }).privateKey }
    ),
    nonceMismatch: { ...credential(), nonce: randomBytes(16).toString('hex') },
    noSubject: credential({ sub: '' }),
  };
  for (const [name, body] of Object.entries(cases)) {
    const res = await signIn(body);
    assert.equal(res.status, 401, `${name}: ${res.status} ${JSON.stringify(res.body)}`);
  }

  // HS256 signed with the public key must not pass as RS256.
  const forged = jwt.sign(
    {
      iss: 'https://appleid.apple.com',
      aud: 'com.exerly.fitness',
      sub: 'x',
      nonce: apple.sha256('n'.repeat(16)),
    },
    publicKey.export({ type: 'spki', format: 'pem' }),
    { algorithm: 'HS256', keyid: KID }
  );
  assert.equal((await signIn({ identityToken: forged, nonce: 'n'.repeat(16) })).status, 401);
  assert.equal((await signIn({ identityToken: 'not-a-jwt', nonce: 'n'.repeat(16) })).status, 401);
  assert.equal((await signIn({ ...credential(), nonce: 'short' })).status, 400);
});

test('a hidden email gets a stable placeholder address', async () => {
  const sub = '001234.hidden.0001';
  const first = await signIn(credential({ sub, email: undefined, email_verified: undefined }));
  assert.equal(first.status, 201);
  assert.match(first.body.user.email, /^apple-[0-9a-f]{24}@users\.exerly\.invalid$/);
  const second = await signIn(credential({ sub, email: undefined, email_verified: undefined }));
  assert.equal(second.body.user._id, first.body.user._id);
});

test('an existing password account must link Apple itself before Apple can sign into it', async () => {
  const existing = await signUp(api, { email: 'shared@exerly.test' });
  const sub = '001234.linking.0001';
  const blocked = await signIn(credential({ sub, email: 'shared@exerly.test' }));
  assert.equal(blocked.status, 409);
  assert.equal(blocked.body.details.code, 'link_required');

  const linked = await api.post(
    '/api/account/identities/apple',
    { ...credential({ sub, email: 'shared@exerly.test' }), password: existing.password },
    {
      token: existing.token,
    }
  );
  assert.equal(linked.status, 201, JSON.stringify(linked.body));

  const viaApple = await signIn(credential({ sub, email: 'shared@exerly.test' }));
  assert.equal(viaApple.status, 200);
  assert.equal(viaApple.body.user._id, existing.user._id);

  // The same Apple ID cannot be attached to a second account.
  const other = await signUp(api);
  const stolen = await api.post(
    '/api/account/identities/apple',
    { ...credential({ sub }), password: other.password },
    { token: other.token }
  );
  assert.equal(stolen.status, 409);

  // Unlinking needs a password, which this account has.
  const unlinked = await api.del('/api/account/identities/apple', {
    token: existing.token,
    body: { password: existing.password },
  });
  assert.equal(unlinked.status, 200);
  assert.equal((await signIn(credential({ sub, email: 'shared@exerly.test' }))).status, 409);
});

test('concurrent first sign-ins with one Apple ID create one account', async () => {
  const sub = '001234.race.0001';
  const results = await Promise.all(
    Array.from({ length: 5 }, () =>
      signIn(credential({ sub, email: 'race@privaterelay.appleid.com' }))
    )
  );
  assert.ok(
    results.every((r) => r.status === 200 || r.status === 201),
    JSON.stringify(results.map((r) => r.status))
  );
  assert.equal(new Set(results.map((r) => r.body.user._id)).size, 1);
  assert.equal(results.filter((r) => r.body.created).length, 1);
  assert.equal(await api.store.count('account_identities', { subject: sub }), 1);
});

test('bootstrap reports which sign-in methods the account has', async () => {
  const methods = async (token) =>
    (await api.get('/api/bootstrap', { token })).body.sign_in_methods;

  const person = await signUp(api);
  assert.deepEqual(await methods(person.token), { password: true, apple: false });
  const sub = '001234.methods.0001';
  await api.post(
    '/api/account/identities/apple',
    { ...credential({ sub }), password: person.password },
    { token: person.token }
  );
  assert.deepEqual(await methods(person.token), { password: true, apple: true });
  await api.del('/api/account/identities/apple', {
    token: person.token,
    body: { password: person.password },
  });
  assert.deepEqual(await methods(person.token), { password: true, apple: false });

  const appleOnly = await signIn(credential());
  assert.deepEqual(await methods(appleOnly.body.token), { password: false, apple: true });
});
