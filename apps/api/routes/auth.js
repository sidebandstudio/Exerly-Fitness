const express = require('express');
const bcrypt = require('bcrypt');

const store = require('../data');
const { asyncHandler, unauthorized, conflict, badRequest } = require('../lib/errors');
const { authenticate, adminEmails } = require('../lib/auth');
const sessions = require('../lib/sessions');
const { rateLimit } = require('../lib/ratelimit');
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

router.post(
  '/signup',
  signupLimiter,
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

    const user = await store.findOne('users', { email });
    // Hash a throwaway password when the user doesn't exist, or signed up with
    // Apple and has no password, so the response time doesn't reveal which
    // emails are registered.
    if (!user?.hash) {
      await bcrypt.compare(password, '$2b$12$invalidinvalidinvalidinvalidinvalidinvalidinvalidinv');
      throw unauthorized('Invalid credentials');
    }

    const ok = await bcrypt.compare(password, user.hash);
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

router.post(
  '/api/change-password',
  authenticate,
  rateLimit({ name: 'change-password', max: 10, windowMs: 60 * 60 * 1000 }),
  asyncHandler(async (req, res) => {
    const currentPassword = v.str(req.body.currentPassword, 'currentPassword', {
      max: 200,
      trim: false,
    });
    const newPassword = v.password(req.body.newPassword, 'newPassword');

    const user = await requireUser(req.user.email);
    const ok = !!user.hash && (await bcrypt.compare(currentPassword, user.hash));
    if (!ok) throw unauthorized('Current password is incorrect');

    await store.update(
      'users',
      { id: user.id },
      {
        hash: await bcrypt.hash(newPassword, BCRYPT_ROUNDS),
        credentials_version: (user.credentials_version ?? 0) + 1,
      }
    );
    await sessions.revokeAll(user.id);
    res.json({ message: 'Password changed successfully' });
  })
);

// Password recovery by a code sent to the account's email. The request always
// gets the same answer, sent before any mail goes out, so it never says
// whether an address has an account.
const RESET_REQUESTED =
  'If an Exerly account uses that email, we sent it a code. It works for 15 minutes.';

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
    const user = await store.findOne('users', { email });
    if (user && passwordReset.deliverable(email)) {
      const code = passwordReset.newCode();
      const now = new Date();
      await store.transaction(async () => {
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
      });
      mail
        .send({
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
        })
        // The address stays out of the log.
        .catch((error) => console.error('Password reset email not sent:', error.message));
    }
    res.status(202).json({ message: RESET_REQUESTED });
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
      // Whoever knew the old password may have signed in or made a token.
      await sessions.revokeAll(user.id);
      await store.updateMany(
        'personal_access_tokens',
        { account_id: user.id, revoked_at: null },
        { revoked_at: now }
      );
      return true;
    });
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
