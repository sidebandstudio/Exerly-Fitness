const express = require('express');
const bcrypt = require('bcrypt');

const store = require('../data');
const { asyncHandler, unauthorized, conflict, badRequest } = require('../lib/errors');
const { authenticate, adminEmails } = require('../lib/auth');
const sessions = require('../lib/sessions');
const { rateLimit, failureLimit, forget, networkPrefix } = require('../lib/ratelimit');
const { confirmationFailures, passwordMatches } = require('../lib/reauth');
const v = require('../lib/validate');
const { requireUser, newUserFields } = require('../lib/users');
const { normalizeTimeZone } = require('../lib/dates');
const passwordReset = require('../lib/passwordReset');
const mail = require('../lib/mail');

const router = express.Router();

const BCRYPT_ROUNDS = 12;

// Without this, an attacker gets unlimited password guesses against any known
// email address. Ten minutes of lockout after 8 tries makes online guessing
// useless while barely inconveniencing someone who fat-fingered their password.
const loginLimiter = rateLimit({
  name: 'login',
  max: 8,
  windowMs: 10 * 60 * 1000,
  message: 'Too many sign-in attempts. Wait a few minutes and try again.',
});

const signupLimiter = rateLimit({
  name: 'signup',
  max: 5,
  windowMs: 60 * 60 * 1000,
  message: 'Too many accounts created from this address.',
});

// Signup says whether an email already has an account (a 409); see
// DECISIONS.md, 2026-10-20. Per address and per email, so it can't be used to
// sweep through a list of addresses quickly.
const emailKey = (req) =>
  String(req.body?.email ?? '')
    .trim()
    .toLowerCase();
const signupEmailLimiter = rateLimit({
  name: 'signup-email',
  max: 5,
  windowMs: 60 * 60 * 1000,
  key: emailKey,
  message: 'Too many attempts with this email. Try again in an hour.',
});

// Guesses at one email, whether or not it has an account. Each network (a
// /24 or /56, lib/ratelimit.js) gets ten wrong passwords per email per 15
// minutes, so whoever is guessing can't lock the owner out from the owner's
// own network. Across all networks, wrong passwords for an email only slow
// every sign-in to it, doubling from the fourth to at most two seconds, so
// spreading guesses over many networks gets slow without ever shutting the
// owner out. A password reset, which proves the mailbox, clears both.
const LOGIN_WINDOW_MS = 15 * 60 * 1000;
const loginNetworkFailures = failureLimit({
  name: 'login-network',
  max: 10,
  windowMs: LOGIN_WINDOW_MS,
  message:
    'Too many sign-in attempts for this email from this network. Wait 15 minutes, or reset your password.',
});
const loginAccountFailures = failureLimit({
  name: 'login-account',
  max: Infinity,
  windowMs: LOGIN_WINDOW_MS,
});
const LOGIN_BACKOFF_CAP_MS = 2000;
const loginBackoffMs = (failures) =>
  failures <= 3 ? 0 : Math.min(100 * 2 ** (failures - 4), LOGIN_BACKOFF_CAP_MS);

router.post(
  '/signup',
  signupLimiter,
  signupEmailLimiter,
  asyncHandler(async (req, res) => {
    const name = v.str(req.body.name, 'name', { max: 80 });
    const email = v.email(req.body.email);
    const password = v.password(req.body.password);
    const timezone = normalizeTimeZone(req.body.timezone || req.get('X-Timezone'));

    const existing = await store.findOne('users', { email });
    if (existing) throw conflict('An account with this email already exists');

    const hash = await bcrypt.hash(password, BCRYPT_ROUNDS);
    const user = await store.insert(
      'users',
      newUserFields({
        name,
        email,
        hash,
        isAdmin: adminEmails().includes(email),
        timezone,
        unitSystem: req.body.unitSystem,
      })
    );

    res
      .status(201)
      .json({ message: 'Signup successful', ...(await sessions.createSession(user, req)) });
  })
);

