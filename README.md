# lume_box

A new Flutter project.

## 使用说明

- 新旧播放器切换：设置 → 阅读与播放 → 播放器方案；下次打开视频生效，默认仍保留现有播放器。
- 参考播放器内：播放设置 → 参考播放器使用说明；片头片尾识别页右上角问号也能打开指南。17 个识别开关都有逐项说明。
- [片头片尾识别、手动打点、模型替换与日志](docs/2026-10-19_片头片尾识别接入.md)
- [漫画阅读器的截图对照与操作验收](docs/2026-10-18_漫画阅读器截图对照验收.md)
- [主题色、字体与自适应颜色设置](docs/2026-10-18_个性化设置.md)

参考播放器的视频 AI 采用实验性的 MobileCLIP 零样本分类。准确率、温控和耗电最终以 iPhone 真机为准；评论服务、DLNA 与 AirPlay 路由尚未接入。浏览器 UA、字幕语言自动优选及详情页“只选中不播放”已接到实际行为，仍需真机验收。

视频源支持通用 Python Spider 与单文件 ESM／CommonJS 模块，见 [Python 与模块源接入](docs/2026-10-20_Python与模块源接入.md)。Python 来源代码在 App 进程内执行，请仅导入可信来源；依赖 Android 或特定客户端接口的脚本仍有兼容边界。

## 图源（脚本不随本仓库分发）

内置图源统一放在 **[teng662858/LumeBox-Sources](https://github.com/teng662858/LumeBox-Sources)**，
按板块提供订阅清单，App 里「导入图源 → 订阅地址」粘贴即可：

| 板块 | 订阅地址 |
|------|----------|
| 小说 | `https://raw.githubusercontent.com/teng662858/LumeBox-Sources/main/novel/sources.txt` |
| 漫画 | `https://raw.githubusercontent.com/teng662858/LumeBox-Sources/main/comic/sources.txt` |
| 视频 | `https://raw.githubusercontent.com/teng662858/LumeBox-Sources/main/video/sources.txt` |

本地要跑「真实引擎 + 真实脚本」的原生用例，先拉一份脚本缓存：

```bash
dart run tool/fetch_sources.dart   # → .sources-cache/<section>/（已 gitignore）
```

没拉缓存时那些用例**整组跳过**（不是失败）：它们验的是「脚本对得上站点真实结构」，
不是 App 自身的行为。

## 打包产物（未签名 IPA）

**构建产物统一放 `ipa/`**（目录已忽略，不进版本库）。文件名带**构建号**：

```
ipa/LumeBox-unsigned-1.0.<run_number>.ipa
```

拉最新一次 CI 构建（`gh` 已登录即可）：

```bash
bash tool/fetch_ipa.sh        # 等价于「把最新成功的 IPA 拉到 ipa/」
bash tool/fetch_ipa.sh <run>  # 指定某次 run
```

装到手机后**核对装的是哪一版**：设置 →「关于」会显示
`LumeBox · 版本 1.0.<run_number>（构建 <run_number>）`——与文件名对上才是这一版。
（以前所有包都是 `1.0.0(1)`、文件名也一直相同，装上旧包看不出来，真机踩过一次
「代码改了但界面没变」。）

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.


### 公共弹幕服务

播放器同时保留源弹幕，并支持[弹弹play开放弹幕网络](https://www.dandanplay.com/)及兼容 API。
在播放器“更多 → 弹幕服务地址”中选择 Cynn、Wenjian、官方服务或自定义 HTTPS 部署前缀；支持 [danmu_api](https://github.com/huangxd-/danmu_api) 的搜索与弹幕接口。默认使用用户指定的 Cynn 地址；服务无结果或不稳定时可换服务。匹配不唯一时使用“匹配公共弹幕”选择对应作品和集数。

官方服务须按[官方接入说明](https://doc.dandanplay.com/open/)申请应用凭证。iOS 配置保存在设备钥匙串，签名仅发到官方主机；第三方兼容服务不接收官方凭证。没有对应弹幕的作品不生成模拟弹幕。
