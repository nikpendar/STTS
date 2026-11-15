"""Rewrites the emoji lists of PersianSTTKeyboard/EmojiPanel.swift from Unicode's emoji-test.txt,
in Unicode's order (the order of the iOS emoji keyboard): every fully-qualified emoji, people
and hands in the light skin tone where Unicode has it (Rooz, 2026-11-15), the other tones left out. The panel hides at run time those the device's iOS cannot draw.

usage: make_emoji_lists.py <emoji-test.txt>
emoji-test.txt: https://raw.githubusercontent.com/unicode-org/unicodetools/main/unicodetools/data/emoji/17.0/emoji-test.txt
Afterwards run make_emoji_names.py for the search words."""
import os, re, sys

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
path = os.path.join(root, 'PersianSTTKeyboard/EmojiPanel.swift')

# The panel's categories in order, after recents; hearts and emotion symbols open the symbols.
order = ['smileys', 'people', 'symbols', 'nature', 'food', 'activities', 'travel', 'objects', 'flags']
lists = {name: [] for name in order}
skin = re.compile('[\U0001F3FB-\U0001F3FF]')
group = subgroup = None
for line in open(sys.argv[1], encoding='utf-8'):
    if line.startswith('# group:'):
        group = line.split(':', 1)[1].strip()
    elif line.startswith('# subgroup:'):
        subgroup = line.split(':', 1)[1].strip()
    elif line.strip() and not line.startswith('#'):
        codes, rest = line.split(';', 1)
        if not rest.strip().startswith('fully-qualified'):
            continue
        emoji = ''.join(chr(int(c, 16)) for c in codes.split())
        tones = set(skin.findall(emoji))
        if tones == {'\U0001F3FB'}:
            # The light skin tone takes the place of the default yellow form listed before it.
            base = skin.sub('', emoji)
            for items in lists.values():
                for i, item in enumerate(items):
                    if item.replace('\uFE0F', '') == base.replace('\uFE0F', ''):
                        items[i] = emoji
            continue
        if tones:
            continue
        name = {
            'Smileys & Emotion': 'symbols' if subgroup in ('heart', 'emotion') else 'smileys',
            'People & Body': 'people', 'Animals & Nature': 'nature', 'Food & Drink': 'food',
            'Activities': 'activities', 'Travel & Places': 'travel', 'Objects': 'objects',
            'Symbols': 'symbols', 'Flags': 'flags',
        }.get(group)
        if name:
            lists[name].append(emoji)

# Iran's flag first.
iran = '\U0001F1EE\U0001F1F7'
lists['flags'].remove(iran)
lists['flags'].insert(0, iran)

source = open(path, encoding='utf-8').read()
found = list(re.finditer(r'list\(\s*"([^"]*)"\)', source))
assert len(found) == len(order), len(found)
for match, name in reversed(list(zip(found, order))):
    source = source[:match.start(1)] + ''.join(lists[name]) + source[match.end(1):]
open(path, 'w', encoding='utf-8').write(source)
print({name: len(items) for name, items in lists.items()})
