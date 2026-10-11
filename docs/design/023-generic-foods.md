# Generic foods from USDA, bundled

Owner: logic agent. Status: built, 2026-10-07. PARITY N02 (food search) and the
Beyond seed B10 (coverage), for generic foods.

## Problem

Food search used Open Food Facts alone. It is good for packaged products and
thin for plain foods: "banana" or "chicken breast" gave branded products, not
the food. MacroFactor's common foods are what a person logs most. USDA's
search API needs a key (QUESTIONS_FOR_ALI.md), but its datasets are public
domain and need none.

## Data

USDA FoodData Central's Food and Nutrient Database for Dietary Studies
(FNDDS) 2021-2023, published 2024-10-31: 5,431 foods as Americans eat them
("Banana, raw", "Egg, whole, fried with oil", "Pizza, cheese, thin crust"),
each with the same 65 nutrients and household portions ("1 banana" = 126 g).
One food, human milk, has no nutrients and is left out of the 5,432.

`apps/api/scripts/build-generic-foods.js` turns the download into
`apps/api/lib/genericFoods.json` (1.7 MB, 0.4 MB gzipped): one food a line,
so a new release reads as a diff. The download itself isn't kept. In memory
it is about 8 MB, loads in under 0.1 s, and a search takes about 4 ms.

## Nutrients

FNDDS gives 39 of ExerlyCore's nutrients, in its units already. The rest,
such as amino acids, manganese, pantothenic acid, added sugars, starch and
trans fat, aren't measured there, so they are left out of `per100g`: unknown,
never zero. FNDDS reports fatty acids by chain length. 18:3 counts as ALA and
18:2 as linoleic acid, as USDA's own intake tables do. Omega-3 is ALA, EPA,
DPA and DHA; omega-6 is 18:2 and 20:4. Vitamin A is RAE, folate is DFE and
vitamin E is alpha-tocopherol, which are the units ExerlyCore's reference
intakes use. A test holds every nutrient's unit to ExerlyCore's.

## Search

`/v1/foods/search` returns generic foods first, a quarter of the results at
most and three at least (five of the default 20), then Open Food Facts
products. Half was tried first, but "oat" then filled the first ten rows with
oatmeal and pushed packaged products off a small screen. Generic results need
no provider call, so they still come back when Open Food Facts is down or over
its budget. Every word
of the query must start a word of the food's name, with plurals folded
("strawberries" finds "Strawberries"). Ranking, in order:

1. Foods the query names: the first part of the name ("Banana, raw" for
   banana), the first parts together ("Beef, ground" for ground beef), or a
   later part alone ("Fish, salmon" for salmon). A part may be the query's
   "-ed" form, so toasted breads are toast, before Shrimp toast and French
   toast.
2. Foods whose first part holds more of the query.
3. Whole words before prefixes.
4. Plain forms ("raw", "NFS") before prepared ones.
5. Shorter descriptions.

The attribution credits USDA when generic foods are shown, and Open Food
Facts when its products are. Generic foods have IDs `usda:<fdcId>` and
`source` `usda`, so the app shows and saves them like any Food.

## Limits

FNDDS has no popularity, so ranking can't know that "Coffee, brewed" is
logged more than "Coffee, Cuban". The person's own history (suggestions and
recent foods) covers that better than a guess. FNDDS has no raw ingredients
by brand and no restaurant menus. A USDA key would add SR Legacy's
ingredients and more; the bundled table doesn't depend on it.
