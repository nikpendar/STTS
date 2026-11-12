#!/usr/bin/env python3
"""Streams each clip of a set through a sherpa-onnx transducer, chunk by chunk as a microphone
would, and writes <clip>.wav.txt next to it (nemotron-eval.yml).

Usage: sherpa_eval.py <model dir> <clip dir> <threads>
Prints one JSON line: audio seconds, decode seconds, peak memory in MB.
"""
import json
import os
import resource
import sys
import time
import wave

import numpy as np
import sherpa_onnx

model, clips, threads = sys.argv[1], sys.argv[2], int(sys.argv[3])
rec = sherpa_onnx.OnlineRecognizer.from_transducer(
    tokens=f"{model}/tokens.txt",
    encoder=f"{model}/encoder.int8.onnx",
    decoder=f"{model}/decoder.int8.onnx",
    joiner=f"{model}/joiner.int8.onnx",
    num_threads=threads,
    sample_rate=16000,
    feature_dim=128,
    decoding_method="greedy_search",
)
audio = spent = 0.0
for line in open(os.path.join(clips, "refs.tsv"), encoding="utf-8"):
    name = line.split("\t", 1)[0]
    with wave.open(os.path.join(clips, name)) as w:
        samples = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32768
    audio += len(samples) / 16000
    start = time.perf_counter()
    stream = rec.create_stream()
    stream.set_option("language", "fa-IR")
    # Silence before (the card: the first word can be dropped without it) and after.
    stream.accept_waveform(16000, np.zeros(8000, dtype=np.float32))
    for i in range(0, len(samples), 1600):
        stream.accept_waveform(16000, samples[i:i + 1600])
        while rec.is_ready(stream):
            rec.decode_stream(stream)
    stream.accept_waveform(16000, np.zeros(19200, dtype=np.float32))
    stream.input_finished()
    while rec.is_ready(stream):
        rec.decode_stream(stream)
    text = rec.get_result(stream)
    spent += time.perf_counter() - start
    with open(os.path.join(clips, name + ".txt"), "w", encoding="utf-8") as out:
        out.write(text.strip())
peak = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024
print(json.dumps({"set": clips, "audio_s": round(audio, 1), "decode_s": round(spent, 1),
                  "rtf": round(spent / max(audio, 1e-9), 3), "peak_mb": round(peak)}))
