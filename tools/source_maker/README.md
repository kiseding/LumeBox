# LumeBox 制源工坊（Windows）

第一次使用请阅读 [新手使用说明](新手使用说明.md)，其中按按钮解释首次制源、手动验证、各引擎、自动适应、批量、App 导入与常见报错。

输入网址、预览数据、抽样检查，并按当前 LumeBox 的真实导入协议导出。Windows x64 便携 EXE 内含 Python、Tk、QuickJS 和采集依赖，使用者无需另装 Python。浏览器功能使用本机 Edge / WebView2；Selenium 首次运行可能需要联网获取匹配的驱动。

## 使用

1. 双击 `LumeBox-SourceMaker-0.5.exe`，填写网站或公开接口地址，选择目标模块。
2. 点击「开始识别」，检查左侧标题、地址及右侧规则。
3. 点击底部固定的「生成源」得到草稿；弹窗可查看源代码或猫源 ZIP 内容，尚未验证时禁止导出。
4. 点击「验证源」抽查最多 3 条内容的详情、选集及正文；有分类、筛选规则时还检查分类切换和筛选回传。通过后才允许「导出源」。改动规则后需重新生成并验证。

预览中显示的是候选链接，分类导航不等于作品数据。媒体地址提取成功不代表已经实际起播；动态网站、登录验证和加密播放器可能需要站点专用适配。底部生成与导出按钮固定显示，右侧设置可用滚动条查看。

默认源名称使用网站完整 `<title>`，导出文件名也使用该标题。Windows 禁用字符替换为 `_`，过长文件名会截短，源 ID 保持稳定。可在「源名称」中手动改名。

导出的脚本实时请求网站，不依赖 Windows 工具常驻。网页模式导出的是抓取时的 HTML 导航快照，点击链接访问原网站。工程可保存为 JSON，之后继续修改。旧版文字小说工程会明确拒绝，需重新选择有声小说识别。

## 动态网页与手动验证

选择「内置浏览器」「Playwright」「Selenium」或 Scrapling 引擎，点击「连接所选引擎」。HTTP 引擎直接连接；浏览器中可手动登录或完成验证，等作品列表出现后，返回制源工具点击「已验证，继续」。内置浏览器顶部菜单也可以继续采集。Playwright / Selenium 保留窗口；Scrapling 的抓取页会在返回页面数据后关闭，会话模式保留浏览器状态。切换站点请结束旧会话，再连接新网址。

会话只访问当前站点；跨域接口、跨站登录与特殊播放器仍可能需要单独适配。工具不代做验证码。Cookie 值不写入工程或导出源，退出会话后失效。Windows 上的登录不会自动传到手机，App 中需再次验证。动态 JS 使用 App 已有的网页渲染桥，手机上的超时、站点环境和实际播放仍需检查。

## 批量与解析

「批量制源 · Scrapy」每次最多接受 10 个公开列表网址，按当前模块处理。可调并发 1～4、请求间隔 .3～5 秒和失败重试 0～2 次，启用自动限速并遵守 robots；通过抽样检查的才导出。日志显示进度，主界面的「暂停批量」暂停后续处理，正在执行的请求需要等待返回。使用同样的网址、模块和目录重新开始可以续作；已导出的文件只有内容校验一致才会复用。完整结果在「采集诊断.json」，检查点在「制源任务.json」。需要登录或验证的站点返回主界面单独处理。

Scrapling 0.5 的抓取与会话接口已接入：Fetcher、AsyncFetcher、FetcherSession（同步/异步）、StealthyFetcher（同步/异步）、StealthySession、AsyncStealthySession。引擎选择框提供对应的 8 个入口。0.5 不再单列旧教程中的 DynamicFetcher。库负责获取页面，导出仍由 LumeBox 协议模板完成；自动验证码处理未启用。

「Scrapling 改版自动适应」默认开启。验证通过后学习列表、章节和漫画图片区域；以后重新识别同一个入口时，尝试恢复变化后的结构并生成普通 CSS。仍需再次验证，不保证任意改版都能恢复。样本保存在本机 `%LOCALAPPDATA%/LumeBox/SourceMaker/adaptive`，可以点「忘记本站样本」删除。自适应功能用于 Windows 制源阶段，手机上的已导入源不会自动安装 Scrapling 或随之更新。

「浏览器操作 / 接口记录」可设置加载更多按钮、点击次数、滚动次数、等待元素。每页最多点击 3 次、滚动 3 次；默认不执行额外操作。这些操作会保存到工程并写入动态 JS，App 通过已有网页渲染桥执行；手机超时预算较短，复杂长流程仍需专门适配。

Playwright、Selenium 和 Scrapling 浏览器可读取最近最多 20 条同站 JSON 接口响应，每条最多 256KB；不记录请求头，并隐藏常见密码、Cookie、Token、签名字段。记录用于人工辅助适配，不会未经验证自动当作源接口。内置浏览器没有此响应记录能力。

界面的「查看各引擎功能范围」列出已接入能力。当前集成面向制源流程；没有提供全部 SDK API 的图形化编辑器，也没有接入分布式集群、远程爬虫部署或 MCP 服务。

