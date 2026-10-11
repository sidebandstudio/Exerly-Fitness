// The bundled USDA generic foods: every one is a Food ExerlyCore accepts, in
// its units, and search puts the food a person means first.

const test = require('node:test');
const assert = require('node:assert/strict');
const generic = require('../lib/genericFoods');
const { NUTRIENTS, NUTRIENT_UNITS, foodProblems } = require('../lib/nutrition/validate');

const now = new Date('2026-10-07T12:00:00.000Z');
const first = (query) => generic.search(query, 1, { now })[0]?.name;

test('every generic food is a valid Food in ExerlyCore units', () => {
  const { table } = generic;
  assert.equal(table.foods.length, 5431);
  assert.equal(table.license, 'Public domain (CC0 1.0)');
  for (const nutrient of table.nutrients) {
    assert.ok(NUTRIENTS.includes(nutrient), nutrient);
    assert.equal(table.units[nutrient], NUTRIENT_UNITS[nutrient], nutrient);
  }
  for (const [fdcId] of table.foods) {
    const food = generic.byID(`usda:${fdcId}`, { now });
    assert.deepEqual(foodProblems(food, food.id), [], food.name);
    assert.equal(typeof food.per100g.energy, 'number', food.name);
  }
  assert.equal(generic.byID('usda:1'), null);
});

test('a generic food keeps unknown nutrients out and has household portions', () => {
  const banana = generic.search('banana', 1, { now })[0];
  assert.equal(banana.id, 'usda:2709224');
  assert.equal(banana.name, 'Banana, raw');
  assert.equal(banana.source, 'usda');
  assert.equal(banana.per100g.energy, 97);
  assert.equal(banana.per100g.potassium, 326);
  assert.ok(!('leucine' in banana.per100g), 'FNDDS has no amino acids: unknown, not zero');
  assert.ok(!('addedSugars' in banana.per100g));
  assert.deepEqual(
    banana.servings.find((serving) => serving.name === '1 banana'),
    { name: '1 banana', grams: 126 }
  );
  assert.equal(banana.createdAt, now.toISOString());
});

test('search puts the food the query names first', () => {
  assert.equal(first('banana'), 'Banana, raw');
  assert.equal(first('Bananas'), 'Banana, raw');
  assert.equal(first('eggs'), 'Egg, whole, raw');
  assert.equal(first('salmon'), 'Fish, salmon, raw');
  assert.equal(first('ground beef'), 'Beef, ground, raw');
  assert.equal(first('strawberries'), 'Strawberries, raw');
  assert.equal(first('cheddar cheese'), 'Cheese, Cheddar');
  assert.equal(first('peanut butter'), 'Peanut butter');
  assert.equal(first('crème brûlée')?.startsWith('Creme brulee'), true);
  assert.deepEqual(generic.search('zzqx', 5), []);
  assert.deepEqual(generic.search('  ', 5), []);
  assert.equal(generic.search('chicken', 7).length, 7);
});

test('without a food that has every word, the foods with most of them come first', () => {
  // No generic food says "diced": canned tomatoes have the other two words.
  assert.deepEqual(
    generic.search('diced tomatoes canned', 2, { now }).map((food) => food.name),
    ['Tomatoes, canned, cooked', 'Tomatoes, canned, reduced sodium, cooked']
  );
  assert.equal(first('tomatoes canned'), 'Tomatoes, canned, cooked', 'An exact match is unchanged');
  assert.equal(first('zzqx banana'), 'Banana, raw');
  // At least half the words: one word of three isn't a match.
  assert.deepEqual(generic.search('zzqx qqzz banana', 5), []);
  // A food with every word still wins over ones with most of them.
  assert.equal(first('kidney beans canned'), 'Kidney beans, from canned, fat added');
});

test('a staple comes before dishes named with it, as food search ranks the person’s own foods', () => {
  // Toast is toasted bread; Shrimp toast, French toast and Melba toast are
  // other foods with more words in their name.
  const toast = generic.search('toast', 5, { now }).map((food) => food.name);
  assert.equal(toast.length, 5);
  for (const name of toast) assert.match(name, /^Bread, .*toasted$/);
  assert.ok(!generic.search('toast', 20).some((food) => /Shrimp|French/.test(food.name)));
  // Naming the dish still finds it first.
  assert.equal(first('french toast'), 'French toast, NFS');
  assert.equal(first('shrimp toast'), 'Shrimp toast');
  assert.equal(first('whole wheat toast'), 'Bread, whole wheat, toasted');
  // A slice of it is a slice USDA weighs.
  const slice = generic.search('toast', 1, { now })[0].servings.find((s) => /slice/.test(s.name));
  assert.ok(slice.grams > 0);
});
