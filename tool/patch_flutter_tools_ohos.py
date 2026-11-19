#!/usr/bin/env python3
"""给鸿蒙 Flutter fork 的 flutter_tools 打补丁，让 native assets 在 ohos 上正常工作。

一共三处
--------

1. `ohos.dart`：把原生资源清单塞进 flutter_assets。
   鸿蒙清单里我们设了 `hooks.user_defines.sqlite3.source: system`，构建期不下载
   二进制，hook 只产出一条映射 `libsqlite3.g.dart -> dlopen("libsqlite3.so")`。
   这条映射必须落在 `<flutter_assets>/NativeAssetsManifest.json`，Dart VM 才知道
   第一次 `sqlite3.open()` 该 dlopen 哪个库。android.dart / common.dart / ios.dart
   都会写，唯独 ohos.dart 漏了。缺这步的典型报错是
   `Failed to lookup symbol ... libsqlite3.so`。

2. `ohos.dart`：`OhosAssetBundle` 改用带架构的 TargetPlatform。
   flutter-hvigor-plugin 调 `flutter assemble` 时固定传 `-dTargetPlatform=ohos`
   （**不带架构**），真实架构放在 `-dOhosArchs`。build hooks 拿不到架构信息时
   native assets 的 key 会退化成 `ohos_arm64`，于是 x86_64 设备上
   `dlopen('libsqlite3.so')` 查不到 manifest 条目，第一次建库就抛
   `No available native assets`。

3. `native_assets.dart`：`InstallCodeAssets` 的 ohos 分支同样换成带架构的。
   否则「生成」阶段产出的是 `ohos_x64`，但「安装」阶段按无架构的 ohos 去找，
   仍然选不到条目。

补丁全部幂等，可重复执行；已经打过会跳过。

用法
----
    python tool/patch_flutter_tools_ohos.py /path/to/flutter_ohos

CI 在 clone 完 fork 之后、初始化工具链之前调用；本地改 SDK 时手动跑一次即可。
"""

from __future__ import annotations

import sys
from pathlib import Path

OHOS_DART = "packages/flutter_tools/lib/src/build_system/targets/ohos.dart"
NATIVE_ASSETS = "packages/flutter_tools/lib/src/build_system/targets/native_assets.dart"

# ---------------------------------------------------------------- 补丁 1

IMPORT_ANCHOR = "import '../../build_info.dart';\n"
IMPORT_LINE = "import '../../devfs.dart';\n"

CALL_OLD = """      targetPlatform: TargetPlatform.ohos,
      buildMode: buildMode,
      flavor: environment.defines[kFlavor],
    );
"""

CALL_NEW = """      targetPlatform: TargetPlatform.ohos,
      buildMode: buildMode,
      flavor: environment.defines[kFlavor],
      // 与 android.dart / common.dart 对齐：把 build hooks 产出的原生资源映射
      // 一起塞进 flutter_assets。缺这一步，Dart VM 拿不到
      // 「assetId -> libsqlite3.so」的对照表，第一次调 sqlite3 就会抛
      // Failed to lookup symbol。
      additionalContent: <String, DevFSContent>{
        'NativeAssetsManifest.json': DevFSFileContent(
          environment.buildDir.childFile('native_assets.json'),
        ),
      },
    );
"""

# ---------------------------------------------------------------- 补丁 2

# 打补丁 1 之后，CALL_OLD 已经被替换成 CALL_NEW，所以补丁 2 的锚点要用
# 「补丁 1 的产物」里那一行 targetPlatform。
BUNDLE_TARGET_OLD = """      targetPlatform: TargetPlatform.ohos,
      buildMode: buildMode,
      flavor: environment.defines[kFlavor],
      // 与 android.dart / common.dart 对齐：把 build hooks 产出的原生资源映射
"""

BUNDLE_TARGET_NEW = """      // 用真实架构而不是裸 TargetPlatform.ohos：后者会让 build hooks 拿到
      // 一个没有架构信息的 target，native assets 的 key 退化成 ohos_arm64，
      // 于是 x86_64 设备上 dlopen('libsqlite3.so') 查不到 manifest 条目，
      // 第一次 sqlite3.open() 就抛 "No available native assets"。
      targetPlatform: _ohosTargetPlatformFromDefines(environment),
      buildMode: buildMode,
      flavor: environment.defines[kFlavor],
      // 与 android.dart / common.dart 对齐：把 build hooks 产出的原生资源映射
"""

