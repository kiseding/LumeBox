# LumeBox 视频源：站点转源结果

## 已发布的订阅链接（推送到 LumeBox-Sources 仓库）

| 用途 | 订阅地址 |
|---|---|
| **影视综合 7 源（推荐）** | `https://raw.githubusercontent.com/teng662858/LumeBox-Sources/main/videos-hd` |
| 影视综合 7 源 · 国内网络用（jsDelivr） | `https://cdn.jsdelivr.net/gh/teng662858/LumeBox-Sources@main/videos-hd-cdn` |
| **18+ 成人向（Hentai2W）** | `https://raw.githubusercontent.com/teng662858/LumeBox-Sources/main/videos-18plus` |
| 18+ · jsDelivr 版 | `https://cdn.jsdelivr.net/gh/teng662858/LumeBox-Sources@main/videos-18plus-cdn` |
| 总订阅（漫画 + 全部视频，含以上两份） | `https://raw.githubusercontent.com/teng662858/LumeBox-Sources/main/all` |
| 原有视频订阅（不含新增） | `https://raw.githubusercontent.com/teng662858/LumeBox-Sources/main/videos` |

App → 视频板块 → 源管理 → 订阅 → 填上面的地址 → 同步即可。脚本实体在
`https://github.com/teng662858/LumeBox-Sources/tree/main/video`（中文文件名，可单独下载导入）。

### 「手机上更新了却没有新源」怎么排查

1. **「一键更新全部订阅」不会发现新清单**：它只刷新**已保存**的订阅地址（`SourceSubscriptionSync.sync`
   只遍历本机 `subscriptions.json` 里的记录）。`videos-hd` 是新清单，必须先添加一次：
   视频板块 → 源管理 → **订阅管理** → 底部「添加订阅地址」填 `videos-hd` → 点「添加订阅并导入」。
   之后「一键更新全部订阅」才会带上它。
2. **想一次到位**：设置 → 总订阅导入导出 → 粘贴 `.../all` → 「导入总订阅」（会把 `videos-hd` 一起加进来并立即同步）。
3. **切到「已有订阅」页签不会多出源**：如果当初加的只是老的 `videos`，那份清单里没有这 7 个源
   （新增的 7 个在独立清单里，避免撞单次订阅 20 条的导入上限）。
4. **国内网络打不开 `raw.githubusercontent.com`**（表现为「订阅拉取失败」，容易被当成"没更新"）：
   改用 jsDelivr 镜像清单 `https://cdn.jsdelivr.net/gh/teng662858/LumeBox-Sources@main/videos-hd-cdn`。
   代价是 jsDelivr 对 `@main` 有缓存（最长约 12 小时），脚本改动要立刻生效时仍用 raw 那份。

订阅端到端复验（从线上拉清单 → 下载每个脚本 → 跑五个入口）：

```bash
node tools/check-subscription.mjs          # 需要能访问 raw.githubusercontent.com
node tools/check-subscription.mjs --manifest https://cdn.jsdelivr.net/gh/teng662858/LumeBox-Sources@main/videos-hd-cdn
```

---

本目录是给 **LumeBox 视频板块**用的图源脚本（`// LumeSource: {...}` 单文件形态，导入即用）。
全部**在本地按 App 的桥接语义实跑过**：真实访问源站、真实取列表/详情/选集、真实探播放地址。
仅本地自用研究，不传播、不商用。

