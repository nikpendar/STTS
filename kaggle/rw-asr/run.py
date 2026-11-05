# Stage 1 of the dictation-correction student: what the app's speech model (Shenava Koochik 1.0,
# greedy CTC, att context [70, 0] as in the app) writes for public Persian speech, next to the
# reference text. Sets: FLEURS fa_ir train/dev/test (CC-BY 4.0) and Common Voice 17 fa dev/test
# (CC0). Held out for the student's evaluation: all of FLEURS test and a fixed tenth of CV test.
# Output /kaggle/working/asr.jsonl: {id, set, split, ref, hyp, wer}; summary.txt with WER per set.
import hashlib, io, json, os, re, subprocess, sys, tarfile, time, unicodedata, urllib.error, urllib.request
from multiprocessing import Pool

T0 = time.time()
OUT = "/kaggle/working"
TMP = "/kaggle/temp"
os.makedirs(TMP, exist_ok=True)
NEMO_URL = "https://huggingface.co/Reza2kn/Shenava-Koochik-v1.0/resolve/main/shenava-koochik-v1.0.nemo"
NEMO_SHA256 = "f7b5124a9fd2d50c15bf070abdc0f80ec2449d64948c5657adb79a7e91dd1d16"
FLEURS = "https://huggingface.co/datasets/google/fleurs/resolve/main/data/fa_ir"
CV = "https://huggingface.co/datasets/fsicoli/common_voice_17_0/resolve/main"


def log(*a):
    print(f"[{(time.time() - T0) / 60:5.1f} min]", *a, flush=True)


def sh(cmd):
    log("$", cmd)
    subprocess.run(cmd, shell=True, check=True)


def fetch(url, path):
    if not os.path.exists(path):
        urllib.request.urlretrieve(url, path)
    return path


def normalize(text):
    text = unicodedata.normalize("NFKC", text)
    text = text.replace("ي", "ی").replace("ى", "ی").replace("ك", "ک").replace("ة", "ه")
    text = text.replace("أ", "ا").replace("إ", "ا").replace("ٱ", "ا")
    text = re.sub("[ً-ٰٟـ]", "", text)
    text = text.replace("‌", "").replace("‏", "").replace("‎", "")
    text = re.sub(r"[^\w\s]|_", " ", text)
    return " ".join(text.lower().split())


def distance(a, b):
    prev = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        cur = [i]
        for j, y in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x != y)))
        prev = cur
    return prev[-1]


def decode(data):
    import numpy as np
    p = subprocess.run(["ffmpeg", "-loglevel", "error", "-i", "pipe:0", "-ar", "16000", "-ac", "1", "-f", "f32le", "pipe:1"],
                       input=data, capture_output=True)
    return np.frombuffer(p.stdout, dtype=np.float32).copy()


sh("nvidia-smi --query-gpu=name,memory.total --format=csv; which ffmpeg; df -h /kaggle/working /kaggle/temp | tail -2")
sh("pip install -q 'nemo_toolkit[asr]' 2>&1 | grep -viE 'warning|already' | tail -5 || true")
fetch(NEMO_URL, f"{TMP}/koochik.nemo")
assert hashlib.sha256(open(f"{TMP}/koochik.nemo", "rb").read()).hexdigest() == NEMO_SHA256
log("model downloaded")

# --- clips: (id, set, ref, compressed bytes)
items = []
for split in ("train", "dev", "test"):
    tsv = fetch(f"{FLEURS}/{split}.tsv", f"{TMP}/fleurs-{split}.tsv")
    refs = {}
    for line in open(tsv, encoding="utf-8"):
        cols = line.rstrip("\n").split("\t")
        if len(cols) > 2:
            refs[cols[1]] = cols[2]
    tgz = fetch(f"{FLEURS}/audio/{split}.tar.gz", f"{TMP}/fleurs-{split}.tar.gz")
    seen = set()
    with tarfile.open(tgz) as tar:
        for m in tar:
            name = os.path.basename(m.name)
            if name in refs and name not in seen:
                seen.add(name)
                items.append((f"fleurs-{split}/{name}", f"fleurs-{split}", refs[name], tar.extractfile(m).read()))
    log(f"fleurs {split}: {len(seen)} clips")
    os.remove(tgz)

