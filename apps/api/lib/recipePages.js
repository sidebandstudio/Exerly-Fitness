// Reads a recipe from a web page for import: fetches the page a person gives
// and returns the schema.org Recipe its JSON-LD describes.
//
// Fetching a URL a client chose is the risky part, so the rules are strict:
// http and https on standard ports only; every address a host resolves to
// must be public, checked when connecting and again after each of at most
// three redirects; 2 MB and 8 s caps; no cookies or credentials; and a
// User-Agent that names Exerly. See docs/DECISIONS.md (2026-10-10).

const dns = require('node:dns');
const http = require('node:http');
const https = require('node:https');
const net = require('node:net');
const zlib = require('node:zlib');
const { ApiError, badRequest } = require('./errors');

const MAX_BYTES = 2 * 1024 * 1024;
const TIMEOUT_MS = 8000;
const MAX_REDIRECTS = 3;
const USER_AGENT = 'ExerlyRecipeImport/1.0 (+https://sideband.studio; hello@sideband.studio)';

// Addresses a page may not be fetched from: private, loopback, link-local
// (with the cloud metadata address 169.254.169.254), carrier-grade NAT,
// multicast, reserved and documentation ranges, and IPv6 forms that carry an
// IPv4 address. IPv4-mapped IPv6 addresses (::ffff:a.b.c.d) are checked
// against the IPv4 rules by BlockList itself; listing ::ffff:0:0/96 here
// would block every IPv4 address.
const blocked = new net.BlockList();
for (const [address, prefix] of [
  ['0.0.0.0', 8],
  ['10.0.0.0', 8],
  ['100.64.0.0', 10],
  ['127.0.0.0', 8],
  ['169.254.0.0', 16],
  ['172.16.0.0', 12],
  ['192.0.0.0', 24],
  ['192.0.2.0', 24],
  ['192.88.99.0', 24],
  ['192.168.0.0', 16],
  ['198.18.0.0', 15],
  ['198.51.100.0', 24],
  ['203.0.113.0', 24],
  ['224.0.0.0', 4],
  ['240.0.0.0', 4],
])
  blocked.addSubnet(address, prefix, 'ipv4');
for (const [address, prefix] of [
  ['::', 96],
  ['64:ff9b::', 96],
  ['64:ff9b:1::', 48],
  ['100::', 64],
  ['2001::', 23],
  ['2001:db8::', 32],
  ['2002::', 16],
  ['fc00::', 7],
  ['fe80::', 10],
  ['fec0::', 10],
  ['ff00::', 8],
])
  blocked.addSubnet(address, prefix, 'ipv6');

/** Whether `address`, an IP address, is one a page may be fetched from. */
function isPublic(address) {
  const family = net.isIP(address);
  return family !== 0 && !blocked.check(address, family === 6 ? 'ipv6' : 'ipv4');
}

// The simulator fixture serves synthetic recipe pages from its own loopback
// address, which the rules refuse. It may allow that one origin, and only
// while NODE_ENV is test and the fixture's flag is set. Production sets
// neither, so there the allowance can't be made, and one made earlier isn't
// honored.
let fixtureOrigin = null;
const fixtureMode = () =>
  process.env.NODE_ENV === 'test' && process.env.EXERLY_TEST_FIXTURE === 'isolated-simulator';

function allowFixtureOrigin(origin) {
  if (!fixtureMode()) throw new Error('Only the isolated test fixture can serve recipe pages');
  fixtureOrigin = new URL(origin).origin;
}

const fromFixture = (url) =>
  fixtureOrigin !== null && fixtureMode() && url.origin === fixtureOrigin;

const refused = () => badRequest("Exerly can't import from that address.");
const timedOut = () => new ApiError(504, 'The page took too long to load. Try again.');
const tooLarge = () => new ApiError(422, 'The page is too large to read.');

/** A link Exerly may fetch, without its fragment. */
function pageURL(text) {
  let url;
  try {
    url = new URL(text);
  } catch {
    throw badRequest('Enter the link to a recipe page, starting with http:// or https://.');
  }
  if (!['http:', 'https:'].includes(url.protocol))
    throw badRequest('Only http and https links can be imported.');
  if (url.username || url.password)
    throw badRequest("Links with a user name or password can't be imported.");
  url.hash = '';
  return url;
}

/** A lookup that fails unless every address the host resolves to is public. */
const publicLookup = (lookup) => (hostname, options, callback) => {
  lookup(hostname, { ...options, all: true }, (error, addresses) => {
    if (error) return callback(error);
    if (!addresses.length || addresses.some(({ address }) => !isPublic(address)))
      return callback(refused());
    if (options.all) return callback(null, addresses);
    callback(null, addresses[0].address, addresses[0].family);
  });
};

