const test = require('node:test');
const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const {join} = require('node:path');
const vm = require('node:vm');
const source = readFileSync(join(__dirname, '../docs/analytics.js'), 'utf8');
const choiceKey = 'machogs.analytics.choice';

function element(dataset = {}) {
  const listeners = new Map();
  return {dataset, hidden: false, disabled: false, textContent: '',
    addEventListener(name, callback) { listeners.set(name, callback); },
    click() { if (!this.disabled) listeners.get('click')?.(); }};
}
function page(options = {}) {
  const location = new URL(options.url || 'https://bnishit.github.io/machogs/?secret=private');
  const storage = new Map(Object.entries(options.storage || {}));
  const yes = element({analyticsConsent: 'yes'});
  const no = element({analyticsConsent: 'no'});
  const banner = element(), status = element();
  const links = (options.placements || ['nav', 'hero', 'install']).map(placement => element({downloadPlacement: placement}));
  const requests = [], windowEvents = new Map(), documentEvents = new Map();
  const document = {
    visibilityState: options.visibility || 'visible', referrer: 'https://private.example/?secret=referrer',
    querySelectorAll(selector) {
      return ({'[data-analytics-choice]': [banner], '[data-analytics-status]': [status],
        '[data-analytics-consent="yes"]': [yes], '[data-analytics-consent]': [yes, no],
        'a[data-download-placement]': links})[selector] || [];
    },
    addEventListener(name, callback) { documentEvents.set(name, callback); }
  };
  const window = {
    machogsAnalyticsConfig: options.config === null ? undefined : {
      token: 'phc_public_test', host: 'https://us.i.posthog.com', version: '1.3.0', ...options.config
    },
    addEventListener(name, callback) { windowEvents.set(name, callback); }
  };
  let serial = 0;
  vm.runInNewContext(source, {
    window, document, location, navigator: {...options.navigator}, URLSearchParams, AbortController,
    crypto: {randomUUID: () => `${options.idPrefix || 'page'}-${++serial}`},
    localStorage: {getItem: key => storage.get(key) ?? null, setItem: (key, value) => storage.set(key, value)},
    fetch(url, init) { requests.push({url, init, payload: JSON.parse(init.body)}); return new Promise(() => {}); }
  });
  return {yes, no, links, banner, status, requests, storage,
    storageChange(value, key = choiceKey) { windowEvents.get('storage')({key, newValue: value}); },
    visible() { document.visibilityState = 'visible'; documentEvents.get('visibilitychange')(); }};
}

test('no visits or downloads are sent before explicit consent', () => {
  const p = page();
  p.links.forEach(link => link.click()); p.visible();
  assert.equal(p.requests.length, 0);
  assert.equal(p.banner.hidden, false);
  p.yes.click();
  assert.deepEqual(p.requests.map(r => r.payload.event), ['machogs_website_visit']);
  assert.equal(p.storage.get(choiceKey), 'yes');
  assert.equal(p.banner.hidden, true);
});

