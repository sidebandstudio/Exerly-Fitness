const express = require('express');

const store = require('../data');
const { asyncHandler, notFound, badRequest } = require('../lib/errors');
const { authenticate } = require('../lib/auth');
const v = require('../lib/validate');

const router = express.Router();
router.use(authenticate);

function readExercises(value) {
  if (value == null) return [];
  if (!Array.isArray(value)) throw badRequest('exercises must be an array');
  if (value.length > 100) throw badRequest('A workout can hold at most 100 exercises');
  return value;
}

router.get(
  '/',
  asyncHandler(async (req, res) => {
    res.json(await store.find('workouts', { email: req.user.email }, { sort: { id: -1 } }));
  })
);

router.post(
  '/',
  asyncHandler(async (req, res) => {
    const created = await store.insert('workouts', {
      email: req.user.email,
      name: v.str(req.body.name, 'name', { max: 120 }),
      exercises: readExercises(req.body.exercises),
      created_at: new Date(),
      updated_at: new Date(),
    });
    res.status(201).json(created);
  })
);

router.put(
  '/:id',
  asyncHandler(async (req, res) => {
    const updated = await store.update(
      'workouts',
      { id: String(req.params.id), email: req.user.email },
      {
        name: v.str(req.body.name, 'name', { max: 120 }),
        exercises: readExercises(req.body.exercises),
        updated_at: new Date(),
      }
    );
    if (!updated) throw notFound('Workout not found');
    res.json(updated);
  })
);

router.delete(
  '/:id',
  asyncHandler(async (req, res) => {
    const deleted = await store.removeOne('workouts', {
      id: String(req.params.id),
      email: req.user.email,
    });
    if (!deleted) throw notFound('Workout not found');
    res.json({ message: 'Workout deleted', workout: deleted });
  })
);

module.exports = router;
module.exports.readExercises = readExercises;
