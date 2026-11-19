#!/usr/bin/env bash
# 交叉编译 quickjs_engine 原生桥到 OpenHarmony（x86_64 与 arm64-v8a）。
#
# 产物：libquickjs_c_bridge_plugin.so
#   - 与 Android/macOS/Linux 侧同名，Dart 侧 Qjs._candidates() 只需加一个 ohos 分支
#   - 放进 ohos/entry/libs/<abi>/，由 HAP 打包进 libs/<abi>/
#
# 用法： ./tool/build_quickjs_ohos.sh [x86_64|arm64-v8a|all] [输出根目录]
#   输出根目录默认 $ROOT/ohos/entry/libs；未生成 ohos 工程时可显式给一个临时目录。
#
# 依赖：DEVECO_SDK_HOME（默认取 DevEco Studio 的 sdk 目录）里的 native/llvm 与 native/sysroot。
set -euo pipefail

ABI="${1:-all}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="$ROOT/third_party/quickjs_engine/native/cxx"
OUT_BASE="${2:-$ROOT/ohos/entry/libs}"

DEVECO_SDK_HOME="${DEVECO_SDK_HOME:-C:/Program Files/Huawei/DevEco Studio/sdk}"
NATIVE="$DEVECO_SDK_HOME/default/openharmony/native"
CLANG="$NATIVE/llvm/bin/clang.exe"
CLANGXX="$NATIVE/llvm/bin/clang++.exe"
SYSROOT="$NATIVE/sysroot"

for f in "$CLANG" "$CLANGXX" "$SYSROOT"; do
  [ -e "$f" ] || { echo "缺少：$f"; exit 1; }
done

# 目标三连 -> 输出目录名。鸿蒙 HAP 的 libs 目录名与 Android 一致（arm64-v8a）。
target_of() {
  case "$1" in
    x86_64)    echo "x86_64-linux-ohos|$OUT_BASE/x86_64" ;;
    arm64-v8a) echo "aarch64-linux-ohos|$OUT_BASE/arm64-v8a" ;;
    *) echo "未知 ABI: $1" >&2; return 1 ;;
  esac
}

# 包装脚本 x86_64-unknown-linux-ohos-clang 用 $SOURCE 拼路径，
# DevEco 默认装在 "Program Files" 下会因空格崩掉；这里直接调底层 clang 并手写参数。
CFLAGS=(
  -std=c11
  -O2
  -fPIC
  -fvisibility=hidden
  -D__MUSL__
  -D_GNU_SOURCE
  -D_DEFAULT_SOURCE
  -DCONFIG_VERSION="\"ng-0.14.0\""
  -Wno-unused-function
  -Wno-unused-variable
  -Wno-unused-parameter
  -Wno-unused-but-set-variable
  -Wno-implicit-function-declaration
  -Wno-int-conversion
)

CXXFLAGS=(
  -std=c++17
  -O2
  -fPIC
  -fvisibility=hidden
  -fvisibility-inlines-hidden
  -D__MUSL__
  -D_GNU_SOURCE
  -D_DEFAULT_SOURCE
  -DCONFIG_VERSION="\"ng-0.14.0\""
  -Wno-unused-function
  -Wno-unused-variable
  -Wno-unused-parameter
  -Wno-unused-but-set-variable
)

# quickjs 本体 4 个 C 文件 + 桥接 1 个 C++
C_SOURCES=(quickjs/quickjs.c quickjs/libregexp.c quickjs/libunicode.c quickjs/dtoa.c)
CXX_SOURCES=(libfastdev_quickjs_runtime.cpp)

build_abi() {
  local abi="$1"
  local spec target outdir
  spec="$(target_of "$abi")"
  target="${spec%%|*}"
  outdir="${spec#*|}"

  local objdir="$ROOT/build/quickjs_ohos/$abi"
  rm -rf "$objdir"
  mkdir -p "$objdir" "$outdir"

  echo "=== [$abi] target=$target ==="

  local objs=()
  for src in "${C_SOURCES[@]}"; do
    local base obj
    base="$(basename "$src" .c)"
    obj="$objdir/$base.o"
    echo "  cc  $src"
    "$CLANG" --target="$target" --sysroot="$SYSROOT" \
      "${CFLAGS[@]}" -I"$SRC_DIR" -I"$SRC_DIR/quickjs" \
      -c "$SRC_DIR/$src" -o "$obj"
    objs+=("$obj")
  done

  local cxxobj="$objdir/bridge.o"
  echo "  cxx ${CXX_SOURCES[0]}"
  "$CLANGXX" --target="$target" --sysroot="$SYSROOT" \
    "${CXXFLAGS[@]}" -I"$SRC_DIR" -I"$SRC_DIR/quickjs" \
    -c "$SRC_DIR/${CXX_SOURCES[0]}" -o "$cxxobj"
  objs+=("$cxxobj")

  # 与 CMakeLists 的 UNIX 分支对齐：链接 libm。
  # C++ 运行库静态链入（-static-libstdc++），避免产物依赖设备侧的 libc++_shared.so
  # ——鸿蒙应用沙箱里不保证有该文件，缺了会在 dlopen 时报 "cannot locate symbol"。
  echo "  link libquickjs_c_bridge_plugin.so"
  # libunwind.a：静态 libc++ 会留下 __register_frame_info / __deregister_frame_info /
  # __at_fini 三个 WEAK UND（运行时找不到会静默解析为 0，不影响加载，但会让
  # libgcc 的 unwind 表注册退化）。静态链入后这些引用就地解析，产物对外只剩 libc。
  local unwind="$NATIVE/llvm/lib/$target/libunwind.a"
  local extra=()
  [ -f "$unwind" ] && extra+=("$unwind")
  "$CLANGXX" --target="$target" --sysroot="$SYSROOT" \
    -shared -static-libstdc++ -o "$outdir/libquickjs_c_bridge_plugin.so" \
    "${objs[@]}" "${extra[@]}" -lm \
    -Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384

  # 去符号表（保留动态符号），体积从数十 MB 降到 MB 级
  local strip="$NATIVE/llvm/bin/llvm-strip.exe"
  if [ -x "$strip" ]; then
    "$strip" --strip-unneeded "$outdir/libquickjs_c_bridge_plugin.so" || true
  fi

  echo "  -> $outdir/libquickjs_c_bridge_plugin.so ($(du -h "$outdir/libquickjs_c_bridge_plugin.so" | cut -f1))"
}

case "$ABI" in
  all) build_abi x86_64; build_abi arm64-v8a ;;
  x86_64|arm64-v8a) build_abi "$ABI" ;;
  *) echo "用法: $0 [x86_64|arm64-v8a|all]"; exit 1 ;;
esac

echo
echo "=== 产物 ==="
for d in "$OUT_BASE"/*/; do
  [ -f "$d/libquickjs_c_bridge_plugin.so" ] && ls -la "$d/libquickjs_c_bridge_plugin.so"
done
