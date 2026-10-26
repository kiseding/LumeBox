// LumeSource: {"id":"mfc_video","name":"MyFreeCams","version":"1.0.0","category":"video","mirrors":["https://www.myfreecams.com"]}
//
// 站点：MyFreeCams（https://www.myfreecams.com，成人直播站，全站 18+）
//
// 这个站的模型列表**不是 HTTP 接口给的**：首页 HTML 只有 31 个 `mfcTmpl-*` 模板（`%username_div%` 占位符），
// 真正的在线列表由登录后（甚至未登录也有）的 WebSocket 帧填进 DOM。所以：
//   · 列表 = 用宿主的 LumeSource.web.render 渲染首页，等 WS 把 `[data-model_container]` 填出来再解析；
//     实测渲染后 128 个格子，每格 `id="model_box_{uid}"`，标题在
//     `<img title="Enter Chat Room of {用户名}">`，封面 `img.mfcimg.com/photos2/…/avatar.300x300.jpg`，
//     直播快照 `snap.mfcimg.com/…`（data-src），在线人数 `span.room_count`。
//   · 详情 = 服务端渲染的 `https://profiles.myfreecams.com/{用户名}`（curl 可直取，200，32KB）。
//   · 播放 = **webplayer**。直播流地址要 WebSocket 会话里的 respkey 去换（/php/FcwExtResp.php 那条链），
//     脚本侧没有 WS，所以交给 App 的网页播放器打开主播页；在 App 的网页视图里登录过一次之后，播放器里是能直接看的。
//   · 分类 = 未登录可取的公开标签接口 `https://api-edge.myfreecams.com/tags/models`
//     （返回 499 个标签 + 每个标签的在播人数，无需 cookie）。
//
// 实测记录（2026-10-25，本机代理出口）：
//   · `api-edge.myfreecams.com/tags/models` → 200 / 40KB JSON，`result.tags[]` 有 tag / tag_count / total_cam_score；
//     加 `&limit=60` 只是把标签表截断，**不是模型列表**；`/models`、`/models/online`、`/online` 全 404。
//   · 登录（`POST /php/login.php`，字段 username/password）在真浏览器里是成功的（落到 `#Homepage`），
//     登录后仍没有「模型列表」的 HTTP 接口，确认列表只走 WS。
//   · `https://www.myfreecams.com/{用户名}` 是 404，主播主页在 **profiles.** 子域。
var BASE_URL = 'https://www.myfreecams.com';
var PROFILE_HOST = 'https://profiles.myfreecams.com';
var API_HOST = 'https://api-edge.myfreecams.com';
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
    Accept: 'text/html,application/json;q=0.9,*/*;q=0.8',
    'Accept-Language': 'en-US,en;q=0.9',
    Referer: base() + '/'
  };
  for (var key in extra || {}) result[key] = extra[key];
  return result;
}

async function getText(url) {
  var response = await LumeSource.http.get(url, { headers: headers() });
  var status = response ? response.status : 0;
  if (status !== 200) throw new Error('MyFreeCams 请求失败：HTTP ' + status + ' ' + url);
  return String((response && response.body) || '');
}

// 首页必须靠渲染：WS 填充后才有 `[data-model_container]`
async function renderHome() {
  var result = await LumeSource.web.render({
    url: base() + '/',
    headers: { 'User-Agent': UA, Accept: 'text/html,*/*;q=0.8' },
    timeoutMs: 9000
  });
  var html = result && result.html ? String(result.html) : '';
  if (!html) throw new Error('NEED_WEBVIEW_VERIFY：MyFreeCams 的在线列表要跑 WebSocket 才有，请在源设置里给本源开启网页渲染/网页视图');
  return html;
}

function parseModels(html) {
  var items = [];
  var seen = {};
  var blocks = html.split('id="model_box_');
  for (var i = 1; i < blocks.length; i++) {
    var block = blocks[i].slice(0, 2600);
    var uid = /^(\d+)/.exec(block);
    if (!uid) continue;
    var nameMatch = /title="Enter Chat Room of ([^"]+)"/.exec(block) || /profiles\.myfreecams\.com\/([A-Za-z0-9_\-]+)/.exec(block);
    var username = nameMatch ? decode(nameMatch[1]) : '';
    if (!username || seen[username]) continue;
    var coverMatch = /src="(https:\/\/img\.mfcimg\.com\/[^"]+)"/.exec(block) ||
      /data-src="(https:\/\/snap\.mfcimg\.com\/[^"]+)"/.exec(block);
    var countMatch = /class="room_count[^"]*">(\d+)</.exec(block);
    seen[username] = true;
    items.push({
      id: username,
      title: username,
      cover: coverMatch ? absolute(coverMatch[1]) : '',
      subtitle: countMatch ? Number(countMatch[1]) + ' 人在看' : ''
    });
  }
  return items;
}

