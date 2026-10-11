// Generic foods ("Banana, raw", "Chicken breast, baked, broiled, or roasted")
// from USDA's FNDDS, bundled so searching them needs no key and no provider
// call. Built by scripts/build-generic-foods.js; see
// docs/design/023-generic-foods.md. Results are ExerlyCore Foods, like
// coreFoods.fromOpenFoodFacts gives.

const table = require('./genericFoods.json');

const ATTRIBUTION = 'Generic foods from USDA FoodData Central (FNDDS 2021-2023), public domain.';

const words = (text) =>
  text
    .normalize('NFD')
    .replace(/\p{M}/gu, '')
    .toLowerCase()
    .replaceAll("'", '')
    .split(/[^\p{L}\p{N}]+/u)
    .filter(Boolean);

/** A query word in the singular, so "eggs" finds "Egg" and "berries" "Berry". */
const singular = (word) =>
  word.length > 3 && word.endsWith('ies')
    ? `${word.slice(0, -3)}y`
    : word.length > 3 && word.endsWith('s') && !word.endsWith('ss')
      ? word.slice(0, -1)
      : word;

const foods = table.foods.map(([fdcId, name, category, values, portions]) => {
  // Each comma-separated part, in the singular: "Fish, salmon, raw" is
  // [["fish"], ["salmon"], ["raw"]]. The first names the food.
  const parts = name.split(',').map((part) => words(part).map(singular));
  return {
    fdcId,
    name,
    category,
    values,
    portions,
    parts,
    words: parts.flat(),
    plain: parts.slice(1).some((part) => ['raw', 'nf'].includes(part.join(' '))),
  };
});

/** Whether a word in `list` starts with `word`, so "tomato" finds "tomatoes". */
const matches = (list, word) => list.some((w) => w.startsWith(word));

const sameWords = (a, b) => a.length === b.length && [...a].sort().join() === [...b].sort().join();

/** A word of a food's name as the query word it is the "-ed" form of: "toasted" is toast. */
const asWanted = (word, wanted) =>
  wanted.find((w) => word === `${w}ed` || (w.endsWith('e') && word === `${w}d`)) ?? word;

/**
 * How directly a food is named by the query: 0 when its first part is the
 * query ("Banana" for banana), k when its first k + 1 parts are ("Beef,
 * ground" for ground beef), or a later part alone is ("Fish, salmon"). A part
 * may be the query's "-ed" form, so "Bread, white, toasted" is toast, the
 * staple, before a dish whose name holds more words ("Shrimp toast").
 */
function naming(food, wanted) {
  const parts = food.parts.map((part) => part.map((word) => asWanted(word, wanted)));
  for (let k = 0; k < parts.length; k++) {
    if (sameWords(parts.slice(0, k + 1).flat(), wanted)) return k;
  }
  const part = parts.findIndex((p) => sameWords(p, wanted));
  return part >= 0 ? part : Infinity;
}

/** The food as ExerlyCore's Food: nutrients per 100 g, unknowns left out. */
function toFood(food, now) {
  const per100g = {};
  table.nutrients.forEach((nutrient, i) => {
    if (food.values[i] != null) per100g[nutrient] = food.values[i];
  });
  return {
    id: `usda:${food.fdcId}`,
    name: food.name,
    source: 'usda',
    per100g,
    servings: food.portions.map(([name, grams]) => ({ name, grams })),
    favorite: false,
    createdAt: now.toISOString(),
  };
}

/**
 * Generic foods matching every word of `query`, best first: foods the query
 * names (see `naming`), then foods whose first part holds more of it, whole
 * words before prefixes, plain forms ("raw", "NFS") before prepared ones,
 * then the shortest descriptions. When no food has every word, the foods
 * with the most of them, at least half, ranked the same way by the words
 * they have: "diced tomatoes canned" finds "Tomatoes, canned".
 */
function search(query, limit = 20, { now = new Date() } = {}) {
  const wanted = words(query).map(singular);
  if (!wanted.length) return [];
  let ranked = rank((food) => wanted.every((word) => matches(food.words, word)) && wanted);
  if (!ranked.length && wanted.length > 1) {
    const enough = Math.ceil(wanted.length / 2);
    ranked = rank((food) => {
      const found = wanted.filter((word) => matches(food.words, word));
      return found.length >= enough && found;
    });
  }
  return ranked.slice(0, limit).map(({ food }) => toFood(food, now));
}

/** Foods `matched` accepts, by the query words it finds in each, best first; see `search`. */
function rank(matched) {
  const ranked = [];
  for (const food of foods) {
    const found = matched(food);
    if (!found) continue;
    ranked.push({
      food,
      rank: [
        -found.length,
        Math.min(naming(food, found), 9),
        found.filter((word) => !matches(food.parts[0], word)).length,
        -found.filter((word) => food.words.includes(word)).length,
        food.plain ? 0 : 1,
        food.name.length,
        food.fdcId,
      ],
    });
  }
  return ranked.sort((a, b) => {
    for (let i = 0; i < a.rank.length; i++)
      if (a.rank[i] !== b.rank[i]) return a.rank[i] - b.rank[i];
    return 0;
  });
}

/** "potatoe", which `singular` leaves of "potatoes", as "potato". */
const stem = (word) => (word.length > 4 && word.endsWith('oe') ? word.slice(0, -1) : word);
// Words that don't make a food different from what a recipe line names.
const NEUTRAL = new Set([
  'raw',
  'nfs',
  'ns',
  'plain',
  'regular',
  'fresh',
  'to',
  'as',
  'of',
  'form',
  'type',
]);
// Words that make a food something else than the line names, unless it says them.
const OTHER = new Set(['meatless', 'imitation', 'substitute', 'replacement', 'vegetarian', 'baby']);

/**
 * The generic food a recipe's ingredient names, or null. Stricter than
 * `search`, because a wrong match is worse than none: every word must be in
 * the food's name, and its first part must be made of them, so "black
 * beans" finds "Black beans, NFS" but "salt" doesn't find a salted granola
 * bar, nor "egg" eggplant, nor "bacon" meatless bacon. Foods with the
 * fewest other words come first, then plain forms, then the shortest.
 */
function ingredient(query, { now = new Date() } = {}) {
  const wanted = words(query).map((word) => stem(singular(word)));
  if (!wanted.length) return null;
  let best = null;
  for (const food of foods) {
    const names = food.words.map(stem);
    if (!wanted.every((word) => names.includes(word))) continue;
    if (!food.parts[0].every((word) => wanted.includes(stem(word)))) continue;
    if (names.some((word) => OTHER.has(word) && !wanted.includes(word))) continue;
    const rank = [
      names.filter((word) => !wanted.includes(word) && !NEUTRAL.has(word)).length,
      food.plain ? 0 : 1,
      food.name.length,
      food.fdcId,
    ];
    if (!best || precedes(rank, best.rank)) best = { food, rank };
  }
  return best ? toFood(best.food, now) : null;
}

const precedes = (a, b) => {
  const i = a.findIndex((value, j) => value !== b[j]);
  return i >= 0 && a[i] < b[i];
};

const byFdcID = new Map(foods.map((food) => [food.fdcId, food]));

/** The generic food with this ID ("usda:<fdcId>"), or null. */
function byID(id, { now = new Date() } = {}) {
  const food = byFdcID.get(Number(String(id).replace(/^usda:/, '')));
  return food ? toFood(food, now) : null;
}

module.exports = { ATTRIBUTION, byID, ingredient, search, table };
