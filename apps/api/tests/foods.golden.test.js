// Open Food Facts products mapped to ExerlyCore Foods, against
// docs/api/golden/foods-v1.json. ExerlyCore's FoodsGoldenTests decode the same
// Foods, so the server can't send a Food the phone can't read. Regenerate with
// EXERLY_WRITE_FOODS_GOLDEN=1 after a deliberate change. The products are synthetic.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { OFF_NUTRIENTS, fromOpenFoodFacts } = require('../lib/coreFoods');
const genericFoods = require('../lib/genericFoods');

const file = path.join(__dirname, '../../../docs/api/golden/foods-v1.json');
const now = new Date('2026-10-06T12:00:00.000Z');

const products = [
  {
    code: '0012345678905',
    product_name: 'Synthetic oat bar',
    brands: 'Example Mills, Other Brand',
    serving_size: '1 bar (40 g)',
    serving_quantity: 40,
    serving_quantity_unit: 'g',
    nutriments: {
      'energy-kcal_100g': 412,
      proteins_100g: 9.5,
      carbohydrates_100g: 62,
      fat_100g: 13.2,
      fiber_100g: 7.1,
      sugars_100g: 21,
      'added-sugars_100g': 18,
      'saturated-fat_100g': 2.4,
      'trans-fat_100g': 0,
      sodium_100g: 0.24,
      potassium_100g: 0.38,
      calcium_100g: 0.12,
      iron_100g: 0.0036,
      'vitamin-a_100g': 0.00015,
      'vitamin-c_100g': 0.012,
      'vitamin-d_100g': 0.0000025,
      'vitamin-b12_100g': 0.0000012,
      'vitamin-b9_100g': 0.0001,
      'vitamin-pp_100g': 0.0042,
      cholesterol_100g: 0,
      caffeine_100g: 0,
      'omega-3-fat_100g': 0.4,
      alcohol_100g: 0,
    },
  },
  {
    code: '5000000000017',
    product_name_en: 'Synthetic sparkling drink',
    nutrition_data_per: '100ml',
    serving_quantity: 330,
    serving_quantity_unit: 'ml',
    nutriments: {
      energy_100g: 180,
      carbohydrates_100g: 10.6,
      sugars_100g: 10.6,
      sodium_100g: 0.01,
    },
  },
  { code: '4000000000016', nutriments: { 'energy-kcal_100g': 100 } },
  { code: 'not-a-code', product_name: 'No barcode', nutriments: {} },
  {
    code: '76543210',
    product_name: 'Synthetic spread',
    nutriments: { 'energy-kcal_100g': -5, fat_100g: 'lots', proteins_100g: 25.25 },
  },
  {
    code: '3000000000013',
    product_name: 'Synthetic olive oil',
    categories_tags: ['en:fats', 'en:vegetable-oils', 'en:olive-oils'],
    nutrition_data_per: '100ml',
    serving_size: '1 tbsp (15 ml)',
    serving_quantity: 15,
    serving_quantity_unit: 'ml',
    nutriments: { 'energy-kcal_100g': 828, fat_100g: 92, 'saturated-fat_100g': 13.8 },
  },
  {
    code: '0041000000016',
    product_name: 'Synthetic red kidney beans',
    brands: 'Example Pantry',
    categories_tags: ['en:canned-foods', 'en:canned-legumes', 'en:kidney-beans'],
    quantity: '15 oz (425 g)',
    product_quantity: 425,
    product_quantity_unit: 'g',
    serving_size: '1/2 cup (130 g)',
    serving_quantity: 130,
    serving_quantity_unit: 'g',
    nutriments: {
      'energy-kcal_100g': 85,
      proteins_100g: 5.4,
      carbohydrates_100g: 15.4,
      fat_100g: 0.4,
      fiber_100g: 5.4,
      sodium_100g: 0.25,
    },
  },
  {
    code: '0041000000023',
    product_name: 'Synthetic diced tomatoes',
    brands: 'Example Pantry',
    categories_tags: ['en:canned-foods', 'en:canned-vegetables', 'en:canned-tomatoes'],
    quantity: '14.5 oz (411 g)',
    product_quantity: 411,
    product_quantity_unit: 'g',
    serving_size: '1/2 cup (121 g)',
    serving_quantity: 121,
    serving_quantity_unit: 'g',
    nutriments: {
      'energy-kcal_100g': 21,
      proteins_100g: 0.8,
      carbohydrates_100g: 4,
      fat_100g: 0,
      sodium_100g: 0.15,
    },
  },
  {
    code: '0049000000443',
    product_name: 'Synthetic cola multipack',
    categories_tags: ['en:beverages', 'en:sodas'],
    quantity: '6 x 330 ml',
    product_quantity: 1980,
    product_quantity_unit: 'ml',
    nutrition_data_per: '100ml',
    nutriments: { 'energy-kcal_100g': 42, carbohydrates_100g: 10.6, sugars_100g: 10.6 },
  },
  {
    code: '0049000000450',
    product_name: 'Synthetic apple juice',
    categories_tags: ['en:beverages', 'en:fruit-juices'],
    quantity: '1 l',
    product_quantity: 1000,
    product_quantity_unit: 'ml',
    nutriments: { 'energy-kcal_100g': 44, carbohydrates_100g: 10.6, sugars_100g: 10 },
  },
];