for split in ("dev", "test"):
    import csv
    tsv = fetch(f"{CV}/transcript/fa/{split}.tsv", f"{TMP}/cv-{split}.tsv")
    refs = {r["path"]: r["sentence"] for r in csv.DictReader(open(tsv, encoding="utf-8"), delimiter="\t", quoting=csv.QUOTE_NONE)}
    n = 0
    for shard in range(50):
        try:
            tar_path = fetch(f"{CV}/audio/fa/{split}/fa_{split}_{shard}.tar", f"{TMP}/cv-{split}-{shard}.tar")
        except urllib.error.HTTPError:
            break
        with tarfile.open(tar_path) as tar:
            for m in tar:
                name = os.path.basename(m.name)
                if name in refs:
                    items.append((f"cv17-{split}/{name}", f"cv17-{split}", refs[name], tar.extractfile(m).read()))
                    n += 1
        os.remove(tar_path)
    log(f"cv17 {split}: {n} clips of {len(refs)}")

with Pool(os.cpu_count()) as pool:
    audio = pool.map(decode, [it[3] for it in items], chunksize=64)
items = [(i, s, r) for (i, s, r, _) in items]
log(f"decoded {len(items)} clips, {sum(len(a) for a in audio) / 16000 / 3600:.1f} h")

# --- transcribe, longest first in batches
import numpy as np
import torch
import nemo.collections.asr as nemo_asr

model = nemo_asr.models.ASRModel.restore_from(f"{TMP}/koochik.nemo", map_location="cuda")
model.encoder.set_default_att_context_size([70, 0])
model.eval()
blank = model.ctc_decoder.num_classes_with_blank - 1
order = sorted(range(len(items)), key=lambda k: -len(audio[k]))
hyps = [""] * len(items)
B = 32
with torch.no_grad():
    for start in range(0, len(order), B):
        idx = [k for k in order[start:start + B] if 4000 <= len(audio[k]) <= 30 * 16000]
        if not idx:
            continue
        lengths = torch.tensor([len(audio[k]) for k in idx])
        x = torch.zeros(len(idx), int(lengths.max()))
        for j, k in enumerate(idx):
            x[j, :len(audio[k])] = torch.from_numpy(audio[k])
        x, lengths = x.cuda(), lengths.cuda()
        f, fl = model.preprocessor(input_signal=x, length=lengths)
        e, el = model.encoder(audio_signal=f, length=fl)
        lp = model.ctc_decoder(encoder_output=e)
        for row, n, k in zip(lp.argmax(-1).tolist(), el.tolist(), idx):
            ids, prev = [], blank
            for t in row[:n]:
                if t != prev and t != blank:
                    ids.append(t)
                prev = t
            hyps[k] = model.tokenizer.ids_to_text(ids)
        if start % (B * 100) == 0:
            log(f"transcribed {start}/{len(order)}")
log("transcription done")

stats = {}
with open(f"{OUT}/asr.jsonl", "w", encoding="utf-8") as f:
    for (cid, cset, ref), hyp in zip(items, hyps):
        if not hyp:
            continue
        r, h = normalize(ref).split(), normalize(hyp).split()
        if not r:
            continue
        err = distance(r, h)
        held = cset == "fleurs-test" or (cset == "cv17-test" and int(hashlib.sha1(cid.encode()).hexdigest(), 16) % 10 == 0)
        f.write(json.dumps({"id": cid, "set": cset, "split": "heldout" if held else "train", "ref": ref, "hyp": hyp,
                            "wer": round(err / len(r), 3)}, ensure_ascii=False) + "\n")
        s = stats.setdefault(cset, [0, 0, 0, 0])
        s[0] += 1; s[1] += err; s[2] += len(r); s[3] += err > 0

lines = [f"{k}: {v[0]} clips, WER {100 * v[1] / v[2]:.1f}, clips with an error {100 * v[3] / v[0]:.0f}%" for k, v in sorted(stats.items())]
rows = [json.loads(l) for l in open(f"{OUT}/asr.jsonl", encoding="utf-8")]
import random
random.seed(1)
lines.append("--- samples (ref | hyp)")
for r in random.sample([r for r in rows if r["wer"] > 0], 25):
    lines.append(f"{r['set']}: {r['ref']} | {r['hyp']}")
lines.append(f"minutes {(time.time() - T0) / 60:.0f}")
open(f"{OUT}/summary.txt", "w", encoding="utf-8").write("\n".join(lines) + "\n")
print("\n".join(lines))
