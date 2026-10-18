"""Fetch pinned upstream models; run before a clean build if assets were removed.

MobileCLIP software MIT, weights Apple ASCL; YAMNet Apache-2.0.
No conversion or inference is performed on this Windows build host.
"""
import hashlib
import json
from pathlib import Path
import re
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'assets/models/intro'
TEMP = ROOT / 'build/intro-models'
REVISION = '3e0a7bfb9fe83da8a3efaa3fd8f7df24214bb947'
FILES = {
    'mobileclip_s0_image.mlpackage/Data/com.apple.CoreML/model.mlmodel': '2c1afa132c41c6535817cc67894bd7484bc2cbd084ed5e2f12b24f611af17591',
    'mobileclip_s0_image.mlpackage/Data/com.apple.CoreML/weights/weight.bin': '87d8f63997bbd2f38ba7defeaaa2c571928bdece56aa9629542198b3ce906ed6',
    'mobileclip_s0_image.mlpackage/Manifest.json': None,
    'mobileclip_s0_text.mlpackage/Data/com.apple.CoreML/model.mlmodel': '81eba836ff4dbc8ae021d70006288b533ba7eed3c2973d245b0d5ea047305bfd',
    'mobileclip_s0_text.mlpackage/Data/com.apple.CoreML/weights/weight.bin': '34723e51445b2630106e94e1fdbebed80e7676b404fb839f4eb9bec97bdcad68',
    'mobileclip_s0_text.mlpackage/Manifest.json': None,
}

def fetch(url, dest, digest=None):
    dest.parent.mkdir(parents=True, exist_ok=True)
    if not dest.exists():
        temp = dest.with_suffix(dest.suffix + '.partial')
        with urllib.request.urlopen(url, timeout=45) as response, temp.open('wb') as output:
            while chunk := response.read(1024 * 1024):
                output.write(chunk)
        temp.replace(dest)
    actual = hashlib.sha256(dest.read_bytes()).hexdigest()
    if digest and actual != digest:
        raise ValueError(f'SHA-256 mismatch: {dest}')
    return actual

def tokens(vocab, merges, text):
    ranks = {tuple(line.split()): i for i, line in enumerate(merges.splitlines()[1:]) if len(line.split()) == 2 and ''.join(line.split()) in vocab}
    result = [vocab['<|startoftext|>']]
    # The bundled English anchors are ASCII; no byte-unicode remapping needed.
    for token in re.findall(r"'s|'t|'re|'ve|'m|'ll|'d|[a-z]+|[0-9]|[^\s\w]+", text.lower()):
        pieces = list(token[:-1]) + [token[-1] + '</w>']
        while len(pieces) > 1:
            pairs = [(ranks.get((pieces[i], pieces[i + 1]), 10**9), i) for i in range(len(pieces) - 1)]
            rank, index = min(pairs)
            if rank == 10**9:
                break
            pieces[index:index + 2] = [pieces[index] + pieces[index + 1]]
        result.extend(vocab[piece] for piece in pieces)
    result = result[:76] + [vocab['<|endoftext|>']]
    return result + [0] * (77 - len(result))

def main():
    OUT.mkdir(parents=True, exist_ok=True)
    checksums = {}
    for name, digest in FILES.items():
        print('Fetching', name, flush=True)
        checksums[name] = fetch(f'https://huggingface.co/apple/coreml-mobileclip/resolve/{REVISION}/{name}', TEMP / name, digest)
    with zipfile.ZipFile(OUT / 'mobileclip_s0.zip', 'w', zipfile.ZIP_DEFLATED) as archive:
        for name in FILES:
            archive.write(TEMP / name, name)
    checksums['yamnet.tflite'] = fetch('https://storage.googleapis.com/audioset/yamnet.tflite', OUT / 'yamnet.tflite', 'e193da5676a2fdb7a3702c10fba62aa27d76f64e4534467443811c1a2ff1667d')
    checksums['mobileclip_s0.zip'] = hashlib.sha256((OUT / 'mobileclip_s0.zip').read_bytes()).hexdigest()
    base = 'https://raw.githubusercontent.com/apple-aiml-research/ml-mobileclip/main/ios_app/MobileCLIPExplore/Resources/'
    fetch(base + 'clip-vocab.json', TEMP / 'clip-vocab.json')
    fetch(base + 'clip-merges.txt', TEMP / 'clip-merges.txt')
    prompts = {
        'recap': ['a television recap of previously shown scenes with subtitles', 'a previously on montage summarizing earlier episodes'],
        'opening': ['the opening title sequence of a television show with cast names', 'an opening theme song montage with a title logo'],
        'main': ['a scene from the main story with characters talking', 'a normal narrative scene from a movie or television episode'],
        'ending': ['closing credits with scrolling cast and crew names', 'the end credits of a television show on a dark background'],
    }
    vocab = json.loads((TEMP / 'clip-vocab.json').read_text('utf8'))
    merges = (TEMP / 'clip-merges.txt').read_text('utf8')
    (OUT / 'prompts.json').write_text(json.dumps({k: [tokens(vocab, merges, p) for p in values] for k, values in prompts.items()}), 'utf8')
    for name in ['LICENSE', 'LICENSE_MODELS', 'ACKNOWLEDGEMENTS']:
        fetch('https://raw.githubusercontent.com/apple-aiml-research/ml-mobileclip/main/' + name, OUT / ('MobileCLIP-' + name + '.txt'))
    fetch('https://raw.githubusercontent.com/tensorflow/models/master/LICENSE', OUT / 'YAMNet-LICENSE.txt')
    (OUT / 'checksums.json').write_text(json.dumps({'revision': REVISION, 'sha256': checksums}, indent=2), 'utf8')
    print('Models and prompt anchors ready.', flush=True)

if __name__ == '__main__':
    main()