router.post(
  '/login',
  loginLimiter,
  asyncHandler(async (req, res) => {
    const email = v.email(req.body.email);
    const password = v.str(req.body.password, 'password', { max: 200, trim: false });
    // Places are held before the password is hashed, so a burst can't all
    // pass the check while bcrypt runs.
    const network = loginNetworkFailures.reserve(`${email} ${networkPrefix(req.ip)}`);
    const account = loginAccountFailures.reserve(email);
    let user;
    let ok = null;
    try {
      const wait = loginBackoffMs(loginAccountFailures.failures(email));
      if (wait) await new Promise((resolve) => setTimeout(resolve, wait));
      user = await store.findOne('users', { email });
      // Hash a throwaway password when the user doesn't exist, or signed up with
      // Apple and has no password, so the response time doesn't reveal which
      // emails are registered.
      if (user?.hash) {
        ok = await bcrypt.compare(password, user.hash);
      } else {
        await bcrypt.compare(
          password,
          '$2b$12$invalidinvalidinvalidinvalidinvalidinvalidinvalidinv'
        );
        ok = false;
      }
    } finally {
      for (const attempt of [network, account]) {
        if (ok === false) attempt.fail();
        else attempt.release();
      }
    }
    if (!ok) throw unauthorized('Invalid credentials');

    let current = user;
    if (adminEmails().includes(email) && !user.is_admin) {
      current = await store.update('users', { id: user.id }, { is_admin: true });
      if (!current || (current.credentials_version ?? 0) !== (user.credentials_version ?? 0))
        throw unauthorized('Credentials changed. Sign in again.');
    }

    res.json(await sessions.createSession(current, req));
  })
);

// Sliding session. Clients call this on launch so an active user is never
// bounced to the login screen.
router.post(
  '/auth/token',
  rateLimit({ name: 'refresh', max: 60, windowMs: 600000 }),
  asyncHandler(async (req, res) => {
    res.json(await sessions.rotate(req.body.refreshToken, req.get('Idempotency-Key')));
  })
);

router.post(
  '/auth/refresh',
  authenticate,
  rateLimit({
    name: 'compatibility-refresh',
    max: 60,
    windowMs: 600000,
    key: (req) => req.account.id,
  }),
  asyncHandler(
    async (req, res) => {
      const user = await requireUser(req.user.email);
      // Session upgrades have their own replay contract, without persisting
      // usable credentials in the generic operation-response table.
      res.json(await sessions.upgradeSession(user, req));
    },
    { transactional: false }
  )
);

// Whoever knew the old password may have signed in, made an agent token, or
// pointed a webhook at their own server, which would tell them when the
// account changes. A new password ends all of it: sessions and tokens are
// revoked, and webhooks made from a session are paused (a token's webhooks
// stop with the token, lib/webhooks.js). Paused webhooks stay listed, and the
// person can turn theirs back on.
const PASSWORD_CHANGED =
  'Password changed. Every device is signed out, agent tokens are revoked and webhooks are paused.';
async function endAccessFromOldPassword(accountID, now = new Date()) {
  await sessions.revokeAll(accountID);
  await store.updateMany(
    'personal_access_tokens',
    { account_id: accountID, revoked_at: null },
    { revoked_at: now }
  );
  await store.updateMany(
    'webhooks',
    { account_id: accountID, token_id: null, disabled_at: null },
    {
      disabled_at: now,
      last_error: 'Paused when the password changed. Turn it on again if you set it up.',
    }
  );
}

router.post(
  '/api/change-password',
  authenticate,
  rateLimit({
    name: 'change-password',
    max: 10,
    windowMs: 60 * 60 * 1000,
    key: (req) => req.account.id,
  }),
  asyncHandler(async (req, res) => {
    const currentPassword = v.str(req.body.currentPassword, 'currentPassword', {
      max: 200,
      trim: false,
    });
    const newPassword = v.password(req.body.newPassword, 'newPassword');

    const user = await requireUser(req.user.email);
    // Wrong guesses share the account's confirmation budget (lib/reauth.js).
    if (!(await passwordMatches(currentPassword, user))) {
      throw unauthorized('Current password is incorrect');
    }

    await store.update(
      'users',
      { id: user.id },
      {
        hash: await bcrypt.hash(newPassword, BCRYPT_ROUNDS),
        credentials_version: (user.credentials_version ?? 0) + 1,
      }
    );
    await endAccessFromOldPassword(user.id);
    res.json({ message: PASSWORD_CHANGED });
  })
);

// Password recovery by a code sent to the account's email. Every valid
// request gets the same answer straight away, before the address is even
// looked up, so neither the answer nor its timing says whether an address has
// an account. The code is issued and mailed afterwards.
const RESET_REQUESTED =
  'If an Exerly account uses that email, we sent it a code. It works for 15 minutes.';

async function issueResetCode(email) {
  if (!passwordReset.deliverable(email)) return;
  const code = passwordReset.newCode();
  const issued = await store.transaction(async () => {
    const user = await store.findOne('users', { email });
    if (!user) return false;
    const now = new Date();
    // A new code ends every earlier one.
    await store.updateMany(
      'password_resets',
      { account_id: user.id, used_at: null },
      { used_at: now }
    );
    await store.insert('password_resets', {
      account_id: user.id,
      code_hash: passwordReset.digest(user.id, code),
      attempts: 0,
      created_at: now,
      expires_at: new Date(now.getTime() + passwordReset.TTL_MS),
    });
    return true;
  });
  if (!issued) return;
  await mail.send({
    to: email,
    subject: 'Your Exerly password reset code',
    text: [
      `Your code is ${passwordReset.display(code)}.`,
      '',
      'Enter it in Exerly within 15 minutes to choose a new password. Changing it signs you out on every device.',
      '',
      'If you didn’t ask for this, ignore this email. Your password hasn’t changed.',
      '',
      'Exerly by Sideband · https://sideband.studio',
    ].join('\n'),
  });
}

