#!/usr/bin/env python3
"""Builds a Common Voice test subset for the benchmark: 16 kHz WAV clips plus refs.tsv.

Usage: prepare_cv.py <test.tsv> <test.tar> <count> <out dir>
Clips are spread evenly over the test split so many speakers are included.
"""
import csv
import os
import subprocess
import sys
import tarfile

tsv, tar_path, count, out = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
os.makedirs(out, exist_ok=True)
rows = list(csv.DictReader(open(tsv, encoding="utf-8"), delimiter="\t", quoting=csv.QUOTE_NONE))
step = max(1, len(rows) // count)
wanted = {row["path"]: row["sentence"] for row in rows[::step][:count]}

total = 0.0
with tarfile.open(tar_path) as tar, open(os.path.join(out, "refs.tsv"), "w", encoding="utf-8") as refs:
    for member in tar:
        name = os.path.basename(member.name)
        if name not in wanted:
            continue
        data = tar.extractfile(member).read()
        wav = name.rsplit(".", 1)[0] + ".wav"
        subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", "pipe:0", "-ar", "16000", "-ac", "1",
                        "-c:a", "pcm_s16le", os.path.join(out, wav)], input=data, check=True)
        total += (os.path.getsize(os.path.join(out, wav)) - 44) / 32000
        refs.write(f"{wav}\t{wanted[name]}\n")
open(os.path.join(out, "audio_seconds"), "w").write(f"{total:.1f}")
print(f"{len(wanted)} clips wanted, audio seconds {total:.1f}")
