// Recipe import from a web page: the fetcher's safety rules, the JSON-LD
// reader, the /v1/recipes/import route and /v1/foods/match. Pages are served
// by a local server the tests allow the way the simulator fixture does;
// every other address goes through the real checks.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const net = require('node:net');
const path = require('node:path');
const zlib = require('node:zlib');
const { randomUUID } = require('node:crypto');
const { startServer, signUp } = require('./helpers/server');
const recipePages = require('../lib/recipePages');
const providers = require('../lib/foodProviders');
const { foodProblems } = require('../lib/nutrition/validate');

const recipe = {
  '@context': 'https://schema.org',
  '@graph': [
    { '@type': 'WebSite', name: 'Synthetic kitchen' },
    {
      '@type': ['Recipe'],
      name: 'Weeknight black bean chili &amp; rice',
      recipeYield: ['4', '4 servings'],
      recipeIngredient: [
        '1 (15 oz) can black beans, drained',
        'For the topping:',
        '&frac12; tsp salt',
        '<b>2 cups</b> cooked rice',
      ],
      recipeInstructions: [
        { '@type': 'HowToStep', text: 'Warm the beans.' },
        {
          '@type': 'HowToSection',
          name: 'To serve',
          itemListElement: [{ '@type': 'HowToStep', text: '2. Spoon over the rice.' }],
        },
      ],
    },
  ],
};
const page = (data) =>
  `<!doctype html><html><head><script type="application/ld+json">{ not json</script>` +
  `<script type="application/ld+json">${JSON.stringify(data)}</script></head><body>Chili</body></html>`;

let api;
let base;
let pages;
let elsewhere;
let elsewhereHits = 0;
const seen = [];

test.before(async () => {
  api = await startServer();
  // A second local server, which no page may reach: a stand-in for an internal service.
  elsewhere = http.createServer((_req, res) => {
    elsewhereHits += 1;
    res.end('internal');
  });
  await new Promise((resolve) => elsewhere.listen(0, '127.0.0.1', resolve));
  pages = http.createServer((req, res) => {
    seen.push({ url: req.url, headers: req.headers });
    const html = (body) => {
      res.setHeader('Content-Type', 'text/html; charset=utf-8');
      res.end(body);
    };
    const chain = /^\/chain\/(\d+)$/.exec(req.url);
    if (req.url === '/recipe') return html(page(recipe));
    if (chain) {
      const left = Number(chain[1]);
      res.writeHead(302, { Location: left ? `/chain/${left - 1}` : '/recipe' });
      return res.end();
    }
    if (req.url === '/cookie') {
      res.writeHead(302, { 'Set-Cookie': 'session=synthetic', Location: '/recipe' });
      return res.end();
    }
    if (req.url === '/to-private') {
      res.writeHead(302, { Location: `http://127.0.0.1:${elsewhere.address().port}/` });
      return res.end();
    }
    if (req.url === '/to-localhost') {
      res.writeHead(301, { Location: `http://localhost:${elsewhere.address().port}/` });
      return res.end();
    }
    if (req.url === '/to-metadata') {
      res.writeHead(307, { Location: 'http://169.254.169.254/latest/meta-data/' });
      return res.end();
    }
    if (req.url === '/to-file') {
      res.writeHead(302, { Location: 'file:///etc/passwd' });
      return res.end();
    }
    if (req.url === '/big') {
      res.setHeader('Content-Type', 'text/html');
      for (let i = 0; i < 22; i++) res.write(' '.repeat(100 * 1024));
      return res.end();
    }
    if (req.url === '/big-gzip') {
      // 4 MB of spaces compress to a few kilobytes; the cap counts what they expand to.
      res.writeHead(200, { 'Content-Type': 'text/html', 'Content-Encoding': 'gzip' });
      return res.end(zlib.gzipSync(Buffer.alloc(4 * 1024 * 1024, ' ')));
    }
    if (req.url === '/gzip') {
      res.writeHead(200, { 'Content-Type': 'text/html', 'Content-Encoding': 'gzip' });
      return res.end(zlib.gzipSync(page(recipe)));
    }
    if (req.url === '/slow') return; // Never answers.
    if (req.url === '/json') {
      res.setHeader('Content-Type', 'application/json');
      return res.end(JSON.stringify(recipe));
    }
    if (req.url === '/plain') return html('<html><body><h1>Chili</h1><p>Beans.</p></body></html>');
    if (req.url === '/missing') {
      res.statusCode = 404;
      return res.end();
    }
    res.statusCode = 500;
    res.end();
  });
  await new Promise((resolve) => pages.listen(0, '127.0.0.1', resolve));
  base = `http://127.0.0.1:${pages.address().port}`;
  process.env.EXERLY_TEST_FIXTURE = 'isolated-simulator';
  recipePages.allowFixtureOrigin(base);
});

