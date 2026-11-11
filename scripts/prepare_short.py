#!/usr/bin/env python3
"""Common Voice clips of one to three words, for the short-utterance benchmark (short-eval.yml).

Usage: prepare_short.py <test.tsv> <test.tar> <count> <out dir>
Takes the first <count> clips in the tar whose sentence has at most three words.
"""
import csv
import os
import subprocess
import sys
import tarfile

tsv, tar_path, count, out = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
os.makedirs(out, exist_ok=True)
rows = csv.DictReader(open(tsv, encoding="utf-8"), delimiter="\t", quoting=csv.QUOTE_NONE)
short = {r["path"]: r["sentence"] for r in rows if 1 <= len(r["sentence"].split()) <= 3}
done = 0
with tarfile.open(tar_path) as tar, open(os.path.join(out, "refs.tsv"), "w", encoding="utf-8") as refs:
    for member in tar:
        name = os.path.basename(member.name)
        if name not in short:
            continue
        wav = name.rsplit(".", 1)[0] + ".wav"
        subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", "pipe:0", "-ar", "16000", "-ac", "1",
                        "-c:a", "pcm_s16le", os.path.join(out, wav)], input=tar.extractfile(member).read(), check=True)
        refs.write(f"{wav}\t{short[name]}\n")
        done += 1
        if done >= count:
            break
print(f"{len(short)} short sentences in the split, {done} clips taken")
