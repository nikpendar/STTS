"""Homo-GE2PE phonemes as the eSpeak-style IPA the Mana Piper voice was trained on; the app's
PersianPhonemes.swift does the same."""
import re

# GE2PE letters -> eSpeak IPA (as Piper's phoneme_id_map spells them).
MAP = {
    "a": "ɑ", "/": "a", "e": "e", "o": "o", "i": "i", "u": "u",
    "@": "ʔ", "?": "ʔ", "c": "tʃ", "C": "tʃ", "$": "ʃ", "S": "ʃ", "Z": "ʒ", ";": "ʒ", "j": "dʒ", "y": "j", "q": "q", "x": "x",
    "g": "ɡ", "b": "b", "p": "p", "t": "t", "d": "d", "k": "k", "f": "f", "v": "v", "s": "s",
    "z": "z", "h": "h", "m": "m", "n": "n", "l": "l", "r": "r", " ": " ",
}
VOWELS = set("ɑaeoiu")

# Words Homo-GE2PE reads wrong, in its own letters (ده as the number «dah», not «deh»).
EXCEPTIONS = {
    "ده": "d/h",
    "آوانگاری": "@avanegari",
    "هم\u200cنویسه": "h/mnevise",
    "هم\u200cنویسه\u200cها": "h/mneviseha",
    "علی": "@/li",
    "گوشی": "gu$i",
}


# Latin letters by their English names, in GE2PE letters: «IPA» is read «آی‌پی‌اِی».
LETTERS = {
    "a": "ey", "b": "bi", "c": "si", "d": "di", "e": "i", "f": "ef", "g": "ji", "h": "ec", "i": "ay",
    "j": "jey", "k": "key", "l": "el", "m": "em", "n": "en", "o": "o", "p": "pi", "q": "kiu", "r": "ar",
    "s": "es", "t": "ti", "u": "yu", "v": "vi", "w": "d/blyu", "x": "eks", "y": "vay", "z": "zed",
}


def latin_runs(clause):
    """`clause` as runs of (is_latin, text). Latin words longer than five letters that are not all
    capitals are left out: their English pronunciation cannot be guessed from the letters."""
    runs = []
    for part in re.findall(r"[A-Za-z]+|[^A-Za-z]+", clause):
        latin = part[0].isascii() and part[0].isalpha()
        if latin and len(part) > 5 and not part.isupper():
            part, latin = " ", False
        runs.append((latin, part))
    return runs


def with_ezafe(word, ezafe, spelling):
    """One GE2PE word with its Ezafe mark set to `ezafe` (from the Ezafe tagger, which decides
    better than GE2PE): «ketab» -> «ketabe1», «sedaye1» -> «seda». The word's own last letter tells
    a vowel ending (-ye) from a consonant (-e): «dane$gah» (دانشگاه) takes -e although it is spelled
    with ه. GE2PE sometimes writes «beduneye1». `spelling` (the Persian word) keeps a written
    Ezafe (خانه‌ی، خانۀ) as GE2PE read it."""
    if spelling.endswith(("\u200cی", "ۀ")):
        return word
    vowels = "aeiou/"
    if word.endswith("1"):
        word = word[:-1]
        # «beduneye1»: -eye on a consonant, only for a word not spelled with a vowel letter at the
        # end («xaneye1» is خانه with -ye).
        if word.endswith("eye") and len(word) > 3 and word[-4] not in vowels and spelling[-1:] not in "اوهیي":
            word = word[:-3]
        elif word.endswith("ye") and len(word) > 2 and word[-3] in vowels:
            word = word[:-2]
        elif word.endswith("e") and len(word) > 1 and word[-2] not in vowels:
            word = word[:-1]
    if not ezafe:
        return word
    return word + ("ye1" if word[-1:] in vowels else "e1")

def _distance(a, b):
    row = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        prev, row[0] = row[0], i
        for j, cb in enumerate(b, 1):
            prev, row[j] = row[j], min(row[j] + 1, row[j - 1] + 1, prev + (ca != cb))
    return row[-1]


def aligned(words, phonemes, alone):
    """GE2PE output as one phoneme word per input word. GE2PE sometimes writes one word as two
    («درمی‌آیند» -> «d/r miay/nd») or two as one; then pieces are grouped (up to three per word)
    to be closest to each word phonemized by itself (`alone(word)`). None when that fails."""
    n, m = len(words), len(phonemes)
    if n == m:
        return phonemes
    if not n or not m or m > 3 * n or n > 3 * m:
        return None
    own = [alone(w).replace(" ", "") for w in words]
    INF = float("inf")
    # best[i][j]: cost of words[:i] taking phonemes[:j]; each word takes 1 to 3 pieces.
    best = [[INF] * (m + 1) for _ in range(n + 1)]
    back = [[0] * (m + 1) for _ in range(n + 1)]
    best[0][0] = 0
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            for k in (1, 2, 3):
                if j - k >= 0 and best[i - 1][j - k] < INF:
                    c = best[i - 1][j - k] + _distance("".join(phonemes[j - k:j]), own[i - 1])
                    if c < best[i][j]:
                        best[i][j], back[i][j] = c, k
    if best[n][m] == INF:
        return None
    out, j = [], m
    for i in range(n, 0, -1):
        k = back[i][j]
        out.append("".join(phonemes[j - k:j]))
        j -= k
    return out[::-1]

def with_exceptions(words, phonemes):
    """GE2PE output with EXCEPTIONS put in, keeping the model's Ezafe; only when the model gave one
    phoneme word per input word."""
    if len(words) != len(phonemes):
        return phonemes
    out = []
    for w, p in zip(words, phonemes):
        fix = EXCEPTIONS.get(w)
        if fix and p.endswith("1"):
            fix += "ye1" if fix[-1] in "aeiou/" else "e1"
        out.append(fix or p)
    return out


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
