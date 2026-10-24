import test from 'node:test';
import assert from 'node:assert/strict';
import worker, { handle } from './worker.mjs';

const env = { ACCESS_TOKEN: 'app-secret', AI_UPSTREAM: 'https://provider.test/chat',
  AI_UPSTREAM_KEY: 'provider-secret', MANGA_UPSTREAM: 'https://manga.test/translate/with-form/image' };
const request = (path, body = '["Hello"]', type = 'application/json') =>
  new Request(`https://worker.test${path}`, { method: 'POST', body,
    headers: { authorization: 'Bearer app-secret', 'content-type': type } });

test('Cloudflare entrypoint ignores the ExecutionContext third argument', async () => {
  const saved = globalThis.fetch;
  globalThis.fetch = async () => new Response('{}');
  try {
    const response = await worker.fetch(request('/v1/chat/completions'), env, { waitUntil() {} });
    assert.equal(response.status, 200);
  } finally { globalThis.fetch = saved; }
});

test('authentication, routes and payload limits are enforced without fetching', async () => {
  const fail = () => { throw new Error('must not fetch'); };
  assert.equal((await handle(new Request('https://worker.test/v1/chat/completions'), env, fail)).status, 401);
  assert.equal((await handle(request('/proxy?url=https://other.test'), env, fail)).status, 404);
  assert.equal((await handle(request('/v1/chat/completions', 'x'.repeat(262145)), env, fail)).status, 413);
  assert.equal((await handle(request('/v1/chat/completions'), { ...env, AI_UPSTREAM: 'http://unsafe.test' }, fail)).status, 503);
});
test('AI request uses the configured upstream secret and does not forward incoming credentials', async () => {
  const response = await handle(request('/v1/chat/completions'), env, async (url, options) => {
    assert.equal(url, env.AI_UPSTREAM);
    assert.equal(options.headers.get('authorization'), 'Bearer provider-secret');
    assert.equal(await options.body.text(), '["Hello"]');
    assert.equal(options.redirect, 'manual');
    return new Response('{"choices":[]}', { headers: { 'content-type': 'application/json' } });
  });
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('cache-control'), 'no-store');
});
test('multipart request boundary is preserved; redirects and failures do not leak upstream bodies', async () => {
  const response = await handle(request('/translate/with-form/image', '--boundary', 'multipart/form-data; boundary=boundary'), env,
    async (_, options) => {
      assert.equal(options.headers.get('content-type'), 'multipart/form-data; boundary=boundary');
      assert.equal(options.headers.has('authorization'), false);
      return new Response('png', { headers: { 'content-type': 'image/png' } });
    });
  assert.equal(response.headers.get('content-type'), 'image/png');
  const redirect = await handle(request('/v1/chat/completions'), env,
    async () => new Response('private upstream detail', { status: 302, headers: { location: 'https://other.test' } }));
  assert.equal(redirect.status, 502);
  assert.equal((await redirect.text()).includes('private'), false);
});
