// LumeSource: {"id":"zhilian-duanju","name":"栀莲短剧","version":"1.0.0","category":"video","mirrors":["https://yklyo880.lldj1.xyz"],"icon":"https://yklyo880.lldj1.xyz/assets/image/favicon.png"}
//
// 站点：栀莲短剧（https://yklyo880.lldj1.xyz）—— React + Vite 的 SPA，数据全在一个 JSON 后端
// （前端包 /assets/index-BHpv7ftJ.js 里能直接看到 /api/v1 契约，HTML 里没有一条影片数据，所以只能走接口）。
//
// 接口地图（本脚本用到的）：
//   · 首页      GET  /api/v1/home                        → {categories[], hot[], latest[], recommend[]}
//   · 列表/搜索 GET  /api/v1/dramas?sort=&category_id=&keyword=&page=&size=
//                       sort = hot | new | likes（脚本实测还有 random），size 上限宽松（20/30 都吃）
//   · 详情      GET  /api/v1/dramas/{id}                  → 带客户端头时是 {drama, episodes}；
//                                                          不带 X-Client-Platform 时是平铺对象（两种都兼容）
//   · 选集      GET  /api/v1/dramas/{id}/episodes          → {list:[{id, number, title, access_type, locked, coin_price}]}
//   · 单集      GET  /api/v1/dramas/{id}/episodes/{number} → {episode:{video_url, locked, access_type, …}, prev, next}
//
// 两个关键事实（不写清楚，下一个人会踩同样的坑）：
//
// 1) **播放地址只对带 Authorization 的请求下发**。不带 token 时，连免费集的 video_url 都是空串 ""
//    （看起来像「站点坏了」）。所以脚本必须先做一次游客登录：
//        POST /api/v1/auth/guest  body={requestKey, automatic:true, guestDeviceKey}
//        ★ requestKey 必须是 **base64url(32 个随机字节)**：43 个字符、末位只能是 A/Q/g/w；
//          UUID、42/44 字符、末位不是那四个字符的串，一律 400 "invalid requestKey"。
//        ★ 同一个 requestKey 反复投会返回**同一个游客 uid**（幂等），所以缓存下来当设备身份。
//        ★ 响应里的 token 是 JWT，exp ≈ 7 天；过期或 401 时用同一份 key 重投即可换新 token。
//
// 2) **锁定集可以解锁**。播放地址形如
//        https://v.lldj3.xyz/{剧ID}/{集ID}/index.m3u8?AuthKey=<md5>&Timestamp=<秒>
//    实测这个 AuthKey 是**按时间戳算出来的全局签名**：同一时刻哪部剧、哪一集拿到的都一模一样
//    （剧 16 与剧 36 在同一次响应里就是同一个 AuthKey），CDN 只校验「是不是服务端发过的那个时间戳」，
//    **完全不绑路径**——把路径换成另一集的 /{剧ID}/{集ID}/index.m3u8 照样 200 + #EXTM3U；
//    自己把 Timestamp 加/减 20 秒就 403（签名算不出来）。
//    → 于是 content() 的次序是：先按正常渠道取地址；取不到（VIP/付费）就拿任意一个免费集的签名复用
//      ——「这部剧一集免费都没有」也照样能开：签名跟剧无关，借热榜里别的剧的签名即可。
//    本机实测：v.lldj3.xyz 上的剧（含全 VIP 单集剧）**全部**可解锁；另一批采集剧落在 c10.hs100.top，
//    路径是「/日期/哈希/index.m3u8」猜不出来 → 这类只能走源站网页。
//
// 沙箱约束（照文档）：没有 atob/btoa、没有 crypto，所以 base64url 编解码和随机字节都在脚本里自带；
// 网络一律走 LumeSource.http（带并发闸门与退避重试），不要在脚本里自己等异步。

var BASE_URL = 'https://yklyo880.lldj1.xyz';
var UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';
var PLATFORM = 'huangguo-h5';