const DECODERS = {
  gzip: zlib.createGunzip,
  'x-gzip': zlib.createGunzip,
  deflate: zlib.createInflate,
  br: zlib.createBrotliDecompress,
};

/** One GET: the page's HTML, or where it redirects. */
function get(url, { lookup, deadline, maxBytes }) {
  return new Promise((resolve, reject) => {
    const remaining = deadline - Date.now();
    if (remaining <= 0) return reject(timedOut());
    const fixture = fromFixture(url);
    const host = url.hostname.replace(/^\[|\]$/g, '');
    if (!fixture && (!['', '80', '443'].includes(url.port) || (net.isIP(host) && !isPublic(host))))
      return reject(refused());
    // No cookie jar and no Authorization: each request carries only these headers.
    const request = (url.protocol === 'https:' ? https : http).request(url, {
      headers: {
        'User-Agent': USER_AGENT,
        Accept: 'text/html,application/xhtml+xml;q=0.9',
        'Accept-Encoding': 'gzip, deflate, br',
      },
      agent: false,
      lookup: fixture ? lookup : publicLookup(lookup),
    });
    let settled = false;
    const finish = (error, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (error) {
        request.destroy();
        reject(error);
      } else resolve(value);
    };
    const timer = setTimeout(() => finish(timedOut()), remaining);
    request.on('error', (error) =>
      finish(
        error instanceof ApiError
          ? error
          : new ApiError(502, "The site couldn't be reached. Check the link and try again.")
      )
    );
    request.on('response', (response) => {
      const status = response.statusCode;
      if ([301, 302, 303, 307, 308].includes(status)) {
        response.resume();
        const location = response.headers.location;
        return location
          ? finish(null, { redirect: location })
          : finish(new ApiError(502, 'The page redirected nowhere.'));
      }
      if (status !== 200) {
        response.resume();
        return finish(
          new ApiError(502, `The page couldn't be loaded (the site answered ${status}).`)
        );
      }
      const [type, ...parameters] = (response.headers['content-type'] || '').split(';');
      if (!['text/html', 'application/xhtml+xml'].includes(type.trim().toLowerCase())) {
        response.resume();
        return finish(new ApiError(422, "That link isn't a web page."));
      }
      if (Number(response.headers['content-length']) > maxBytes) return finish(tooLarge());
      const encoding = (response.headers['content-encoding'] || '').trim().toLowerCase();
      if (encoding && encoding !== 'identity' && !DECODERS[encoding])
        return finish(new ApiError(422, "The page's encoding can't be read."));
      // The cap counts decoded bytes, so a small compressed page can't expand past it.
      const body = DECODERS[encoding] ? response.pipe(DECODERS[encoding]()) : response;
      const chunks = [];
      let size = 0;
      body.on('data', (chunk) => {
        size += chunk.length;
        if (size > maxBytes) {
          body.destroy();
          return finish(tooLarge());
        }
        chunks.push(chunk);
      });
      body.on('error', () => finish(new ApiError(502, "The page couldn't be read.")));
      body.on('end', () => {
        const charset = parameters
          .map((p) => p.trim().toLowerCase())
          .find((p) => p.startsWith('charset='))
          ?.slice(8)
          .replace(/"/g, '');
        let decoder;
        try {
          decoder = new TextDecoder(charset || 'utf-8');
        } catch {
          decoder = new TextDecoder('utf-8');
        }
        finish(null, { html: decoder.decode(Buffer.concat(chunks)) });
      });
    });
    request.end();
  });
}

/**
 * The page at `input` and its final URL, following at most three redirects,
 * each to a link checked as the first was. `lookup` is dns.lookup's shape.
 */
async function fetchPage(
  input,
  { lookup = dns.lookup, timeoutMs = TIMEOUT_MS, maxBytes = MAX_BYTES } = {}
) {
  let url = pageURL(input);
  const deadline = Date.now() + timeoutMs;
  for (let redirects = 0; ; redirects++) {
    const result = await get(url, { lookup, deadline, maxBytes });
    if (result.html !== undefined) return { url: url.href, html: result.html };
    if (redirects === MAX_REDIRECTS) throw new ApiError(422, 'That link redirects too many times.');
    url = pageURL(new URL(result.redirect, url).href);
  }
}

const ENTITIES = {
  amp: '&',
  lt: '<',
  gt: '>',
  quot: '"',
  apos: "'",
  nbsp: ' ',
  frac12: '½',
  frac14: '¼',
  frac34: '¾',
  frac13: '⅓',
  frac23: '⅔',
  frac18: '⅛',
  deg: '°',
  ndash: '–',
  mdash: '—',
  lsquo: '‘',
  rsquo: '’',
  ldquo: '“',
  rdquo: '”',
  hellip: '…',
};

const decode = (value) =>
  value.replace(/&(#x[0-9a-f]+|#\d+|[a-z]+\d*);/gi, (entity, name) => {
    if (name[0] !== '#') return ENTITIES[name.toLowerCase()] ?? entity;
    const code =
      name[1] === 'x' || name[1] === 'X' ? parseInt(name.slice(2), 16) : Number(name.slice(1));
    return code > 0 && code <= 0x10ffff ? String.fromCodePoint(code) : '';
  });

/** Plain text: entities decoded (twice, for pages that encode them twice) and tags removed. */
const plain = (value) =>
  typeof value === 'string'
    ? decode(decode(value).replace(/<[^>]*>/g, ' '))
        .replace(/\s+/g, ' ')
        .trim()
    : '';

/** The first Recipe node in parsed JSON-LD: in a list, a @graph, or a page's main entity. */
function findRecipe(node, depth = 0) {
  if (depth > 6 || node === null || typeof node !== 'object') return null;
  if (Array.isArray(node)) {
    for (const item of node) {
      const found = findRecipe(item, depth + 1);
      if (found) return found;
    }
    return null;
  }
  // "Recipe", "schema:Recipe" or "https://schema.org/Recipe".
  const types = [].concat(node['@type'] ?? []);
  if (types.some((type) => typeof type === 'string' && type.replace(/^.*[/:]/, '') === 'Recipe'))
    return node;
  for (const key of ['@graph', 'mainEntity', 'mainEntityOfPage', 'itemListElement', 'item']) {
    const found = findRecipe(node[key], depth + 1);
    if (found) return found;
  }
  return null;
}

/** Instructions as lines: steps, a section's name before its steps. */
function steps(node, depth = 0) {
  if (depth > 4 || node == null) return [];
  if (typeof node === 'string') {
    return node
      .split(/<\/p>|<br\s*\/?>|\n/i)
      .map(plain)
      .filter(Boolean);
  }
  if (Array.isArray(node)) return node.flatMap((item) => steps(item, depth + 1));
  if (typeof node !== 'object') return [];
  if (node.itemListElement) {
    const name = plain(node.name);
    return [...(name ? [`${name}:`] : []), ...steps(node.itemListElement, depth + 1)];
  }
  return steps(node.text ?? node.name, depth + 1);
}

/** Servings from a recipeYield such as 4, "4 servings", ["4", "4 servings"] or "Serves 4-6". */
function servings(value) {
  for (const item of [].concat(value ?? [])) {
    const match = /(\d+(?:\.\d+)?)/.exec(plain(String(item)));
    const count = match && Number(match[1]);
    if (count > 0 && count <= 100) return count;
  }
  return null;
}

/**
 * The recipe in a page's JSON-LD: its name, ingredient lines, servings,
 * numbered steps and the page's URL. Throws when the page has none.
 */
function readRecipe(html, url) {
  let recipe = null;
  const scripts = html.matchAll(
    /<script\b[^>]*\btype\s*=\s*["']?application\/ld\+json\b[^>]*>([\s\S]*?)<\/script\s*>/gi
  );
  for (const [, text] of scripts) {
    try {
      recipe = findRecipe(JSON.parse(text.trim().replace(/^<!--|-->$/g, '')));
    } catch {
      // A page's other JSON-LD blocks may be malformed; the recipe can still be in a later one.
    }
    if (recipe) break;
  }
  if (!recipe)
    throw new ApiError(
      422,
      "This page has no recipe data. Try the recipe's own page, or add the ingredients yourself."
    );
  const ingredients = []
    .concat(recipe.recipeIngredient ?? recipe.ingredients ?? [])
    .map(plain)
    // Group headings such as "For the sauce:" aren't ingredients.
    .filter((line) => line && !(line.endsWith(':') && !/\d/.test(line)))
    .map((line) => line.slice(0, 300))
    .slice(0, 100);
  if (!ingredients.length) throw new ApiError(422, "This page's recipe data lists no ingredients.");
  let number = 0;
  const instructions = steps(recipe.recipeInstructions)
    .map((line) => (line.endsWith(':') ? line : `${++number}. ${line.replace(/^\d+[.)]\s*/, '')}`))
    .join('\n')
    .slice(0, 5000);
  return {
    name: (plain(recipe.name) || plain(recipe.headline) || 'Imported recipe').slice(0, 120),
    ingredients,
    servings: servings(recipe.recipeYield ?? recipe.yield),
    instructions: instructions || null,
    url,
  };
}

module.exports = {
  MAX_BYTES,
  USER_AGENT,
  allowFixtureOrigin,
  fetchPage,
  isPublic,
  readRecipe,
};
