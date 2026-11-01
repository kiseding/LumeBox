# VITS AISHELL3 offline speech resource

Source archive: https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-zh-aishell3.tar.bz2
Model card: https://huggingface.co/csukuangfj/vits-zh-aishell3
Upstream training weights: https://huggingface.co/jackyqs/vits-aishell3-175-chinese
ONNX conversion and lexicon generation: https://github.com/csukuangfj/vits_chinese
Runtime: sherpa-onnx 1.13.8, https://github.com/k2-fsa/sherpa-onnx (Apache-2.0).

Nothing but `manifest.json` is tracked here. The seven runtime files
(123,661,958 bytes in total) are downloaded the first time the user enables
offline reading, from the addresses in `manifest.json` → `sources`:

1. `https://hf-mirror.com/csukuangfj/vits-zh-aishell3/resolve/main/` (国内镜像)
2. `https://huggingface.co/csukuangfj/vits-zh-aishell3/resolve/main/` (官方)

Every file is verified against the SHA-256 pinned in `files[].sha256`, which is
the same value the archive-based install has always enforced; a mismatch deletes
the temporary file and reports an error instead of handing half a model to the
native layer. Downloads resume with HTTP `Range`, so a 121 MB file does not
restart from zero after a dropped connection.

The official `vits-zh-aishell3.tar.bz2` is still accepted for manual import
(「从文件安装」): it is checked against `archiveSha256`, and only the seven
whitelisted runtime files are extracted — the upstream int8 and FAR variants are
ignored.

Measured runtime format: 8,000 Hz mono, 174 speaker IDs (0–173).
Role assignment is a reader preference; a numeric speaker ID is not a verified
gender label. Unknown dialogue names use stable alternating role assignment.
This is a speech synthesis model, not a local text-generation language model.