test('Open Food Facts products map to the Foods in the golden file', () => {
  const foods = products.map((product) => fromOpenFoodFacts(product, { now }));
  // Every nutrient the mapper can write, with the factor from grams; ExerlyCore
  // checks each is one of its nutrients and the factor matches its unit.
  const nutrients = Object.values(OFF_NUTRIENTS);
  // A few bundled USDA generic foods, with each nutrient's unit there.
  const generic = {
    units: genericFoods.table.units,
    foods: ['banana', 'salmon', 'peanut butter'].map(
      (query) => genericFoods.search(query, 1, { now })[0]
    ),
  };
  if (process.env.EXERLY_WRITE_FOODS_GOLDEN === '1') {
    fs.writeFileSync(
      file,
      `${JSON.stringify({ version: 1, nutrients, products, foods, generic }, null, 2)}\n`
    );
  }
  const golden = JSON.parse(fs.readFileSync(file, 'utf8'));
  assert.deepEqual(golden.products, products, 'The fixture products match the golden file');
  assert.deepEqual(golden.nutrients, nutrients);
  assert.deepEqual(foods, golden.foods);
  assert.deepEqual(generic, golden.generic);
});

test('nutrients land in ExerlyCore units and bad values are left out', () => {
  const [bar, drink, unnamed, uncoded, spread] = products.map((product) =>
    fromOpenFoodFacts(product, { now })
  );
  assert.equal(bar.id, 'off:0012345678905');
  assert.equal(bar.brand, 'Example Mills');
  assert.equal(bar.per100g.sodium, 240, 'mg');
  assert.equal(bar.per100g.iron, 3.6, 'mg');
  assert.equal(bar.per100g.vitaminA, 150, 'µg');
  assert.equal(bar.per100g.vitaminD, 2.5, 'µg');
  assert.equal(bar.per100g.folate, 100, 'µg');
  assert.equal(bar.per100g.niacin, 4.2, 'mg');
  assert.ok(!('alcohol' in bar.per100g), 'alcohol is % by volume in Open Food Facts');
  assert.deepEqual(bar.servings, [{ name: '1 bar (40 g)', grams: 40 }]);
  assert.equal(drink.per100g.energy, 43.021, 'kJ converted to kcal');
  assert.deepEqual(drink.servings, [{ name: '330 ml', grams: 330 }]);
  assert.deepEqual(drink.volume, {
    density: 1,
    assumed: true,
    note: "Water's density, assumed: not known for this product",
  });
  assert.equal(bar.volume, undefined, 'A label per 100 g needs no density');
  assert.equal(unnamed, null);
  assert.equal(uncoded, null);
  assert.deepEqual(spread.per100g, { protein: 25.25 });
});

test('a label per 100 ml becomes per 100 g through the density of its category', () => {
  const oil = fromOpenFoodFacts(products[5], { now });
  assert.deepEqual(oil.volume, { density: 0.92, assumed: true, note: 'Typical for oils' });
  assert.deepEqual(oil.per100g, { energy: 900, fat: 100, saturatedFat: 15 });
  assert.deepEqual(oil.servings, [{ name: '1 tbsp (15 ml)', grams: 13.8 }]);
});

test('a package size is a serving: a can for canned food, never a multipack', () => {
  const [beans, tomatoes, cola, juice] = products
    .slice(6)
    .map((product) => fromOpenFoodFacts(product, { now }));
  assert.deepEqual(beans.servings, [
    { name: '1/2 cup (130 g)', grams: 130 },
    { name: '1 can', grams: 425 },
  ]);
  assert.deepEqual(tomatoes.servings.at(-1), { name: '1 can', grams: 411 });
  assert.deepEqual(cola.servings, [], 'Six cans are not one package');
  // A carton sold by volume, labelled per 100 g: its litre needs a density.
  assert.deepEqual(juice.servings, [{ name: '1 package', grams: 1040 }]);
  assert.equal(juice.volume.note, 'Typical for juices');
  // A single serve already is its package.
  const bar = fromOpenFoodFacts(
    { ...products[0], product_quantity: 40, product_quantity_unit: 'g' },
    { now }
  );
  assert.deepEqual(bar.servings, [{ name: '1 bar (40 g)', grams: 40 }]);
});
