# New phonemes for the keyless-voice-prep rows without redoing its audio: transcripts with ژ (Homo-GE2PE
# writes it ";", which the first prep dropped) go through the phonemizer again, and colons and
# semicolons become commas in every row. Output: /kaggle/working/metadata.csv (same names), which
# kaggle/train prefers over the prep one; the audio stays in the prep output. CPU only.
import glob, os, re, subprocess, sys, time, urllib.request
from multiprocessing import Pool

subprocess.run("pip install -q num2fawords onnxruntime", shell=True, check=True)
import pandas as pd
from huggingface_hub import hf_hub_download

# The prep code itself, with the fixed tts_phonemes.py it downloads, minus its main loop.
SRC = "https://raw.githubusercontent.com/nikpendar/STTS/claude/project-thread-xaj97f/kaggle/prep/run.py"
src = urllib.request.urlopen(SRC).read().decode()
src = src.replace('os.makedirs(f"{OUT}/wavs", exist_ok=True)\n', "")
exec(compile(src.split("\nstart = time.time()")[0], "prep", "exec"))

meta = glob.glob("/kaggle/input/**/metadata.csv", recursive=True)
assert meta, "attach the output of keyless-voice-prep"
rows = [r.split("|") for r in open(meta[0], encoding="utf-8").read().splitlines()]
names = {name for name, _, _ in rows}
print(len(rows), "rows from", meta[0], flush=True)

start = time.time()
redo = {}
for part in range(1, 78):
    try:
        path = hf_hub_download("MahtaFetrat/Mana-TTS", f"dataset/dataset_part_{part:03d}.parquet", repo_type="dataset", cache_dir="/kaggle/temp/hf")
        df = pd.read_parquet(path, columns=["transcript"])
    except Exception as e:  # noqa: BLE001
        print(f"part {part}: not read: {e!r}", flush=True)
        continue
    for i, text in df["transcript"].items():
        name = f"p{part:03d}_{i:05d}.flac"
        if name in names and "ژ" in str(text):
            redo[name] = str(text)
    try:
        os.remove(os.path.realpath(path))
    except OSError:
        pass
    print(f"part {part}: {len(redo)} rows with ژ, {time.time() - start:.0f} s", flush=True)

with Pool(os.cpu_count()) as pool:
    new = dict(pool.imap(work, list(redo.items()), chunksize=16))

changed = 0
with open(f"{OUT}/metadata.csv", "w", encoding="utf-8") as f:
    for name, ipa, ids in rows:
        if name in new and new[name] and not new[name].startswith("!"):
            ipa = new[name]
        fixed = re.sub("[:;]", ",", ipa)
        if fixed != ipa or name in new:
            changed += 1
        f.write(f"{name}|{fixed}|{' '.join(map(str, ids_of(fixed)))}\n")
print("rows with ʒ now:", sum("ʒ" in v for v in new.values()), "changed:", changed, flush=True)
with open(f"{OUT}/stats.txt", "w") as f:
    f.write(f"rows {len(rows)} with zhe {len(redo)} changed {changed}\n")
subprocess.run(f"grep -m3 ʒ {OUT}/metadata.csv", shell=True)