```
sources/video/
├── ysxq-boju.js   播剧网（ysxq.cc）      苹果CMS JSON 接口，424 万+ 影片，最稳的一个
├── a123tv.js      A123TV（a123tv.com）   服务端渲染 HTML + 播放页内嵌 m3u8
├── fdzys.js       饭搭子影视（fdzys.com） 定制模板 HTML + player_aaaa，搜索走 suggest 接口
├── flixflop.js    飞流视频（flixflop.com）Next.js flight 数据里直出播放串
├── duanju2.js     短剧网（duanju2.com）   短剧站，player_aaaa + suggest 搜索
├── olehdtv.js     欧乐影院（olehdtv.com） 苹果CMS HTML，**需代理**
├── huavod.js      华视影院（huavod.com）  **需代理**，播放走网页播放器（P2P 频道）
├── yue5xi5.js     快猫（yue5xi5.xyz）     AES-128-CBC 加密接口，游客号过登录，mp4 直链
├── thepornjoy.js  ThePornJoy（thepornjoy.org）KVS tube，详情页内联签名 mp4，直连可用
├── haoqi7.js      好妻网（haoqi7.com）    TanStack SSR，免 token serverFn，整片 m3u8（VIP 只在前端），**需代理**
├── xfdxv.js       41看片（xfdxv….lifestyle）Fernet 配置解出 apiBase，m3u8 直链（543786/542372 的落点）
├── spankbang.js   SpankBang（spankbang.com）**CF JS 挑战**，需网页视图过校验后复用 Cookie
├── hstv.js        HSTV（d1nu1x3tadacmt.cloudfront.net）匿名设备登录拿 JWT；免费篇整片，金币/VIP 篇服务端只发 15 秒
├── jiuxse.js      9sex（9sex.com）        ThinkPHP；info 接口要 Accept-Language+XHR 三件套；**需代理**
├── mwx43zd.js     快猫镜像站（mwx43zd.xyz）AES hex 密文 + md5(升序query+salt)；免费整片，付费/VIP/搜索服务端 401
├── yuese.js       月色视频（ys.ph3ywdns.icu）Flutter Web 的 REST（dart2js 常量）；switch_line 绕游客配额
├── haijiao.js     海角（haijiao.com）     三重 Base64；**播放地址只对登录态下发**，需填账号
├── aido8.js       爱豆（ww15.aido8.icu）  /awsapi 加密 JSON；匿名整片；封面是反转 JPEG（占位图）
├── tangtoutiao.js 汤头条（p1.wgbqoiqv.com）Nuxt 壳 + 独立接口域，AES-256-CFB 签名；付费仅 ~2 分钟试看
├── h4dh3.js       hxc（h4dh3.com）        **VIP 真破解**：getPreUrl 签名只覆盖路径，删 start/end 即整片
├── cf2.js         Butterfly（d1q6v0m0fmxvl0.cloudfront.net）匿名设备登录即整片；interfaceKey 独立
├── cf3.js         Butterfly2（d17rhkrwip15vt.cloudfront.net）同 SDK 另一运营方；API 域与页面域分离
├── hentai2w.js    Hentai2W（hentai2w.com）**18+**，**需代理**，Inertia props + 自动过年龄门
└── zhilian-duanju.js 栀莲短剧（yklyo880.lldj1.xyz）短剧站，SPA + `/api/v1` JSON 接口；游客登录获取当前会话获准播放的地址，锁定集转源站网页
```

---

## 一、怎么导入

**推荐用订阅**（上面那个 `videos-hd` 地址）。也可以手动导入 ——
App → 视频板块 → **源管理** → 导入，三种方式任选：

1. **选文件**：把对应 `.js` 下载/传到手机，导入时选中它；
2. **粘贴**：把 `.js` 全文粘进导入框（脚本自带 `// LumeSource:` 身份头，App 会自动识别）；
3. **订阅链接**：把本目录的文件挂到你自己的静态地址上，用「订阅」方式填 URL（可多个，一行一个）。

> 导入后建议先跑一次「图源管理 → 测试连通性」；它走与浏览完全相同的调用链。

## 二、逐站实测结果（本机复验于 2026-10）

