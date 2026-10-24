// AI coach: Gemini-backed when a key is configured, canned responses otherwise.
//
// Rewritten onto the storage adapter. The credit system is unchanged: 5 per
// rolling hour, 20 per UTC day.

const express = require('express');
const { GoogleGenerativeAI } = require('@google/generative-ai');

const store = require('../data');
const { asyncHandler, notFound, badRequest, tooMany } = require('../lib/errors');
const { authenticate } = require('../lib/auth');
const { clientIP } = require('../lib/ratelimit');
const v = require('../lib/validate');
const { requireUser } = require('../lib/users');
const AIErrorLogger = require('../utils/errorLogger');

const router = express.Router();
router.use(authenticate);

const HOURLY_LIMIT = 5;
const DAILY_LIMIT = 20;
const PLAN_TYPES = ['workout_plan', 'nutrition_advice', 'progress_analysis', 'custom_question'];

const apiKey = process.env.GEMINI_API_KEY || process.env.AI_API_KEY;
const model = apiKey
  ? new GoogleGenerativeAI(apiKey).getGenerativeModel({
      model: 'gemini-2.0-flash-lite',
      generationConfig: { maxOutputTokens: 500, temperature: 0.7 },
    })
  : null;

const MOCK_RESPONSES = {
  workout_plan:
    '**Sample 3-Day Split**\n\n- Day 1 Push: bench 4x6, overhead press 3x8, dips 3x10\n- Day 2 Pull: rows 4x6, chin-ups 3xAMRAP, curls 3x12\n- Day 3 Legs: squat 4x5, RDL 3x8, calf raises 3x15\n\n(Local development mode: set GEMINI_API_KEY for real responses.)',
  nutrition_advice:
    '**Nutrition basics**\n\n- Hit your protein target first; the rest follows\n- Eat mostly whole foods, leave room for what you enjoy\n- Weigh yourself daily and judge on the weekly trend\n\n(Local development mode: set GEMINI_API_KEY for real responses.)',
  progress_analysis:
    '**Progress**\n\nNot enough logged data to analyse yet. Log food and weight for two weeks and check back.\n\n(Local development mode: set GEMINI_API_KEY for real responses.)',
  custom_question:
    'Local development mode is on, so this is a canned reply. Set GEMINI_API_KEY to get real answers.',
};

// ---------- credits ----------

function applyResets(user) {
  const now = new Date();
  const patch = {};

  const lastHourly = new Date(user.aiLastCreditReset || 0);
  if ((now - lastHourly) / 3600000 >= 1) {
    patch.aiCreditsRemaining = HOURLY_LIMIT;
    patch.aiLastCreditReset = now;
  }

  // UTC calendar day, matching how getTodayUTC used to define the boundary.
  const lastDaily = new Date(user.aiDailyResetDate || 0);
  const lastDay = Number.isNaN(lastDaily.getTime()) ? null : lastDaily.toISOString().slice(0, 10);
  if (lastDay !== now.toISOString().slice(0, 10)) {
    patch.aiDailyCreditsUsed = 0;
    patch.aiDailyResetDate = now;
  }

  return patch;
}

async function loadUserWithCredits(email) {
  const user = await requireUser(email);
  const patch = applyResets(user);
  if (Object.keys(patch).length === 0) return user;
  return store.update('users', { id: user.id }, patch);
}

function timeUntilHourlyReset(user) {
  const next = new Date(new Date(user.aiLastCreditReset || 0).getTime() + 3600000);
  const diff = Math.max(0, next - Date.now());
  const minutes = Math.floor(diff / 60000);
  const seconds = Math.floor((diff % 60000) / 1000);
  return `${minutes}:${String(seconds).padStart(2, '0')}`;
}

function timeUntilMidnight() {
  const midnight = new Date();
  midnight.setUTCHours(24, 0, 0, 0);
  const diff = midnight - Date.now();
  return `${Math.floor(diff / 3600000)}h ${Math.floor((diff % 3600000) / 60000)}m`;
}

router.get(
  '/credits',
  asyncHandler(async (req, res) => {
    const user = await loadUserWithCredits(req.user.email);
    res.json({
      hourly: {
        remaining: user.aiCreditsRemaining ?? HOURLY_LIMIT,
        limit: HOURLY_LIMIT,
        resetTime: timeUntilHourlyReset(user),
      },
      daily: {
        used: user.aiDailyCreditsUsed ?? 0,
        limit: DAILY_LIMIT,
        resetTime: timeUntilMidnight(),
      },
    });
  })
);

// ---------- prompt building ----------

// Strips control characters and caps length before free text reaches the model.
// Limits both the prompt-injection opening and the token bill.
function sanitize(text, maxLen = 1000) {
  return (
    String(text || '')
      // eslint-disable-next-line no-control-regex -- deliberate control-char strip
      .replace(/[\x00-\x1F\x7F]/g, ' ')
      .trim()
      .slice(0, maxLen)
  );
}

function buildContext(user, program) {
  return `User Profile:
- Name: ${user.name || 'Not specified'}
- Age: ${user.age || 'Not specified'}
- Gender: ${user.gender || 'Not specified'}
- Height: ${user.height || 'Not specified'} cm
- Weight: ${user.weight || 'Not specified'} kg
- Goal: ${user.goal || 'Not specified'}
- Experience Level: ${user.experienceLevel || 'Not specified'}
- Workout Days/Week: ${user.workoutDaysPerWeek || 'Not specified'}
- Equipment Access: ${user.equipmentAccess || 'Not specified'}
- Daily calorie target: ${program?.calories || 'Not set'}
- Protein target: ${program?.protein_g ? `${program.protein_g}g` : 'Not set'}
- Measured expenditure: ${program?.expenditure || 'Not enough data yet'}`;
}

