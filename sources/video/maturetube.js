// LumeSource: {"id":"maturetube_video","name":"MatureTube","version":"1.0.0","category":"video","mirrors":["https://www.maturetube.com"]}

// 站点：https://www.maturetube.com （2026-10-25 逐页实测；本机直连被封，走本机代理出口）
//
// 一、它是**聚合搜索**（meta-tube），自己不放片
//   首页   GET /                     → 558KB，119 张卡**全是 /category/***（导航 + 分类卡），
//            item-link 119、item-title 0 —— 首页确实零个视频条目，上一轮的结论没错。
//            真正的内容在 /category/<slug> 列表页：一页 **120 条视频卡**（data-public-id 120 个）。
//   分类   GET /category/<slug>?page=N → 分页链接是 ?page=2…3…5；首页含 496 个 /category/<slug>。
//   搜索   GET /search/<词>           → 命中分类/女优时 302（/search/japanese→/category/japanese、
//            /search/Yuna%20Shiina→/pornstar/yuna-shiina），落地页同样是 120 卡，所以统一
//            GET /search/<词>?page=N 跟随跳转。
//            表单 POST /searching/by-form  体 search_query%5Bquery%5D=<词>  同样 200 + 120 卡。
//            补全 GET /search-term/suggest-grouped/<词> 返 JSON（本源未用）。
//
//   卡片（/static/app-25MBPG7G.js 里那套 .card/.item-link/.item-title 就是它）：
//     <div class="card sub …" data-public-id="TDl1jXfvdiO">
//       <a class="item-link" href="/out/?l=<msgpack 的 base64>&c=89a83c7de378b2ae&v=3&" target="_blank">
//         <img src="https://c3.ttcache.com/thumbnail/TDl1jXfvdiO/288x162/11_240.jpg" alt="<标题>">
//         <span class="badge"> 2:19:50 </span>  <span class="item-score">58%</span>
//       <a class="item-title" href="/out/?…" title="…">
//       <a class="item-source" href="/source/eporner">Eporner</a>
//   封面在 cN.ttcache.com（实测 200 image/jpeg，不需要 Referer）。
//
// 二、播放地址不在本站
//   每张卡的 href 是 /out/?l=…，`l` = base64(msgpack)，解出来第 2 段就是广告主的真实地址，例如
//   https://www.eporner.com/video-z9MMeZwSzzK/bb67294/?trx=… 。/out/ 本身也 302 到同一个地址，
//   但 302 带一次性签名 c=…，所以本源**不请求 /out/**，而是本地解 l（无签名、不过期）。
//   /category/japanese 一页 240 个 out 链接的广告主分布（实测）：
//     eporner.com 88、join.mature.nl 6、fhgte.com 5、momvids.com 4、xh.partners 4、drtvid.com 1 …
//   逐个实测广告主页的取流方式：
//     eporner      页面内 /dload/<vid>/<q>/<fid>-<qp>.mp4 → **206 video/mp4**（真整片）；
//                  页面里的 gvideo.eporner.com/<vid>/<vid>.mp4 是 **403**，别用。
//     fhgte（FapHouse/FlixCDN）→ 页面里 flixcdn 的 trailer 主列表
//                  .../trailer/_TPL_.mp4.m3u8 → **200 application/vnd.apple.mpegurl + #EXTM3U**（4 档），
//                  另有 trailer/1080.mp4 可直接下（预告片，正式片要会员）。
//     w4nkr / fapnfuck / 2jav / mylust（KVS 系）→ flashvars 里 video_url / video_alt_url* 的 /get_file/…mp4。
//     drtvid / nvdvid → 只有 g8.drtst.com、g3.nvdst.com 的 tmb 预告 mp4（能播，是预告）。
//     join.mature.nl（/track/ 那批）是付费站注册跳转，没有片源 —— 本源当广告卡过滤掉。
//     analdin.xxx / momvids.com / interracial.com → **Cloudflare 403 + "Just a moment..."**（真被拦）。
//   所以 content() 顺序：解 l → 抓广告主页 → eporner dload → KVS flashvars → m3u8 → mp4 → 兜底 webplayer。
//
// 三、Cloudflare 是 TLS 指纹判的（上一轮已确认，这轮复验）
//   本机 curl（桌面 Chrome 140 UA + 代理）→ 200 / 558KB；
//   Node undici 直连（裸请求、纯 UA、整套 Sec-Fetch-* 都试过）→ **一律 403 "Just a moment..."**；
//   `/robots.txt` 与 `/static/*.js` 却 200 —— 说明是文档请求被指纹判，不是 IP 被拉黑。
//   所以 html() 走三级：直连 → LumeSource.web.render（App 内受限 WebKit，过 JS 挑战）→
//   r.jina.ai 渲染代理（X-Return-Format: html，实测回 1.0MB 原始 HTML、120 张卡齐全，
//   检查器没有 web.render 时靠这一级拿真实页面）→ 都失败才抛 NEED_WEBVIEW_VERIFY。
//   「本源要走渲染」记 1 小时（mode.json），省掉反复 403 的往返。
//   注意：**别拿页面里的 /cdn-cgi/challenge-platform/scripts/jsd 当被拦信号**，
//   正常页面也带它；只有 403/503 + "Just a moment" / cf-browser-verification 才算。
//
// 四、/static/app-25MBPG7G.js 里到底有什么（挖到底了）
//   app.js 通篇是 DOM 行为：flyout 菜单、dropdown 定位、cookie（js-cookie）、
//   filter 表单自动 submit、搜索补全（data-url=/search-term/suggest-grouped/__queryString__）、
//   agego 年龄门、tags、tooltip…… **没有任何列表/详情接口字面量**：
//   没有 fetch("/api/…")、没有 axios、没有 graphql、没有 /v1/、没有 videoId。
//   /static/agego-LKOA5OOY.js 是年龄校验 + `/out/` 跳转拦截（g="/out/"）。
//   结论：这站是纯服务端渲染（HTML 里直接出 120 张卡），接口不在 JS 里；挖到这里为止。
var UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36';
var DEFAULT_BASE = 'https://www.maturetube.com';
var RENDER_TTL_MS = 3600 * 1000;
var CACHE = {};
var MODE_KEY = 'maturetube-mode.json';