router.post(
  '/auth/password/forgot',
  rateLimit({ name: 'password-forgot', max: 5, windowMs: 15 * 60 * 1000 }),
  rateLimit({
    name: 'password-forgot-email',
    max: 3,
    windowMs: 60 * 60 * 1000,
    key: (req) =>
      String(req.body?.email ?? '')
        .trim()
        .toLowerCase(),
    message: 'We already sent codes to this email. Check your inbox, or try again in an hour.',
  }),
  asyncHandler(async (req, res) => {
    const email = v.email(req.body.email);
    res.status(202).json({ message: RESET_REQUESTED });
    passwordReset.afterResponse(email, () => issueResetCode(email));
  })
);

router.post(
  '/auth/password/reset',
  rateLimit({ name: 'password-reset', max: 10, windowMs: 15 * 60 * 1000 }),
  asyncHandler(async (req, res) => {
    const email = v.email(req.body.email);
    const code = passwordReset.normalize(req.body.code);
    const newPassword = v.password(req.body.newPassword, 'newPassword');
    // Hashed whether or not the code is right, so timing says nothing.
    const hash = await bcrypt.hash(newPassword, BCRYPT_ROUNDS);
    const changed = await store.transaction(async () => {
      const user = await store.findOne('users', { email });
      if (!user || !code) return false;
      const [reset] = await store.find(
        'password_resets',
        { account_id: user.id, used_at: null, expires_at: { gt: new Date() } },
        { sort: { created_at: -1 }, limit: 1 }
      );
      if (!reset) return false;
      if (!passwordReset.matches(reset.code_hash, user.id, code)) {
        const attempts = reset.attempts + 1;
        await store.update(
          'password_resets',
          { id: reset.id },
          attempts >= passwordReset.MAX_ATTEMPTS ? { attempts, used_at: new Date() } : { attempts }
        );
        return false;
      }
      const now = new Date();
      await store.updateMany(
        'password_resets',
        { account_id: user.id, used_at: null },
        { used_at: now }
      );
      await store.update(
        'users',
        { id: user.id },
        { hash, credentials_version: (user.credentials_version ?? 0) + 1 }
      );
      await endAccessFromOldPassword(user.id, now);
      return user.id;
    });
    if (changed) {
      // Proving the mailbox is the way out of every guessing limit.
      confirmationFailures.clear(changed);
      forget('change-password', changed);
      loginNetworkFailures.clearPrefix(`${email} `);
      loginAccountFailures.clear(email);
    }
    if (!changed) {
      throw badRequest(
        'That code is wrong or has expired. Check the latest email, or ask for a new code.',
        {
          code: 'reset_code_invalid',
        }
      );
    }
    res.json({ message: 'Password changed. Sign in with your new password.' });
  })
);

router.post(
  '/auth/logout',
  authenticate,
  asyncHandler(async (req, res) => {
    if (req.user.sid)
      await store.update(
        'sessions',
        { session_id: req.user.sid, account_id: req.account.id },
        { revoked_at: new Date() }
      );
    else
      await store.update(
        'users',
        { id: req.account.id },
        { credentials_version: (req.account.credentials_version ?? 0) + 1 }
      );
    res.json({ message: 'Signed out' });
  })
);

router.get(
  '/api/sessions',
  authenticate,
  asyncHandler(async (req, res) => {
    const rows = await store.find(
      'sessions',
      { account_id: req.account.id, revoked_at: null },
      { sort: { updated_at: -1 }, limit: 100 }
    );
    res.json(
      rows
        .filter((row) => sessions.isActive(row, req.account))
        .map((row) => ({
          id: row.session_id,
          device_name: row.device_name,
          created_at: row.created_at,
          updated_at: row.updated_at,
          current: row.session_id === req.user.sid,
        }))
    );
  })
);

router.delete(
  '/api/sessions/:id',
  authenticate,
  asyncHandler(async (req, res) => {
    await store.update(
      'sessions',
      { session_id: req.params.id, account_id: req.account.id },
      { revoked_at: new Date() }
    );
    res.json({ message: 'Session revoked' });
  })
);

module.exports = router;