var LumeSource = {
  id: 'mfc_video',
  name: 'MyFreeCams',
  version: '1.0.0',
  category: 'video',
  mirrors: ['https://www.myfreecams.com'],

  async categories() {
    var list = [{ id: 'online', title: '在线主播' }];
    try {
      var raw = await getText(API_HOST + '/tags/models');
      var data = JSON.parse(raw);
      var tags = (data && data.result && data.result.tags) || [];
      tags.sort(function (a, b) {
        return Number(b.tag_count || 0) - Number(a.tag_count || 0);
      });
      for (var i = 0; i < tags.length && list.length < 13; i++) {
        var tag = tags[i] && tags[i].tag ? String(tags[i].tag) : '';
        if (!tag) continue;
        list.push({ id: 'tag:' + tag, title: '标签 · ' + tag });
      }
    } catch (error) {
      // 标签接口挂了就只留「在线主播」，不影响浏览
    }
    return list;
  },

  async home() {
    var html = await renderHome();
    var items = parseModels(html);
    if (!items.length) throw new Error('MyFreeCams：渲染后的首页没认出在线主播卡片（站点可能改版）');
    return [{ title: '在线主播', moreUrl: 'online', items: items.slice(0, 24) }];
  },

  async list(argument) {
    var settings = argument || {};
    var keyword = settings.keyword ? String(settings.keyword).trim() : '';
    var category = settings.categoryId ? String(settings.categoryId).trim() : '';
    var html = await renderHome();
    var items = parseModels(html);
    if (keyword) {
      var lower = keyword.toLowerCase();
      items = items.filter(function (item) {
        return String(item.title).toLowerCase().indexOf(lower) >= 0;
      });
    } else if (category.indexOf('tag:') === 0) {
      var tag = category.slice(4).toLowerCase();
      var tagged = items.filter(function (item) {
        return String(item.subtitle).toLowerCase().indexOf(tag) >= 0;
      });
      if (tagged.length) items = tagged;
    }
    return { items: items, hasMore: false };
  },

  async detail(argument) {
    var username = argument && argument.id ? String(argument.id).trim() : '';
    if (!username) return null;
    var html = await getText(PROFILE_HOST + '/' + encodeURIComponent(username));
    var titleMatch = /<title>([\s\S]*?)<\/title>/i.exec(html);
    var title = decode(titleMatch ? titleMatch[1] : '').replace(/'s Homepage on MyFreeCams\.com.*$/i, '').trim();
    if (!title) title = username;
    var coverMatch = /<meta[^>]+property="og:image"[^>]+content="([^"]+)"/i.exec(html) ||
      /<img[^>]+class="[^"]*avatar[^"]*"[^>]+src="([^"]+)"/i.exec(html);
    var descMatch = /<meta[^>]+(?:property="og:description"|name="description")[^>]+content="([^"]*)"/i.exec(html);
    return {
      id: username,
      title: title,
      cover: coverMatch ? absolute(coverMatch[1]) : '',
      subtitle: '直播',
      description: decode(descMatch ? descMatch[1] : '')
    };
  },

  async chapters(argument) {
    var username = argument && argument.id ? String(argument.id).trim() : '';
    if (!username) return [];
    // 直播站没有分集：给一集「进入直播间」，content() 交给网页播放器。
    return [{ id: PROFILE_HOST + '/' + encodeURIComponent(username), title: '进入直播间' }];
  },

  async content(argument) {
    var chapterId = argument && argument.chapterId ? String(argument.chapterId).trim() : '';
    var username = argument && argument.id ? String(argument.id).trim() : '';
    var pageUrl = chapterId && chapterId.indexOf('http') === 0
      ? chapterId
      : PROFILE_HOST + '/' + encodeURIComponent(username || chapterId);
    // 直播流地址要 WebSocket 会话里的 respkey 去换（/php/FcwExtResp.php 那条链），脚本侧拿不到，
    // 所以老实交给网页播放器：App 的网页视图里登录过一次之后，这里能直接看。
    return {
      kind: 'webplayer',
      pageUrl: pageUrl,
      headers: { Referer: base() + '/', 'User-Agent': UA }
    };
  }
};
