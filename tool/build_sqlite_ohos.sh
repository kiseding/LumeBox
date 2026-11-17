#!/usr/bin/env bash
# 重新生成鸿蒙用的 libsqlite3.so（ohos/entry/libs/<abi>/libsqlite3.so）。
#
# 为什么需要它
# ------------
# `package:sqlite3` 3.x 走 native assets，鸿蒙不在它的平台表里；我们在
# pubspec_ohos.yaml 里把 hooks 设成 `source: system`，于是运行期只是
# dlopen("libsqlite3.so")。系统里没有这个库（OpenHarmony 不对外暴露 sqlite），
# 所以由我们自己从 amalgamation 编一份塞进 HAP。
#
# 版本：OpenHarmony third_party_sqlite 的 amalgamation（3.44.4）。
# 换版本时改 SQLITE_REPO_REF 即可，编完记得重新构建 HAP 并装机验证。
#
# 用法：
#   OHOS_NATIVE=/c/fo/command-line-tools/sdk/default/openharmony/native \
#     tool/build_sqlite_ohos.sh
# 产物直接写进 ohos/entry/libs/{x86_64,arm64-v8a}/libsqlite3.so，可以入库。

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NATIVE="${OHOS_NATIVE:-/c/fo/command-line-tools/sdk/default/openharmony/native}"
WORK="${WORK:-$ROOT/build/sqlite-ohos}"
API_BASE="https://api.atomgit.com/api/v5/repos/openharmony/third_party_sqlite/contents"

SQLITE_VERSION_EXPECTED="3.44.4"

if [ ! -d "$NATIVE/llvm/bin" ]; then
  echo "找不到鸿蒙原生工具链: $NATIVE（用 OHOS_NATIVE 指定）" >&2
  exit 1
fi

# 这些开关跟着 LumeBox 现有查询走：FTS5 给全文检索，RTREE 给空间索引，
# MATH_FUNCTIONS 是 3.35 之后的默认扩展但在 amalgamation 里要显式打开。
CFLAGS=(
  --sysroot="$NATIVE/sysroot"
  -shared -fPIC -O2 -fno-strict-aliasing
  -DSQLITE_ENABLE_FTS5
  -DSQLITE_ENABLE_FTS3
  -DSQLITE_ENABLE_FTS4
  -DSQLITE_ENABLE_RTREE
  -DSQLITE_ENABLE_COLUMN_METADATA
  -DSQLITE_ENABLE_MATH_FUNCTIONS
  -DSQLITE_THREADSAFE=1
  -DSQLITE_MAX_VARIABLE_NUMBER=250000
  -DSQLITE_DEFAULT_SYNCHRONOUS=1
  -DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1
  -Wl,-soname,libsqlite3.so
)

download() {
  local repo_path="$1" out="$2"
  python - "$API_BASE/$repo_path" "$out" << 'PY'
import base64, json, os, subprocess, sys

url, out = sys.argv[1], sys.argv[2]
env = {k: v for k, v in os.environ.items()
       if k.lower() not in ("http_proxy", "https_proxy", "all_proxy")}
raw = subprocess.run(["curl", "-s", "--max-time", "300", "-L", url],
                     capture_output=True, env=env, check=True).stdout
doc = json.loads(raw.decode("utf-8"))
data = base64.b64decode(doc["content"])
open(out, "wb").write(data)
print(f"  {out} <- {len(data)} bytes")
PY
}

mkdir -p "$WORK"
cd "$WORK"
if [ ! -f sqlite3.c ]; then
  echo "下载 sqlite3 amalgamation..."
  download "src/sqlite3.c" sqlite3.c
  download "include/sqlite3.h" sqlite3.h
fi

ver="$(sed -n 's/^#define SQLITE_VERSION *"\(.*\)"/\1/p' sqlite3.c | head -1)"
echo "amalgamation 版本: $ver"
if [ "$ver" != "$SQLITE_VERSION_EXPECTED" ]; then
  echo "警告：预期 $SQLITE_VERSION_EXPECTED，实际 $ver（继续）" >&2
fi

build_one() {
  local triple="$1" out="$2"
  local cc="$NATIVE/llvm/bin/${triple}-clang"
  if [ ! -x "$cc" ]; then
    echo "缺少编译器 $cc" >&2
    return 1
  fi
  echo "编译 $triple ..."
  "$cc" "${CFLAGS[@]}" -o "$out" sqlite3.c -lm -ldl -lpthread
}

build_one x86_64-unknown-linux-ohos libsqlite3-x86_64.so
build_one aarch64-unknown-linux-ohos libsqlite3-arm64.so

mkdir -p "$ROOT/ohos/entry/libs/x86_64" "$ROOT/ohos/entry/libs/arm64-v8a"
cp libsqlite3-x86_64.so "$ROOT/ohos/entry/libs/x86_64/libsqlite3.so"
cp libsqlite3-arm64.so "$ROOT/ohos/entry/libs/arm64-v8a/libsqlite3.so"

echo "完成："
ls -lh "$ROOT/ohos/entry/libs"/*/libsqlite3.so
