#!/usr/bin/env python3
"""Joins consecutive clips into paragraphs for the punctuation check (punct-speech.yml): N clips
of a folder (16 kHz mono 16-bit WAVs and refs.tsv: file, punctuated sentence) become one WAV
with 0.5 s of silence between them, and refs.tsv gets the sentences joined with a space.

Usage: punct_paragraphs.py <clips dir> <out dir> <clips per paragraph>
"""
import os
import sys
import wave

src, out, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
os.makedirs(out, exist_ok=True)
rows = [l.rstrip("\n").split("\t", 1) for l in open(os.path.join(src, "refs.tsv"), encoding="utf-8") if "\t" in l]
rows = [r for r in rows if os.path.exists(os.path.join(src, r[0]))]
silence = b"\x00\x00" * 8000
with open(os.path.join(out, "refs.tsv"), "w", encoding="utf-8") as refs:
    for p in range(0, len(rows) - n + 1, n):
        group = rows[p:p + n]
        name = f"p{p // n:03d}.wav"
        frames = []
        for file, _ in group:
            with wave.open(os.path.join(src, file)) as w:
                assert w.getframerate() == 16000 and w.getnchannels() == 1 and w.getsampwidth() == 2
                frames.append(w.readframes(w.getnframes()))
        with wave.open(os.path.join(out, name), "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(16000)
            w.writeframes(silence.join(frames))
        refs.write(name + "\t" + " ".join(s.strip() for _, s in group) + "\n")
print(f"{len(rows) // n} paragraphs of {n} clips")