test.after(async () => {
  pages.closeAllConnections();
  await new Promise((resolve) => pages.close(resolve));
  await new Promise((resolve) => elsewhere.close(resolve));
  await api.close();
});

/** dns.lookup's shape, answering every host with `addresses`. */
const lookupTo =
  (...addresses) =>
  (_hostname, options, callback) => {
    const all = addresses.map((address) => ({ address, family: net.isIP(address) }));
    if (options.all) callback(null, all);
    else callback(null, all[0].address, all[0].family);
  };

test('private, loopback, link-local, metadata and embedded IPv4 addresses are refused', () => {
  for (const address of [
    '127.0.0.1',
    '10.1.2.3',
    '172.16.5.4',
    '192.168.1.1',
    '169.254.169.254',
    '100.64.0.1',
    '0.0.0.0',
    '224.0.0.1',
    '::1',
    '::',
    'fe80::1',
    'fd00:ec2::254',
    '::ffff:127.0.0.1',
    '::ffff:10.0.0.1',
    '64:ff9b::7f00:1',
    '2002:7f00:1::1',
    'ff02::1',
  ])
    assert.equal(recipePages.isPublic(address), false, address);
  for (const address of [
    '93.184.216.34',
    '1.1.1.1',
    '8.8.8.8',
    '2606:4700:4700::1111',
    '2001:4860:4860::8888',
    '::ffff:93.184.216.34',
  ])
    assert.equal(recipePages.isPublic(address), true, address);
});

test('only http and https links, without credentials or unusual ports, are fetched', async () => {
  for (const link of [
    'file:///etc/passwd',
    'ftp://recipes.example/chili',
    'javascript:alert(1)',
    'data:text/html,<p>hi</p>',
    'gopher://recipes.example/',
    'not a link',
    'http://cook:secret@recipes.example/chili',
    'http://recipes.example:8080/chili',
  ])
    await assert.rejects(
      recipePages.fetchPage(link, { lookup: lookupTo('93.184.216.34') }),
      { status: 400 },
      link
    );
});

test('private addresses are refused, typed or resolved, before connecting', async () => {
  for (const link of [
    'http://127.0.0.1/',
    'http://[::1]/',
    'http://169.254.169.254/latest/meta-data/',
    'http://2130706433/',
    'http://10.0.0.1/',
    `http://127.0.0.1:${elsewhere.address().port}/`,
  ])
    await assert.rejects(recipePages.fetchPage(link), { status: 400 }, link);
  // A host that resolves to a private address, or to a public and a private one.
  for (const lookup of [lookupTo('10.0.0.7'), lookupTo('93.184.216.34', '127.0.0.1')])
    await assert.rejects(recipePages.fetchPage('https://recipes.example/chili', { lookup }), {
      status: 400,
      message: "Exerly can't import from that address.",
    });
  assert.equal(elsewhereHits, 0);
});

test('a redirect to a private address, or away from http, is refused', async () => {
  for (const route of ['/to-private', '/to-localhost', '/to-metadata', '/to-file'])
    await assert.rejects(recipePages.fetchPage(`${base}${route}`), { status: 400 }, route);
  assert.equal(elsewhereHits, 0, 'Nothing reached the internal server');
});

test('at most three redirects are followed', async () => {
  const followed = await recipePages.fetchPage(`${base}/chain/2`);
  assert.equal(followed.url, `${base}/recipe`, 'Three redirects reach the page');
  await assert.rejects(recipePages.fetchPage(`${base}/chain/3`), {
    status: 422,
    message: 'That link redirects too many times.',
  });
});

test('pages over 2 MB, plain or compressed, are refused; a compressed page is read', async () => {
  await assert.rejects(recipePages.fetchPage(`${base}/big`), {
    status: 422,
    message: 'The page is too large to read.',
  });
  await assert.rejects(recipePages.fetchPage(`${base}/big-gzip`), { status: 422 });
  const read = await recipePages.fetchPage(`${base}/gzip`);
  assert.equal(recipePages.readRecipe(read.html, read.url).servings, 4);
});

test('a page that takes too long times out', async () => {
  const started = Date.now();
  await assert.rejects(recipePages.fetchPage(`${base}/slow`, { timeoutMs: 300 }), { status: 504 });
  assert.ok(Date.now() - started < 2000);
});

