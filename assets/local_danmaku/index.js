'use strict'
// LumeBox adapter; upstream AGPL-3.0 source and modifications: manifest.json.
const crypto = require('node:crypto')
module.exports.start = async function start(config) {
  const upstream = require(config.upstreamPath)
  const token = String(config.token || '')
  if (token.length < 32) throw new Error('Local danmaku token missing')
  const env = Object.freeze({
    TOKEN: token,
    SOURCE_ORDER: '360,douban,renren,hanjutv',
    PLATFORM_ORDER: 'qq,qiyi,youku,mgtv,bilibili',
    SEARCH_CACHE_MINUTES: '1', COMMENT_CACHE_MINUTES: '2',
    RATE_LIMIT_MAX_REQUESTS: '0',
    MAX_REQUESTS: '2',
  })
  const equal = value => {
    const a = Buffer.from(value), b = Buffer.from(token)
    return a.length === b.length && crypto.timingSafeEqual(a, b)
  }
  const server = globalThis.catServerFactory(async (req, res) => {
    const url = new URL(req.url, 'http://127.0.0.1')
    const parts = url.pathname.split('/')
    if (!equal(parts[1] || '')) { res.writeHead(403); res.end(); return }
    const route = '/' + parts.slice(2).join('/')
    if (req.method !== 'GET') { res.writeHead(405); res.end(); return }
    if (route === '/_health') {
      res.writeHead(200, { 'content-type': 'application/json' })
      res.end('{"ok":true,"service":"local-danmaku"}'); return
    }
    // No upstream admin UI, file upload, arbitrary URL proxy or config writes.
    if (!/^\/api\/v2\/(?:search\/episodes|bangumi\/[^/]+|comment\/[^/]+)$/.test(route)) {
      res.writeHead(404); res.end(); return
    }
    try {
      const result = await upstream.handle('http://127.0.0.1' + url.pathname + url.search, env)
      const bytes = Buffer.from(await result.arrayBuffer())
      if (res.destroyed) return
      res.writeHead(result.status, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' })
      res.end(bytes)
    } catch (_) {
      if (!res.destroyed && !res.headersSent) {
        res.writeHead(502, { 'content-type': 'application/json' })
        res.end('{"success":false,"errorCode":502}')
      }
    }
  })
  server.requestTimeout = 35000
  server.headersTimeout = 10000
  server.maxConnections = 4
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, resolve) })
}
