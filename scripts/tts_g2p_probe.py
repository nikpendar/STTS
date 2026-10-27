"""Persian TTS groundwork: phonemizes test sentences with Homo-GE2PE (MIT, a small ByT5 model) and
eSpeak, maps the GE2PE phoneme letters to the eSpeak IPA symbols the Mana Piper voice was trained on,
and synthesizes each sentence with several stress variants for listening.

    python3 scripts/tts_g2p_probe.py G2P_DIR VOICE.onnx VOICE.onnx.json OUT_DIR
"""
import json, os, re, subprocess, sys, time, wave
from collections import Counter

import numpy as np
import onnxruntime as ort

sys.path.insert(0, os.path.join(sys.argv[1], "assets"))
from GE2PE import GE2PE  # noqa: E402

G2P_DIR, VOICE, CONFIG, OUT = sys.argv[1:5]
os.makedirs(OUT, exist_ok=True)

sys.path.insert(0, os.path.dirname(__file__))
from tts_g2p_probe_sentences import SENTENCES  # noqa: E402

# GE2PE letters -> eSpeak IPA (as Piper's phoneme_id_map spells them).
MAP = {
    "a": "ɑ", "/": "a", "e": "e", "o": "o", "i": "i", "u": "u",
    "@": "ʔ", "?": "ʔ", "C": "tʃ", "S": "ʃ", "Z": "ʒ", "j": "dʒ", "y": "j", "q": "q", "x": "x",
    "g": "ɡ", "b": "b", "p": "p", "t": "t", "d": "d", "k": "k", "f": "f", "v": "v", "s": "s",
    "z": "z", "h": "h", "m": "m", "n": "n", "l": "l", "r": "r", " ": " ",
}
VOWELS = set("ɑaeoiu")


def ipa_word(word, stress):
    """One GE2PE word (with a trailing 1 for Ezafe) as eSpeak-style IPA, stressed per `stress`."""
    ezafe = word.endswith("1")
    word = word.rstrip("1")
    body = "".join(MAP.get(c, "") for c in word)
    if stress != "none":
        # Vowel positions; Persian stress is mostly on the last syllable of the word itself
        # (before the Ezafe), and on the prefix mi-/ne-/be- of a verb.
        vows = [i for i, c in enumerate(body) if c in VOWELS]
        if vows:
            target = vows[-1]
            if stress == "rules" and re.match(r"^(mi|nemi|ne|be|na)[^ɑaeoiu]", body) and len(vows) > 1:
                target = vows[0]
            # The stress mark goes before the syllable's onset consonant, like eSpeak writes it.
            start = target - 1 if target > 0 and body[target - 1] not in VOWELS else target
            body = body[:start] + "ˈ" + body[start:]
    if ezafe:
        body += "je" if body and body[-1] in VOWELS else "e"
    return body


def to_ids(ipa, id_map):
    ids = id_map["^"] + id_map["_"]
    missing = Counter()
    for ch in ipa:
        if ch in id_map:
            ids += id_map[ch] + id_map["_"]
        else:
            missing[ch] += 1
    return ids + id_map["$"], missing


def main():
    cfg = json.load(open(CONFIG))
    id_map = cfg["phoneme_id_map"]
    print("ID MAP KEYS", " ".join(sorted(id_map)))
    inf = cfg["inference"]
    sess = ort.InferenceSession(VOICE, providers=["CPUExecutionProvider"])
    rate = cfg["audio"]["sample_rate"]

    t = time.perf_counter()
    g2p = GE2PE(model_path=os.path.join(G2P_DIR, "homo-ge2pe"))
    print(f"G2P load {time.perf_counter() - t:.1f} s, params {sum(p.numel() for p in g2p.model.parameters())/1e6:.1f} M")
    t = time.perf_counter()
    beam = g2p.generate(SENTENCES, use_rules=True)
    print(f"G2P beam5 {1000 * (time.perf_counter() - t) / len(SENTENCES):.0f} ms/sentence")
    # Greedy, the cheaper decoding for the phone.
    norm = [g2p.norma.normalize(s).replace("ك", "ک") for s in SENTENCES]
    t = time.perf_counter()
    enc = g2p.tokenizer(norm, padding=True, add_special_tokens=False, return_tensors="pt")
    out = g2p.model.generate(enc["input_ids"], attention_mask=enc["attention_mask"], num_beams=1, max_length=512)
    greedy = [s.strip() for s in g2p.tokenizer.batch_decode(out, skip_special_tokens=True)]
    print(f"G2P greedy {1000 * (time.perf_counter() - t) / len(SENTENCES):.0f} ms/sentence")
    # Without the Parsivar normalizer (the phone has none).
    enc = g2p.tokenizer(SENTENCES, padding=True, add_special_tokens=False, return_tensors="pt")
    out = g2p.model.generate(enc["input_ids"], attention_mask=enc["attention_mask"], num_beams=1, max_length=512)
    raw = [s.strip() for s in g2p.tokenizer.batch_decode(out, skip_special_tokens=True)]

    letters = Counter()
    for i, s in enumerate(SENTENCES):
        es = subprocess.run(["espeak-ng", "-q", "-v", "fa", "--ipa", s], capture_output=True, text=True).stdout.strip()
        print(f"\nS{i}: {s}\n  NORM   {norm[i]}\n  BEAM   {beam[i]}\n  GREEDY {greedy[i]}\n  RAW    {raw[i]}\n  ESPEAK {es}")
        letters.update(beam[i])
        for stress in ("none", "final", "rules"):
            ipa = " ".join(ipa_word(w, stress) for w in beam[i].split())
            ids, missing = to_ids(ipa, id_map)
            if stress == "rules":
                print(f"  IPA    {ipa}" + (f"  MISSING {dict(missing)}" if missing else ""))
            audio = sess.run(None, {
                "input": np.array([ids], dtype=np.int64),
                "input_lengths": np.array([len(ids)], dtype=np.int64),
                "scales": np.array([inf["noise_scale"], inf["length_scale"], inf["noise_w"]], dtype=np.float32),
            })[0].squeeze()
            audio = np.clip(audio / max(0.01, np.abs(audio).max()) * 32767 * 0.9, -32768, 32767).astype(np.int16)
            with wave.open(os.path.join(OUT, f"mana-g2p-{stress}-{i}.wav"), "wb") as w:
                w.setnchannels(1); w.setsampwidth(2); w.setframerate(rate); w.writeframes(audio.tobytes())
    print("\nGE2PE LETTERS", sorted(letters.items()))
    print("UNMAPPED", sorted(c for c in letters if c not in MAP and c != "1"))


main()