test('only allowed event fields are sent, with no URL, query, referrer or browser identity', () => {
  const p = page({storage: {[choiceKey]: 'yes'}});
  p.links.forEach(link => link.click());
  assert.deepEqual(p.requests.map(r => r.payload.event), ['machogs_website_visit', ...Array(3).fill('machogs_download_clicked')]);
  for (const {url, init, payload} of p.requests) {
    assert.equal(url, 'https://us.i.posthog.com/i/v0/e/');
    assert.deepEqual(Object.keys(payload).sort(), ['api_key', 'distinct_id', 'event', 'properties', 'uuid']);
    assert.deepEqual(Object.keys(payload.properties).sort(), [
      '$geoip_disable', '$ip', '$process_person_profile', 'app_version', 'environment',
      ...(payload.event === 'machogs_download_clicked' ? ['placement'] : []), 'platform', 'product'
    ].sort());
    assert.equal(payload.properties.environment, 'production');
    assert.equal(payload.properties.$process_person_profile, false);
    assert.equal(payload.properties.$geoip_disable, true);
    assert.equal(payload.properties.$ip, '0.0.0.0');
    assert.equal(payload.properties.product, 'machogs');
    assert.equal(init.credentials, 'omit');
    assert.equal(init.referrerPolicy, 'no-referrer');
    assert.doesNotMatch(init.body, /private|secret|referrer|https?:\/\//);
  }
  assert.deepEqual(p.requests.slice(1).map(r => r.payload.properties.placement), ['nav', 'hero', 'install']);
});

test('unknown download placements cannot leak arbitrary strings', () => {
  const p = page({storage: {[choiceKey]: 'yes'}, placements: ['https://private.example/?secret=referrer']});
  p.links[0].click();
  assert.equal(p.requests.length, 1, 'unknown placements must not create a capture request');
});

test('visit and clicks share one page identity; reload gets a different identity', () => {
  const p = page({storage: {[choiceKey]: 'yes'}, idPrefix: 'first'});
  p.links[0].click(); p.links[1].click(); p.visible();
  assert.equal(p.requests.length, 3);
  assert.equal(new Set(p.requests.map(r => r.payload.distinct_id)).size, 1);
  assert.equal(new Set(p.requests.map(r => r.payload.uuid)).size, 3);
  const next = page({storage: Object.fromEntries(p.storage), idPrefix: 'next'});
  assert.notEqual(next.requests[0].payload.distinct_id, p.requests[0].payload.distinct_id);
  assert.deepEqual([...p.storage.keys()], [choiceKey]);
});

test('opt-out aborts outstanding requests and prevents future capture', () => {
  const p = page({storage: {[choiceKey]: 'yes'}});
  p.links[0].click(); p.no.click();
  assert.ok(p.requests.every(r => r.init.signal.aborted));
  p.links[1].click(); p.visible();
  assert.equal(p.requests.length, 2);
  assert.equal(p.storage.get(choiceKey), 'no');
  const next = page({storage: Object.fromEntries(p.storage)});
  next.links[0].click();
  assert.equal(next.requests.length, 0);
  assert.equal(next.banner.hidden, true);
});

test('re-enabling consent on the same page does not double count its visit', () => {
  const p = page(); p.yes.click(); p.no.click(); p.yes.click();
  assert.equal(p.requests.length, 1);
  p.links[0].click();
  assert.equal(p.requests.length, 2);
  assert.notEqual(p.requests[0].payload.distinct_id, p.requests[1].payload.distinct_id);
});

for (const navigator of [{doNotTrack: '1'}, {globalPrivacyControl: true}]) {
  test(`browser privacy signal overrides saved consent: ${JSON.stringify(navigator)}`, () => {
    const p = page({navigator, storage: {[choiceKey]: 'yes'}});
    p.yes.click(); p.links[0].click(); p.storageChange('yes');
    assert.equal(p.requests.length, 0);
    assert.equal(p.yes.disabled, true);
    assert.match(p.status.textContent, /privacy signal/);
  });
}

for (const url of ['http://localhost:3000/', 'https://preview.example/machogs/', 'https://bnishit.github.io/other/']) {
  test(`non-production page does not send: ${url}`, () => {
    const p = page({url, storage: {[choiceKey]: 'yes'}}); p.yes.click(); p.links[0].click();
    assert.equal(p.requests.length, 0);
    assert.equal(p.yes.disabled, true);
  });
}

test('explicit test mode is labeled test and uses separate consent storage', () => {
  const p = page({url: 'http://localhost:3000/?analytics_test=1', navigator: {webdriver: true}, storage: {[choiceKey]: 'yes'}});
  assert.equal(p.requests.length, 0);
  p.yes.click(); p.links[0].click();
  assert.equal(p.requests.length, 2);
  assert.ok(p.requests.every(r => r.payload.properties.environment === 'test'));
  assert.equal(p.storage.get('machogs.analytics.test.choice'), 'yes');
  assert.equal(p.storage.get(choiceKey), 'yes');
  p.storageChange('no'); p.links[0].click();
  assert.equal(p.requests.length, 3, 'production choice does not alter test consent');
  p.storageChange('no', 'machogs.analytics.test.choice'); p.links[0].click();
  assert.equal(p.requests.length, 3);
});

test('automated production visits are excluded even with saved consent', () => {
  const p = page({navigator: {webdriver: true}, storage: {[choiceKey]: 'yes'}});
  p.links[0].click(); assert.equal(p.requests.length, 0);
});

test('consent changes across tabs apply immediately and withdrawal aborts requests', () => {
  const p = page(); p.storageChange('yes'); p.links[0].click();
  assert.equal(p.requests.length, 2);
  p.storageChange('no'); p.links[0].click();
  assert.equal(p.requests.length, 2);
  assert.ok(p.requests.every(r => r.init.signal.aborted));
  p.storageChange('yes'); assert.equal(p.requests.length, 2);
  p.links[0].click(); assert.equal(p.requests.length, 3);
  p.storageChange(null); p.links[0].click();
  assert.equal(p.requests.length, 3);
  assert.equal(p.requests[2].init.signal.aborted, true);
});

test('hidden tabs defer visit until visible; privacy page does not count as landing visit', () => {
  const p = page({visibility: 'hidden', storage: {[choiceKey]: 'yes'}});
  assert.equal(p.requests.length, 0); p.visible(); p.visible(); assert.equal(p.requests.length, 1);
  const privacy = page({url: 'https://bnishit.github.io/machogs/privacy.html', storage: {[choiceKey]: 'yes'}});
  assert.equal(privacy.requests.length, 0);
  assert.equal(privacy.banner.hidden, false);
});

for (const config of [null, {token: ''}, {host: 'https://untrusted.example'}]) {
  test(`missing or untrusted config disables capture: ${JSON.stringify(config)}`, () => {
    const p = page({config, storage: {[choiceKey]: 'yes'}}); p.links[0].click();
    assert.equal(p.requests.length, 0);
    assert.equal(p.yes.disabled, true);
  });
}
