#!/usr/bin/env python3
"""给鸿蒙 Flutter fork 的 flutter_tools 打一个补丁：把原生资源清单塞进 flutter_assets。

背景
----
`package:sqlite3` 3.x 起改用 Dart 的 native assets（build hooks）来提供 SQLite。
鸿蒙清单里我们设了 `hooks.user_defines.sqlite3.source: system`，于是构建期不会下载
任何二进制，hook 只产出一条映射：

    package:sqlite3/src/ffi/libsqlite3.g.dart -> ["system", "libsqlite3.so"]

这条映射必须落在 `<flutter_assets>/NativeAssetsManifest.json`，Dart VM 启动后才知道
第一次 `sqlite3.open()` 该 dlopen 哪个库。android.dart / common.dart / ios.dart 都会
把它写进 assets，唯独 ohos.dart 漏了（fork 的问题，不是我们的配置问题）。缺这一步
的典型报错是 `Failed to lookup symbol ... libsqlite3.so`。

补丁只做两件事：补一行 import，给 copyAssets 传 additionalContent。幂等，可重复执行。

用法
----
    python tool/patch_flutter_tools_ohos.py /path/to/flutter_ohos

CI 在 clone 完 fork 之后、初始化工具链之前调用；本地改 SDK 时手动跑一次即可。
"""

from __future__ import annotations

import sys
from pathlib import Path

TARGET = "packages/flutter_tools/lib/src/build_system/targets/ohos.dart"

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
      // 一起写进 flutter_assets，否则 Dart VM 拿不到 libsqlite3.so 的对照表。
      additionalContent: <String, DevFSContent>{
        'NativeAssetsManifest.json': DevFSFileContent(
          environment.buildDir.childFile('native_assets.json'),
        ),
      },
    );
"""


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
    target = sdk / TARGET
    if not target.is_file():
        print(f"::error::找不到 {target}，flutter_ohos 目录不对？")
        return 1

    text = target.read_text(encoding="utf-8")

    if "'NativeAssetsManifest.json'" in text:
        print(f"{TARGET}: 已有 NativeAssetsManifest.json，跳过")
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
        target.write_text(text, encoding="utf-8")
        print(f"{TARGET}: 已补上 NativeAssetsManifest.json")

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
