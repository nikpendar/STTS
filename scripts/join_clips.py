#!/usr/bin/env python3
"""Joins every <n> consecutive test clips into one recording, as a long dictation.

Usage: join_clips.py <clips_dir> <n>. Rewrites <clips_dir> in place: the joined WAVs (16 kHz
mono PCM16), refs.tsv with the references joined, and audio_seconds. The clips keep their
own silence at either end, so the sentences are apart by a natural pause.
"""
import os
import sys
import wave

clips, n = sys.argv[1], int(sys.argv[2])
lines = [line.rstrip("\n").split("\t", 1) for line in open(f"{clips}/refs.tsv", encoding="utf-8")]
refs, total = [], 0.0
for g in range(0, len(lines) - n + 1, n):
    group = lines[g:g + n]
    frames = b""
    for name, _ in group:
        with wave.open(f"{clips}/{name}") as w:
            frames += w.readframes(w.getnframes())
    name = f"joined{g // n:03d}.wav"
    with wave.open(f"{clips}/{name}", "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(16000)
        out.writeframes(frames)
    total += len(frames) / 2 / 16000
    refs.append((name, " ".join(ref for _, ref in group)))
for name, _ in lines:
    os.remove(f"{clips}/{name}")
with open(f"{clips}/refs.tsv", "w", encoding="utf-8") as f:
    f.writelines(f"{name}\t{ref}\n" for name, ref in refs)
with open(f"{clips}/audio_seconds", "w") as f:
    f.write(f"{total:.1f}")
print(f"{len(refs)} recordings, {total:.0f} s")
