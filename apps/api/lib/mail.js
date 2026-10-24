// Outgoing email, behind one function so the provider can change.
//
// MAIL_TRANSPORT chooses how mail leaves:
// - memory: kept in `outbox` and never sent. Tests and the simulator fixture
//   read codes from it. The default when NODE_ENV=test.
// - log: printed to the console, body included. For local development only,
//   and refused in production because the body can hold a reset code.
// - unset in production: nothing can be sent yet. send() rejects and the
//   caller logs it. A production provider needs an account Ali chooses
//   (docs/QUESTIONS_FOR_ALI.md); add its transport here.

const OUTBOX_LIMIT = 100;
const outbox = [];

const FROM = () => process.env.MAIL_FROM || 'Exerly <hello@sideband.studio>';

function transportName() {
  if (process.env.MAIL_TRANSPORT) return process.env.MAIL_TRANSPORT;
  if (process.env.NODE_ENV === 'test') return 'memory';
  if (process.env.NODE_ENV === 'production') return null;
  return 'log';
}

const transports = {
  async memory(message) {
    outbox.push({ ...message, sent_at: new Date() });
    if (outbox.length > OUTBOX_LIMIT) outbox.shift();
  },
  async log(message) {
    if (process.env.NODE_ENV === 'production') {
      throw new Error('MAIL_TRANSPORT=log would print mail bodies in production');
    }
    console.log(`[mail] to ${message.to}: ${message.subject}\n${message.text}`);
  },
};

/** Sends { to, subject, text }. Rejects when no transport is configured. */
async function send({ to, subject, text }) {
  const name = transportName();
  const transport = name && transports[name];
  if (!transport) throw new Error(`No mail transport is configured (MAIL_TRANSPORT=${name})`);
  await transport({ from: FROM(), to, subject, text });
}

/** Messages the memory transport kept, newest last. */
function sent(to) {
  return to ? outbox.filter((message) => message.to === to) : [...outbox];
}

function clear() {
  outbox.length = 0;
}

module.exports = { send, sent, clear, transportName };