优先识别视频与漫画卡片、章节区和漫画阅读区；支持常见懒加载图片、srcset、真实下一页链接、HTML5 媒体与 JSON-LD 公开媒体。高级 CSS 可调整卡片、标题、封面、章节、图片、下一页。JS 支持标签、类、ID、属性、后代、直接子元素与逗号，不支持完整浏览器 CSS。视频 JS 检查失败后会自动尝试静态 HTML PY，PY 也失败则阻止导出；浏览器模式不会自动降为静态 PY。

## 按目标选择输出

| 目标 | 输出 | App 中的实际协议 / 位置 |
| --- | --- | --- |
| 有声小说 | `.js` | `category=video`、`mediaType=audio`、`kind=audio`；有声小说标签 |
| 漫画 | `.js` | `category=comic`、图片章节、每张图的 `imageHeaders` |
| 图片 | `.js` | 同属 `comic` 存储，详情页直接作为图集；导入后可手动分组为「美图」 |
| 视频 | `.js` | 视频列表、选集、`kind=video` 公开媒体地址 |
| PY | `.py` | App 的视频 Python `Spider` 协议；公开 HTML 或苹果 CMS；漫画 PY 尚需 App 支持 |
| 模块 | `.cjs` | `LumeRuntime: module` 和 `module.exports` 源对象 |
| 猫源 | `.zip` | Node `start()` 服务、`index.config.js`、MD5；猫源订阅页导入本地 ZIP |
| Kazumi | `.json` | `searchList` / `chapterResult` / `baseURL` 规则；Kazumi 入口导入 |
| 网页 | `.html` | HTML 导航快照；视频源选择 → 网页 → 导入 HTML |

以上是内容类型与运行协议的组合，并非九个独立的 `category`。当前 App 没有文字小说正文载荷；本工具不再生成 `category=novel` 或 `kind=text`。

## 调整规则

| 设置 | 用途 | 示例 |
| --- | --- | --- |
| 列表网址 | `{page}` 替换为页数；未配置分页只抓输入页 | `https://example.com/list?page={page}` |
| 搜索网址 | `{keyword}` 替换为编码后的关键词 | `https://example.com/search?q={keyword}&page={page}` |
| 列表链接规则 | 按绝对地址筛选内容链接的 JavaScript 正则 | `/voddetail/` |
| 分类链接规则 | 从入口页实时抓分类链接，选择分类后实际请求对应列表 | `/(category|catalog)/` |
| 章节 / 选集链接规则 | 从详情页筛选章节；没有章节时仅接受已识别到媒体的页面 | `/chapter/\d+` |
| 内容元素 ID | 限定漫画、图片区域，填写 ID 不带 `#` | `content` |
| 编辑 Kazumi XPath | 配置搜索结果与章节链接 XPath | `//a[contains(@href,'/vodplay/')]` |

修改后重新预览并测试。HTML Kazumi 必须配置真实搜索网址；JSON 接口 Kazumi 自动生成 JSONPath 与多线路分隔规则。纯 JavaScript 网站不能仅靠普通 HTTP 自动恢复接口。猫源包内使用 UTF-8 解码；旧编码网页优先使用普通 JS。无法识别或尚未适配的协议会拒绝导出。

JS、CommonJS 和猫源支持识别同站 GET 表单的 `select[name]` 筛选项，并把选项值回传到列表请求。没有识别到的筛选结构会标为「未适配」，不会硬编码年份、地区或忽略传入条件。苹果 CMS 标准接口提供分类，但未必提供额外筛选，工具不会凭空生成。Kazumi JSON 的分类与筛选能力受 App 的 Kazumi 适配器限制，不等同于普通 JS。

校验检查解析和返回数据；封面只检查地址，媒体不实际起播。不能承诺任意网站仅输入网址即可生成完整可用源。人物、作者、栏目等网页不能因为能取到标题就被当作作品；没有选集或公开媒体时会报错并阻止导出。

普通 HTTP 抓取使用系统代理及 TLS 校验，单页上限 6 MB，单请求超时 18 秒。浏览器会话有独立的加载与元素等待超时。专用签名、加密接口或不公开的媒体仍可能需要开发适配。

## 启动和构建

Windows x64 Python 3.14（含 Tk）：

```powershell
python -m pip install -r tools/source_maker/requirements.txt
python tools/source_maker/app.py
powershell -ExecutionPolicy Bypass -File tools/source_maker/build.ps1
```

输出：`build/source-maker/LumeBox-SourceMaker.exe`、使用说明。构建运行工具集成测试；含 Node 的开发环境还会运行 App 自带 `assets/cat/bootstrap.js` 启动猫源并验证接口。

App 协议验收：

```powershell
powershell -ExecutionPolicy Bypass -File tools/source_maker/verify_app.ps1
```

此检查要求本仓库的 Flutter 依赖、已构建 QuickJS DLL，以及已准备的 `.cache/python-source-runtime/packages`。它执行真实 Dart 导入器 / QuickJS / 数据源内容模型测试和 App 自带 CPython 宿主；无原生桥时直接失败。测试 HTTP 为本地快照，不访问真实源站，不能替代 iOS 设备上的网站实播验证。

实现对应源码及验收范围见 [协议核对记录](../../docs/source-maker-contracts.md)。
