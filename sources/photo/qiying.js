// LumeSource: {"id":"qiying_vault","name":"栖影图库","version":"1.0.1","category":"comic","contentCategory":"adult","mirrors":["https://qiying-media-vault.cfmxy123.workers.dev"]}
// LumeRuntime: javascript
//
// 站点：栖影（https://qiying-media-vault.cfmxy123.workers.dev）—— 纯前端的「吃瓜图库」：
// Cloudflare Worker 上一套静态文件（index.html + app.js + media-data/），**没有任何后端接口**，
// 数据是预生成的 JSON 分片，页面自己拉下来在浏览器里过滤/分页。所以本源也只能照它的算法来。
//
// 数据地图（media-data/v2/，都另有同名 .gz）：
//   · manifest.json            schema=2，给出 catalog 分片表（28 个 × 800 条）、details 桶数（96）、
//                              modes（images/videos 逐媒体清单，本源不用）
//   · catalog/catalog-XXX.json 帖子目录：21707 条，按时间倒序。
//                              记录形如 {p:pid, t:标题, d:简介, r:封面路径, i:图片数, v:视频数,
//                                        k:[分类], g:[标签], a:作者, c:创建时间}
//   · details/details-XXX.json 帖子明细：桶号 = pid % 96（三位补零）。
//                              记录形如 {p:pid, i:[{i,p,w,h,c}], v:[{i,p,w,h,d}]}，**图片在 i[].p**
//
// 媒体：
//   · 图片：路径形如 /upload/upload/2023....jpg、/upload_01/xiao/....jpeg，主域
//     https://imgpublic.ycomesc.live（实测 200 + image/jpeg）；备用 https://pwa.eisees.com。
//     站点自己还有 pic.jjlxoi.cn / pic.uforxk.cn / image.qzycbu.cn / new.qzycbu.cn 四个域，本机实测均不可用，
//     所以本源按「主域 → 备用域」自动探活一次并缓存。
//   · 视频：走 hls.ffxddn.cn / op.vkjyoi.cn 的签名 HLS（auth_key = md5(路径-时间戳-随机-0-密钥)）。
//     **实测两条域现在都拿不到流**（hls.ffxddn.cn 已 NXDOMAIN；op.vkjyoi.cn 经 Cloudflare 返回 530/526，
//     带正确签名直连也 TLS 断连），站点自己的 /api/hls 反代同样 526。所以本源只做图片：
//     视频条目（i=0）不进列表，图文帖在选集标题里标注还有几段视频。
//
// 沙箱约束：没有 DecompressionStream / pako，所以 gzip 一律走宿主原生 `LumeSource.tools.inflate`
// （拿 .gz 只有 1/30 体积，28 个分片一共 ~400KB）；宿主不提供该能力时自动回落明文 .json。
// 站点在 Cloudflare 上，国内要代理才能解析（本机 DNS 被污染成 69.171.247.71 / 127.0.0.1）。

var BASE_URL = 'https://qiying-media-vault.cfmxy123.workers.dev';
var DATA_DIR = 'media-data/v2/';
var IMG_HOSTS = ['https://imgpublic.ycomesc.live', 'https://pwa.eisees.com'];
var PAGE_SIZE = 20;

var INDEX_FILE = 'index.json';
var IMG_HOST_FILE = 'img-host.json';
var INDEX_TTL_MS = 6 * 3600 * 1000;
var IMG_HOST_TTL_MS = 12 * 3600 * 1000;

var gzUnsupported = false;

function base() {
  var domain = LumeSource.config && LumeSource.config.domain ? LumeSource.config.domain : '';
  return (domain || BASE_URL).replace(/\/+$/, '');
}

function dataUrl(relative) {
  return base() + '/' + DATA_DIR + String(relative || '').replace(/^\/+/, '');
}

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

// --------------------------------------------------------------- 网络与解压

