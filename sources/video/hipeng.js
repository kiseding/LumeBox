// LumeSource: {"id":"hipeng_video","name":"嗨碰","version":"1.0.0","category":"video","mirrors":["https://60lkly.scenicembrace.com"]}
//
// 站点：嗨碰（"向在炮火连天第一线战斗的原创者致敬!"，成人短视频站，全站 18+）
// 来历：`https://xinhuanews.dyhs.us/` 发布页里的跳板域 `60lkly.scenicembrace.com` **本身就是内容站**
//   （同一批跳板里 `*.thaispa-amazing.com` 才 302 到云老婆）。
//
// 结构（2026-10-25 实测，**服务端渲染**，不用渲染/不用解接口）：
//   · 首页/推荐   GET /            GET /recommend?page=N     24 条/页
//   · 热榜        GET /hot?page=N
//   · 分类        GET /tag/{slug}?page=N    （如 /tag/guochan 国产、/tag/%E9%98%BF%E5%A7%A8 阿姨）
//   · 卡片        <article class="hiporn-list-card"><a href="/video/{id}-{slug}" class="hiporn-video-card …">
//                   <div class="…thumb"><img src="/dist/notfound.jpg" data-original="{封面}">
//                   <span class="hiporn-video-card-duration">3:58</span></div>
//                   <h3 class="hiporn-video-card-title">标题</h3></a>
//                 注意 `src` 是站点的 notfound.jpg，**只认 data-original**。
//   · 详情        GET /video/{id}-{slug}     标题 h1、封面 data-original、时长为卡片上那个
//   · 播放        <video> 里没有 src，真正的播放在页面里的 m3u8：
//                   https://customer-hpnet.hlsdelivery.net/hls/mp4/{hash}.mp4/index.m3u8?sign=…&t=…
//                 签名带过期时间（`t=…`），所以每次播放都现取详情页。
//   · 搜索        站点搜索是前端交互（`/search?q=` 只回空壳），本源不做假搜索：
//                 `list({keyword})` 会在「推荐」页里本地过滤标题。
var BASE_URL = 'https://60lkly.scenicembrace.com';
var UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36';

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

function headers(extra) {
  var result = {
    'User-Agent': UA,
    Accept: 'text/html,*/*;q=0.8',
    'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
    Referer: base() + '/'
  };
  for (var key in extra || {}) result[key] = extra[key];
  return result;
}

async function getText(target) {
  var url = /^https?:\/\//i.test(target) ? target : base() + (String(target).charAt(0) === '/' ? target : '/' + target);
  var response = await LumeSource.http.get(url, { headers: headers() });
  var status = response ? response.status : 0;
  if (status !== 200) throw new Error('嗨碰：请求失败 HTTP ' + status + ' ' + url);
  return String((response && response.body) || '');
}

// 卡片：<a href="/video/{id}-{slug}" class="hiporn-video-card …"> … data-original="封面" … <h3 class="…-title">标题</h3></a>
// 注意 href 在 class **之前**，所以不能用「按 class 切块」再找 href，改成整段匹配。
function parseItems(html) {
  var items = [];
  var seen = {};
  var pattern = /href="([^"]*\/video\/[^"]+)"[^>]*class="hiporn-video-card[^"]*"([\s\S]{0,1500}?)<\/a>/g;
  var matched;
  while ((matched = pattern.exec(html)) !== null) {
    var href = matched[1];
    if (seen[href]) continue;
    var block = matched[2];
    var titleMatch = /class="hiporn-video-card-title"[^>]*>([\s\S]{0,200}?)<\/h3>/.exec(block) ||
      /alt="([^"]*)"/.exec(block);
    var title = decode(titleMatch ? titleMatch[1] : '');
    if (!title) continue;
    var coverMatch = /data-original="([^"]+)"/.exec(block);
    var durMatch = /class="hiporn-video-card-duration"[^>]*>([^<]{0,10})</.exec(block);
    seen[href] = true;
    items.push({
      id: absolute(href),
      title: title,
      cover: coverMatch ? absolute(coverMatch[1]) : '',
      subtitle: durMatch ? decode(durMatch[1]) : ''
    });
  }
  return items;
}
var CATEGORIES = [
  { id: 'recommend', title: '为您推荐', path: '/recommend' },
  { id: 'hot', title: '热榜', path: '/hot' },
  { id: 'guochan', title: '国产', path: '/tag/guochan' },
  { id: 'home', title: '首页', path: '/' }
];

