#!/usr/bin/env python3
"""Transcribes every WAV in a folder with a sherpa-onnx NeMo CTC model, writing <wav>.txt.

Usage: sherpa_transcribe.py <model.onnx> <tokens.txt> <clips dir> <feature dim>
"""
import glob
import sys
import wave

import numpy as np
import sherpa_onnx

model, tokens, clips, feature_dim = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
recognizer = sherpa_onnx.OfflineRecognizer.from_nemo_ctc(
    model=model, tokens=tokens, num_threads=4, sample_rate=16000, feature_dim=feature_dim,
    decoding_method="greedy_search")
for path in sorted(glob.glob(f"{clips}/*.wav")):
    with wave.open(path) as w:
        samples = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32768
    stream = recognizer.create_stream()
    stream.accept_waveform(16000, samples)
    recognizer.decode_stream(stream)
    text = stream.result.text
    open(path + ".txt", "w", encoding="utf-8").write(text)
    print(text)
