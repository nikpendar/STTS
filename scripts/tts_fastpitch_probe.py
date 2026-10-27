"""Persian TTS comparison: SadeghK's FastPitch + HiFi-GAN (Apache-2.0) on the same sentences as
tts_g2p_probe.py, with its own Persian phonemizer from the NeMo fork, fp32 and int8: size, speed
(real-time factor, 1 thread) and WAV files for listening.

    python3 scripts/tts_fastpitch_probe.py FASTPITCH.onnx HIFIGAN.onnx DICT OUT_DIR
"""
import os, sys, time, wave

import numpy as np
import onnxruntime as ort
from onnxruntime.quantization import QuantType, quantize_dynamic

from nemo.collections.tts.g2p.models.fa_ir_persian.g2p import PersianG2p
from nemo.collections.tts.g2p.models.fa_ir_persian.normalizer import PersianNormalizer
from nemo.collections.tts.g2p.models.fa_ir_persian.tokenizer import PersianPhonemesTokenizer

sys.path.insert(0, os.path.dirname(__file__))
FP, HG, DICT, OUT = sys.argv[1:5]
os.makedirs(OUT, exist_ok=True)

# The same sentences as tts_g2p_probe.py.
from tts_g2p_probe_sentences import SENTENCES  # noqa: E402

normalizer = PersianNormalizer()
g2p = PersianG2p(phoneme_dict=DICT)
tokenizer = PersianPhonemesTokenizer(g2p=g2p, use_emotion_tokens=True, use_pause_tokens=True, use_speed_tokens=True)

variants = {"fp32": (FP, HG)}
for name, path in (("fp", FP), ("hg", HG)):
    quantize_dynamic(path, f"{path}.int8.onnx", weight_type=QuantType.QUInt8)
variants["int8"] = (f"{FP}.int8.onnx", f"{HG}.int8.onnx")

for variant, (fp, hg) in variants.items():
    size = (os.path.getsize(fp) + os.path.getsize(hg)) / 1e6
    so = ort.SessionOptions(); so.intra_op_num_threads = 1
    fps = ort.InferenceSession(fp, so, providers=["CPUExecutionProvider"])
    hgs = ort.InferenceSession(hg, so, providers=["CPUExecutionProvider"])
    print(f"===== fastpitch {variant} size {size:.1f} MB, inputs {[i.name for i in fps.get_inputs()]}")
    comp = audio_s = 0.0
    for i, s in enumerate(SENTENCES):
        text = normalizer.normalize(s)
        ids = tokenizer.encode(text)
        if variant == "fp32":
            print(f"S{i}: {text}\n  PHON {g2p(text) if callable(g2p) else ''}")
        t = time.perf_counter()
        mel = fps.run(None, {"text": np.array([ids], dtype=np.int64)})[0]
        audio = hgs.run(None, {"mel_spec": mel})[0].squeeze()
        comp += time.perf_counter() - t
        audio_s += len(audio) / 22050
        pcm = np.clip(audio / max(0.01, np.abs(audio).max()) * 32767 * 0.9, -32768, 32767).astype(np.int16)
        with wave.open(os.path.join(OUT, f"fastpitch-{variant}-{i}.wav"), "wb") as w:
            w.setnchannels(1); w.setsampwidth(2); w.setframerate(22050); w.writeframes(pcm.tobytes())
    print(f"RTF fastpitch {variant} threads=1 {comp / audio_s:.3f} (audio {audio_s:.1f} s)")
