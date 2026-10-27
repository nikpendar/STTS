"""Builds the app's Persian voice files (release tts-fa-mana):

    g2p-encoder.onnx, g2p-decoder.onnx  Homo-GE2PE (MahtaFetrat, MIT), a small ByT5 that writes
                                        Persian text as phonemes with Ezafe and homographs, int8
    mana.onnx, mana.onnx.json           Mana Persian Piper voice (MahtaFetrat, MIT), int8
    tts-reference.json                  phonemes and eSpeak-style IPA for the test sentences, which
                                        the app's Swift port is checked against

The decoder runs without a cache: it reads the whole output so far at every step, which for a
2-layer model and one sentence at a time costs little and keeps the app's loop simple. The app
feeds the model the text as the Parsivar normalizer leaves it for these sentences: Persian ی as
Arabic ي, ك as ک, ZWNJ kept, punctuation and diacritics dropped; this script checks that this gives
the same phonemes as Parsivar.

    python3 scripts/tts_export.py G2P_DIR VOICE.onnx VOICE.onnx.json OUT_DIR
"""
import json, os, shutil, sys, time

import numpy as np
import onnxruntime as ort
import torch
from onnxruntime.quantization import QuantType, quantize_dynamic
from transformers import AutoTokenizer, T5ForConditionalGeneration

sys.path.insert(0, os.path.dirname(__file__))
from tts_g2p_probe_sentences import SENTENCES  # noqa: E402
from tts_phonemes import ipa_word  # noqa: E402

G2P_DIR, VOICE, CONFIG, OUT = sys.argv[1:5]
os.makedirs(OUT, exist_ok=True)

model = T5ForConditionalGeneration.from_pretrained(os.path.join(G2P_DIR, "homo-ge2pe")).eval()
tok = AutoTokenizer.from_pretrained(os.path.join(G2P_DIR, "homo-ge2pe"))


class Encoder(torch.nn.Module):
    def __init__(self, m):
        super().__init__()
        self.m = m

    def forward(self, input_ids):
        return self.m.encoder(input_ids=input_ids).last_hidden_state


class Decoder(torch.nn.Module):
    def __init__(self, m):
        super().__init__()
        self.m = m

    def forward(self, decoder_input_ids, encoder_hidden_states):
        h = self.m.decoder(input_ids=decoder_input_ids, encoder_hidden_states=encoder_hidden_states).last_hidden_state
        # Only the last position's logits are needed.
        return self.m.lm_head(h[:, -1, :])


def export():
    ids = torch.tensor([[50, 60, 70]])
    hidden = Encoder(model)(ids)
    for name, module, args, inputs, axes in (
        ("g2p-encoder", Encoder(model), (ids,), ["input_ids"], {"input_ids": {1: "n"}, "hidden": {1: "n"}}),
        ("g2p-decoder", Decoder(model), (torch.tensor([[0, 50]]), hidden), ["decoder_input_ids", "encoder_hidden_states"],
         {"decoder_input_ids": {1: "t"}, "encoder_hidden_states": {1: "n"}}),
    ):
        fp32 = os.path.join(OUT, f"{name}-fp32.onnx")
        torch.onnx.export(module, args, fp32, input_names=inputs, output_names=["hidden" if name.endswith("encoder") else "logits"],
                          dynamic_axes=axes, opset_version=17, dynamo=False)
        quantize_dynamic(fp32, os.path.join(OUT, f"{name}.onnx"), weight_type=QuantType.QInt8)
        os.remove(fp32)


def app_text(s):
    """What the app feeds the G2P model (PersianPhonemizer.clean and modelText): Persian letters,
    ZWNJ and single spaces; Arabic yeh, Persian kaf."""
    out = ""
    for ch in s:
        v = ord(ch)
        if 0x0621 <= v <= 0x063A or 0x0641 <= v <= 0x064A or v in (0x067E, 0x0686, 0x0698, 0x06A9, 0x06AF, 0x06CC, 0x06C0, 0x0622, 0x200C):
            out += ch
        elif out and out[-1] != " " and not (0x064B <= v <= 0x0652) and v != 0x0640:
            out += " "
    out = out.strip()
    return out.replace("ی", "ي").replace("ى", "ي").replace("ك", "ک").replace("ۀ", "ه")


def to_ids(s):
    # ByT5: UTF-8 bytes shifted by 3 (0 pad, 1 end, 2 unknown); no end token on the input.
    return [b + 3 for b in s.encode("utf-8")]


def onnx_greedy(enc, dec, text, max_len=400):
    hidden = enc.run(None, {"input_ids": np.array([to_ids(text)], dtype=np.int64)})[0]
    out = [0]
    while len(out) < max_len:
        logits = dec.run(None, {"decoder_input_ids": np.array([out], dtype=np.int64), "encoder_hidden_states": hidden})[0]
        nxt = int(logits[0].argmax())
        if nxt == 1:
            break
        out.append(nxt)
    return bytes(i - 3 for i in out[1:] if i >= 3).decode("utf-8", "replace").strip()


def torch_greedy(text):
    enc = tok([text], add_special_tokens=False, return_tensors="pt")
    out = model.generate(enc["input_ids"], num_beams=1, max_length=512)
    return tok.batch_decode(out, skip_special_tokens=True)[0].strip()


def main():
    export()
    enc = ort.InferenceSession(os.path.join(OUT, "g2p-encoder.onnx"))
    dec = ort.InferenceSession(os.path.join(OUT, "g2p-decoder.onnx"))
    sys.path.insert(0, os.path.join(G2P_DIR, "assets"))
    cwd = os.getcwd()
    os.chdir(os.path.join(G2P_DIR, "assets"))
    from Parsivar.normalizer import Normalizer
    norma = Normalizer(pinglish_conversion_needed=True)
    os.chdir(cwd)

    reference, same_norm, same_quant, ms = [], 0, 0, []
    for s in SENTENCES:
        text = app_text(s)
        t = time.perf_counter()
        phon = onnx_greedy(enc, dec, text)
        ms.append(1000 * (time.perf_counter() - t))
        ref = torch_greedy(norma.normalize(s).replace("ك", "ک"))
        same_norm += torch_greedy(text) == ref
        same_quant += phon == ref
        print(f"{s}\n  int8 {phon}\n  fp32 {ref}")
        reference.append({"text": s, "phonemes": phon, "ipa": " ".join(ipa_word(w, "rules") for w in phon.split())})
    print(f"app text = Parsivar: {same_norm}/{len(SENTENCES)}; int8 ONNX = fp32 torch: {same_quant}/{len(SENTENCES)}; "
          f"ONNX greedy {np.mean(ms):.0f} ms/sentence")
    json.dump(reference, open(os.path.join(OUT, "tts-reference.json"), "w"), ensure_ascii=False, indent=1)

    quantize_dynamic(VOICE, os.path.join(OUT, "mana.onnx"), weight_type=QuantType.QUInt8)
    shutil.copy(CONFIG, os.path.join(OUT, "mana.onnx.json"))
    for f in sorted(os.listdir(OUT)):
        print(f"FILE {f} {os.path.getsize(os.path.join(OUT, f)) / 1e6:.1f} MB")


main()
