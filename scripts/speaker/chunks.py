# Splits each recording at pauses and transcribes each piece: rec/<f>.chunks.json
import sys, json, numpy as np, soundfile as sf
from scipy.signal import butter, sosfilt
from pywhispercpp.model import Model
model = Model(sys.argv[1], n_threads=4, print_progress=False, print_realtime=False)
for f in sys.argv[2:]:
    x, sr = sf.read(f)
    y = sosfilt(butter(4, 80, 'hp', fs=sr, output='sos'), x)
    fr = int(0.02 * sr); n = len(y) // fr
    db = 10 * np.log10((y[:n * fr].reshape(n, fr) ** 2).mean(1) + 1e-12)
    voiced = db > np.percentile(db, 5) + 14
    # pauses of at least 0.45 s split pieces
    pieces, start, quiet = [], None, 0
    for i, v in enumerate(voiced):
        if v:
            if start is None: start = i
            quiet = 0
        elif start is not None:
            quiet += 1
            if quiet >= 23:
                pieces.append((start, i - quiet + 1)); start = None; quiet = 0
    if start is not None: pieces.append((start, n))
    pieces = [(a, b) for a, b in pieces if b - a >= 10]  # >= 0.2 s
    out = []
    for a, b in pieces:
        s0, s1 = max(0, a * fr - int(0.15 * sr)), min(len(x), b * fr + int(0.15 * sr))
        seg = x[s0:s1].astype(np.float32)
        text = " ".join(s.text for s in model.transcribe(seg, language="fa", audio_ctx=min(1500, int(len(seg) / 16000 * 50) + 64)))
        out.append({"t0": s0 / sr, "t1": s1 / sr, "text": text.strip()})
    json.dump(out, open(f + ".chunks.json", "w"), ensure_ascii=False, indent=0)
    print(f, len(out), flush=True)
