"""Writes PersianSTTKeyboard/emoji_names.txt, the words the emoji search matches: for each emoji
of the panel (EmojiPanel.swift), its CLDR name and keywords in Persian and English.

usage: make_emoji_names.py <cldr-json dir>
The directory holds annotations (cldr-annotations-full) and derived annotations
(cldr-annotations-derived-full) for fa and en, as ann-fa.json, der-fa.json, ann-en.json and
der-en.json, from https://github.com/unicode-org/cldr-json (Unicode license).
Each line: emoji, a tab, then Persian terms and English terms separated by |, lower case."""
import json, re, sys, os

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
source = open(os.path.join(root, 'PersianSTTKeyboard/EmojiPanel.swift'), encoding='utf-8').read()
lists = re.findall(r'list\(\s*"([^"]*)"', source)

def load(path, key):
    with open(path, encoding='utf-8') as f:
        return json.load(f)[key]['annotations']

def plain(e):
    return e.replace('️', '')

names = {}
for lang in ['fa', 'en']:
    table = {}
    for name, key in [('der', 'annotationsDerived'), ('ann', 'annotations')]:
        for emoji, entry in load(os.path.join(sys.argv[1], f'{name}-{lang}.json'), key).items():
            terms = entry.get('tts', []) + entry.get('default', [])
            table.setdefault(plain(emoji), [])
            table[plain(emoji)] += [t.lower().strip() for t in terms]
    names[lang] = table

import unicodedata
def emojis_of(text):
    # Grapheme clusters, roughly: a base followed by joiners, selectors, modifiers, tags and flags.
    out, cur = [], ''
    for ch in text:
        cp = ord(ch)
        joins = (cp in (0x200D, 0xFE0F, 0x20E3) or 0x1F3FB <= cp <= 0x1F3FF or 0xE0020 <= cp <= 0xE007F)
        if cur and (joins or cur.endswith('‍')):
            cur += ch
        elif cur and 0x1F1E6 <= cp <= 0x1F1FF and len(cur) == 1 and 0x1F1E6 <= ord(cur) <= 0x1F1FF:
            cur += ch
        else:
            if cur: out.append(cur)
            cur = ch
    if cur: out.append(cur)
    return [e for e in out if e.strip()]

lines, missing = [], 0
seen = set()
for text in lists:
    for emoji in emojis_of(text):
        if emoji in seen: continue
        seen.add(emoji)
        terms = []
        for lang in ['fa', 'en']:
            for t in names[lang].get(plain(emoji), []):
                t = t.replace('|', ' ')
                if t and t not in terms: terms.append(t)
        if not terms:
            missing += 1
            continue
        lines.append(emoji + '\t' + '|'.join(terms))
with open(os.path.join(root, 'PersianSTTKeyboard/emoji_names.txt'), 'w', encoding='utf-8') as f:
    f.write('\n'.join(lines) + '\n')
print(len(lines), 'emoji named,', missing, 'without a name')
