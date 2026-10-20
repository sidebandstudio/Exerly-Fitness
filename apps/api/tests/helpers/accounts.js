// Account and session helpers shared by the security tests. Identity tokens
// are signed by a local key that stands in for Apple's, so Apple's servers
// are never contacted; mail stays in the memory transport's outbox.

const assert = require('node:assert/strict');
const { generateKeyPairSync, randomBytes } = require('node:crypto');
const jwt = require('jsonwebtoken');
const apple = require('../../lib/apple');
const mail = require('../../lib/mail');
const passwordReset = require('../../lib/passwordReset');

const { privateKey, publicKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
const KID = 'local-test-key';

/** Makes the API trust the local key instead of Apple's. Call before starting the server. */
function trustLocalAppleKey() {
  apple.publicKey = async (kid) => (kid === KID ? publicKey : null);
}

/** A Sign in with Apple identity token and its raw nonce. */
function appleCredential(
  sub,
  { issuedSecondsAgo = 0, lifetime = 600, withoutIssuedAt = false } = {}
) {
  const nonce = randomBytes(16).toString('hex');
  const iat = Math.floor(Date.now() / 1000) - issuedSecondsAgo;
  const claims = {
    iss: 'https://appleid.apple.com',
    aud: 'com.exerly.fitness',
    sub,
    nonce: apple.sha256(nonce),
    exp: iat + lifetime,
  };
  if (!withoutIssuedAt) claims.iat = iat;
  const identityToken = jwt.sign(claims, privateKey, {
    algorithm: 'RS256',
    keyid: KID,
    noTimestamp: withoutIssuedAt,
  });
  return { identityToken, nonce };
}

const appleSubject = () => `001234.${randomBytes(6).toString('hex')}.0001`;

/** A new account made by Sign in with Apple. */
async function appleAccount(api) {
  const sub = appleSubject();
  const signedIn = await api.post('/auth/apple', appleCredential(sub));
  assert.equal(signedIn.status, 201, JSON.stringify(signedIn.body));
  return { sub, token: signedIn.body.token, id: signedIn.body.user._id };
}

/** A session with a rotating refresh credential, as the app signs in. */
async function loginModern(api, email, password) {
  const res = await api.post(
    '/login',
    { email, password },
    { headers: { 'X-Session-Protocol': '2' } }
  );
  assert.equal(res.status, 200, JSON.stringify(res.body));
  return res.body;
}

const refresh = (api, refreshToken, key) =>
  api.post('/auth/token', { refreshToken }, { headers: { 'Idempotency-Key': key } });

/** A read-only personal access token's secret. */
async function personalToken(api, user) {
  const res = await api.post(
    '/v1/tokens',
    { name: 'Synthetic agent', scopes: ['read'], password: user.password },
    {
      token: user.token,
      headers: { 'Idempotency-Key': `token-${randomBytes(6).toString('hex')}` },
    }
  );
  assert.equal(res.status, 201, JSON.stringify(res.body));
  return res.body.token;
}

/** The latest reset code mailed to `email`, once queued reset requests have run. */
async function mailedCode(email) {
  await passwordReset.settle();
  const message = mail.sent(email).at(-1);
  assert.ok(message, `no mail to ${email}`);
  const match = message.text.match(/code is ([A-Z0-9]{4}-[A-Z0-9]{4})/);
  assert.ok(match, message.text);
  return match[1];
}

const forgot = (api, email) => api.post('/auth/password/forgot', { email });
const resetPassword = (api, email, code, newPassword = 'a-brand-new-passphrase') =>
  api.post('/auth/password/reset', { email, code, newPassword });

module.exports = {
  trustLocalAppleKey,
  appleCredential,
  appleSubject,
  appleAccount,
  loginModern,
  refresh,
  personalToken,
  mailedCode,
  forgot,
  resetPassword,
};
