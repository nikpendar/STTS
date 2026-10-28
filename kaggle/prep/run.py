# Mana-TTS (CC0) as training data for the Mana Piper voice with the app's own phonemes: each
# transcript goes through what PersianPhonemizer does in the app (numbers spelled, Homo-GE2PE int8
# ONNX greedy, IPA with stress, Piper ids ^ _ p _ … $), audio at 22050 Hz FLAC. Rows the corpus marks
# as badly aligned (high CER) are left out. Output: /kaggle/working/{wavs/, metadata.csv, stats.txt}
# for kaggle/train (piper1-gpl, --data.data_type phoneme_ids). CPU only.
import io, json, os, re, subprocess, sys, time, urllib.request
from multiprocessing import Pool

import numpy as np

subprocess.run("pip install -q num2fawords soundfile onnxruntime", shell=True, check=True)
import onnxruntime as ort
import pandas as pd
import soundfile as sf
from huggingface_hub import hf_hub_download
from num2fawords import words as fa_words
from scipy.signal import resample_poly

PARTS = int(os.environ.get("PARTS", "77"))
MAX_CER = 0.10
MIN_S, MAX_S = 1.0, 15.0
REL = "https://github.com/nikpendar/STTS/releases/download/tts-fa-mana/"
OUT = "/kaggle/working"
VOICE = "/kaggle/temp/voice"
os.makedirs(f"{OUT}/wavs", exist_ok=True)
os.makedirs(VOICE, exist_ok=True)
for f in ("g2p-encoder.onnx", "g2p-decoder.onnx", "mana.onnx.json"):
    urllib.request.urlretrieve(REL + f, f"{VOICE}/{f}")
urllib.request.urlretrieve("https://raw.githubusercontent.com/nikpendar/STTS/claude/project-thread-xaj97f/scripts/tts_phonemes.py", "/kaggle/temp/tts_phonemes.py")
sys.path.insert(0, "/kaggle/temp")
from tts_phonemes import ipa_word  # noqa: E402

IDS = {k: v[0] for k, v in json.load(open(f"{VOICE}/mana.onnx.json"))["phoneme_id_map"].items()}
PUNCT = {".": ".", "!": "!", "?": "?", "؟": "?", "،": ",", ",": ",", ";": ";", "؛": ";", ":": ":"}
enc = dec = None


def spell(n):
    w = fa_words(n).replace("یکصد", "صد")
    return w[3:] if w.startswith("یک هزار") else w


def clean(s):
    out = ""
    for ch in s:
        v = ord(ch)
        if 0x0621 <= v <= 0x063A or 0x0641 <= v <= 0x064A or v in (0x067E, 0x0686, 0x0698, 0x06A9, 0x06AF, 0x06CC, 0x06C0, 0x0622, 0x200C):
            out += ch
        elif out and out[-1] != " " and not (0x064B <= v <= 0x0652) and v != 0x0640:
            out += " "
    return out.strip()


def g2p(text):
    b = [x + 3 for x in text.replace("ی", "ي").replace("ى", "ي").replace("ك", "ک").replace("ۀ", "ه").encode()]
    if not b:
        return ""
    h = enc.run(None, {"input_ids": np.array([b], dtype=np.int64)})[0]
    o = [0]
    while len(o) < 4 * len(b) + 16:
        n = int(dec.run(None, {"decoder_input_ids": np.array([o], dtype=np.int64), "encoder_hidden_states": h})[0][0].argmax())
        if n == 1:
            break
        o.append(n)
    return bytes(i - 3 for i in o[1:] if 3 <= i < 259).decode("utf-8", "replace").strip()


def split(t, marks):
    p, cur = [], ""
    for c in t:
        cur += c
        if c in marks:
            p.append(cur)
            cur = ""
    p.append(cur)
    return [x for x in p if x.strip()]