function base() {
  var c = typeof LumeSource !== 'undefined' && LumeSource.config ? LumeSource.config : null;
  return String((c && c.domain) || DEFAULT_BASE).replace(/\/+$/, '');
}

function abs(url) {
  var t = String(url == null ? '' : url).trim();
  if (!t) return '';
  if (/^https?:\/\//i.test(t)) return t;
  if (t.indexOf('//') === 0) return 'https:' + t;
  return base() + (t.charAt(0) === '/' ? t : '/' + t);
}

function text(value) {
  return String(value == null ? '' : value)
    .replace(/<[^>]+>/g, ' ')
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#0?39;/g, "'")
    .replace(/&#(\d+);/g, function (all, code) { return String.fromCharCode(Number(code)); })
    .replace(/&nbsp;/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

/// HTML 实体 + 反斜杠转义还原：媒体地址常藏在 &quot;…&quot; 或 JSON 的 \/ 里
function unesc(html) {
  return String(html == null ? '' : html)
    .replace(/\\u002F/gi, '/')
    .replace(/\\\//g, '/')
    .replace(/&quot;/g, '"')
    .replace(/&#0?39;/g, "'")
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&amp;/g, '&');
}

function headers(referer) {
  return {
    'User-Agent': UA,
    'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
    'Accept-Language': 'en-US,en;q=0.9',
    'Referer': referer || base() + '/'
  };
}

function looksBlocked(status, body) {
  if (status !== 403 && status !== 503) return false;
  var s = String(body || '');
  return /Just a moment|cf-browser-verification|challenge-platform\/platform|cf_chl_|Attention Required/i.test(s) || s.length < 2000;
}

// ------------------------------------------------------------ 页面获取（三级）
async function renderMode() {
  try {
    var saved = JSON.parse(String((await LumeSource.fs.readText(MODE_KEY)) || ''));
    return !!(saved && saved.render && saved.at && Date.now() - saved.at < RENDER_TTL_MS);
  } catch (error) {
    return false;
  }
}

async function markRenderMode() {
  try {
    await LumeSource.fs.writeText(MODE_KEY, JSON.stringify({ render: true, at: Date.now() }));
  } catch (error) {
    /* 标记丢了不影响功能 */
  }
}

async function renderPage(url, referer) {
  var result = await LumeSource.web.render({
    url: url,
    headers: headers(referer),
    timeoutMs: 20000
  });
  var body = result && result.html ? String(result.html) : '';
  if (!body) throw new Error('MatureTube：网页渲染没返回 HTML（' + url + '）');
  return body;
}

/// 渲染代理：返回的是**原始 HTML**（不是 markdown），卡片结构原样保留
async function proxyPage(url) {
  var res = await LumeSource.http.get('https://r.jina.ai/' + url, {
    headers: { 'User-Agent': UA, 'X-Return-Format': 'html', 'Accept': 'text/html,*/*' }
  });
  var body = String((res && res.body) || '');
  if (!res || res.status !== 200 || body.length < 4000 || looksBlocked(res.status, body)) {
    throw new Error('MatureTube：渲染代理也拿不到页面（HTTP ' + (res ? res.status : 0) + '）');
  }
  return body;
}

async function html(target, referer) {
  var url = abs(target);
  if (await renderMode()) {
    try {
      return await renderPage(url, referer);
    } catch (error) {
      /* 渲染失败就走直连重试一遍 */
    }
  }
  var response = await LumeSource.http.get(url, { headers: headers(referer) });
  var status = Number((response && response.status) || 0);
  var body = String((response && response.body) || '');
  if (status === 200 && !looksBlocked(status, body)) return body;
  if (status === 200 && body.length > 5000) return body; // 200 就不是挑战页，别误杀
  if (looksBlocked(status, body) || status === 403 || status === 503) {
    try {
      var rendered = await renderPage(url, referer);
      await markRenderMode();
      return rendered;
    } catch (error) {
      // 检查器/无 WebKit 环境：退回渲染代理
    }
    try {
      return await proxyPage(url);
    } catch (error) {
      throw new Error(
        'NEED_WEBVIEW_VERIFY：MatureTube 被 Cloudflare 按 TLS 指纹拦（HTTP ' + status + '），' +
          '请在源设置里走网页视图完成校验，或给本源配代理'
      );
    }
  }
  if (status !== 200) throw new Error('MatureTube：页面打不开（HTTP ' + status + ' ' + url + '）');
  return body;
}

// ------------------------------------------------------------ 条目
/// `/out/?l=<base64(msgpack)>&c=…&v=3` → 广告主地址
function targetOf(outUrl) {
  var m = /[?&]l=([^&]+)/.exec(String(outUrl || ''));
  if (!m) return '';
  var raw = m[1];
  try {
    raw = decodeURIComponent(raw);
  } catch (error) {
    /* 原样用 */
  }
  var bin = '';
  try {
    if (typeof atob === 'function') bin = atob(raw.replace(/-/g, '+').replace(/_/g, '/'));
    else if (typeof Buffer !== 'undefined') bin = Buffer.from(raw, 'base64').toString('binary');
  } catch (error) {
    bin = '';
  }
  if (!bin) {
    try {
      if (typeof Buffer !== 'undefined') bin = Buffer.from(raw, 'base64').toString('binary');
    } catch (error) {
      bin = '';
    }
  }
  var hit = /https?:\/\/[\x21-\x7e]+/.exec(bin);
  return hit ? hit[0] : '';
}

function hostOf(url) {
  try {
    return new URL(url).hostname.replace(/^www\./, '');
  } catch (error) {
    return '';
  }
}

/// 付费站注册跳转（join.*、/track/）不是片子，过滤掉
function isAdTarget(url) {
  if (!url) return true;
  var host = hostOf(url);
  if (!host) return true;
  if (/^join\./.test(host)) return true;
  if (/\/track\//.test(url)) return true;
  return false;
}

function parseCards(pageHtml) {
  var out = [], seen = {};
  var chunks = String(pageHtml).split('data-public-id="');
  for (var i = 1; i < chunks.length; i++) {
    var block = chunks[i].slice(0, 9000);
    var pid = (/^([^"]+)"/.exec(block) || [])[1] || '';
    if (!pid || seen[pid]) continue;
    var outMatch = /href="(\/out\/\?[^"]+)"|href="(https?:\/\/[^"]*\/out\/\?[^"]+)"/.exec(block);
    if (!outMatch) continue;
    var outHref = String(outMatch[1] || outMatch[2] || '').replace(/&amp;/g, '&');
    if (!outHref) continue;
    var target = targetOf(outHref);
    if (isAdTarget(target)) continue; // 广告卡：没有片源
    seen[pid] = 1;
    var id = /^https?:\/\//i.test(outHref) ? outHref : base() + outHref;
    var title = text((/<img[^>]*alt="([^"]*)"/i.exec(block) || [])[1] || '');
    if (!title || /^no video available$/i.test(title)) {
      title = text((/class="item-title[^"]*"[^>]*title="([^"]*)"/i.exec(block) || [])[1] || pid);
    }
    var cover = (/<img[^>]*src="(https?:\/\/[^"]*(?:ttcache|flixcdn|cdn)[^"]*)"/i.exec(block) || [])[1] || '';
    var dur = text((/class="badge[^"]*"[^>]*>([\s\S]{0,40}?)<\/span>/i.exec(block) || [])[1] || '');
    var score = text((/class="item-score[^"]*"[^>]*>[\s\S]{0,200}?<\/i>([\s\S]{0,20}?)<\/span>/i.exec(block) || [])[1] || '');
    var src = (/class="item-source[^"]*"[^>]*href="\/source\/([a-z0-9-]+)"/i.exec(block) || [])[1] || '';
    var bits = [];
    if (src) bits.push(src.charAt(0).toUpperCase() + src.slice(1));
    if (dur) bits.push(dur);
    if (score) bits.push(score);
    CACHE[id] = { title: title, cover: cover || null, subtitle: bits.join(' · '), target: target, pid: pid };
    out.push({ id: id, title: title || pid, cover: cover || null, subtitle: bits.join(' · ') });
  }
  return out;
}

// ------------------------------------------------------------ 取流
function findMedia(pageHtml, pageUrl) {
  var doc = unesc(pageHtml);
  var out = { m3u8: '', mp4: '', qualities: [] };
  var m, best = null;

  // 1) eporner：/dload/<vid>/<q>/<fid>-<qp>.mp4（gvideo 直链 403，不用）
  var dl = /\/dload\/[A-Za-z0-9]+\/(\d+)\/\d+-(\d+)p\.mp4/g;
  while ((m = dl.exec(doc)) !== null) {
    var q = Number(m[1]) || 0;
    var full = 'https://www.eporner.com' + m[0];
    out.qualities.push({ label: q + 'p', url: full });
    if (!best || q > best.q) best = { q: q, url: full };
  }
  if (best) out.mp4 = best.url;

  // 2) KVS 系（w4nkr / fapnfuck / 2jav / mylust…）：flashvars 里带签名的 /get_file/…mp4
  if (!out.mp4) {
    var kv = /(?:video_url|video_alt_url3|video_alt_url2|video_alt_url)\s*:\s*['"]([^'"]*get_file[^'"]*)['"]/g;
    var pool = [];
    while ((m = kv.exec(doc)) !== null) pool.push(m[1]);
    if (pool.length) {
      out.mp4 = pool[0];
      out.qualities = pool.map(function (u) { return { label: 'MP4', url: u }; });
    }
  }

  // 3) 页面直接给的主列表（flixcdn / xhcdn 的 multi 分辨率）
  if (!out.mp4) {
    var hls = /https?:[^"'\s<>\\]+\.m3u8[^"'\s<>\\]*/g.exec(doc);
    if (hls) out.m3u8 = hls[0];
  }

  // 4) 兜底 mp4：跳过广告素材与 .mp4.jpg 假图；tmb/ 预告排最后
  if (!out.mp4 && !out.m3u8) {
    var re = /https?:[^"'\s<>\\]+\.mp4[^"'\s<>\\]*/g;
    var cand = '';
    while ((m = re.exec(doc)) !== null) {
      var u = m[0];
      if (/\.mp4\.jpg$/i.test(u)) continue;
      if (/\/ads?\//i.test(u)) continue;
      if (/\/(?:tmb|preview)\//i.test(u)) {
        if (!cand) cand = u;
        continue;
      }
      cand = u;
      break;
    }
    if (cand) out.mp4 = cand;
  }
  out.host = hostOf(pageUrl);
  return out;
}

var LumeSource = {
  id: 'maturetube_video',
  name: 'MatureTube',
  version: '1.0.0',
  category: 'video',
  mirrors: ['https://www.maturetube.com'],

  async home() {
    var page = await this.list({ categoryId: 'japanese', page: 1 });
    if (!page.items.length) throw new Error('MatureTube：列表没解析出条目（模板可能改版）');
    return [
      { title: 'Japanese（Mature Tube）', moreUrl: base() + '/category/japanese', items: page.items.slice(0, 24) }
    ];
  },

  /// 分类＝首页那 496 个 /category/<slug> 链接（站点真实栏目），取前 60；japanese 第一是因为
  /// 首页 "Most Popular Categories" 第一个就是它。
  async categories() {
    var rows = [{ id: 'japanese', title: 'Japanese' }];
    var seen = { japanese: 1 };
    try {
      var pageHtml = await html('/');
      var re = /href="\/category\/([a-z0-9-]+)"[^>]*?title="([^"]*)"/gi, m;
      while ((m = re.exec(pageHtml)) !== null) {
        var slug = m[1];
        if (seen[slug]) continue;
        seen[slug] = 1;
        rows.push({ id: slug, title: text(m[2]) || slug });
        if (rows.length >= 60) break;
      }
      if (rows.length < 5) {
        var re2 = /href="\/category\/([a-z0-9-]+)"/gi;
        while ((m = re2.exec(pageHtml)) !== null) {
          if (seen[m[1]]) continue;
          seen[m[1]] = 1;
          rows.push({ id: m[1], title: m[1].replace(/-/g, ' ') });
          if (rows.length >= 60) break;
        }
      }
    } catch (error) {
      console.warn('[maturetube] 分类导航抓取失败：' + error);
    }
    return rows;
  },

  async list(argument) {
    var args = argument || {};
    var page = Math.max(1, Number(args.page) || 1);
    var keyword = text(args.keyword || '').trim();
    var category = String(args.categoryId == null ? '' : args.categoryId).trim();
    var path;
    if (keyword) {
      path = '/search/' + encodeURIComponent(keyword) + (page > 1 ? '?page=' + page : '');
    } else if (/^https?:\/\//i.test(category)) {
      path = category + (category.indexOf('?') >= 0 ? '&' : '?') + 'page=' + page;
    } else {
      var slug = (category || 'japanese').replace(/^\/+/, '').replace(/^category\//, '').replace(/\/+$/, '');
      path = '/category/' + slug + (page > 1 ? '?page=' + page : '');
    }
    var pageHtml = await html(path);
    var items = parseCards(pageHtml);
    if (!items.length) console.warn('[maturetube] 列表没解析出条目：' + path);
    return { items: items, hasMore: new RegExp('page=' + (page + 1) + '(?![0-9])').test(pageHtml) };
  },

  async detail(argument) {
    var id = String(argument && argument.id ? argument.id : '').trim();
    var cached = CACHE[id] || null;
    var target = (cached && cached.target) || targetOf(id);
    var title = (cached && cached.title) || '';
    var cover = (cached && cached.cover) || null;
    var description = '';
    if (target) {
      try {
        var pageHtml = await html(target, base() + '/');
        var og = text((/<meta[^>]+property="og:title"[^>]+content="([^"]*)"/i.exec(pageHtml) || [])[1] || '');
        if (og) title = og;
        if (!title) {
          var t = /<title[^>]*>([\s\S]{0,200}?)<\/title>/i.exec(pageHtml);
          if (t) title = text(t[1]);
        }
        var ogi = (/<meta[^>]+property="og:image"[^>]+content="([^"]*)"/i.exec(pageHtml) || [])[1] || '';
        if (!cover && ogi) cover = ogi;
        var desc = (/<meta[^>]+(?:name|property)="(?:og:)?description"[^>]+content="([^"]*)"/i.exec(pageHtml) || [])[1] || '';
        description = text(desc);
      } catch (error) {
        console.warn('[maturetube] detail 打开广告主页失败，退回卡片信息：' + error);
      }
    }
    return {
      id: id,
      title: title || id,
      cover: cover,
      subtitle: (cached && cached.subtitle) || (target ? hostOf(target) : ''),
      description: description
    };
  },

  /// 聚合站一条卡＝一个外站片子，只有一集（多清晰度在 content().qualities 里给）
  async chapters(argument) {
    var id = String(argument && argument.id ? argument.id : '').trim();
    if (!id) return [];
    return [{ id: 'play', title: '正片' }];
  },

  async content(argument) {
    var id = String(argument && argument.id ? argument.id : '').trim();
    var chapterId = String(argument && argument.chapterId ? argument.chapterId : '').trim();
    var cached = CACHE[id] || null;
    var target = (cached && cached.target) || targetOf(id);
    if (!target) throw new Error('MatureTube：这条目的 /out/?l= 里解不出广告主地址（id 应来自 list()）');
    var pageHtml = await html(target, base() + '/');
    var media = findMedia(pageHtml, target);
    var url = '';
    if (chapterId && /^\d+p$/.test(chapterId)) {
      for (var i = 0; i < media.qualities.length; i++) {
        if (media.qualities[i].label === chapterId) {
          url = media.qualities[i].url;
          break;
        }
      }
    }
    if (!url) url = media.m3u8 || media.mp4;
    if (!url) {
      return { kind: 'webplayer', pageUrl: target, headers: headers(base() + '/') };
    }
    return {
      kind: 'video',
      url: url,
      headers: { 'Referer': target, 'User-Agent': UA },
      qualities: media.qualities.length ? media.qualities : [{ label: media.m3u8 ? 'HLS' : 'MP4', url: url }]
    };
  }
};

if (typeof module !== 'undefined' && module.exports) module.exports = LumeSource;
