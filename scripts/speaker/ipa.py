"""Persian text as the IPA the app's voice gets (Homo-GE2PE greedy, the Ezafe tagger, exceptions,
stress rules): the same steps as PersianPhonemizer.sentences, for training labels.
ipa.Phonemizer(VOICE_DIR, EZAFE_DIR).ipa(text); VOICE_DIR has g2p-*.onnx, EZAFE_DIR hf/tokenizer.json
and model.int8.onnx (release tts-fa-ezafe)."""
import os, re, sys
import numpy as np, onnxruntime as ort
from num2fawords import words as fa_words
from tokenizers import Tokenizer

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from tts_phonemes import ipa_word, with_exceptions, latin_runs, LETTERS, with_ezafe, aligned

PUNCT = {".": ".", "!": "!", "?": "?", "؟": "?", "،": ",", ",": ",", ";": ",", "؛": ",", ":": ","}


def clean(s):
    out = ""
    for ch in s:
        v = ord(ch)
        if 0x0621 <= v <= 0x063A or 0x0641 <= v <= 0x064A or v in (0x067E, 0x0686, 0x0698, 0x06A9, 0x06AF, 0x06CC, 0x06C0, 0x0622, 0x200C):
            out += ch
        elif out and out[-1] != " " and not (0x064B <= v <= 0x0652) and v != 0x0640:
            out += " "
    return out.strip()


def split(t, marks):
    p, cur = [], ""
    for c in t:
        cur += c
        if c in marks: p.append(cur); cur = ""
    p.append(cur)
    return [x for x in p if x.strip()]


def spell(n):
    w = fa_words(n).replace("یکصد", "صد")
    return w[3:] if w.startswith("یک هزار") else w


class Phonemizer:
    def __init__(self, voice, ezafe):
        self.enc = ort.InferenceSession(f"{voice}/g2p-encoder.onnx")
        self.dec = ort.InferenceSession(f"{voice}/g2p-decoder.onnx")
        self.tok = Tokenizer.from_file(f"{ezafe}/hf/tokenizer.json")
        self.ez = ort.InferenceSession(f"{ezafe}/model.int8.onnx")

    def g2p(self, text):
        text = text.replace("ی", "ي").replace("ى", "ي").replace("ك", "ک").replace("ۀ", "ه")
        b = [x + 3 for x in text.encode()]
        if not b: return ""
        h = self.enc.run(None, {"input_ids": np.array([b], dtype=np.int64)})[0]
        o = [0]
        while len(o) < 4 * len(b) + 16:
            n = int(self.dec.run(None, {"decoder_input_ids": np.array([o], dtype=np.int64), "encoder_hidden_states": h})[0][0].argmax())
            if n == 1: break
            o.append(n)
        return bytes(i - 3 for i in o[1:] if 3 <= i < 259).decode("utf-8", "replace").strip()

    def flags(self, words):
        e = self.tok.encode([w.replace("ي", "ی") for w in words], is_pretokenized=True)
        last = {w: i for i, w in enumerate(e.word_ids) if w is not None}
        x = np.array([e.ids], dtype=np.int64)
        lg = self.ez.run(None, {"input_ids": x, "attention_mask": np.ones_like(x)})[0][0]
        return [int(lg[last[i]].argmax()) if i in last else 0 for i in range(len(words))]

    def letters(self, text):
        """GE2PE letters per clause, with exceptions and the tagger's Ezafe: [(words, letters, mark)]."""
        text = text.translate(str.maketrans("۰۱۲۳۴۵۶۷۸۹٠١٢٣٤٥٦٧٨٩", "01234567890123456789"))
        text = re.sub(r"\d+", lambda m: " " + spell(int(m.group())) + " ", text)
        out = []
        for sent in split(text, ".!?؟\n"):
            for clause in split(sent, "،,;؛:"):
                mark = PUNCT.get(clause.rstrip()[-1:] if clause.rstrip() else "", "")
                ws, ps = [], []
                for latin, run in latin_runs(clause):
                    if latin:
                        ws += list(run.lower()); ps += [LETTERS[c] for c in run.lower()]
                        continue
                    w = clean(run).split()
                    for i in range(0, len(w), 24):
                        part = w[i:i + 24]
                        ph = self.g2p(" ".join(part)).split()
                        phs = with_exceptions(part, aligned(part, ph, self.g2p) or ph)
                        if len(phs) == len(part):
                            phs = [with_ezafe(x, f, g) for x, f, g in zip(phs, self.flags(part), part)]
                        else:
                            part = ["?"] * len(phs)
                        ws += part; ps += phs
                out.append((ws, ps, mark))
        return out

    @staticmethod
    def ipa_of(clauses, stress="rules"):
        ipa = ""
        for _, ps, mark in clauses:
            if ipa and not ipa.endswith(" "): ipa += " "
            ipa += " ".join(ipa_word(p, stress) for p in ps)
            if mark and ipa: ipa += mark
        return ipa.strip()
