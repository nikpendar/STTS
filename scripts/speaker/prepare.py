"""Speaker recordings to a sealed training set, end to end:
prepare.py RECORDINGS_DIR SENTENCES GGML VOICE_DIR EZAFE_DIR MANA_JSON PUBHEX WORK [FIXED_LABELS]

RECORDINGS_DIR: one file per run of sentences, named by the first and last sentence number
("0101-0150.wav", any format ffmpeg reads; lossless preferred). SENTENCES: the script ("N. text").
Each file is split at pauses and transcribed (chunks.py), matched to its sentences with retakes and
skips (align.py) and cut, keeping the last good take (cut.py). Takes whose transcript matches the
sentence badly, or that clip, are left out and listed in WORK/report.txt. Labels are the app's own
phonemizer (GE2PE + Ezafe tagger); FIXED_LABELS ("id<TAB>letters", hand-checked) win where given.
Writes WORK/data (FLAC + metadata.csv, dataset.py), WORK/key.txt (result key) and WORK/speaker.sealed."""
import glob, os, re, subprocess, sys, tarfile

here = os.path.dirname(os.path.abspath(__file__))
rec, sentences, ggml, voice, ezafe, mana, pub, work = sys.argv[1:9]
fixed = dict(l.split("\t")[:2] for l in open(sys.argv[9], encoding="utf-8").read().splitlines()) if len(sys.argv) > 9 else {}
os.makedirs(f"{work}/audio", exist_ok=True)
cut = f"{work}/cut"
if os.path.exists(f"{cut}/metadata.csv"):
    os.remove(f"{cut}/metadata.csv")
run = lambda *a, **k: subprocess.run([str(x) for x in a], check=True, **k)
report = []

for path in sorted(glob.glob(f"{rec}/*")):
    m = re.match(r"(\d+)\D+(\d+)", os.path.basename(path))
    if not m:
        report.append(f"skipped {path}: name has no sentence range")
        continue
    first, last = int(m.group(1)), int(m.group(2))
    base = f"{work}/audio/{first:04d}-{last:04d}"
    run("ffmpeg", "-loglevel", "error", "-y", "-i", path, "-ac", "1", "-ar", "44100", "-c:a", "pcm_f32le", f"{base}.wav")
    run("ffmpeg", "-loglevel", "error", "-y", "-i", path, "-ac", "1", "-ar", "16000", f"{base}.16k.wav")
    run(sys.executable, f"{here}/chunks.py", ggml, f"{base}.16k.wav", stderr=subprocess.DEVNULL)
    with open(f"{base}.align.json", "w") as f:
        run(sys.executable, f"{here}/align.py", sentences, f"{base}.16k.wav.chunks.json", first, last, stdout=f)
    notes = subprocess.run([sys.executable, f"{here}/cut.py", f"{base}.wav", f"{base}.align.json", cut], check=True, capture_output=True, text=True).stdout
    report += [f"{first:04d}-{last:04d}: {l}" for l in notes.splitlines()]
    print(path, notes.splitlines()[-1] if notes else "", flush=True)

# Left out: badly matched or clipped takes (cut.py's notes).
bad = {int(l.split(": ", 1)[1].split()[0]) for l in report if ("low match" in l or "clipped" in l) and ": " in l and l.split(": ", 1)[1].split()[0].isdigit()}
sys.path.insert(0, here)
from ipa import Phonemizer

ph = Phonemizer(voice, ezafe)
rows = [l.split("|", 1) for l in open(f"{cut}/metadata.csv", encoding="utf-8").read().splitlines()]
with open(f"{work}/labels.tsv", "w", encoding="utf-8") as f:
    for name, text in rows:
        if int(name) in bad:
            continue
        letters = fixed.get(name) or " ".join(" ".join(ps) + mark for _, ps, mark in ph.letters(text) if ps)
        f.write(f"{name}\t{letters}\t{text}\n")
report.append(f"kept {len(rows) - len(bad)} of {len(rows)} cut sentences; left out: {' '.join(map(str, sorted(bad)))}")
open(f"{work}/report.txt", "w", encoding="utf-8").write("\n".join(report) + "\n")

run(sys.executable, f"{here}/dataset.py", f"{work}/labels.tsv", f"{cut}/wavs", mana, f"{work}/data", stdout=subprocess.DEVNULL)
key = os.urandom(32).hex()
open(f"{work}/key.txt", "w").write(key)
open(f"{work}/data/key.txt", "w").write(key)
with tarfile.open(f"{work}/bundle.tar", "w") as t:
    t.add(f"{work}/data", arcname=".")
os.remove(f"{work}/data/key.txt")
run(sys.executable, f"{here}/sealed.py", "seal", pub, f"{work}/bundle.tar", f"{work}/speaker.sealed")
os.remove(f"{work}/bundle.tar")
print(report[-1])
print(f"sealed {work}/speaker.sealed; result key {work}/key.txt")