OHOS_HELPERS = """
/// 从 `-dOhosArchs` 解析出带架构的 [TargetPlatform]。
///
/// flutter-hvigor-plugin 调 `flutter assemble` 时固定传 `-dTargetPlatform=ohos`
/// （不带架构），真实架构放在 `-dOhosArchs`（可空格分隔多架构）。build hooks
/// 需要一个带架构的 target 才能生成正确的 native assets key（`ohos_x64` /
/// `ohos_arm64`），所以这里优先按 `-dOhosArchs` 回填，拿不到时再退回
/// `-dTargetPlatform`，两者都没有就保持原样。
TargetPlatform _ohosTargetPlatformFromDefines(Environment environment) {
  final String? archs = environment.defines[kOhosArchs];
  if (archs != null) {
    for (final String raw in archs.split(' ')) {
      final TargetPlatform? platform = _ohosPlatformFromToken(raw.trim());
      if (platform != null) {
        return platform;
      }
    }
  }
  final String? platformName = environment.defines[kTargetPlatform];
  if (platformName != null) {
    final TargetPlatform? platform = _ohosPlatformFromToken(platformName);
    if (platform != null) {
      return platform;
    }
  }
  return TargetPlatform.ohos;
}

/// 把 `-dOhosArchs` / `-dTargetPlatform` 里的一个 token 转成带架构的
/// [TargetPlatform]。
///
/// 两处传值形式不一样，这里都要吃：
///   * flutter-hvigor-plugin 的 `-dOhosArchs` 传的是**平台名**（`ohos-x64`，
///     见 hvigor 里的 PLATFORM_X86_64 常量）；
///   * 手动调 `flutter assemble` 时习惯写**arch 名**（`x86_64`）。
/// 认不出来返回 null，由调用方继续试下一个。
TargetPlatform? _ohosPlatformFromToken(String token) {
  // 已经是 `ohos-x64` / `ohos-arm64` / `ohos-arm` 就直接用。
  if (token == 'ohos-x64' || token == 'ohos-arm64' || token == 'ohos-arm') {
    return getTargetPlatformForName(token);
  }
  // 裸平台名 `ohos`（无架构）认不出来，交给兜底逻辑。
  switch (token) {
    case 'x86_64':
    case 'x64':
      return TargetPlatform.ohos_x64;
    case 'arm64-v8a':
    case 'arm64':
      return TargetPlatform.ohos_arm64;
    case 'armeabi-v7a':
    case 'arm':
      return TargetPlatform.ohos_arm;
    default:
      return null;
  }
}
"""

# ---------------------------------------------------------------- 补丁 3

INSTALL_CODE_ASSETS_OLD = """    } else if (osName == 'ohos') {
      final Uri configTargetUri = projectUri.resolve(
        '${getBuildDirectory()}/native_assets/ohos/',
      );
      await installCodeAssets(
        dartHookResult: dartHookResult,
        environmentDefines: environment.defines,
        targetPlatform: targetPlatform,
"""

INSTALL_CODE_ASSETS_NEW = """    } else if (osName == 'ohos') {
      final Uri configTargetUri = projectUri.resolve(
        '${getBuildDirectory()}/native_assets/ohos/',
      );
      // hvigor 传的是不带架构的 `-dTargetPlatform=ohos`，这里换成带架构的，
      // 否则安装阶段选不到 hooks 为 `ohos_x64` 生成的条目。
      final TargetPlatform archPlatform = _ohosArchTargetPlatform(environment) ?? targetPlatform;
      await installCodeAssets(
        dartHookResult: dartHookResult,
        environmentDefines: environment.defines,
        targetPlatform: archPlatform,
"""

NATIVE_ASSETS_HELPERS = """
/// 从 `-dOhosArchs` 解析带架构的 OHOS [TargetPlatform]；解析不到返回 null。
///
/// flutter-hvigor-plugin 固定传 `-dTargetPlatform=ohos`（无架构），真实架构在
/// `-dOhosArchs`（可空格分隔多个）。native assets 的 key 依赖架构，缺了会退化
/// 成 `ohos_arm64`，在 x86_64 设备上就找不到 `libsqlite3.so` 的条目。
TargetPlatform? _ohosArchTargetPlatform(Environment environment) {
  final String? archs = environment.defines[kOhosArchs];
  if (archs == null) {
    return null;
  }
  for (final String raw in archs.split(' ')) {
    // flutter-hvigor-plugin 传的是平台名 `ohos-x64`（见 hvigor 里的
    // PLATFORM_X86_64 常量），手动调 assemble 时习惯写 arch 名 `x86_64`，
    // 两种形式都要认。
    switch (raw.trim()) {
      case 'ohos-x64':
      case 'x86_64':
      case 'x64':
        return TargetPlatform.ohos_x64;
      case 'ohos-arm64':
      case 'arm64-v8a':
      case 'arm64':
        return TargetPlatform.ohos_arm64;
      case 'ohos-arm':
      case 'armeabi-v7a':
      case 'arm':
        return TargetPlatform.ohos_arm;
    }
  }
  return null;
}
"""


