// LumeSource: {"id":"tmrj37_video","name":"37tmrj","version":"1.0.0","category":"video","group":"影视","mirrors":["https://www.37tmrj.com","https://www.24nbfp.com"]}
// 发布页：www.24nbfp.com/index.htm → 直接 302 到 37tmrj，可当镜像切换
//
// 站点：37tmrj（https://www.37tmrj.com，成人影视/小说/图片综合站，全站 18+）
//
// 为什么这个源必须走「网页渲染」而不是直连接口：
//   · 它是 Vite SPA（`/assets/index-*.js` + `/static/runtime-config.js`，`apiBase:''` 即同源 `/api`）；
//   · 页面数据接口是 `/api/movie/home_sections`、`/api/movie/tags`、`/api/config/ini?project=xs`，
//     返回的是**加密信封**：`{"enc":3,"alg":"XOR2","n":"<nonce>","d":"<base64url 密文>"}`；
//   · 解密封装在打包文件里（FNV-1a 派生种子 + xorshift32 生成 4 字节字 keystream 的流式 XOR，
//     见 index-*.js 里 `enc===3` 那条分支）。我按反编译出来的流程试了「种子=nonce|d」「d|nonce」
//     「密文字节串|nonce」多种组合都没还原出明文 JSON —— 缺的正是那段压缩过的确切取值，
//     所以本源不硬猜算法，改用 App 自己的 WebKit 渲染页面（页面里已经是解密后的数据）。
//   · 渲染后的首页实测 386KB DOM，卡片结构：
//       <a class="movie-card movie-card-ad" href="站外广告">…</a>   ← 广告，跳过
//       <div class="movie-card" role="link" data-cover-id="261772">
//         <div class="thumbnail-wrapper"><img src="data:image/jpeg;base64,…（模糊占位）"></div>
//         <p class="movie-title">标题</p><span class="movie-duration">…</span>
//     真实封面走懒加载（占位图是 base64 模糊图），所以 cover 取 `data-src` / `srcset` / 背景图里
//     第一个 http(s) 地址，取不到就留空（宁缺不错）。
//   · 详情/播放页路由：`/pages/movie/detail?id={data-cover-id}`。渲染后若 DOM 里出现 m3u8 就交原生播放，
//     否则退回网页播放器（这个站的播放器还要鉴权/广告，直链不保证）。
var BASE_URL = 'https://www.37tmrj.com';
var UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36';
var LIST_ROUTE = '/pages/home/index';

function base() {
  var domain = LumeSource.config && LumeSource.config.domain ? LumeSource.config.domain : '';
  return (domain || BASE_URL).replace(/\/+$/, '');
}

function decode(text) {
  return String(text == null ? '' : text)
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#0?39;/g, "'")
    .replace(/&nbsp;/g, ' ')
    .replace(/<[^>]+>/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

async function render(target) {
  if (!LumeSource.web || typeof LumeSource.web.render !== 'function') {
    throw new Error('NEED_WEBVIEW_VERIFY：37tmrj 是加密接口的 SPA，必须用 App 的网页渲染/网页视图打开');
  }
  var result = await LumeSource.web.render({
    url: /^https?:\/\//i.test(target) ? target : base() + target,
    headers: { 'User-Agent': UA, Accept: 'text/html,*/*;q=0.8' },
    timeoutMs: 9000
  });
  var html = result && result.html ? String(result.html) : '';
  if (!html) throw new Error('NEED_WEBVIEW_VERIFY：37tmrj 渲染没有返回内容，请在源设置里走网页视图');
  return html;
}

// 卡片：`<div class="movie-card" … data-cover-id="{id}">…<p class="movie-title">标题</p>`
function parseCards(html) {
  var items = [];
  var seen = {};
  var blocks = html.split('class="movie-card');
  for (var i = 1; i < blocks.length; i++) {
    var block = blocks[i].slice(0, 2200);
    if (/^[\s]*movie-card-ad/.test(block)) continue; // 站外广告卡
    var idMatch = /data-cover-id="(\d+)"/.exec(block);
    if (!idMatch) continue;
    var titleMatch = /class="movie-title"[^>]*>([\s\S]{0,160}?)</.exec(block);
    var title = decode(titleMatch ? titleMatch[1] : '');
    if (!title) continue;
    var coverMatch = /(?:data-src|data-original)="(https?:\/\/[^"]+)"/.exec(block) ||
      /srcset="([^",\s]+)/.exec(block) ||
      /url\((https?:\/\/[^)]+)\)/.exec(block);
    var durMatch = /class="movie-duration"[^>]*>([^<]{0,20})</.exec(block);
    var dateMatch = /class="movie-update-date"[^>]*>([^<]{0,20})</.exec(block);
    var id = idMatch[1];
    if (seen[id]) continue;
    var parts = [];
    if (durMatch) parts.push(decode(durMatch[1]));
    if (dateMatch) parts.push(decode(dateMatch[1]));
    seen[id] = true;
    items.push({
      id: id,
      title: title,
      cover: coverMatch ? coverMatch[1] : '',
      subtitle: parts.join(' · ')
    });
  }
  return items;
}