function pageUrl(category, pageNo) {
  var spec = null;
  for (var i = 0; i < CATEGORIES.length; i++) if (CATEGORIES[i].id === category) spec = CATEGORIES[i];
  var path = spec ? spec.path : '/recommend';
  if (pageNo > 1) path = path + (path.indexOf('?') >= 0 ? '&' : '?') + 'page=' + pageNo;
  return path;
}

var LumeSource = {
  id: 'hipeng_video',
  name: '嗨碰',
  version: '1.0.0',
  category: 'video',
  mirrors: ['https://60lkly.scenicembrace.com'],

  async categories() {
    var list = [];
    for (var i = 0; i < CATEGORIES.length; i++) list.push({ id: CATEGORIES[i].id, title: CATEGORIES[i].title });
    return list;
  },

  async home() {
    var html = await getText('/recommend');
    var items = parseItems(html);
    if (!items.length) throw new Error('嗨碰：首页没认出卡片（站点可能改版或换了跳板域）');
    return [{ title: '为您推荐', moreUrl: 'recommend', items: items.slice(0, 24) }];
  },

  async list(argument) {
    var settings = argument || {};
    var pageNo = Number(settings.page || 1);
    if (!pageNo || pageNo < 1) pageNo = 1;
    var category = settings.categoryId ? String(settings.categoryId).trim() : 'recommend';
    var keyword = settings.keyword ? String(settings.keyword).trim().toLowerCase() : '';
    var html = await getText(pageUrl(category, pageNo));
    var items = parseItems(html);
    if (keyword) {
      items = items.filter(function (item) {
        return String(item.title).toLowerCase().indexOf(keyword) >= 0;
      });
    }
    return { items: items, hasMore: items.length >= 20 };
  },

  async detail(argument) {
    var id = argument && argument.id ? String(argument.id) : '';
    if (!id) return null;
    var html = await getText(id);
    var titleMatch = /<h1[^>]*>([\s\S]{0,200}?)<\/h1>/.exec(html) || /<title>([\s\S]*?)<\/title>/.exec(html);
    var title = decode(titleMatch ? titleMatch[1] : '').replace(/\s*-\s*嗨碰\s*$/, '').trim();
    if (!title) return null;
    var coverMatch = /data-original="([^"]+)"/.exec(html) || /<meta[^>]+property="og:image"[^>]+content="([^"]+)"/.exec(html);
    var descMatch = /<meta[^>]+name="description"[^>]+content="([^"]*)"/.exec(html);
    var durMatch = /class="hiporn-video-card-duration"[^>]*>([^<]{0,10})</.exec(html);
    return {
      id: absolute(id),
      title: title,
      cover: coverMatch ? absolute(coverMatch[1]) : '',
      subtitle: durMatch ? decode(durMatch[1]) : '视频',
      description: decode(descMatch ? descMatch[1] : '')
    };
  },

  async chapters(argument) {
    var id = argument && argument.id ? String(argument.id) : '';
    if (!id) return [];
    return [{ id: absolute(id), title: '正片' }];
  },

  async content(argument) {
    var chapterId = argument && argument.chapterId ? String(argument.chapterId).trim() : '';
    var id = argument && argument.id ? String(argument.id).trim() : '';
    var target = chapterId || id;
    if (!target) throw new Error('嗨碰：缺少视频地址');
    var html = await getText(target);
    var media = /(https?:\/\/[^"'\s<>]+\.m3u8[^"'\s<>]*)/i.exec(html);
    if (media) {
      return {
        kind: 'video',
        url: media[1].replace(/&amp;/g, '&'),
        headers: { Referer: absolute(target), 'User-Agent': UA, Accept: '*/*' }
      };
    }
    var mp4 = /(https?:\/\/[^"'\s<>]+\.mp4[^"'\s<>]*)/i.exec(html);
    if (mp4) {
      return {
        kind: 'video',
        url: mp4[1].replace(/&amp;/g, '&'),
        headers: { Referer: absolute(target), 'User-Agent': UA, Accept: '*/*' }
      };
    }
    return { kind: 'webplayer', pageUrl: absolute(target), headers: headers() };
  }
};