| 源 | 需代理 | 首页 | 分类 | 列表条目 | 搜索 | 详情 | 选集 | 播放 |
|---|---|---|---|---|---|---|---|---|
| 播剧网（ysxq） | 否 | 20 | 9 | 15 | 20 | ok | 28 | **video（m3u8 直链）** |
| A123TV | 否 | 18 | 54 | 36 | 12 | ok | 16 | **video（m3u8 直链）** |
| 饭搭子影视 | 否 | 18 | 6 | 24 | 2 | ok | 18 | **video（m3u8 直链）** |
| 飞流视频 | 否 | 18 | 7 | 48 | 不支持 | ok | 2 | **video（m3u8 直链）** |
| 短剧网 | 否 | 12 | 3 | 24 | 20 | ok | 1 | **video（m3u8 直链）** |
| 欧乐影院 | **是** | 18 | 29 | 60 | 1 | ok | 2 | **video（m3u8 直链）** |
| 华视影院 | **是** | 18 | 5 | 246 | 17 | ok | 2 | webplayer（网页播放器） |
| 快猫（yue5xi5） | 否 | 2 块 | 2 | 20 | 本地过滤（站点无搜索接口） | ok | 1 | **video（mp4 直链）** |
| ThePornJoy | 否 | 3 块 | 42 | 24 | 24 | ok | 1 | **video（mp4 直链，206）** |
| 好妻网 | **是** | 1 块 | 14 | 20 | 16 | ok | 1 | **video（m3u8 整片，46KB）** |
| 41看片 | 否 | 2 块 | 6 | 20 | 20 | ok | 3 | **video（m3u8 直链）** |
| SpankBang | **是** | — | — | — | — | — | — | 403 → 网页视图过校验（解析已按真实 HTML 实测：列表 82 条、播放三码率） |
| HSTV | 否 | 2 块 | 2 | 20 | 20 | ok | 1 | **video（m3u8；免费篇整片，金币篇 15 秒）** |
| 9sex | **是** | — | 29 | — | — | ok | 1 | **video（m3u8）** |
| 快猫镜像站 | 否 | 2 块 | 5 | 20 | 本地过滤 | ok | 1 | **video（m3u8 整片）** |
| 月色视频 | 否 | 2 块 | 76 | 24 | ok | ok | 1 | **video（m3u8 整片，2–3 清晰度）** |
| 海角 | **是** | — | 6 组 | ok | ok | ok | — | 需登录（账号登入）后才有播放地址 |
| 爱豆 | 否 | 4 块 | 9 | ok | ok | ok | 1 | **video（m3u8 整片）** |
| 汤头条 | 否 | 2 块 | 8 | 10 | 20 | ok | 1 | **video（免费整片；付费 2 分钟试看）** |
| hxc | 否 | 2 块 | ok | ok | ok | ok | 1 | **video（m3u8 整片，删 start/end 后）** |
| Butterfly | 否 | 2 块 | ok | ok | ok | ok | 1 | **video（m3u8 整片）** |
| Butterfly2 | 否 | 2 块 | ok | ok | 本地过滤 | ok | 1 | **video（m3u8 整片）** |
| 栀莲短剧 | 否 | 3 块 | 10 | 20 | 20 | ok | 18 | video / webplayer（获准播放的地址直连，锁定集转源站） |
| Hentai2W（18+） | **是** | 4 板块 | 24 | 24 | 24 | ok | 1 | **video（m3u8 直链）** |

「播放」列是**真去请求那个地址**验的：`video` 表示拿到播放地址且 HTTP 200 + `#EXTM3U`（HLS 清单）；
`webplayer` 表示拿不到可直连的 m3u8，交给 App 内置网页播放器去跑源站自己的播放器。

### 复验命令（本机）

```bash
# 一次跑完清单里的全部源（自带分组：该走代理的走代理），输出上面那张表
node tools/check-all-sources.mjs

# 单跑一个源，看五个入口的详细结果 + 每个请求的状态码/耗时
node tools/lume-source-check.mjs sources/video/a123tv.js --keyword 寒战

# 只看某站「App 同款 HTTP 栈」能不能通（直连 vs 走代理）
dart run tools/site_reachability.dart
```

`tools/lume-source-check.mjs` 不是 App 的一部分，是**开发期跑测器**：它在本机复刻
`lib/core/js/source_bridge.dart` 的桥接语义（`LumeSource` 全局对象、脚本赋值被吸收进桥、
`config` 只读快照…），再调 `categories / list / detail / chapters / content`。

## 三、两个站要挂代理（重要的环境事实）

用 **App 同款 Dart HTTP 栈**实测（`dart run tools/site_reachability.dart`）：

| 站点 | Dart 直连 | Dart 经本机代理 |
|---|---|---|
| ysxq / a123tv / fdzys / flixflop / duanju2 / dongpian12 | 200 | 200 |
| **欧乐 olehdtv** | **403（空响应）** | 200 |
| **华视 huavod** | **403（Cloudflare 拦截页）** | 200 |

