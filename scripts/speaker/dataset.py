"""The training set of a speaker's pilot voice: dataset.py LABELS WAVS MANA_JSON OUT
LABELS: "id<TAB>GE2PE letters" per line, punctuation kept on the words (hand-checked against the
recording, since a few minutes of audio cannot absorb wrong labels); WAVS: NNNN.wav at 22050 Hz from
cut.py. Writes OUT/NNNN.flac (edges trimmed to 0.15 s of room, peak 0.95 like the Mana training set)
and OUT/metadata.csv "name|ipa|ids" for piper1-gpl (--data.dataset_type phoneme_ids)."""
import json, os, sys
import numpy as np, soundfile as sf
from scipy.signal import butter, sosfiltfilt

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from tts_phonemes import ipa_word

labels, wavs, mana, out = sys.argv[1:5]
IDS = {k: v[0] for k, v in json.load(open(mana))["phoneme_id_map"].items()}
MARKS = ".,!?"
os.makedirs(out, exist_ok=True)


def ipa_of(letters):
    words = []
    for token in letters.split():
        body = token.rstrip(MARKS)
        mark = token[len(body):][:1]
        if body:
            words.append(ipa_word(body, "rules") + mark)
    ipa = " ".join(words)
    return ipa if ipa[-1] in MARKS else ipa + "."


def trimmed(a, rate, room=0.15):
    frame = int(rate * 0.01)
    n = len(a) // frame
    db = 20 * np.log10(np.sqrt((a[:n * frame].reshape(n, frame) ** 2).mean(1)) + 1e-9)
    loud = np.flatnonzero(db > max(np.percentile(db, 95) - 35, np.percentile(db, 5) + 8))
    lo = max(0, loud[0] * frame - int(room * rate))
    hi = min(len(a), (loud[-1] + 1) * frame + int(room * rate))
    a = a[lo:hi].copy()
    fade = int(rate * 0.01)
    a[:fade] *= np.linspace(0, 1, fade)
    a[-fade:] *= np.linspace(1, 0, fade)
    return a


total = 0.0
with open(f"{out}/metadata.csv", "w", encoding="utf-8") as meta:
    for line in open(labels, encoding="utf-8").read().splitlines():
        name, letters = line.split("\t")[:2]
        a, rate = sf.read(f"{wavs}/{name}.wav", dtype="float32")
        assert rate == 22050 and a.ndim == 1
        a = trimmed(sosfiltfilt(butter(4, 80, "high", fs=rate, output="sos"), a), rate)
        sf.write(f"{out}/{name}.flac", (a / np.abs(a).max() * 0.95).astype(np.float32), rate, format="FLAC", subtype="PCM_16")
        ipa = ipa_of(letters)
        unknown = {c for c in ipa if c not in IDS}
        assert not unknown, (name, unknown)
        seq = [IDS["^"], IDS["_"]]
        for c in ipa:
            seq += [IDS[c], IDS["_"]]
        meta.write(f"{name}.flac|{ipa}|{' '.join(map(str, seq + [IDS['$']]))}\n")
        total += len(a) / rate
        print(name, f"{len(a) / rate:.1f}", ipa)
print(f"{total / 60:.1f} min")
