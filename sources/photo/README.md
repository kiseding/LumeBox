# LumeBox 美图源（漫画板块 → 「美图」分组）

本目录放**图片类**图源脚本（`category: "comic"`，内容形态是 `{kind:'images'}`）。
放到 `photo/` 下是因为 App 的源选择器按路径把源归到「美图」分组（`SourcePickerGroups.groupFor`）；
分组只是展示归类，不改变归属板块。

```
sources/photo/
└── qiying.js   栖影图库（qiying-media-vault.cfmxy123.workers.dev）吃瓜图集站；
                Cloudflare Worker 纯静态数据（media-data/v2 的 JSON 分片），**需代理**，全站 18+
```

## 栖影图库（`qiying_vault`）

| 项 | 值 |
|---|---|
| 站点 | `https://qiying-media-vault.cfmxy123.workers.dev/`（Cloudflare Worker 静态站，`app.js` 里没有任何后端接口） |
| 数据 | `media-data/v2/manifest.json` → `catalog/catalog-NNN.json`（28 片 × 800 条）+ `details/details-NNN.json`（桶号 = `pid % 96`） |
| 规模 | 21707 条帖子 / 50459 张图片 / 10031 段视频；带图片的 18825 条进本源 |
| 图片域 | 主 `imgpublic.ycomesc.live`，备 `pwa.eisees.com`（脚本 HEAD 探活一次并缓存） |
| 视频 | **不可用**：`hls.ffxddn.cn` 已 NXDOMAIN，`op.vkjyoi.cn` 经 Cloudflare 530 / 直连 TLS 断连，站点自己的 `/api/hls` 反代 526 |
| 代理 | **需要**：`*.workers.dev` 国内被 DNS 污染（本机解析到 69.171.247.71），真值 172.67.217.239 / 104.21.70.20 |
| 分级 | 18+（`SourceContentRating` 里登记了 `qiying_vault` / 「栖影图库」） |

### 实现要点

- **索引**：28 个目录分片压成紧凑数组（`[pid, 标题, 封面, 图片数, 视频数, 分类, 作者, 创建时间, 简介, 标签]`），
  落 `LumeSource.fs` 的 `index.json`（约 2.6 MB / 18825 条），有效期 6 小时；三片一批拉取（贴住宿主单域名并发上限 3）。
- **gzip**：沙箱没有 `DecompressionStream`/`pako`，`.gz` 走宿主原生 `LumeSource.tools.inflate`
  （28 片共 ~400 KB，明文要 13 MB）；宿主不支持时自动置位 `gzUnsupported` 并回落明文，
  所以 Node 侧的 `tools/lume-source-check.mjs` 走的是明文回落路径。
- **分类**：站点没有分类接口，19 个分类由索引里的 `k` 字段统计得出（今日吃瓜、师生专栏、深夜撸片…），
  另加「全部」「未命名」。
- **搜索**：本地多词 AND，匹配标题 / 标签 / 作者 / 分类。
- **脏数据**：抓取来的路径里混过 `"/upload_01/upload\" alt=\"xx.jpg"`、`"/upload/u![Screenshot…"`，
  `imageUrl()` 先按分隔符截断；混进路径的域名（`/new.tuzhoo.cn/...`）会还原成 `https://`。

### 复验

```bash
set HTTPS_PROXY=http://127.0.0.1:7890
set NODE_USE_ENV_PROXY=1
node tools/lume-source-check.mjs sources/photo/qiying.js --page 3 --keyword 偷拍
```

全绿：`home` 4 块、`categories` 21 项、`filters` 3 组、`list` 20 条、搜索 20 条、
`chapters` 1 条、`content` 19 张图、首图 `200 + image/jpeg`。