def ipa_of(text):
    """The whole transcript as one IPA string with punctuation, as the app makes per sentence."""
    global enc, dec
    if enc is None:
        so = ort.SessionOptions()
        so.intra_op_num_threads = 1
        enc = ort.InferenceSession(f"{VOICE}/g2p-encoder.onnx", so)
        dec = ort.InferenceSession(f"{VOICE}/g2p-decoder.onnx", so)
    text = text.translate(str.maketrans("۰۱۲۳۴۵۶۷۸۹٠١٢٣٤٥٦٧٨٩", "01234567890123456789"))
    text = re.sub(r"\d+", lambda m: " " + spell(int(m.group())) + " ", text)
    ipa = ""
    for clause in split(text, ".!?؟\n،,;؛:"):
        mark = PUNCT.get(clause.rstrip()[-1:])
        w = clean(clause).split()
        for i in range(0, len(w), 24):
            ph = g2p(" ".join(w[i:i + 24]))
            if ipa and not ipa.endswith(" "):
                ipa += " "
            ipa += " ".join(ipa_word(x, "rules") for x in ph.split())
        if mark and ipa:
            ipa += mark
    return ipa.strip()


def ids_of(ipa):
    seq = [IDS["^"], IDS["_"]]
    for c in ipa:
        if c in IDS:
            seq += [IDS[c], IDS["_"]]
    return seq + [IDS["$"]]


def work(item):
    name, text = item
    try:
        return name, ipa_of(text)
    except Exception as e:  # noqa: BLE001
        return name, f"!{e!r}"


start = time.time()
kept = skipped = 0
hours = 0.0
with open(f"{OUT}/metadata.csv", "w", encoding="utf-8") as meta, Pool(os.cpu_count()) as pool:
    for part in range(1, PARTS + 1):
        try:
            path = hf_hub_download("MahtaFetrat/Mana-TTS", f"dataset/dataset_part_{part:03d}.parquet", repo_type="dataset", cache_dir="/kaggle/temp/hf")
            df = pd.read_parquet(path)
        except Exception as e:  # noqa: BLE001
            print(f"part {part}: not read: {e!r}", flush=True)
            continue
        ok = (df["CER"] <= MAX_CER) & df["duration"].between(MIN_S, MAX_S) & df["transcript"].fillna("").str.len().gt(2)
        skipped += int((~ok).sum())
        df = df[ok]
        rate_col = "samplerate" if "samplerate" in df.columns else "sample_rate"
        items = []
        for i, row in df.iterrows():
            name = f"p{part:03d}_{i:05d}.flac"
            try:
                audio = np.asarray(row["audio"], dtype=np.float32).reshape(-1)
                rate = int(row[rate_col])
                if rate == 44100:
                    audio = resample_poly(audio, 1, 2)
                elif rate != 22050:
                    audio = resample_poly(audio, 22050, rate)
                peak = float(np.abs(audio).max()) if audio.size else 0.0
                if peak <= 0 or not np.isfinite(peak):
                    raise ValueError("silent")
                sf.write(f"{OUT}/wavs/{name}", (audio / peak * 0.95).astype(np.float32), 22050, format="FLAC", subtype="PCM_16")
            except Exception as e:  # noqa: BLE001
                if skipped < 50:
                    print(f"skip {name}: {e!r}", flush=True)
                skipped += 1
                continue
            items.append((name, str(row["transcript"])))
            hours += row["duration"] / 3600
        for name, ipa in pool.imap(work, items, chunksize=16):
            if not ipa or ipa.startswith("!"):
                if ipa and skipped < 50:
                    print(f"skip {name}: {ipa}", flush=True)
                os.remove(f"{OUT}/wavs/{name}")
                skipped += 1
                continue
            meta.write(f"{name}|{ipa}|{' '.join(map(str, ids_of(ipa)))}\n")
            kept += 1
        meta.flush()
        try:
            os.remove(os.path.realpath(path))
        except OSError:
            pass
        du = subprocess.run(f"du -sm {OUT}", shell=True, capture_output=True, text=True).stdout.split()[0]
        print(f"part {part}: kept {kept}, skipped {skipped}, {hours:.1f} h, {du} MB, {time.time() - start:.0f} s", flush=True)

with open(f"{OUT}/stats.txt", "w") as f:
    f.write(f"kept {kept} skipped {skipped} hours {hours:.1f}\n")
subprocess.run(f"du -sh {OUT}/wavs; head -3 {OUT}/metadata.csv", shell=True)
