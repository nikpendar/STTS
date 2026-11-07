# Stage 1c of the dictation-correction student (round 3): more real speech-model errors. Round 1 had
# only FLEURS + CV dev/test, and Shenava was trained on FLEURS (likely CV train too), so its errors there
# are rarer and milder than on a phone. Here: Common Voice 17 fa train and "other" (unvalidated, so
# probably unseen by Shenava; rows with WER > 0.6 dropped as bad recordings or references), and part of
# every clip set degraded the way phone dictation is: background noise (SNR 5-20 dB), room echo,
# 8 kHz phone band, quiet voice, speed +-8%. Held-out FLEURS test and the CV test tenth come back
# degraded only, as a separate "noisy" evaluation set (split heldout, aug true).
# Processed shard by shard (audio is not all kept in memory) until the time budget.
# Output /kaggle/working/asr2.jsonl: {id, set, split, aug, ref, hyp, wer}; summary.txt.
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



import csv, random
import numpy as np

BUDGET_H = float(os.environ.get("BUDGET_H", "2.5"))
AUG_P = 0.6
random.seed(5)

sh("nvidia-smi --query-gpu=name,memory.total --format=csv; df -h /kaggle/working /kaggle/temp | tail -2")
sh("pip install -q 'nemo_toolkit[asr]' 2>&1 | grep -viE 'warning|already' | tail -5 || true")
fetch(NEMO_URL, f"{TMP}/koochik.nemo")
assert hashlib.sha256(open(f"{TMP}/koochik.nemo", "rb").read()).hexdigest() == NEMO_SHA256
import torch, torchaudio
import nemo.collections.asr as nemo_asr
from scipy.signal import fftconvolve

model = nemo_asr.models.ASRModel.restore_from(f"{TMP}/koochik.nemo", map_location="cuda")
model.encoder.set_default_att_context_size([70, 0])
model.eval()
blank = model.ctc_decoder.num_classes_with_blank - 1
log("model ready")


def degrade(x, rnd):
    """One or two phone-like degradations; returns audio and their names."""
    kinds = rnd.sample(["noise", "echo", "phone", "quiet", "speed"], rnd.choice([1, 1, 2]))
    t = torch.from_numpy(x)
    for k in kinds:
        if k == "speed":
            t = torchaudio.functional.resample(t, 16000, rnd.choice([14800, 15200, 15600, 16400, 16800, 17200]))
        elif k == "phone":
            t = torchaudio.functional.resample(torchaudio.functional.resample(t, 16000, 8000), 8000, 16000)
        elif k == "echo":
            n = int(16000 * rnd.uniform(0.2, 0.6))
            ir = np.exp(-np.arange(n) / (n / 6)) * np.random.default_rng(rnd.randrange(1 << 30)).standard_normal(n) * 0.3
            ir[0] = 1
            t = torch.from_numpy(fftconvolve(t.numpy(), ir)[: len(t)].astype(np.float32))
        elif k == "quiet":
            t = t * rnd.uniform(0.05, 0.25)
        elif k == "noise":
            white = torch.from_numpy(np.random.default_rng(rnd.randrange(1 << 30)).standard_normal(len(t)).astype(np.float32))
            noise = torchaudio.functional.lowpass_biquad(white, 16000, rnd.uniform(400, 4000)) + white * rnd.uniform(0.05, 0.3)
            snr = rnd.uniform(5, 20)
            noise = noise * (t.pow(2).mean().sqrt() / (noise.pow(2).mean().sqrt() + 1e-9)) / (10 ** (snr / 20))
            t = t + noise
    peak = t.abs().max()
    if peak > 1:
        t = t / peak
    return t.numpy().astype(np.float32), "+".join(kinds)


def transcribe(audio):
    hyps = [""] * len(audio)
    order = sorted(range(len(audio)), key=lambda k: -len(audio[k]))
    with torch.no_grad():
        for start in range(0, len(order), 32):
            idx = [k for k in order[start:start + 32] if 4000 <= len(audio[k]) <= 30 * 16000]
            if not idx:
                continue
            lengths = torch.tensor([len(audio[k]) for k in idx])
            x = torch.zeros(len(idx), int(lengths.max()))
            for j, k in enumerate(idx):
                x[j, :len(audio[k])] = torch.from_numpy(audio[k])
            f, fl = model.preprocessor(input_signal=x.cuda(), length=lengths.cuda())
            e, el = model.encoder(audio_signal=f, length=fl)
            lp = model.ctc_decoder(encoder_output=e)
            for row, n, k in zip(lp.argmax(-1).tolist(), el.tolist(), idx):
                ids, prev = [], blank
                for tok in row[:n]:
                    if tok != prev and tok != blank:
                        ids.append(tok)
                    prev = tok
                hyps[k] = model.tokenizer.ids_to_text(ids)
    return hyps


out = open(f"{OUT}/asr2.jsonl", "w", encoding="utf-8")
stats = {}
deadline = T0 + BUDGET_H * 3600