test('a link that is not a web page, or fails, says so', async () => {
  await assert.rejects(recipePages.fetchPage(`${base}/json`), {
    status: 422,
    message: "That link isn't a web page.",
  });
  await assert.rejects(recipePages.fetchPage(`${base}/missing`), { status: 502 });
});

test('requests carry Exerly’s User-Agent and no cookies, even after a cookie is set', async () => {
  seen.length = 0;
  await recipePages.fetchPage(`${base}/cookie`);
  assert.deepEqual(
    seen.map((request) => request.url),
    ['/cookie', '/recipe']
  );
  for (const request of seen) {
    assert.equal(request.headers['user-agent'], recipePages.USER_AGENT);
    assert.equal(request.headers.cookie, undefined);
    assert.equal(request.headers.authorization, undefined);
  }
});

test('the fixture allowance cannot be made or used outside the isolated test fixture', async () => {
  const saved = process.env.NODE_ENV;
  try {
    process.env.NODE_ENV = 'production';
    assert.throws(() => recipePages.allowFixtureOrigin('http://127.0.0.1:1'));
    // The allowance made above isn't honored either.
    await assert.rejects(recipePages.fetchPage(`${base}/recipe`), { status: 400 });
  } finally {
    process.env.NODE_ENV = saved;
  }
  delete process.env.EXERLY_TEST_FIXTURE;
  try {
    assert.throws(() => recipePages.allowFixtureOrigin('http://127.0.0.1:1'));
    await assert.rejects(recipePages.fetchPage(`${base}/recipe`), { status: 400 });
  } finally {
    process.env.EXERLY_TEST_FIXTURE = 'isolated-simulator';
  }
  // Only the fixture script makes the allowance, and nothing deployed sets its flag.
  const root = path.join(__dirname, '../../..');
  const sources = (dir) =>
    fs
      .readdirSync(dir, { withFileTypes: true })
      .flatMap((entry) =>
        entry.isDirectory()
          ? entry.name === 'node_modules' || entry.name === 'tests'
            ? []
            : sources(path.join(dir, entry.name))
          : [path.join(dir, entry.name)]
      );
  const callers = sources(path.join(root, 'apps/api')).filter(
    (file) => file.endsWith('.js') && fs.readFileSync(file, 'utf8').includes('allowFixtureOrigin(')
  );
  assert.deepEqual(callers, [path.join(root, 'apps/api/lib/recipePages.js')]);
  for (const file of ['Procfile', 'docker-compose.yml', 'apps/api/Dockerfile'])
    assert.ok(!fs.readFileSync(path.join(root, file), 'utf8').includes('EXERLY_TEST_FIXTURE'));
});

test('the recipe in a page’s JSON-LD is read as plain text', async () => {
  const read = await recipePages.fetchPage(`${base}/recipe`);
  assert.deepEqual(recipePages.readRecipe(read.html, read.url), {
    name: 'Weeknight black bean chili & rice',
    ingredients: ['1 (15 oz) can black beans, drained', '½ tsp salt', '2 cups cooked rice'],
    servings: 4,
    instructions: '1. Warm the beans.\nTo serve:\n2. Spoon over the rice.',
    url: `${base}/recipe`,
  });
  const single = recipePages.readRecipe(
    page({
      '@type': 'Recipe',
      name: 'Oats',
      recipeYield: 'Serves 2-3',
      recipeIngredient: ['80 g oats'],
      recipeInstructions: '<p>Soak.</p><p>Eat.</p>',
    }),
    'https://recipes.example/oats'
  );
  assert.equal(single.servings, 2);
  assert.equal(single.instructions, '1. Soak.\n2. Eat.');
  assert.throws(() => recipePages.readRecipe(page({ '@type': 'Recipe', name: 'Empty' }), base), {
    status: 422,
  });
});

test('a page without recipe data says so', async () => {
  const read = await recipePages.fetchPage(`${base}/plain`);
  assert.throws(() => recipePages.readRecipe(read.html, read.url), {
    status: 422,
    message:
      "This page has no recipe data. Try the recipe's own page, or add the ingredients yourself.",
  });
});