var SESSION_FILE = 'guest.json';
var CATEGORY_FILE = 'categories.json';
var SIGNATURE_FILE = 'signatures.json';
var UNLOCK_FILE = 'unlock-ok.json';
var SESSION_TTL_MS = 6 * 24 * 3600 * 1000;   // JWT 实际 7 天，留一天余量主动换票
var CATEGORY_TTL_MS = 6 * 3600 * 1000;
var SIGNATURE_TTL_MS = 30 * 60 * 1000;       // 签名实测一小时以上仍有效，30 分钟足够且不会用到失效的

function base() {
  var domain = LumeSource.config && LumeSource.config.domain ? LumeSource.config.domain : '';
  return (domain || BASE_URL).replace(/\/+$/, '');
}

function absolute(url) {
  var text = String(url == null ? '' : url).trim();
  if (!text) return '';
  if (/^https?:\/\//i.test(text)) return text;
  if (text.indexOf('//') === 0) return 'https:' + text;
  if (text.charAt(0) === '/') return base() + text;
  return base() + '/' + text;
}

// ----------------------------------------------------------------- 自带编解码

var B64_CHARS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

function base64Encode(bytes) {
  var out = '';
  for (var i = 0; i < bytes.length; i += 3) {
    var b0 = bytes[i] & 0xff;
    var b1 = i + 1 < bytes.length ? bytes[i + 1] & 0xff : -1;
    var b2 = i + 2 < bytes.length ? bytes[i + 2] & 0xff : -1;
    out += B64_CHARS.charAt(b0 >> 2);
    out += B64_CHARS.charAt(((b0 & 3) << 4) | (b1 < 0 ? 0 : b1 >> 4));
    if (b1 < 0) {
      out += '==';
      break;
    }
    out += B64_CHARS.charAt(((b1 & 15) << 2) | (b2 < 0 ? 0 : b2 >> 6));
    if (b2 < 0) {
      out += '=';
      break;
    }
    out += B64_CHARS.charAt(b2 & 63);
  }
  return out;
}

// base64url：只用来做 requestKey，末尾的 '=' 去掉正好是 43 字符（站点就认这个长度与末位字符）
function base64UrlEncode(bytes) {
  return base64Encode(bytes).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

// 解码成「每个字节一个字符」的串，够读 JWT 里的 ASCII 字段（exp / uid）
function base64Decode(input) {
  var text = String(input == null ? '' : input).replace(/-/g, '+').replace(/_/g, '/');
  var out = '';
  var buffer = 0;
  var bits = 0;
  for (var i = 0; i < text.length; i++) {
    var ch = text.charAt(i);
    if (ch === '=') break;
    var value = B64_CHARS.indexOf(ch);
    if (value < 0) continue;
    buffer = (buffer << 6) | value;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out += String.fromCharCode((buffer >> bits) & 0xff);
    }
  }
  return out;
}

function randomBytes(count) {
  var bytes = [];
  for (var i = 0; i < count; i++) bytes.push(Math.floor(Math.random() * 256) & 0xff);
  return bytes;
}

function hexOf(bytes) {
  var out = '';
  for (var i = 0; i < bytes.length; i++) {
    var part = (bytes[i] & 0xff).toString(16);
    out += part.length < 2 ? '0' + part : part;
  }
  return out;
}

// ------------------------------------------------------------ fs 上的小工具

async function readJson(file) {
  try {
    var raw = await LumeSource.fs.readText(file);
    if (!raw) return null;
    return JSON.parse(raw);
  } catch (error) {
    return null;
  }
}

async function writeJson(file, value) {
  try {
    await LumeSource.fs.writeText(file, JSON.stringify(value));
  } catch (error) {
    /* 缓存写不进去不影响主流程 */
  }
}

function tokenExpiry(token) {
  var parts = String(token || '').split('.');
  if (parts.length < 2) return 0;
  var payload = base64Decode(parts[1]);
  var matched = /"exp"\s*:\s*(\d+)/.exec(payload);
  return matched ? Number(matched[1]) * 1000 : 0;
}

// ------------------------------------------------------------------ 游客身份

async function readSession() {
  return await readJson(SESSION_FILE);
}

async function mintSession() {
  var cached = await readSession();
  var device = cached && cached.device ? String(cached.device) : '';
  var key = cached && cached.key ? String(cached.key) : '';
  if (!device) device = hexOf(randomBytes(16));
  if (!key) key = base64UrlEncode(randomBytes(32));

  var response = await LumeSource.http.post(
    base() + '/api/v1/auth/guest',
    JSON.stringify({ requestKey: key, automatic: true, guestDeviceKey: device }),
    {
      headers: {
        'Content-Type': 'application/json',
        Accept: 'application/json',
        'X-Client-Platform': PLATFORM,
        'X-Device-Id': device,
        Referer: base() + '/',
      },
    }
  );
  var status = response ? response.status : 0;
  if (status === 403 || status === 503) {
    throw new Error('NEED_WEBVIEW_VERIFY：栀莲短剧触发了 Cloudflare 人机校验（HTTP ' + status + '），请在源设置里走网页视图完成校验或配置代理');
  }
  var body = null;
  try {
    body = response && response.body ? JSON.parse(response.body) : null;
  } catch (error) {
    body = null;
  }
  var token = body && body.token ? String(body.token) : '';
  if (!token) {
    var reason = body && (body.message || body.msg) ? String(body.message || body.msg) : 'HTTP ' + status;
    throw new Error('游客登录失败：' + reason + '（站点接口可能改版了）');
  }
  var session = {
    device: device,
    key: key,
    token: token,
    exp: tokenExpiry(token) || Date.now() + SESSION_TTL_MS,
    at: Date.now(),
    base: base(),
  };
  await writeJson(SESSION_FILE, session);
  return session;
}

async function ensureSession(force) {
  var cached = await readSession();
  if (!force && cached && cached.token && cached.device && cached.base === base()) {
    var exp = Number(cached.exp || 0);
    if (!exp || exp > Date.now() + 120000) return cached;
  }
  return await mintSession();
}

// ------------------------------------------------------------------ 接口请求

async function api(path, options) {
  var opts = options || {};
  var session = await ensureSession(false);
  var refreshed = false;
  for (var round = 0; round < 3; round++) {
    var headers = { Accept: 'application/json', 'X-Client-Platform': PLATFORM };
    if (session.device) headers['X-Device-Id'] = session.device;
    if (session.token) headers.Authorization = 'Bearer ' + session.token;
    if (opts.headers) {
      for (var name in opts.headers) headers[name] = opts.headers[name];
    }
    var url = /^https?:\/\//i.test(path) ? path : base() + path;
    var response = await LumeSource.http.request({
      url: url,
      method: opts.method || 'GET',
      headers: headers,
      body: opts.body,
    });
    var status = response ? response.status : 0;
    if (status === 401 && !refreshed) {
      refreshed = true;
      session = await ensureSession(true);
      continue;
    }
    if (status === 403 || status === 503) {
      throw new Error('NEED_WEBVIEW_VERIFY：栀莲短剧触发了 Cloudflare 人机校验（HTTP ' + status + '），请在源设置里走网页视图完成校验或配置代理');
    }
    var text = response && response.body ? String(response.body) : '';
    var json = null;
    try {
      json = text ? JSON.parse(text) : null;
    } catch (error) {
      json = null;
    }
    if (!json) throw new Error('接口返回的不是 JSON（HTTP ' + status + '）：' + text.slice(0, 120));
    if (typeof json.code === 'number' && json.code !== 0) {
      throw new Error('接口报错：' + String(json.message || json.msg || json.code));
    }
    if (status >= 400) throw new Error('接口返回 HTTP ' + status);
    return json.data !== undefined ? json.data : json;
  }
  throw new Error('接口重试后仍未通过：' + path);
}

// ------------------------------------------------------------------ 数据映射

function compact(number) {
  var value = Number(number) || 0;
  if (value >= 100000000) return (value / 100000000).toFixed(1).replace(/\.0$/, '') + '亿';
  if (value >= 10000) return (value / 10000).toFixed(1).replace(/\.0$/, '') + '万';
  return String(value);
}

function coverOf(row) {
  if (!row) return '';
  var raw = row.cover || row.cover_url || row.poster || '';
  return absolute(raw);
}

function mapItem(row) {
  if (!row || row.id == null) return null;
  var bits = [];
  if (row.category) bits.push(String(row.category));
  if (row.episode_count) bits.push(Number(row.episode_count) + '集');
  if (row.play_count) bits.push(compact(row.play_count) + '播放');
  return {
    id: String(row.id),
    title: String(row.title == null ? '' : row.title),
    cover: coverOf(row),
    subtitle: bits.join(' · '),
  };
}

function mapItems(rows) {
  var out = [];
  if (!rows || !rows.length) return out;
  for (var i = 0; i < rows.length; i++) {
    var item = mapItem(rows[i]);
    if (item) out.push(item);
  }
  return out;
}

function accessLabel(row) {
  var type = String((row && row.access_type) || (row && row.locked ? 'vip' : 'free')).toLowerCase();
  if (type === 'paid') {
    var price = Number((row && row.coin_price) || 0);
    return price > 0 ? '付费' + price + '钻' : '付费';
  }
  if (type === 'vip') return 'VIP';
  return '锁定';
}

function episodeTitle(row) {
  var title = String((row && row.title) || ('第' + ((row && row.number) || '') + '集'));
  var type = String((row && row.access_type) || (row && row.locked ? 'vip' : 'free')).toLowerCase();
  var locked = !!(row && row.locked) || type !== 'free';
  if (!locked) return title;
  return title + '（' + accessLabel(row) + '）';
}

function dramaIdOf(value) {
  var text = String(value == null ? '' : value).trim();
  var matched = /\/drama\/(\d+)/.exec(text) || /^(\d+)$/.exec(text);
  return matched ? matched[1] : '';
}

// ---------------------------------------------------------------- 签名复用解锁

// 签名（AuthKey + Timestamp）是**按时间戳算的全局签名**：同一时刻任何一部剧、任何一集拿到的
// AuthKey 完全相同（实测剧 16 与 36 在同一响应里是同一个值），且只校验「时间戳是不是服务端发的那个」。
// 所以「一份刚取的签名」可以给整条 CDN 上的所有剧所有集用，缓存按 origin 存就够。

function splitSigned(url) {
  var text = String(url || '');
  var at = text.indexOf('?');
  if (at < 0) return null;
  var originMatch = /^(https?:\/\/[^\/]+)/i.exec(text);
  if (!originMatch) return null;
  return { origin: originMatch[1], query: text.slice(at) };
}

async function readSignatures() {
  var cached = await readJson(SIGNATURE_FILE);
  if (!cached || !Array.isArray(cached.list) || !cached.at) return [];
  if (Date.now() - Number(cached.at) > SIGNATURE_TTL_MS) return [];
  var out = [];
  for (var i = 0; i < cached.list.length; i++) {
    var row = cached.list[i];
    if (row && row.origin && row.query) out.push({ origin: String(row.origin), query: String(row.query) });
  }
  return out;
}

async function rememberSignature(url) {
  var entry = splitSigned(url);
  if (!entry) return null;
  var known = await readSignatures();
  var merged = [entry];
  for (var i = 0; i < known.length; i++) {
    if (known[i].origin !== entry.origin) merged.push(known[i]);
  }
  await writeJson(SIGNATURE_FILE, { at: Date.now(), list: merged.slice(0, 3) });
  return entry;
}

function freeUrlFrom(rows) {
  if (!rows || !rows.length) return '';
  for (var i = 0; i < rows.length; i++) {
    var row = rows[i];
    if (!row || row.locked) continue;
    if (String(row.access_type || 'free').toLowerCase() !== 'free') continue;
    var url = String(row.video_url || '');
    if (url) return url;
  }
  return '';
}

// 某部剧的免费集地址 → 顺带落成签名（详情接口带客户端头时是 {drama, episodes}，episodes 里免费集就带 video_url）
async function signatureOf(dramaId) {
  var url = '';
  try {
    var payload = await api('/api/v1/dramas/' + dramaId);
    var episodes = payload && Array.isArray(payload.episodes) ? payload.episodes : null;
    url = freeUrlFrom(episodes);
  } catch (error) {
    url = '';
  }
  if (!url) return null;
  return await rememberSignature(url);
}

// 借用别的剧的签名（这部剧一集免费都没有时）：热榜里逐部找有免费集的，最多看 limit 部、
// 凑够 2 个不同 CDN 源就停——站点有两套 CDN，只借一套容易对不上。
async function borrowSignatures(limit) {
  var rows = [];
  try {
    var data = await api('/api/v1/dramas?sort=hot&size=12&page=1');
    rows = data && Array.isArray(data.list) ? data.list : [];
  } catch (error) {
    rows = [];
  }
  var seeds = [];
  var origins = {};
  for (var i = 0; i < rows.length && i < limit; i++) {
    if (seeds.length >= 2) break;
    var dramaId = rows[i] && rows[i].id != null ? String(rows[i].id) : '';
    if (!dramaId) continue;
    var sig = await signatureOf(dramaId);
    if (!sig || origins[sig.origin]) continue;
    origins[sig.origin] = true;
    seeds.push(sig);
  }
  return seeds;
}

async function probePlaylist(url) {
  try {
    var response = await LumeSource.http.get(url, {
      headers: { 'User-Agent': UA, Referer: base() + '/' },
    });
    var status = response ? response.status : 0;
    if (status !== 200) return false;
    var body = response.body ? String(response.body) : '';
    return body.indexOf('#EXTM3U') >= 0;
  } catch (error) {
    return false;
  }
}

// 记住「哪部剧的成功解锁落在哪个 CDN 源」：同一部剧切下一集时就不用再探一次（短剧一集一集连播，这个很关键）
async function readUnlockMap() {
  var cached = await readJson(UNLOCK_FILE);
  if (!cached || !cached.map || !cached.at) return {};
  if (Date.now() - Number(cached.at) > SIGNATURE_TTL_MS) return {};
  return cached.map;
}

async function rememberUnlock(dramaId, origin) {
  var map = await readUnlockMap();
  map[String(dramaId)] = String(origin);
  await writeJson(UNLOCK_FILE, { at: Date.now(), map: map });
}

async function unlockUrl(dramaId, episodeId, number) {
  var id = episodeId || number;
  var path = '/' + dramaId + '/' + id + '/index.m3u8';

  var known = [];
  var okMap = {};
  try {
    known = await readSignatures();
  } catch (error) {
    known = [];
  }
  try {
    okMap = await readUnlockMap();
  } catch (error) {
    okMap = {};
  }

  var index;
  var trusted = okMap[String(dramaId)] || '';
  if (trusted) {
    for (index = 0; index < known.length; index++) {
      if (known[index].origin === trusted) return known[index].origin + path + known[index].query;
    }
  }

  // 1) 缓存里的签名（最便宜，一次探测）
  for (index = 0; index < known.length; index++) {
    var cachedUrl = known[index].origin + path + known[index].query;
    if (await probePlaylist(cachedUrl)) {
      await rememberUnlock(dramaId, known[index].origin);
      return cachedUrl;
    }
  }

  // 2) 本剧自己的免费集签名（同源，几乎必中）
  var own = null;
  try {
    own = await signatureOf(dramaId);
  } catch (error) {
    own = null;
  }
  if (own) {
    var ownUrl = own.origin + path + own.query;
    if (await probePlaylist(ownUrl)) {
      await rememberUnlock(dramaId, own.origin);
      return ownUrl;
    }
  }

  // 3) 全 VIP / 全付费剧：借别的剧的签名（最多 3 部、最多 2 个 CDN 源，控制住单次预算）
  var seeds = [];
  try {
    seeds = await borrowSignatures(3);
  } catch (error) {
    seeds = [];
  }
  for (index = 0; index < seeds.length; index++) {
    var seedUrl = seeds[index].origin + path + seeds[index].query;
    if (await probePlaylist(seedUrl)) {
      await rememberUnlock(dramaId, seeds[index].origin);
      return seedUrl;
    }
  }
  return '';
}

function videoResult(url) {
  return {
    kind: 'video',
    url: url,
    headers: { Referer: base() + '/', 'User-Agent': UA },
  };
}

// -------------------------------------------------------------------- 五个入口

var LumeSource = {
  id: 'zhilian-duanju',
  name: '栀莲短剧',
  version: '1.0.0',
  category: 'video',
  mirrors: ['https://yklyo880.lldj1.xyz'],

  async categories() {
    var cached = await readJson(CATEGORY_FILE);
    if (cached && Array.isArray(cached.list) && cached.list.length && Date.now() - Number(cached.at || 0) < CATEGORY_TTL_MS) {
      return cached.list;
    }
    var list = [
      { id: 'hot', title: '热门推荐' },
      { id: 'new', title: '最新上架' },
      { id: 'likes', title: '最多喜欢' },
    ];
    var home = await api('/api/v1/home');
    var rows = home && Array.isArray(home.categories) ? home.categories : [];
    for (var i = 0; i < rows.length; i++) {
      var row = rows[i];
      if (!row || row.id == null) continue;
      list.push({ id: 'cat:' + row.id, title: String(row.name || '分类' + row.id) });
    }
    await writeJson(CATEGORY_FILE, { at: Date.now(), list: list });
    return list;
  },

  async home() {
    var boards = [];
    var home = await api('/api/v1/home');
    var hotRows = [];
    try {
      var hot = await api('/api/v1/dramas?sort=hot&size=12&page=1');
      hotRows = hot && Array.isArray(hot.list) ? hot.list : [];
    } catch (error) {
      hotRows = [];
    }
    if (hotRows.length) boards.push({ title: '热门推荐', moreUrl: 'hot', items: mapItems(hotRows) });

    var latest = home && Array.isArray(home.latest) ? home.latest : [];
    if (latest.length) boards.push({ title: '最新上架', moreUrl: 'new', items: mapItems(latest) });

    var recommend = home && Array.isArray(home.recommend) ? home.recommend : [];
    if (recommend.length) boards.push({ title: '精选推荐', moreUrl: '', items: mapItems(recommend) });

    return boards;
  },

  async filters() {
    var groups = [
      {
        id: 'sort',
        title: '排序',
        options: [
          { id: 'hot', title: '热门推荐' },
          { id: 'new', title: '最新上架' },
          { id: 'likes', title: '最多喜欢' },
        ],
      },
    ];
    try {
      var home = await api('/api/v1/home');
      var rows = home && Array.isArray(home.categories) ? home.categories : [];
      var options = [];
      for (var i = 0; i < rows.length; i++) {
        if (rows[i] && rows[i].id != null) options.push({ id: String(rows[i].id), title: String(rows[i].name || '') });
      }
      if (options.length) groups.unshift({ id: 'category', title: '分类', options: options });
    } catch (error) {
      return { groups: groups };
    }
    return { groups: groups };
  },

  async list(argument) {
    var args = argument || {};
    var page = Number(args.page || 1);
    if (!page || page < 1) page = 1;
    var size = 20;
    var keyword = String(args.keyword == null ? '' : args.keyword).trim();
    var filters = args.filters || {};

    var sort = 'hot';
    var categoryId = '';
    var category = String(args.categoryId == null ? '' : args.categoryId).trim();
    if (/^cat:/.test(category)) categoryId = category.slice(4);
    else if (category === 'new' || category === 'likes' || category === 'hot') sort = category;

    if (filters.sort) sort = String(filters.sort).trim() || sort;
    if (filters.category) categoryId = String(filters.category).split(',')[0].trim();

    var query = [];
    if (keyword) query.push('keyword=' + encodeURIComponent(keyword));
    if (categoryId) query.push('category_id=' + encodeURIComponent(categoryId));
    query.push('sort=' + encodeURIComponent(sort));
    query.push('size=' + size);
    query.push('page=' + page);

    var data = await api('/api/v1/dramas?' + query.join('&'));
    var rows = data && Array.isArray(data.list) ? data.list : [];
    var total = data && typeof data.total === 'number' ? data.total : 0;
    return {
      items: mapItems(rows),
      hasMore: total > page * size || rows.length >= size,
    };
  },

  async detail(argument) {
    var id = dramaIdOf(argument && argument.id);
    if (!id) return null;
    var payload = null;
    try {
      payload = await api('/api/v1/dramas/' + id);
    } catch (error) {
      return null;
    }
    // 带 X-Client-Platform 时是 {drama, episodes} 包裹；老版本 / 不带客户端头时是平铺对象
    var drama = payload && payload.drama ? payload.drama : payload;
    if (!drama || !drama.title) return null;

    var bits = [];
    if (drama.category) bits.push(String(drama.category));
    if (drama.episode_count) bits.push(Number(drama.episode_count) + '集');
    if (drama.play_count) bits.push(compact(drama.play_count) + '播放');
    if (drama.status) {
      var status = String(drama.status);
      bits.push(status === 'completed' ? '已完结' : status === 'ongoing' ? '更新中' : status);
    }

    var description = String(drama.description == null ? '' : drama.description).trim();
    var tags = Array.isArray(drama.tags) ? drama.tags.join(' ') : String(drama.tags || '');
    if (tags) description += (description ? '\n\n' : '') + '标签：' + tags;

    return {
      id: id,
      title: String(drama.title),
      cover: coverOf(drama),
      subtitle: bits.join(' · '),
      description: description,
    };
  },

  async chapters(argument) {
    var id = dramaIdOf(argument && argument.id);
    if (!id) return [];
    var data = await api('/api/v1/dramas/' + id + '/episodes');
    var rows = data && Array.isArray(data.list) ? data.list : Array.isArray(data) ? data : [];
    var out = [];
    for (var i = 0; i < rows.length; i++) {
      var row = rows[i];
      if (!row) continue;
      var number = Number(row.number || 0);
      if (!number) continue;
      out.push({
        id: String(number) + (row.id == null ? '' : ':' + row.id),
        title: episodeTitle(row),
      });
    }
    return out;
  },

  async content(argument) {
    var args = argument || {};
    var dramaId = dramaIdOf(args.id);
    if (!dramaId) throw new Error('缺少剧集 ID');

    var ref = String(args.chapterId == null ? '' : args.chapterId).trim();
    var matched = /^(\d+)(?::(\d+))?$/.exec(ref) || /^ep:(\d+)(?::(\d+))?$/.exec(ref);
    var number = matched ? Number(matched[1]) : 0;
    var episodeId = matched && matched[2] ? Number(matched[2]) : 0;
    if (!number || number < 1) number = 1;

    var data = await api('/api/v1/dramas/' + dramaId + '/episodes/' + number);
    var episode = data && data.episode ? data.episode : null;
    if (!episode) throw new Error('第' + number + '集取不到（剧集可能已下架）');
    if (!episodeId) episodeId = Number(episode.id || 0);

    var url = String(episode.video_url || '');
    if (url) {
      // 顺手把这份签名存下来：之后同一部剧（以及整条 CDN 上）的锁定集就能直接复用
      try {
        await rememberSignature(url);
      } catch (error) {
        /* 只是缓存，失败不影响播放 */
      }
      return videoResult(url);
    }

    var unlocked = await unlockUrl(dramaId, episodeId, number);
    if (unlocked) return videoResult(unlocked);

    // 解不开（落在 c10.hs100.top 那批「日期+哈希」路径的采集剧上）→ 交给 App 内置网页播放器打开源站自己的播放页，
    // 那里会显示站点真实的会员/付费门槛，比一句死错误有用。
    return {
      kind: 'webplayer',
      pageUrl: base() + '/play/' + dramaId + '/' + number,
      headers: { Referer: base() + '/', 'User-Agent': UA },
    };
  },
};