const PROMPTS = {
  workout_plan: (
    context
  ) => `You are an expert AI fitness coach. Create a personalized workout plan.

${context}

Instructions:
- Create a specific, actionable workout plan
- Include warm-up, main workout, and cool-down
- Specify exercises, sets, reps, and rest periods
- Consider their experience level and equipment access
- Use clear formatting with bullet points`,

  nutrition_advice: (
    context
  ) => `You are an expert AI nutritionist. Provide personalized nutrition advice.

${context}

Instructions:
- Give specific, actionable nutrition advice
- Work with the calorie and protein targets above rather than inventing new ones
- Provide practical meal suggestions
- Use clear formatting with bullet points`,

  progress_analysis: (context) => `You are an expert AI fitness coach. Analyze their progress.

${context}

Instructions:
- Analyze their current situation against their goals
- Be encouraging but honest
- Suggest specific improvements
- Use clear formatting with bullet points`,

  custom_question: (context, question) => `You are an expert AI fitness and nutrition coach.

${context}

The user asks: "${question}"

Answer directly and practically. If the question is outside fitness, nutrition, sleep, or
training, say so briefly instead of guessing.`,
};

// ---------- coach ----------

const burstWindow = new Map();

// The hourly credit budget is the real quota. This only stops a stuck client
// from firing the same request in a tight loop.
function burstOk(email) {
  const now = Date.now();
  const last = burstWindow.get(email) || 0;
  if (now - last < 10000) return false;
  burstWindow.set(email, now);
  return true;
}

router.post(
  '/coach',
  asyncHandler(async (req, res) => {
    const type = v.oneOf(req.body.type ?? 'custom_question', 'type', PLAN_TYPES);
    const question = sanitize(req.body.question);
    if (type === 'custom_question' && !question) {
      throw badRequest('A question is required');
    }

    const user = await loadUserWithCredits(req.user.email);
    if (!burstOk(user.email)) throw tooMany('Slow down a moment before asking again.');

    const remaining = user.aiCreditsRemaining ?? HOURLY_LIMIT;
    const dailyUsed = user.aiDailyCreditsUsed ?? 0;

    if (remaining <= 0) {
      throw tooMany(`Out of hourly credits. Resets in ${timeUntilHourlyReset(user)}.`);
    }
    if (dailyUsed >= DAILY_LIMIT) {
      throw tooMany(`Daily limit reached. Resets in ${timeUntilMidnight()}.`);
    }

    const program = await store.findOne('programs', { email: user.email });
    const context = req.body.includeContext === false ? '' : buildContext(user, program);
    const prompt = PROMPTS[type](context, question);

    let response;
    if (model) {
      try {
        const result = await model.generateContent(prompt);
        response = result.response.text();
      } catch (err) {
        await AIErrorLogger.logError({
          email: user.email,
          userId: user.id,
          sessionId: req.get('X-Session-Id') || 'unknown',
          errorType: 'AI_MODEL_ERROR',
          errorCode: err.status ? String(err.status) : 'GENERATE_FAILED',
          errorMessage: err.message,
          userAgent: req.get('User-Agent'),
          ipAddress: clientIP(req),
          requestData: { type },
          stackTrace: err.stack,
          severity: 'HIGH',
        });
        throw Object.assign(
          new Error('The AI coach is unavailable right now. Try again shortly.'),
          {
            expected: true,
            status: 503,
          }
        );
      }
    } else {
      response = MOCK_RESPONSES[type];
    }

    const plan = await store.insert('ai_plans', {
      email: user.email,
      userId: String(user.id),
      type,
      prompt: question || type,
      response,
      applied: false,
      createdAt: new Date(),
    });

    // Mock responses cost nothing to produce, so they shouldn't cost a credit.
    if (model) {
      await store.update(
        'users',
        { id: user.id },
        { aiCreditsRemaining: remaining - 1, aiDailyCreditsUsed: dailyUsed + 1 }
      );
    }

    res.json({
      response,
      creditsRemaining: model ? remaining - 1 : remaining,
      dailyUsed: model ? dailyUsed + 1 : dailyUsed,
      planId: String(plan.id),
    });
  })
);

// ---------- saved plans ----------

function serializePlan(plan) {
  return {
    _id: String(plan.id),
    type: plan.type || 'custom_question',
    prompt: plan.prompt || '',
    response: plan.response || '',
    createdAt: plan.createdAt || null,
    applied: !!plan.applied,
  };
}

router.get(
  '/plans',
  asyncHandler(async (req, res) => {
    const limit = Math.min(100, Math.max(1, parseInt(req.query.limit, 10) || 50));
    const plans = await store.find(
      'ai_plans',
      { email: req.user.email },
      { sort: { createdAt: -1, id: -1 }, limit }
    );
    res.json(plans.map(serializePlan));
  })
);

router.delete(
  '/plans/:id',
  asyncHandler(async (req, res) => {
    const deleted = await store.removeOne('ai_plans', {
      id: String(req.params.id),
      email: req.user.email,
    });
    if (!deleted) throw notFound('Plan not found');
    res.json({ message: 'Plan deleted' });
  })
);

router.patch(
  '/plans/:id/apply',
  asyncHandler(async (req, res) => {
    const updated = await store.update(
      'ai_plans',
      { id: String(req.params.id), email: req.user.email },
      { applied: req.body?.applied != null ? !!req.body.applied : true }
    );
    if (!updated) throw notFound('Plan not found');
    res.json(serializePlan(updated));
  })
);

module.exports = router;
