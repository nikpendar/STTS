"""Homo-GE2PE phonemes as the eSpeak-style IPA the Mana Piper voice was trained on; the app's
PersianPhonemes.swift does the same."""
import re

# GE2PE letters -> eSpeak IPA (as Piper's phoneme_id_map spells them).
MAP = {
    "a": "ɑ", "/": "a", "e": "e", "o": "o", "i": "i", "u": "u",
    "@": "ʔ", "?": "ʔ", "c": "tʃ", "C": "tʃ", "$": "ʃ", "S": "ʃ", "Z": "ʒ", "j": "dʒ", "y": "j", "q": "q", "x": "x",
    "g": "ɡ", "b": "b", "p": "p", "t": "t", "d": "d", "k": "k", "f": "f", "v": "v", "s": "s",
    "z": "z", "h": "h", "m": "m", "n": "n", "l": "l", "r": "r", " ": " ",
}
VOWELS = set("ɑaeoiu")


def is_prefixed_verb(body, vowels):
    """A verb with mi-, nemi-, be-, ne- or na- (stressed there): a personal or past ending
    (می‌رسم، نکرد), or a short imperative (بگو، بزن). Not میلیون، بهترین، نمونه، بدون."""
    if not re.match(r"^(mi|nemi|ne|be|na)[^ɑaeoiu]", body):
        return False
    if re.search(r"(am|i|im|d|t)$", body):
        return True
    return vowels <= 2 and not re.search(r"(in|un|e|ɑ)$", body)


def ipa_word(word, stress):
    """One GE2PE word as eSpeak-style IPA, stressed per `stress`. Greedy GE2PE output marks the
    Ezafe with a 1 after the word's e or ye; eSpeak, which the voice learned from, writes no glottal
    stop at the start of a word."""
    ezafe = ""
    if word.endswith("1"):
        word = word[:-1]
        if word.endswith("ye") and len(word) > 2:
            word, ezafe = word[:-2], "je"
        elif word.endswith("e"):
            word, ezafe = word[:-1], "e"
    if word.startswith("@"):
        word = word[1:]
    body = "".join(MAP.get(c, "") for c in word)
    if stress != "none":
        # Persian stress is mostly on the last syllable of the word itself (not the Ezafe), and on
        # the prefix mi-/ne-/be- of a verb.
        vows = [i for i, c in enumerate(body) if c in VOWELS]
        if vows:
            target = vows[-1]
            if stress == "rules" and len(vows) > 1 and is_prefixed_verb(body, len(vows)):
                target = vows[0]
            # The mark goes before the syllable's first consonant, as eSpeak writes it, and before
            # the whole of tʃ and dʒ.
            start = target - 1 if target > 0 and body[target - 1] not in VOWELS else target
            if start > 0 and body[start - 1:start + 1] in ("tʃ", "dʒ"):
                start -= 1
            body = body[:start] + "ˈ" + body[start:]
    return body + ezafe
