"""Rebuild the current mobile component from a checked-out upstream repository."""
import gzip
import subprocess
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
subprocess.run(
    ['node', str(root / 'tool/build_builtin_danmaku.mjs'), sys.argv[1]],
    cwd=root,
    check=True,
)

# 随包以 gzip 存放：upstream.cjs 约 3 MB，压缩后约 0.8 MB。运行时解压出的字节
# 与原文件完全一致，所以 manifest 的 patchedSha256 与安装期校验都不用改。
# mtime=0 让产物可复现，重复生成不会产生二进制差异。
danmaku = root / 'assets/local_danmaku'
plain = danmaku / 'upstream.cjs'
if plain.exists():
    (danmaku / 'upstream.cjs.gz').write_bytes(
        gzip.compress(plain.read_bytes(), compresslevel=9, mtime=0)
    )
    plain.unlink()
    print('Packed upstream.cjs -> upstream.cjs.gz')
