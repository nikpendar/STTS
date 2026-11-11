"""A/B listening test: Gooya RizehPizeh v2 (Reza2kn, MIT, Piper) with its Negara v7.1 G2P (Apache-2.0)
on the voice check's test sentences. Our own code, no files from those repos run as code.

usage: tts_gooya_ab.py GOOYA_DIR NEGARA_DIR SENTENCES_JSON OUT_DIR
Writes OUT_DIR/gooya-NN.wav per sentence, gooya-all.wav, and gooya-phonemes.txt.
"""
import json, os, sys, unicodedata, wave
import numpy as np
import onnxruntime as ort
import torch
from transformers import AutoModelForSeq2SeqLM, AutoTokenizer

gooya, negara, sentences, out = sys.argv[1:5]
os.makedirs(out, exist_ok=True)
tok = AutoTokenizer.from_pretrained(negara)
g2p = AutoModelForSeq2SeqLM.from_pretrained(negara).eval()
overlay = json.load(open(f"{negara}/overlay.json", encoding="utf-8"))
rules = {(r["surface"], r["raw"]): r["target"] for r in overlay["rules"]}
cfg = json.load(open(f"{gooya}/gooya-rizehpizeh-v2.onnx.json", encoding="utf-8"))
ids_map, inf, sr = cfg["phoneme_id_map"], cfg["inference"], cfg["audio"]["sample_rate"]
voice = ort.InferenceSession(f"{gooya}/gooya-rizehpizeh-v2.onnx")


def words(text):
    """Letters, marks, digits and ZWNJ runs (as the Negara script scans words)."""
    out, cur = [], ""
    for ch in text:
        if ch == "‌" or unicodedata.category(ch)[0] in "LMN":
            cur += ch
        elif cur:
            out.append(cur); cur = ""
    return out + ([cur] if cur else [])


def phones(text):
    ws = words(text)
    enc = tok(" ".join(ws), return_tensors="pt", add_special_tokens=False)
    with torch.inference_mode():
        ids = g2p.generate(**enc, max_new_tokens=512, num_beams=5, early_stopping=True)
    raw = tok.batch_decode(ids, skip_special_tokens=True)[0].strip().split()
    if len(raw) == len(ws):
        raw = [rules.get((w, p), p) for w, p in zip(ws, raw)]
    return " ".join(raw)


def ids_of(p):
    seq = [*np.atleast_1d(ids_map["^"]), *np.atleast_1d(ids_map["_"])]
    for ch in p:
        if ch in ids_map:
            seq += list(np.atleast_1d(ids_map[ch])) + list(np.atleast_1d(ids_map["_"]))
    return seq + list(np.atleast_1d(ids_map["$"]))


def write(path, audio):
    pcm = (np.clip(audio, -1, 1) * 32767).astype(np.int16)
    with wave.open(path, "wb") as f:
        f.setnchannels(1); f.setsampwidth(2); f.setframerate(sr); f.writeframes(pcm.tobytes())


texts = [r["text"] for r in json.load(open(sentences, encoding="utf-8"))]
every, lines = [], []
for n, text in enumerate(texts):
    p = phones(text)
    seq = ids_of(p)
    a = voice.run(None, {"input": np.array([seq], dtype=np.int64), "input_lengths": np.array([len(seq)], dtype=np.int64),
                         "scales": np.array([inf["noise_scale"], inf["length_scale"], inf["noise_w"]], dtype=np.float32)})[0].reshape(-1)
    a = a / max(0.01, float(np.abs(a).max())) * 0.9
    write(f"{out}/gooya-{n:02d}.wav", a)
    every += [a, np.zeros(int(sr * 0.5), dtype=np.float32)]
    lines.append(f"{text}\n  {p}")
    print(lines[-1], flush=True)
write(f"{out}/gooya-all.wav", np.concatenate(every))
open(f"{out}/gooya-phonemes.txt", "w", encoding="utf-8").write("\n".join(lines) + "\n")