def run_batch(items, held_only_aug=False):
    """items: (id, set, ref, compressed bytes, held)."""
    with Pool(os.cpu_count()) as pool:
        audio = pool.map(decode, [it[3] for it in items], chunksize=32)
    augs = []
    for k, it in enumerate(items):
        rnd = random.Random(it[0])
        if held_only_aug or rnd.random() < AUG_P:
            audio[k], a = degrade(audio[k], rnd)
        else:
            a = ""
        augs.append(a)
    hyps = transcribe(audio)
    for (cid, cset, ref, _, held), hyp, a in zip(items, hyps, augs):
        r, h = normalize(ref).split(), normalize(hyp).split()
        if not hyp or not r:
            continue
        wer = distance(r, h) / len(r)
        if cset == "cv17-other" and wer > 0.6:
            continue
        key = cset + ("-aug" if a else "")
        s = stats.setdefault(key, [0, 0.0, 0, 0])
        s[0] += 1; s[1] += wer * len(r); s[2] += len(r); s[3] += wer > 0
        out.write(json.dumps({"id": cid + ("#" + a if a else ""), "set": cset, "split": "heldout" if held else "train",
                              "aug": a, "ref": ref, "hyp": hyp, "wer": round(wer, 3)}, ensure_ascii=False) + "\n")
    out.flush()


# --- held out, degraded: FLEURS test + the CV test tenth (same rule as rw-asr)
tsv = fetch(f"{FLEURS}/test.tsv", f"{TMP}/fleurs-test.tsv")
refs = {c[1]: c[2] for c in (l.rstrip("\n").split("\t") for l in open(tsv, encoding="utf-8")) if len(c) > 2}
items, seen = [], set()
with tarfile.open(fetch(f"{FLEURS}/audio/test.tar.gz", f"{TMP}/fleurs-test.tar.gz")) as tar:
    for m in tar:
        name = os.path.basename(m.name)
        if name in refs and name not in seen:
            seen.add(name)
            items.append((f"fleurs-test/{name}", "fleurs-test", refs[name], tar.extractfile(m).read(), True))


def cv_refs(split):
    tsv = fetch(f"{CV}/transcript/fa/{split}.tsv", f"{TMP}/cv-{split}.tsv")
    return {r["path"]: r["sentence"] for r in csv.DictReader(open(tsv, encoding="utf-8"), delimiter="\t", quoting=csv.QUOTE_NONE)}


def cv_shards(split):
    for shard in range(200):
        try:
            path = fetch(f"{CV}/audio/fa/{split}/fa_{split}_{shard}.tar", f"{TMP}/cv-{split}-{shard}.tar")
        except urllib.error.HTTPError:
            return
        yield path


refs = cv_refs("test")
for path in cv_shards("test"):
    with tarfile.open(path) as tar:
        for m in tar:
            name = os.path.basename(m.name)
            cid = f"cv17-test/{name}"
            if name in refs and int(hashlib.sha1(cid.encode()).hexdigest(), 16) % 10 == 0:
                items.append((cid, "cv17-test", refs[name], tar.extractfile(m).read(), True))
    os.remove(path)
run_batch(items, held_only_aug=True)
log(f"held out degraded: {len(items)} clips")

# --- training clips: CV train, then CV other, shard by shard until the budget
for split in ("train", "other"):
    try:
        refs = cv_refs(split)
    except urllib.error.HTTPError as e:
        log(f"cv17 {split}: no transcript ({e})")
        continue
    n = 0
    for path in cv_shards(split):
        items = []
        with tarfile.open(path) as tar:
            for m in tar:
                name = os.path.basename(m.name)
                if name in refs:
                    items.append((f"cv17-{split}/{name}", f"cv17-{split}", refs[name], tar.extractfile(m).read(), False))
        os.remove(path)
        run_batch(items)
        n += len(items)
        log(f"cv17 {split}: {n} clips of {len(refs)}")
        if time.time() > deadline:
            break
    if time.time() > deadline:
        log("time budget reached")
        break
out.close()

lines = [f"{k}: {v[0]} clips, WER {100 * v[1] / v[2]:.1f}, clips with an error {100 * v[3] / v[0]:.0f}%" for k, v in sorted(stats.items())]
rows = [json.loads(l) for l in open(f"{OUT}/asr2.jsonl", encoding="utf-8")]
lines.append(f"unique references in training rows: {len({r['ref'] for r in rows if r['split'] == 'train'})}")
lines.append("--- samples (degradation: ref | hyp)")
bad = [r for r in rows if r["wer"] > 0]
for r in random.sample(bad, min(25, len(bad))):
    lines.append(f"{r['set']} {r['aug'] or 'clean'}: {r['ref']} | {r['hyp']}")
lines.append(f"minutes {(time.time() - T0) / 60:.0f}")
open(f"{OUT}/summary.txt", "w", encoding="utf-8").write("\n".join(lines) + "\n")
print("\n".join(lines))
