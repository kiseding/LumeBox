import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

// Run the SDK emitted by html_home_files_smoke_test.dart. No dependency copies,
// source endpoints or remote scripts are executed by this check.
const sdk = fs.readFileSync(process.argv[2] || 'build/html-home-checks/sdk.js', 'utf8');
class Storage {
  values = new Map();
  getItem(key) { return this.values.get(String(key)) ?? null; }
  setItem(key, value) { this.values.set(String(key), String(value)); }
  removeItem(key) { this.values.delete(String(key)); }
  clear() { this.values.clear(); }
}
const calls = [], events = [], css = new Map();
const context = {
  localStorage: new Storage(),
  document: { documentElement: { style: { setProperty: (key, value) => css.set(key, value) } } },
  Event: class { constructor(type) { this.type = type; } },
  CustomEvent: class { constructor(type, options) { this.type = type; this.detail = options.detail; } },
  dispatchEvent: event => events.push(event),
  fetch: async (url, options) => {
    const call = JSON.parse(options.body);
    calls.push(call);
    let result = true;
    if (call.method === 'request') result = { ok: true, status: 200, body: '中文响应', headers: {} };
    if (call.method === 'chrome') result = { chromeMode: call.args.mode, safeTop: call.args.mode === 'edge' ? 59 : 0 };
    return { ok: true, json: async () => call.args.url === 'fail' ? { error: 'fixture failure' } : { result } };
  },
};
context.window = context;
vm.createContext(context);
vm.runInContext(sdk, context);
assert.equal(context.localStorage.getItem('theme'), 'green');
assert.equal(context.localStorage.getItem('escaped'), '</script>');
assert.equal(events.filter(event => event.type === 'fmsdk').length, 1);
assert.equal((await context.fm.req('https://fixture.invalid/', { timeout: 16 })).body, '中文响应');
assert.equal((await context.fm.req('fail')).ok, false);
const resource = new URL(context.fm.res('https://fixture.invalid/p.png', { headers: { Referer: 'https://live.invalid/' } }));
assert.equal(resource.pathname, '/session/resource');
assert.equal(JSON.parse(resource.searchParams.get('headers')).Referer, 'https://live.invalid/');
context.__fmWebHomeInlineResolver = async () => ({ url: 'https://fixture.invalid/live.m3u8', headers: { Referer: 'live' } });
await context.fm.vodInline({ vod_name: '直播间', mark: 'HLS', episodes: [{ name: 'HLS', url: 'fallback' }] });
assert.equal(calls.at(-1).args.options.headers.Referer, 'live');
assert.equal(calls.at(-1).args.url, 'https://fixture.invalid/live.m3u8');
await context.fm.pan.play({ url: 'https://pan.invalid/s/abc', title: '分享', password: '1234' });
assert.equal(calls.at(-1).args.url, 'push://https://pan.invalid/s/abc');
assert.equal(calls.at(-1).args.options.password, '1234');
assert.equal((await context.fm.config()).driveCheck, false);
assert.equal((await context.fm.pan.check([{}])).results[0].state, 'uncertain');
await context.fm.cache.set('key', 'value', 'livecombo');
assert.equal(calls.at(-1).args.scope, 'livecombo');
context.localStorage.setItem('theme', 'blue');
context.localStorage.setItem('theme', 'dark');
await new Promise(resolve => setImmediate(resolve));
assert.deepEqual(calls.filter(call => call.method === 'storage.set').map(call => call.args.value), ['blue', 'dark']);
await context.fm.ui.setChrome({ mode: 'edge' });
assert.equal(context.fm.ui.getViewport().safeTop, 59);
assert.equal(css.get('--fm-chrome-mode'), 'edge');
await context.fm.ui.restoreChrome();
assert.equal(context.fm.ui.getViewport().chromeMode, 'normal');

let scripts = 0;
for (const file of process.argv.slice(3)) {
  const html = fs.readFileSync(file, 'utf8');
  for (const match of html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script\s*>/gi)) {
    if (/\bsrc\s*=|type\s*=\s*["'](?:application\/json|application\/ld\+json)/i.test(match[1])) continue;
    new vm.Script(match[2], { filename: file });
    scripts++;
  }
}
console.log(JSON.stringify({ sdkContracts: 'passed', authorScriptsParsed: scripts, executedRemoteRequests: 0 }));