function statusError(status) {
  if (status === 403 || status === 503) {
    return new Error('NEED_WEBVIEW_VERIFY：栖影图库被 Cloudflare 挡下（HTTP ' + status + '），请在源设置里走网页视图或配置代理');
  }
  return null;
}

// App 侧：拿 .gz（体积 1/30）后用宿主原生 inflate 解压；宿主没有这个能力就返回空，让调用方回落明文
async function gzText(relative) {
  if (gzUnsupported) return '';
  var tools = LumeSource.tools;
  if (!tools || typeof tools.inflate !== 'function') {
    gzUnsupported = true;
    return '';
  }
  var reply = null;
  try {
    reply = await LumeSource.http.get(dataUrl(relative) + '.gz', {
      binary: true,
      headers: { Accept: 'application/gzip,application/json;q=0.9' },
    });
  } catch (error) {
    reply = null;
  }
  if (!reply || reply.status !== 200) return '';
  var encoded = reply.bodyBase64 ? String(reply.bodyBase64) : '';
  if (!encoded) {
    // 宿主没回 bodyBase64：说明它不支持 binary 透传（或这份 .gz 是空的），以后直接走明文
    gzUnsupported = true;
    return '';
  }
  try {
    var inflated = await tools.inflate(encoded, false);
    var text = await tools.base64Decode(String(inflated || ''));
    return text || '';
  } catch (error) {
    gzUnsupported = true;
    return '';
  }
}

async function getJson(relative) {
  var compressed = await gzText(relative);
  if (compressed) {
    try {
      return JSON.parse(compressed);
    } catch (error) {
      /* 解压出来的不是 JSON 就回落明文 */
    }
  }
  var reply = await LumeSource.http.get(dataUrl(relative), { headers: { Accept: 'application/json' } });
  var status = reply ? reply.status : 0;
  var blocked = statusError(status);
  if (blocked) throw blocked;
  if (status !== 200) throw new Error('数据拉取失败：HTTP ' + status + ' ' + relative);
  var body = reply && reply.body ? String(reply.body) : '';
  if (!body) throw new Error('数据是空的：' + relative);
  return JSON.parse(body);
}

// --------------------------------------------------------------- 图片地址

function pad3(value) {
  var text = String(value);
  while (text.length < 3) text = '0' + text;
  return text;
}