所以 `olehdtv.js` / `huavod.js` 在国内直连会先被 WAF 拦住，两个办法：

1. **给该源配代理**：源设置 → 网络 → 代理，填你自己的代理地址（例如 `http://192.168.1.10:7890`）；
2. **走网页视图过校验**：脚本在 403 时抛的是 `NEED_WEBVIEW_VERIFY`，App 会给出「网页视图」入口，
   过完人机校验后 Cookie 会存进该源的会话并自动复用。

> 顺带一提：这两个站的拦截是**按客户端指纹**判的——本机用 PowerShell/.NET 直连是 200，
> 用 curl 直连也是 200，但 App 用的 Dart 客户端直连就是 403。所以「我用浏览器能打开」
> 不代表 App 里能打开；要判断 App 行为只能看上面这张 Dart 表。

## 四、懂片帝AI（dongpian12.com）为什么没有源

这个站**不是点播站**，是「AI 找片 + 对话」类应用（React SPA + `/v1/threads` 会话接口 +
邀请/配额/TV cast 一堆登录态接口）。我把它的前端包拆开确认过：

- 没有分类列表 / 搜索 / 详情 这类可脚本化的公开接口（`/v1/` 下全是会话、配额、用户、cast）；
- 播放要 `player-token` + `player-hls-p2p-policy`（P2P 频道 key），要登录态与 AI 线程上下文；
- 页面上也没有可直接播的 m3u8。

硬凑一个只会得到「能导入、点开就报错」的假源，所以**故意不提供**。
想用它就用 App 自带的**网页源**（把 `https://dongpian12.com/` 加成网页源，在内置浏览器里看）。

## 五、各源实现要点（改站点结构时看这里）

