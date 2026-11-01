"""Reproduce the pinned local-service adapter; never accepts an unpinned update."""
import gzip
import hashlib
import json
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1] / 'assets/local_danmaku'
manifest = json.loads((root / 'manifest.json').read_text(encoding='utf-8'))
data = Path(sys.argv[1]).read_bytes()
if hashlib.sha256(data).hexdigest() != manifest['upstreamReleaseSha256']:
    raise SystemExit('Upstream SHA-256 does not match the pinned release')
source = data.decode('utf-8')
for before, after in manifest['patches']:
    if before not in source:
        raise SystemExit('Upstream adapter anchor is missing')
    source = source.replace(before, after)
data = source.encode('utf-8')
if hashlib.sha256(data).hexdigest() != manifest['patchedSha256']:
    raise SystemExit('Patched SHA-256 mismatch')
# 随包以 gzip 存放：源文件 3.1 MB，压缩后 0.8 MB。运行时解压出的字节与原文件
# 完全一致，所以 manifest 的 patchedSha256 与安装期校验都不用改。mtime=0 让
# 产物可复现，重复生成不会产生二进制差异。
(root / 'upstream.cjs.gz').write_bytes(gzip.compress(data, compresslevel=9, mtime=0))
(root / 'upstream.cjs').unlink(missing_ok=True)
print('Pinned local danmaku adapter reproduced and verified')