def _patch_ohos_dart(sdk: Path) -> int:
    target = sdk / OHOS_DART
    if not target.is_file():
        print(f"::error::找不到 {target}，flutter_ohos 目录不对？")
        return 1

    text = target.read_text(encoding="utf-8")
    changed = False

    # --- 补丁 1：把 NativeAssetsManifest.json 写进 flutter_assets
    if "'NativeAssetsManifest.json'" in text:
        print(f"{OHOS_DART}: 补丁 1（manifest）已存在，跳过")
    else:
        if IMPORT_LINE not in text:
            if IMPORT_ANCHOR not in text:
                print("::error::ohos.dart 结构与预期不符，找不到 import 锚点")
                return 1
            text = text.replace(IMPORT_ANCHOR, IMPORT_ANCHOR + IMPORT_LINE, 1)

        if CALL_OLD not in text:
            print("::error::ohos.dart 结构与预期不符，找不到 copyAssets 调用")
            return 1
        text = text.replace(CALL_OLD, CALL_NEW, 1)
        changed = True
        print(f"{OHOS_DART}: 已补上补丁 1（NativeAssetsManifest.json）")

    # --- 补丁 2：OhosAssetBundle 改用带架构的 TargetPlatform
    if "_ohosTargetPlatformFromDefines" in text:
        print(f"{OHOS_DART}: 补丁 2（带架构 target）已存在，跳过")
    else:
        if BUNDLE_TARGET_OLD not in text:
            print("::error::ohos.dart 结构与预期不符，找不到 OhosAssetBundle 的 targetPlatform")
            return 1
        text = text.replace(BUNDLE_TARGET_OLD, BUNDLE_TARGET_NEW, 1)
        text = text.rstrip("\n") + "\n" + OHOS_HELPERS
        changed = True
        print(f"{OHOS_DART}: 已补上补丁 2（带架构的 TargetPlatform）")

    if changed:
        target.write_text(text, encoding="utf-8")
    return 0


def _patch_native_assets(sdk: Path) -> int:
    target = sdk / NATIVE_ASSETS
    if not target.is_file():
        print(f"::error::找不到 {target}，flutter_ohos 目录不对？")
        return 1

    text = target.read_text(encoding="utf-8")

    if "_ohosArchTargetPlatform" in text:
        print(f"{NATIVE_ASSETS}: 补丁 3（安装阶段 arch）已存在，跳过")
        return 0

    if INSTALL_CODE_ASSETS_OLD not in text:
        print("::error::native_assets.dart 结构与预期不符，找不到 ohos 安装分支")
        return 1

    text = text.replace(INSTALL_CODE_ASSETS_OLD, INSTALL_CODE_ASSETS_NEW, 1)
    text = text.rstrip("\n") + "\n" + NATIVE_ASSETS_HELPERS
    target.write_text(text, encoding="utf-8")
    print(f"{NATIVE_ASSETS}: 已补上补丁 3（安装阶段按架构选条目）")
    return 0


def main(argv: list[str]) -> int:
    # Windows runner 上 stdout 是 cp1252，直接 print 中文会 UnicodeEncodeError
    # 把脚本打成 exit 1（补丁其实已经写进去了）。强制 UTF-8。
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8", errors="replace")

    if len(argv) != 2:
        print("用法: python tool/patch_flutter_tools_ohos.py <flutter_ohos 根目录>")
        return 2

    sdk = Path(argv[1]).resolve()
    if _patch_ohos_dart(sdk) != 0:
        return 1
    if _patch_native_assets(sdk) != 0:
        return 1

    # 改了源码但没改 git revision 时，flutter 不会重建工具快照，
    # 删掉 stamp 让它下次调用时重新编译，否则补丁不生效。
    stamp = sdk / "bin" / "cache" / "flutter_tools.stamp"
    snapshot = sdk / "bin" / "cache" / "flutter_tools.snapshot"
    for path in (stamp, snapshot):
        if path.exists():
            path.unlink()
            print(f"已删除 {path.relative_to(sdk)}（触发工具快照重建）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))