function imageUrl(path, host) {
  var text = String(path == null ? '' : path).trim();
  if (!text) return '';
  // 抓取数据里夹杂过脏串（`/upload_01/upload" alt="xx.jpg`、`/upload/u![Screenshot…`），先按分隔符截断
  text = text.split(/["'\s!\[\]()<>]/)[0];
  if (!text) return '';
  if (/^https?:\/\//i.test(text)) return text;
  if (text.charAt(0) !== '/') text = '/' + text;
  // 站点数据里偶尔把域名混进路径（例如 /new.tuzhoo.cn/upload_01/...），按域名还原
  var hostLike = /^\/([a-z0-9-]+(?:\.[a-z0-9-]+)*\.[a-z]{2,})\//i.exec(text);
  if (hostLike) return 'https://' + text.slice(1);
  return (host || IMG_HOSTS[0]) + text;
}

async function cachedImageHost() {
  var cached = await readJson(IMG_HOST_FILE);
  if (cached && cached.host && cached.at && Date.now() - Number(cached.at) < IMG_HOST_TTL_MS) {
    return String(cached.host);
  }
  return '';
}

async function pickImageHost(samplePath) {
  var cached = await cachedImageHost();
  if (cached) return cached;
  var sample = String(samplePath || '');
  for (var i = 0; i < IMG_HOSTS.length; i++) {
    var host = IMG_HOSTS[i];
    if (!sample) break;
    try {
      var reply = await LumeSource.http.request({
        url: imageUrl(sample, host),
        method: 'HEAD',
        headers: { Accept: 'image/*' },
      });
      if (reply && reply.status === 200) {
        await writeJson(IMG_HOST_FILE, { host: host, at: Date.now() });
        return host;
      }
    } catch (error) {
      /* 换下一个备用域 */
    }
  }
  return cached || IMG_HOSTS[0];
}

// --------------------------------------------------------------- 目录索引

// 紧凑索引：一条 [pid, 标题, 封面, 图片数, 视频数, 分类, 作者, 创建时间, 简介, 标签]
function compactRecord(row) {
  var images = Number(row && row.i) || 0;
  if (images <= 0) return null; // 纯视频帖不进图片源
  return [
    Number(row.p),
    String(row.t || ''),
    String(row.r || ''),
    images,
    Number(row.v) || 0,
    (row.k || []).join('|'),
    String(row.a || ''),
    String(row.c || ''),
    String(row.d || '').slice(0, 180),
    (row.g || []).slice(0, 10).join('|'),
  ];
}

async function buildIndex() {
  var manifest = await getJson('manifest.json');
  var files = manifest && manifest.catalog && manifest.catalog.files ? manifest.catalog.files : [];
  var names = [];
  var i;
  for (i = 0; i < files.length; i++) {
    if (files[i] && files[i].file) names.push(String(files[i].file));
  }
  if (!names.length) throw new Error('目录清单里没有分片（站点数据可能改版了）');

  var list = [];
  // 三片一批：宿主单域名并发上限就是 3，一批一批拿还能把解压后的中间数据及时丢掉
  for (i = 0; i < names.length; i += 3) {
    var batch = names.slice(i, i + 3);
    var parts = await Promise.all(
      batch.map(function (name) {
        return getJson(name);
      })
    );
    for (var b = 0; b < parts.length; b++) {
      var rows = parts[b] || [];
      for (var r = 0; r < rows.length; r++) {
        var record = compactRecord(rows[r]);
        if (record) list.push(record);
      }
    }
    parts = null;
  }

  var buckets = manifest && manifest.details && Number(manifest.details.buckets) ? Number(manifest.details.buckets) : 96;
  var payload = { at: Date.now(), buckets: buckets, total: list.length, list: list };
  await writeJson(INDEX_FILE, payload);
  return payload;
}

async function ensureIndex() {
  var cached = await readJson(INDEX_FILE);
  if (cached && Array.isArray(cached.list) && cached.list.length && cached.at && Date.now() - Number(cached.at) < INDEX_TTL_MS) {
    return cached;
  }
  return await buildIndex();
}

function recordById(index, pid) {
  var rows = index.list || [];
  for (var i = 0; i < rows.length; i++) {
    if (Number(rows[i][0]) === pid) return rows[i];
  }
  return null;
}

function categoriesOf(record) {
  var raw = String((record && record[5]) || '');
  return raw ? raw.split('|') : [];
}

function compact(number) {
  var value = Number(number) || 0;
  if (value >= 10000) return (value / 10000).toFixed(1).replace(/\.0$/, '') + '万';
  return String(value);
}

function mapItem(record, host) {
  if (!record) return null;
  var cats = categoriesOf(record);
  var bits = [];
  if (cats.length) bits.push(cats[0]);
  bits.push(Number(record[3]) + '图');
  var created = String(record[7] || '').slice(0, 10);
  if (created) bits.push(created);
  return {
    id: String(record[0]),
    title: String(record[1] || ('条目 ' + record[0])),
    cover: imageUrl(record[2], host),
    subtitle: bits.join(' · '),
  };
}

// ------------------------------------------------------------------ 入口

var LumeSource = {
  id: 'qiying_vault',
  name: '栖影图库',
  version: '1.0.1',
  category: 'comic',
  contentCategory: 'adult',
  mirrors: ['https://qiying-media-vault.cfmxy123.workers.dev'],

  async categories() {
    var index = await ensureIndex();
    var counts = {};
    var rows = index.list || [];
    for (var i = 0; i < rows.length; i++) {
      var cats = categoriesOf(rows[i]);
      for (var c = 0; c < cats.length; c++) counts[cats[c]] = (counts[cats[c]] || 0) + 1;
    }
    var ordered = [];
    for (var name in counts) ordered.push({ name: name, count: counts[name] });
    ordered.sort(function (a, b) {
      return b.count - a.count;
    });
    var list = [{ id: 'all', title: '全部（' + compact(rows.length) + '）' }];
    for (var k = 0; k < ordered.length; k++) {
      list.push({ id: 'cat:' + ordered[k].name, title: ordered[k].name + '（' + compact(ordered[k].count) + '）' });
    }
    list.push({ id: 'other', title: '未命名' });
    return list;
  },

  async home() {
    var index = await ensureIndex();
    var host = await cachedImageHost();
    var boards = [];
    var latest = [];
    var rows = index.list || [];
    for (var i = 0; i < rows.length && latest.length < 12; i++) latest.push(mapItem(rows[i], host));
    if (latest.length) boards.push({ title: '最新收录', moreUrl: 'all', items: latest });

    var wanted = ['今日吃瓜', '师生专栏', '深夜撸片'];
    for (var w = 0; w < wanted.length; w++) {
      var picks = [];
      for (var j = 0; j < rows.length && picks.length < 12; j++) {
        if (categoriesOf(rows[j]).indexOf(wanted[w]) >= 0) picks.push(mapItem(rows[j], host));
      }
      if (picks.length) boards.push({ title: wanted[w], moreUrl: 'cat:' + wanted[w], items: picks });
    }
    return boards;
  },

  async filters() {
    var index = await ensureIndex();
    var counts = {};
    var rows = index.list || [];
    for (var i = 0; i < rows.length; i++) {
      var cats = categoriesOf(rows[i]);
      for (var c = 0; c < cats.length; c++) counts[cats[c]] = (counts[cats[c]] || 0) + 1;
    }
    var ordered = [];
    for (var name in counts) ordered.push({ name: name, count: counts[name] });
    ordered.sort(function (a, b) {
      return b.count - a.count;
    });
    var options = [{ id: '', title: '全部分类' }];
    for (var k = 0; k < ordered.length; k++) options.push({ id: ordered[k].name, title: ordered[k].name });
    return {
      groups: [
        { id: 'category', title: '分类', options: options },
        {
          id: 'media',
          title: '内容',
          options: [
            { id: '', title: '全部' },
            { id: 'image', title: '仅图片' },
            { id: 'mixed', title: '图片+视频' },
          ],
        },
        {
          id: 'sort',
          title: '排序',
          options: [
            { id: 'new', title: '最新收录' },
            { id: 'images', title: '图片最多' },
          ],
        },
      ],
    };
  },

  async list(argument) {
    var args = argument || {};
    var page = Number(args.page || 1);
    if (!page || page < 1) page = 1;
    var keyword = String(args.keyword == null ? '' : args.keyword).trim().toLowerCase();
    var category = String(args.categoryId == null ? '' : args.categoryId).trim();
    var filters = args.filters || {};
    var media = String(filters.media || '').trim();
    var sort = String(filters.sort || 'new').trim();
    var filterCategory = String(filters.category || '').trim();

    if (/^cat:/.test(category)) filterCategory = category.slice(4);
    var onlyUnnamed = category === 'other';

    var index = await ensureIndex();
    var host = await cachedImageHost();
    var rows = index.list || [];
    var terms = keyword ? keyword.split(/\s+/) : [];
    var picked = [];

    for (var i = 0; i < rows.length; i++) {
      var record = rows[i];
      var cats = categoriesOf(record);
      if (filterCategory && cats.indexOf(filterCategory) < 0) continue;
      if (onlyUnnamed && String(record[1] || '')) continue;
      var videos = Number(record[4]) || 0;
      if (media === 'image' && videos > 0) continue;
      if (media === 'mixed' && videos <= 0) continue;
      if (terms.length) {
        var haystack = (String(record[1] || '') + ' ' + String(record[9] || '') + ' ' + String(record[6] || '') + ' ' + String(record[5] || '')).toLowerCase();
        var hit = true;
        for (var t = 0; t < terms.length; t++) {
          if (haystack.indexOf(terms[t]) < 0) {
            hit = false;
            break;
          }
        }
        if (!hit) continue;
      }
      picked.push(record);
    }

    if (sort === 'images') {
      picked.sort(function (a, b) {
        return (Number(b[3]) || 0) - (Number(a[3]) || 0);
      });
    }

    var start = (page - 1) * PAGE_SIZE;
    var items = [];
    for (var p = start; p < picked.length && items.length < PAGE_SIZE; p++) {
      var mapped = mapItem(picked[p], host);
      if (mapped) items.push(mapped);
    }
    return { items: items, hasMore: start + PAGE_SIZE < picked.length };
  },

  async detail(argument) {
    var pid = Number(argument && argument.id);
    if (!pid) return null;
    var index = await ensureIndex();
    var record = recordById(index, pid);
    if (!record) return null;
    var host = await cachedImageHost();
    var cats = categoriesOf(record);
    var bits = [];
    if (cats.length) bits.push(cats.join(' / '));
    bits.push(Number(record[3]) + ' 张图片');
    if (Number(record[4]) > 0) bits.push(Number(record[4]) + ' 段视频（站点 CDN 已失效）');
    if (record[6]) bits.push(String(record[6]));
    var created = String(record[7] || '').slice(0, 19);
    if (created) bits.push(created);

    var description = String(record[8] || '');
    var tags = String(record[9] || '').replace(/\|/g, ' ');
    if (tags) description += (description ? '\n\n' : '') + '标签：' + tags;
    return {
      id: String(pid),
      title: String(record[1] || ('条目 ' + pid)),
      cover: imageUrl(record[2], host),
      subtitle: bits.join(' · '),
      description: description,
    };
  },

  async chapters(argument) {
    var pid = Number(argument && argument.id);
    if (!pid) return [];
    var index = await ensureIndex();
    var record = recordById(index, pid);
    if (!record) return [];
    var images = Number(record[3]) || 0;
    var videos = Number(record[4]) || 0;
    var title = '全部 ' + images + ' 张图片';
    if (videos > 0) title += '（另有 ' + videos + ' 段视频）';
    return [{ id: 'all', title: title }];
  },

  async content(argument) {
    var args = argument || {};
    var pid = Number(args.id);
    if (!pid) throw new Error('缺少条目 ID');
    var index = await ensureIndex();
    var record = recordById(index, pid);
    if (!record) {
      throw new Error('这个条目只有视频或已被清洗（本源只收图片帖）：站点视频 CDN（hls.ffxddn.cn / op.vkjyoi.cn）目前取不到流');
    }

    var buckets = Number(index.buckets) || 96;
    var bucket = pid % buckets;
    if (bucket < 0) bucket += buckets;
    var rows = await getJson('details/details-' + pad3(bucket) + '.json');
    var detail = null;
    for (var i = 0; i < rows.length; i++) {
      if (Number(rows[i].p) === pid) {
        detail = rows[i];
        break;
      }
    }
    if (!detail) throw new Error('这个条目的明细没有找到（桶 ' + pad3(bucket) + '），可能刚被清洗过');

    var paths = [];
    var images = detail.i || [];
    for (var j = 0; j < images.length; j++) {
      var path = String(images[j] && images[j].p ? images[j].p : '');
      if (path) paths.push(path);
    }
    if (!paths.length) {
      throw new Error('该条目只有视频，没有图片：站点视频 CDN（hls.ffxddn.cn / op.vkjyoi.cn）目前取不到流');
    }

    var host = await pickImageHost(paths[0]);
    var urls = [];
    for (var k = 0; k < paths.length; k++) urls.push(imageUrl(paths[k], host));
    return { kind: 'images', images: urls };
  },
};
