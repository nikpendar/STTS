"""Listening files and a whisper character error rate for each exported voice:
evaluate.py VOICE_DIR EZAFE_DIR GGML SENTENCES OUT voice-*.onnx
VOICE_DIR has g2p-*.onnx and mana.onnx.json; each voice reads every line of SENTENCES into
OUT/<voice>.wav (and <voice>/NN.wav for the recognizer)."""
import json, os, re, sys
import numpy as np, onnxruntime as ort, soundfile as sf
from scipy.signal import resample_poly

sys.path.insert(0, os.path.dirname(__file__))
from ipa import Phonemizer

vdir, ezafe, ggml, sentences, out = sys.argv[1:6]
cfg = json.load(open(f"{vdir}/mana.onnx.json"))
IDS = {k: v[0] for k, v in cfg["phoneme_id_map"].items()}
inf = cfg["inference"]
ph = Phonemizer(vdir, ezafe)
texts = [t for t in open(sentences, encoding="utf-8").read().splitlines() if t.strip()]
ipas = [Phonemizer.ipa_of(ph.letters(t)) for t in texts]
from pywhispercpp.model import Model

asr = Model(ggml, n_threads=os.cpu_count(), print_progress=False, print_realtime=False)
norm = lambda s: re.sub(r"[^ء-ی]", "", s.replace("ي", "ی").replace("ك", "ک").replace("‌", ""))


def distance(a, b):
    row = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        prev, row[0] = row[0], i
        for j, y in enumerate(b, 1):
            prev, row[j] = row[j], min(row[j] + 1, row[j - 1] + 1, prev + (x != y))
    return row[-1]


for path in sys.argv[6:]:
    name = os.path.basename(path).rsplit(".", 1)[0]
    voice = ort.InferenceSession(path)
    os.makedirs(f"{out}/{name}", exist_ok=True)
    whole, errors, chars, seconds, letters = [], 0, 0, 0.0, 0
    for n, (text, ipa) in enumerate(zip(texts, ipas)):
        seq = [IDS["^"], IDS["_"]]
        for c in ipa:
            if c in IDS: seq += [IDS[c], IDS["_"]]
        seq.append(IDS["$"])
        a = voice.run(None, {"input": np.array([seq], dtype=np.int64), "input_lengths": np.array([len(seq)], dtype=np.int64),
                             "scales": np.array([inf["noise_scale"], inf["length_scale"], inf["noise_w"]], dtype=np.float32)})[0].reshape(-1)
        a = a / max(0.01, np.abs(a).max()) * 0.9
        sf.write(f"{out}/{name}/{n:02d}.wav", a, 22050, subtype="PCM_16")
        whole += [a, np.zeros(int(22050 * 0.35), dtype=np.float32)]
        a16 = resample_poly(a, 320, 441).astype(np.float32)
        heard = "".join(s.text for s in asr.transcribe(a16, language="fa", audio_ctx=min(1500, int(len(a16) / 16000 * 50) + 64)))
        errors += distance(norm(heard), norm(text)); chars += len(norm(text))
        seconds += len(a) / 22050; letters += len(norm(text))
    sf.write(f"{out}/{name}.wav", np.concatenate(whole), 22050, subtype="PCM_16")
    print(f"{name}: CER {100 * errors / chars:.1f}%  {letters / seconds:.1f} letters/s", flush=True)