| 源 | 数据来源 | 播放地址怎么拿 |
|---|---|---|
| 播剧网 | 苹果CMS `api.php/provide/vod/`（`ac=detail` 带 `vod_play_url`） | `vod_play_url` 里 `$` 后的 m3u8 |
| A123TV | 列表 `/t/{类型}/p{页}.html`、详情 `/v/{slug}.html`、搜索 `/s/{关键词}.html` | 播放页 `div.w4-player[data-src]` |
| 饭搭子 | 列表 `/{分区}/all?page=N`、详情 `/{分区}/{slug}`、搜索 `/index.php/ajax/suggest` | 页面内嵌 `var player_aaaa={…}`（encrypt 0/1/2 都支持） |
| 飞流视频 | 列表 `/explore/{分类}?page=N`、详情 `/streams/{id}/detail` | Next.js flight 数据里 `"url":"第01集$https://…m3u8#…"`，章节 id 直接就是 m3u8 |
| 短剧网 | 列表 `/show/{类型}---{分类}-----{页}---.html`、详情 `/vod/{id}.html`、搜索 suggest | 播放页 `/play/{id}-{线路}-{集数}.html` 里的 `player_aaaa` |
| 欧乐影院 | 列表 `/index.php/vod/show/id/{类型}/page/{页}.html`、搜索 `search.html?wd=` | 播放页 `player_aaaa` |
| 华视影院 | 列表 `/vodtype/{类型}.html`（一次铺完 246 部）、搜索 suggest | 播放页只有 iframe `/Player/ec?episode=…`，直链是 P2P 频道 key（直连 403）→ 返回 webplayer |
| 快猫 | `POST /api/videos/listAll`（最新）/ `listHot`（最热）/ `detail`（详情+播放），全部 AES-128-CBC 加密 + md5 签名，脚本内置纯 JS 实现；**无搜索/分类接口** | `detail` 的 `mv_play_url`（列表里的老 CDN `119.28.204.36` 已死）；`is_play=0` 时按身份池重试并探无水印变体 |
| ThePornJoy | KVS：`/latest-updates/`、`/most-popular/`、`/top-rated/`、`/categories/{slug}/{N}/`、`/search/{词}/`（分页 `?from=24`）、`/videos/{id}/{slug}/` | 详情页内联 `video_url: '…/get_file/…/{id}_720p.mp4/?v-acctoken=…'`，实测 206 + video/mp4；登录只影响收藏/评论，播放免费 |
| 好妻网 | TanStack Start SSR：分类/列表/搜索走**免 token** 的 `POST /_serverFn/{hash}`（body 是 seroval 序列化），`/api/v1` 那层 token 中间件根本不碰 | `/play/{id}` 的 SSR 内联 `initialDetail.m3u8Url` ＝ **整片**（前端播放器才用 `files[0].url` 试看）⇒ VIP 锁只在前端；媒体域每次现取 |
| 41看片 | 首页 `window.CONFIG` 是 Fernet 串 → 解出 apiBase `sm-api.wieuc.com`；`/api/vod/video?page=&per_page=&site_id=6&orderby=`、`/api/vod/tag_group`、`/search/vod/?search=`、`/api/vod/video/{id}` | 详情给 3 条线路，播放 `https://<线路>/videos…/index.m3u8`，实测 200 + `#EXTM3U` |
| SpankBang | 纯 HTTP 全路径/UA/头组合均 403（CF `Just a moment...`，只有 `/robots.txt` 放行；带浏览器导出的 cookie 用 curl 也 403） | 抓取层抛 `NEED_WEBVIEW_VERIFY`；**解析已用真实 HTML 实测**：`data-testid="video-item"` 卡片 + `/{short}/video/{slug}` + `tbi.sb-cd.com` 封面 + `video-item-length`；播放取详情页 `var stream_data.m3u8`（240p/480p/720p，实测 200 + mpegurl）与 `…-720p.mp4`（206） |
| HSTV | Vue3 前端 + `/api/app/*`，响应自定义 AES-256-CBC（interfaceKey 派生）；**`POST /mine/login/h5` 匿名设备登录即得 JWT**（`Authorization: <JWT>`，不加 Bearer） | `POST /video/play` → `playPolicy.result`：`FULL` 整片 m3u8；`PREVIEW` 服务端截断 15 秒（4 段/18.48s + ENDLIST），换 scene/videoType 无效 ⇒ VIP 锁在服务端 |
| 栀莲短剧 | React SPA + `/api/v1`：`/home`（分类+最新+推荐）、`/dramas?sort=&category_id=&keyword=&page=&size=`、`/dramas/{id}`（带客户端头时返回 `{drama, episodes}`）、`/dramas/{id}/episodes/{number}` | **`POST /api/v1/auth/guest` 游客登录**（`requestKey` 必须是 base64url(32 随机字节)，43 字符）；`video_url` 只对带 `Authorization` 的请求下发。没有下发媒体地址时转源站网页显示权限要求，不构造播放路径。 |

三个「苹果CMS」系源都自带纯 JS 版 base64 / 百分号解码（沙箱没有 `atob`/`unescape`），
所以 `encrypt=1/2` 的站点换了编码也不用改脚本。

## 六、已知限制

- **飞流视频没有搜索**：它的搜索是 Next.js Server Action（POST + 加密 action id），没有可脚本化的 GET 路由；分类浏览、详情、播放都正常。`list({keyword})` 返回空列表而不是乱造地址。
- **华视影院是网页播放**：拿不到可直连 m3u8（P2P 频道 key 需要它的 meshplay SDK），所以走 App 的网页播放器；如果 App 的网页播放器对该站不兼容，就只能回到源站网页看。
- **华视影院分类页没有分页**：站方一次铺完 246 部，`hasMore` 恒为 false。
- **站点改版就会失效**：这些源靠 HTML 结构/正则吃饭，源站换模板后需要按新结构改（每站文件头都写了它是怎么解析的）。失效时先在 App 里「测试连通性」，再跑 `tools/lume-source-check.mjs` 看是哪一步断了。
- **成人分区**：A123TV 有「福利」分类（站点自带），这些源不对内容做过滤，请自行按需使用。
- **栀莲短剧使用游客会话**：令牌到期或接口返回 401 时重新登录，已有游客身份按站点分别缓存。仅使用该集接口实际下发的播放地址；锁定集转源站网页显示会员或付费要求。

## 七、免责

这些脚本只是把你本来就能在浏览器里看到的公开页面**换成 App 里的浏览/播放体验**，
不破解任何付费内容、不绕过登录、不下载不存储视频；仅供本地自用研究，请勿传播或商用。
