#!/usr/bin/env python3
"""Transcribes every WAV in a folder with a Shenava cache-aware streaming CTC Core ML step, writing <wav>.txt.

Usage: shenava_stream.py <model dir> <clips dir> <compute units: cpu|all> <out timing.json>

The model dir is a snapshot of a Reza2kn/Shenava-*-CoreML-iOS15-fp16 repo. Audio is fed the way an app
would stream it: log-mel features (NeMo AudioToMelSpectrogramPreprocessor, see preprocessor.json), then one
Core ML prediction per 8 new feature frames (80 ms) with a 9-frame pre-encode cache and the encoder caches
carried between steps. Greedy CTC over the per-step logits.
"""
import glob
import json
import sys
import time
import wave

import coremltools as ct
import numpy as np

model_dir, clips, units, timing_out = sys.argv[1:]
pre = json.load(open(f"{model_dir}/preprocessor.json"))
manifest = json.load(open(glob.glob(f"{model_dir}/*_manifest.json")[0]))
vocab = json.load(open(f"{model_dir}/tokens.json"))
tokens, blank = vocab["tokens"], vocab["blank_id"]
mel = np.array(json.load(open(f"{model_dir}/{pre['mel_filters_file']}")), dtype=np.float64)  # [80, 257]

n_fft, win, hop = pre["n_fft"], pre["win_length"], pre["hop_length"]
i = np.arange(win)
window = np.zeros(n_fft)
window[(n_fft - win) // 2:(n_fft - win) // 2 + win] = 0.5 - 0.5 * np.cos(2 * np.pi * i / (win - 1))
guard = pre["log_zero_guard_value"]


def features(audio: np.ndarray) -> np.ndarray:
    x = np.concatenate([audio[:1], audio[1:] - pre["preemphasis"] * audio[:-1]]).astype(np.float64)
    x = np.pad(x, n_fft // 2, mode="reflect")
    frames = 1 + (len(x) - n_fft) // hop
    idx = np.arange(n_fft)[None, :] + hop * np.arange(frames)[:, None]
    spec = np.abs(np.fft.rfft(x[idx] * window, n=n_fft)) ** 2  # [T, 257]
    return np.log(spec @ mel.T + guard).T.astype(np.float32)  # [80, T]


ins = manifest["inputs"]
frames_in = ins["processed_signal"][2]
shift = manifest["shift_size"]
keep = frames_in - shift  # pre-encode cache frames
units_enum = ct.ComputeUnit.CPU_ONLY if units == "cpu" else ct.ComputeUnit.ALL
t0 = time.time()
model = ct.models.MLModel(glob.glob(f"{model_dir}/*.mlmodel")[0], compute_units=units_enum)
load_s = time.time() - t0
special = {k for k, t in enumerate(tokens) if t.startswith("<") and t.endswith(">")}


def transcribe(audio: np.ndarray, step_times: list) -> str:
    feats = features(audio)
    total = feats.shape[1]
    pad = (-total) % shift
    feats = np.pad(feats, ((0, 0), (keep, pad)), constant_values=pre["pad_value"])
    cache_ch = np.zeros(ins["cache_last_channel"], dtype=np.float32)
    cache_t = np.zeros(ins["cache_last_time"], dtype=np.float32)
    out, prev = [], blank
    for start in range(0, feats.shape[1] - keep, shift):
        chunk = feats[None, :, start:start + frames_in]
        s = time.perf_counter()
        pred = model.predict({"processed_signal": chunk, "cache_last_channel": cache_ch, "cache_last_time": cache_t})
        step_times.append(time.perf_counter() - s)
        cache_ch, cache_t = pred["cache_last_channel_next"], pred["cache_last_time_next"]
        logits = np.asarray(pred["logits"])
        for k in logits.reshape(-1, logits.shape[-1]).argmax(-1):
            k = int(k)
            if k != prev and k != blank and k not in special:
                out.append(tokens[k])
            prev = k
    return "".join(out).replace("▁", " ").strip()


# Warm-up so the first clip does not carry model compilation.
transcribe(np.zeros(16000, dtype=np.float32), [])
step_times, audio_s = [], 0.0
for path in sorted(glob.glob(f"{clips}/*.wav")):
    with wave.open(path) as w:
        audio = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32768
    audio_s += len(audio) / 16000
    text = transcribe(audio, step_times)
    open(path + ".txt", "w", encoding="utf-8").write(text)
    print(text, flush=True)

st = np.array(step_times) * 1000
timing = {
    "units": units, "load_s": round(load_s, 2), "steps": len(st), "audio_s": round(audio_s, 1),
    "step_ms_mean": round(float(st.mean()), 2), "step_ms_p95": round(float(np.percentile(st, 95)), 2),
    "step_ms_max": round(float(st.max()), 2), "rtf": round(float(st.sum() / 1000 / audio_s), 4),
    "audio_ms_per_step": shift * hop * 1000 // pre["sample_rate"],
}
json.dump(timing, open(timing_out, "w"))
print("TIMING " + json.dumps(timing))
