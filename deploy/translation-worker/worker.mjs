const json = (value, status = 200) => new Response(JSON.stringify(value), {
  status, headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' },
});

// Only the operator's configured upstream endpoints can be called.
export async function handle(request, env, send = fetch) {
  const path = new URL(request.url).pathname;
  if (path === '/health' && request.method === 'GET') return json({ ok: true });
  if (!env.ACCESS_TOKEN || request.headers.get('authorization') !== `Bearer ${env.ACCESS_TOKEN}`) {
    return json({ error: 'unauthorized' }, 401);
  }
  const image = path === '/translate/with-form/image';
  if (!image && path !== '/v1/chat/completions') return json({ error: 'not_found' }, 404);
  if (request.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);
  const upstream = image ? env.MANGA_UPSTREAM : env.AI_UPSTREAM;
  if (!upstream) return json({ error: 'upstream_not_configured' }, 503);
  let endpoint;
  try { endpoint = new URL(upstream); } catch { return json({ error: 'invalid_upstream' }, 503); }
  if (endpoint.protocol !== 'https:' || endpoint.username || endpoint.password) {
    return json({ error: 'https_upstream_required' }, 503);
  }
  const max = image ? 21 * 1024 * 1024 : 256 * 1024;
  if (Number(request.headers.get('content-length')) > max) return json({ error: 'body_too_large' }, 413);
  // Read a bounded body even when Content-Length was omitted or forged.
  const reader = request.body?.getReader();
  if (!reader) return json({ error: 'body_required' }, 400);
  const chunks = []; let length = 0;
  while (true) {
    const { value, done } = await reader.read();
    if (done) break;
    length += value.byteLength;
    if (length > max) { await reader.cancel(); return json({ error: 'body_too_large' }, 413); }
    chunks.push(value);
  }
  const headers = new Headers();
  const type = request.headers.get('content-type') ?? '';
  if (image ? !type.startsWith('multipart/form-data;') : !type.startsWith('application/json')) {
    return json({ error: 'unsupported_content_type' }, 415);
  }
  headers.set('content-type', type);
  const key = image ? env.MANGA_UPSTREAM_TOKEN : env.AI_UPSTREAM_KEY;
  if (key) headers.set('authorization', `Bearer ${key}`);
  try {
    const response = await send(endpoint.toString(), { method: 'POST', headers,
      body: new Blob(chunks), redirect: 'manual',
      signal: AbortSignal.timeout(image ? 210000 : 55000) });
    if (response.status >= 300 && response.status < 400) {
      await response.body?.cancel();
      return json({ error: 'upstream_redirect_rejected' }, 502);
    }
    if (!response.ok) {
      await response.body?.cancel();
      return json({ error: 'upstream_failed', upstream_status: response.status }, 502);
    }
    return new Response(response.body, { status: response.status, headers: {
      'content-type': response.headers.get('content-type') ?? (image ? 'image/png' : 'application/json'),
      'cache-control': 'no-store',
    } });
  } catch { return json({ error: 'upstream_unavailable_or_timeout' }, 502); }
}

export default { fetch(request, env) { return handle(request, env); } };
