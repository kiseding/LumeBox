# 内置本机弹幕服务

当前上游：huangxd-/danmu_api 1.21.9。源码提交和产物摘要见 manifest.json；AGPL-3.0 许可见 LICENSE。

功能：搜索、服务端自动匹配、平台链接取弹幕、分片、持久化收藏、本机 AI 和远程标题／季集映射配置。与 Cloudflare 共用 App 客户端；本机服务无需服务器地址。AI 需自行配置模型及密钥。

随包存放的是 `upstream.cjs.gz`（3.1 MB → 0.8 MB，gzip -9，mtime 置 0 保证可复现）。安装时解压成 `upstream.cjs` 再写入沙盒，解压后的字节与原文件完全一致，所以 `manifest.json` 里的 `patchedSha256` 和安装期校验都不变。

重建适配文件：在仓库根目录执行 `python tool/prepare_builtin_danmaku.py 原始danmu_api_server.cjs文件路径`。脚本验证原始 SHA-256，逐条应用 manifest 中的补丁并验证最终哈希。原始文件来自上游 release `latest/danmu_api_server.cjs`，后续 release 变化不会被静默接受。上游源码的开发与打包方法见其仓库；本仓库公开手机适配后的完整产物和全部修改。

组件与猫源共用 Node，使用随机回环令牌与限定接口。原生网络桥接保持独立；环境配置不写入进程全局。数据、收藏与设置留在稳定数据目录，组件更新不会更换数据目录。

构建：`node tool/build_builtin_danmaku.mjs <upstream-checkout>`。依赖由该 checkout 的 package.json 安装，构建输入应先通过上游测试。

App 首次启动使用打包组件，后台每六小时检查 teng662858/LumeBox-Danmaku 的 mobile 目录。下载固定提交下的 manifest、RSA/SHA-256 签名及两个组件文件；仅接受 App 内固定公钥验签成功、文件摘要匹配的组件，下次服务启动启用。坏包不激活，启动失败回退打包版并拒绝同一坏版本。

App 仅含公钥。签名私钥留在本机，未上传 GitHub；未配置签名发布凭据时，Cloudflare 仍自动同步，新的手机组件不会自动发布。手机会自动获取已经签名发布的版本。

未完成 iPhone 真机验收。桌面 Node 测试覆盖网络桥接、请求鉴权、管理接口隔离、停止重启及猫源共存；Flutter 测试覆盖签名、损坏包拒绝和安装。
