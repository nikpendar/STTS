#!/usr/bin/env python3
"""Cuts the silence before and after the speech of each clip, with no margin: a word said the
moment the microphone opens and a recording stopped right after the last word (short-eval.yml).

Usage: trim_clips.py <in dir> <out dir>  (16 kHz 16-bit mono WAVs; refs.tsv is copied)
Speech: 10 ms frames within 35 dB of the clip's loudest frame.
"""
import array
import math
import os
import shutil
import sys
import wave

src, dst = sys.argv[1:]
os.makedirs(dst, exist_ok=True)
shutil.copy(os.path.join(src, "refs.tsv"), os.path.join(dst, "refs.tsv"))
cut = 0.0
for name in sorted(os.listdir(src)):
    if not name.endswith(".wav"):
        continue
    with wave.open(os.path.join(src, name)) as w:
        pcm = array.array("h", w.readframes(w.getnframes()))
    frame = 160
    rms = [math.sqrt(sum(x * x for x in pcm[i:i + frame]) / frame) for i in range(0, len(pcm) - frame + 1, frame)]
    if not rms:
        continue
    floor = max(rms) * 10 ** (-35 / 20)
    voiced = [i for i, r in enumerate(rms) if r >= floor]
    a, b = voiced[0] * frame, (voiced[-1] + 1) * frame
    cut += (len(pcm) - (b - a)) / 16000
    with wave.open(os.path.join(dst, name), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(16000)
        w.writeframes(pcm[a:b].tobytes())
print(f"{dst}: {cut:.1f} s of silence cut")