test('import needs the app’s session, a link, and stays under the hourly limit', async () => {
  const user = await signUp(api);
  assert.equal((await api.post('/v1/recipes/import', { url: `${base}/recipe` })).status, 401);
  const token = await api.post(
    '/v1/tokens',
    { name: 'Synthetic agent', scopes: ['read', 'propose', 'write'], password: user.password },
    { token: user.token, headers: { 'Idempotency-Key': randomUUID() } }
  );
  const byToken = await api.post(
    '/v1/recipes/import',
    { url: `${base}/recipe` },
    { token: token.body.token }
  );
  assert.equal(byToken.status, 403);

  const imported = await api.post(
    '/v1/recipes/import',
    { url: `${base}/recipe` },
    { token: user.token }
  );
  assert.equal(imported.status, 200, JSON.stringify(imported.body));
  assert.equal(imported.body.recipe.name, 'Weeknight black bean chili & rice');
  assert.equal(imported.body.recipe.ingredients.length, 3);
  const plain = await api.post(
    '/v1/recipes/import',
    { url: `${base}/plain` },
    { token: user.token }
  );
  assert.equal(plain.status, 422);
  assert.match(plain.body.message, /no recipe data/);
  assert.equal(
    (await api.post('/v1/recipes/import', { url: 'http://10.0.0.1/' }, { token: user.token }))
      .status,
    400
  );
  assert.equal((await api.post('/v1/recipes/import', {}, { token: user.token })).status, 400);

  // 30 an hour per account, counting the four above; another account has its own.
  for (let i = 0; i < 26; i++)
    assert.equal(
      (await api.post('/v1/recipes/import', { url: 'ftp://x' }, { token: user.token })).status,
      400
    );
  const limited = await api.post('/v1/recipes/import', { url: 'ftp://x' }, { token: user.token });
  assert.equal(limited.status, 429);
  const other = await signUp(api);
  assert.equal(
    (await api.post('/v1/recipes/import', { url: 'ftp://x' }, { token: other.token })).status,
    400
  );
});

test('ingredient names match generic foods strictly, without Open Food Facts searches', async () => {
  const user = await signUp(api);
  const original = providers.searchOpenFoodFactsProducts;
  providers.searchOpenFoodFactsProducts = async () => assert.fail('No provider search');
  try {
    const queries = [
      'black beans',
      'black beans canned',
      'coconut milk canned',
      'quinoa',
      'egg',
      'butter',
      'potatoes',
      'ground beef',
      'bacon',
      'salt',
      'flour',
      '',
    ];
    const res = await api.post('/v1/foods/match', { queries }, { token: user.token });
    assert.equal(res.status, 200, JSON.stringify(res.body));
    // Salt and flour aren't in the generic table; a wrong match (a salty granola bar,
    // a flour tortilla) would be worse than none.
    assert.deepEqual(
      res.body.foods.map((food) => food?.name ?? null),
      [
        // A recipe lists its own fat: not "Black beans, NFS", which has the fat-added values.
        'Black beans, from dried, no added fat',
        // A can's line asks for canned, and falls back to the plain name without one.
        'Black beans, from canned, no added fat',
        'Coconut milk',
        'Quinoa, no added fat',
        'Egg, whole, raw',
        'Butter, NFS',
        'Potato, NFS',
        'Beef, ground, raw',
        // Not "Bacon strip, meatless".
        'Bacon, NS as to type of meat, cooked',
        null,
        null,
        null,
      ]
    );
    assert.equal(res.body.foods[0].source, 'usda');
    assert.match(res.body.attribution, /USDA/);
  } finally {
    providers.searchOpenFoodFactsProducts = original;
  }
  const many = Array.from({ length: 101 }, () => 'salt');
  assert.equal(
    (await api.post('/v1/foods/match', { queries: many }, { token: user.token })).status,
    400
  );
  assert.equal(
    (await api.post('/v1/foods/match', { queries: 'salt' }, { token: user.token })).status,
    400
  );
  assert.equal((await api.post('/v1/foods/match', { queries: ['salt'] })).status, 401);
});

test('a recipe keeps its source link only as an http or https link', () => {
  const food = {
    id: 'recipe-1',
    name: 'Chili',
    source: 'recipe',
    per100g: { energy: 100 },
    servings: [],
    favorite: false,
    createdAt: '2026-10-10T12:00:00.000Z',
    ingredients: [
      {
        food: { foodID: 'usda:1', name: 'Beans', source: 'usda', per100g: { energy: 100 } },
        grams: 100,
      },
    ],
  };
  assert.deepEqual(
    foodProblems({ ...food, sourceURL: 'https://recipes.example/chili' }, 'recipe-1'),
    []
  );
  assert.deepEqual(foodProblems({ ...food, sourceURL: 'javascript:alert(1)' }, 'recipe-1'), [
    'sourceURL must be an http or https link',
  ]);
});
