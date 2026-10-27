"""Shared helpers for the punctuation research: text to (words, labels), and scoring.

A label belongs to a word and says which mark follows it: 0 none, 1 comma (، ؛), 2 period (. !), 3 question (؟).
Words are what the speech model would write: no punctuation, quotes or brackets, Persian ی/ک, no diacritics.
"""
import re

LABELS = ["O", "COMMA", "PERIOD", "QUESTION"]
MARKS = {"،": 1, ",": 1, "؛": 1, ";": 1, ".": 2, "!": 2, "…": 2, "؟": 3, "?": 3}
SYMBOL = {1: "،", 2: ".", 3: "؟"}
DROP = set("«»\"“”'‘’()[]{}<>:*_–—-/\\|") | set(MARKS)
_CHARS = str.maketrans({"ي": "ی", "ى": "ی", "ك": "ک", "ـ": None, "‏": None, "‎": None})
_DIACRITICS = re.compile("[ً-ْٰ]")
PERSIAN = re.compile("[؀-ۿ]")


def normalize(text):
    return _DIACRITICS.sub("", text.translate(_CHARS))


def label_text(text):
    """Punctuated text -> (words, labels); a mark standing alone labels the word before it."""
    words, labels = [], []
    for raw in normalize(text).split():
        # Marks at the end of a token label it; marks inside (e.g. 12.5) stay part of the word.
        mark = 0
        core = raw
        while core and core[-1] in DROP:
            mark = max(mark, MARKS.get(core[-1], 0))
            core = core[:-1]
        core = core.lstrip("".join(DROP))
        core = "".join(c for c in core if c not in "«»\"“”()[]{}")
        if core:
            words.append(core)
            labels.append(mark)
        elif words and mark:
            labels[-1] = max(labels[-1], mark)
    return words, labels


def render(words, labels):
    return " ".join(w + SYMBOL.get(l, "") for w, l in zip(words, labels))


def score(pairs):
    """pairs: iterable of (gold labels, predicted labels). Returns per-class and micro P/R/F1 (percent)."""
    tp = [0] * 4; fp = [0] * 4; fn = [0] * 4
    tp_in = [0] * 4; fp_in = [0] * 4; fn_in = [0] * 4
    exact = n = 0
    for gold, pred in pairs:
        n += 1
        exact += list(gold) == list(pred)
        last = len(gold) - 1
        for i, (g, p) in enumerate(zip(gold, pred)):
            for c in (1, 2, 3):
                hit = (g == c) + 2 * (p == c)
                if not hit:
                    continue
                arr = (tp if hit == 3 else fn if hit == 1 else fp)
                arr[c] += 1
                if i != last:
                    (tp_in if hit == 3 else fn_in if hit == 1 else fp_in)[c] += 1

    def prf(t, f_p, f_n):
        p = t / (t + f_p) if t + f_p else 0.0
        r = t / (t + f_n) if t + f_n else 0.0
        return round(100 * p, 1), round(100 * r, 1), round(100 * 2 * p * r / (p + r), 1) if p + r else 0.0

    out = {LABELS[c]: prf(tp[c], fp[c], fn[c]) for c in (1, 2, 3)}
    out["micro"] = prf(sum(tp), sum(fp), sum(fn))
    out["inner_period"] = prf(tp_in[2], fp_in[2], fn_in[2])
    out["support"] = {LABELS[c]: tp[c] + fn[c] for c in (1, 2, 3)}
    out["exact"] = round(100 * exact / max(n, 1), 1)
    out["n"] = n
    return out


def f1_line(name, s):
    return (f"{name}: comma F1 {s['COMMA'][2]} (P {s['COMMA'][0]} R {s['COMMA'][1]}), period F1 {s['PERIOD'][2]}, "
            f"inner period F1 {s['inner_period'][2]}, question F1 {s['QUESTION'][2]} (P {s['QUESTION'][0]} R {s['QUESTION'][1]}), "
            f"micro F1 {s['micro'][2]}, exact {s['exact']}% of {s['n']}, support {s['support']}")
