# Picks one take per sentence and cuts it: OUT/wavs/NNNN.wav (22.05 kHz mono), OUT/metadata.csv, prints notes.
# usage: cut.py AUDIO(44.1k wav) ALIGN_JSON OUT
import sys, json, os, csv, numpy as np, soundfile as sf
from scipy.signal import butter, sosfilt, resample_poly
audio, align, out = sys.argv[1:4]
x, sr = sf.read(audio)
x = sosfilt(butter(4, 60, 'hp', fs=sr, output='sos'), x)
takes = {}
for t in json.load(open(align)):
    takes.setdefault(t["id"], []).append(t)
os.makedirs(f"{out}/wavs", exist_ok=True)

def quietest(a, b):
    w = int(0.15 * sr); best, at = None, (a + b) // 2
    for s in range(a, b - w, int(0.01 * sr)):
        e = float((x[s:s + w] ** 2).mean())
        if best is None or e < best: best, at = e, s + w // 2
    return at

rows = []
for i, ts in sorted(takes.items()):
    top = max(t["sim"] for t in ts)
    pick = [t for t in ts if t["sim"] >= top - 0.1][-1]
    a, b = int(pick["t0"] * sr), int(pick["t1"] * sr)
    if pick["part"]:
        mate = [t for t in takes.get(i + (1 if pick["part"] == "first" else -1), []) if t["t0"] == pick["t0"]]
        n1 = len(pick["text"] if pick["part"] == "first" else mate[0]["text"]) if mate else 1
        n2 = len(mate[0]["text"] if pick["part"] == "first" else pick["text"]) if mate else 1
        mid = a + int((b - a) * n1 / (n1 + n2))
        cut = quietest(mid - int(0.2 * (b - a)), mid + int(0.2 * (b - a)))
        a, b = (a, cut) if pick["part"] == "first" else (cut, b)
    seg = x[a:b]
    seg = resample_poly(seg, 1, 2) if sr == 44100 else seg
    peak = float(np.abs(seg).max())
    sf.write(f"{out}/wavs/{i:04d}.wav", (seg * 0.9 / max(peak, 1e-3) if peak > 0.95 else seg).astype(np.float32), 22050, subtype="PCM_16")
    rows.append((f"{i:04d}", pick["text"]))
    note = []
    if len(ts) > 1: note.append(f"{len(ts)} takes, kept #{ts.index(pick) + 1}")
    if pick["sim"] < 0.75: note.append(f"low match {pick['sim']}: heard «{pick['heard']}»")
    if peak > 0.98: note.append("clipped")
    if note: print(i, "; ".join(note))
with open(f"{out}/metadata.csv", "a", encoding="utf-8") as f:
    for r in rows: f.write("|".join(r) + "\n")
print("cut", len(rows))