var LumeSource = {
  id: 'tmrj37_video',
  name: '37tmrj',
  version: '1.0.0',
  category: 'video',
  mirrors: ['https://www.37tmrj.com'],

  async categories() {
    // 分类是「标签」形态（/api/movie/tags 加密返回），这里只给一个入口，避免造假分类。
    return [{ id: 'home', title: '首页推荐' }];
  },

  async home() {
    var html = await render(LIST_ROUTE);
    var items = parseCards(html);
    if (!items.length) throw new Error('37tmrj：渲染后的首页没认出卡片（站点可能改版）');
    return [{ title: '最新推荐', moreUrl: 'home', items: items.slice(0, 24) }];
  },

  async list(argument) {
    var settings = argument || {};
    var html = await render(LIST_ROUTE);
    var items = parseCards(html);
    var keyword = settings.keyword ? String(settings.keyword).trim().toLowerCase() : '';
    if (keyword) {
      items = items.filter(function (item) {
        return String(item.title).toLowerCase().indexOf(keyword) >= 0;
      });
    }
    return { items: items, hasMore: false };
  },

  async detail(argument) {
    var id = argument && argument.id ? String(argument.id).replace(/[^\d]/g, '') : '';
    if (!id) return null;
    var html = await render('/pages/movie/detail?id=' + id);
    var titleMatch = /<h1[^>]*>([\s\S]{0,200}?)<\/h1>/.exec(html) ||
      /class="[^"]*title[^"]*"[^>]*>([\s\S]{0,160}?)</.exec(html);
    var title = decode(titleMatch ? titleMatch[1] : '');
    if (!title) title = '作品 ' + id;
    var coverMatch = /<meta[^>]+property="og:image"[^>]+content="([^"]+)"/.exec(html) ||
      /(?:data-src|data-original)="(https?:\/\/[^"]+)"/.exec(html);
    var descMatch = /<meta[^>]+name="description"[^>]+content="([^"]*)"/.exec(html);
    return {
      id: id,
      title: title,
      cover: coverMatch ? coverMatch[1] : '',
      subtitle: '影视',
      description: decode(descMatch ? descMatch[1] : '')
    };
  },

  async chapters(argument) {
    var id = argument && argument.id ? String(argument.id).replace(/[^\d]/g, '') : '';
    if (!id) return [];
    return [{ id: id, title: '正片' }];
  },

  async content(argument) {
    var id = argument && argument.chapterId ? String(argument.chapterId).replace(/[^\d]/g, '') : '';
    if (!id) id = argument && argument.id ? String(argument.id).replace(/[^\d]/g, '') : '';
    if (!id) throw new Error('37tmrj：缺少作品 id');
    var pageUrl = base() + '/pages/movie/detail?id=' + id;
    var html = await render('/pages/movie/detail?id=' + id);
    var media = /(https?:\/\/[^"'\s<>]+\.(?:m3u8|mp4)[^"'\s<>]*)/i.exec(html);
    if (media) {
      return {
        kind: 'video',
        url: media[1].replace(/&amp;/g, '&'),
        headers: { Referer: base() + '/', 'User-Agent': UA, Accept: '*/*' }
      };
    }
    // 播放器要鉴权/广告时不硬凑，交给网页播放器。
    return { kind: 'webplayer', pageUrl: pageUrl, headers: { Referer: base() + '/', 'User-Agent': UA } };
  }
};
