#!/usr/bin/env python3
"""Cuts a recording of 28 s or more into pieces at pauses, as the app does
(Transcriber.pieces): each piece ends at the latest pause in the next 28 s, leaving at least
3 s for the next piece, so Whisper never runs a second 30 s window over the tail.

Usage: split_long.py <in.wav> <out_prefix> [longest seconds, 28]. Writes <out_prefix>.<i>.wav
and prints their paths.
"""
import array
import sys
import wave

RATE = 16000
FRAME = RATE // 10
LONGEST = int(float(sys.argv[3]) * RATE) if len(sys.argv) > 3 else 28 * RATE
SHORTEST = 3 * RATE


def pause(samples):
    """AudioLoader.pause(in:): the latest pause after 6 s, else the quietest point
    between 10 and 20 s once the audio is 20 s long."""
    levels = []
    for start in range(0, len(samples) - FRAME + 1, FRAME):
        chunk = samples[start:start + FRAME]
        levels.append((sum(x * x for x in chunk) / FRAME) ** 0.5)
    if len(levels) <= 64:
        return None
    quiet = sum(levels) / len(levels) / 3
    for i in range(len(levels) - 3, 60, -1):
        if levels[i - 1] < quiet and levels[i] < quiet and levels[i + 1] < quiet:
            return i * FRAME + FRAME // 2
    if len(levels) < 200:
        return None
    quietest = min(range(100, 200), key=lambda i: levels[i])
    return quietest * FRAME + FRAME // 2


def pieces(samples):
    out, start = [], 0
    while len(samples) - start >= LONGEST:
        window = min(LONGEST, len(samples) - start - SHORTEST)
        cut = pause(samples[start:start + window]) or min(20 * RATE, window)
        out.append((start, start + cut))
        start += cut
    out.append((start, len(samples)))
    return out


src, prefix = sys.argv[1:3]
with wave.open(src) as w:
    samples = array.array("h", w.readframes(w.getnframes()))
floats = [x / 32768 for x in samples]
for i, (a, b) in enumerate(pieces(floats)):
    path = f"{prefix}.{i}.wav"
    with wave.open(path, "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(RATE)
        out.writeframes(samples[a:b].tobytes())
    print(path)
