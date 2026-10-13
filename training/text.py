"""Text as the speech model writes it, for training labels and scores."""
import re
import unicodedata


def normalize(text):
    """Persian letters without ZWNJ (the model's vocabulary has none, and it writes میخوام), no
    diacritics or punctuation, single spaces. Digits stay: the model says numbers in words (the
    keyboard writes them back in words before uploading), so a label with digits is not used."""
    text = unicodedata.normalize("NFKC", text)
    text = text.replace("ي", "ی").replace("ى", "ی").replace("ك", "ک").replace("ة", "ه")
    text = text.replace("أ", "ا").replace("إ", "ا").replace("ٱ", "ا")
    text = re.sub("[ً-ٰٟـ]", "", text)  # diacritics and tatweel
    text = text.replace("‌", "").replace("‏", "").replace("‎", "")
    text = re.sub(r"[^\w\s]|_", " ", text)
    return " ".join(text.lower().split())


def distance(a, b):
    prev = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        cur = [i]
        for j, y in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x != y)))
        prev = cur
    return prev[-1]
