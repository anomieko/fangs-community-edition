"""Players' patch notes: one JSON file per update in backend/patchnotes/ (docs/CHANGELOG.md, "How it works").

The same files make the PDF (tools/patchnotes/build_pdf.py) and the in-game PATCH NOTES page (FangsBoot's
patchnotes.lua), which shows them in a RichTextBlock with the styles of the game's privacy-policy screen
(DT_LoginRichTypes): Title (Futura PT Bold 28), HLGSubtitle (Heavy 22), DateandSubtitle (Heavy 18), Useragreetxt
(Medium 16) and the default style (Heavy 16), used for bold. Rich-text tags don't nest, so bold is the default style
between Medium runs. The game's fonts have no "→": it becomes "»".

A notes file: {"tag": "deploy-…", "date": "YYYY-MM-DD", "title", "subtitle", "intro": [paragraphs],
"sections": [{"name", "items": [...]} or {"name", "heroes": [[hero, [items]], ...]}], "outro"}. Paragraphs and items may
use <b>…</b>.
"""
import json
import re
from pathlib import Path

BODY = 'RichText.Useragreetxt'


def load(folder):
    """Every notes file in `folder`, newest first (by date, then tag); unreadable files are skipped."""
    notes = []
    for p in sorted(Path(folder).glob('*.json')):
        try:
            n = json.loads(p.read_text(encoding='utf-8'))
        except (OSError, ValueError):
            continue
        if isinstance(n, dict) and n.get('tag') and n.get('title'):
            notes.append(n)
    return sorted(notes, key=lambda n: (n.get('date', ''), n['tag']), reverse=True)


def _plain(text):
    """Text for a rich-text run: no tag characters, the game fonts' arrow."""
    return text.replace('→', '»').replace('<', '‹').replace('>', '›')


def rich(text):
    """One paragraph: <b>…</b> in the default (Heavy) style, the rest Medium."""
    out = []
    for i, part in enumerate(re.split(r'</?b>', text)):
        if not part:
            continue
        part = _plain(part)
        out.append(part if i % 2 else f'<{BODY}>{part}</>')
    return ''.join(out)


def render(note):
    """A notes file as one rich text, for the game's RichTextBlock."""
    lines = [f'<RichText.Title>{_plain(note["title"])}</>']
    if note.get('subtitle'):
        lines.append(f'<RichText.DateandSubtitle>{_plain(note["subtitle"])}</>')
    lines.append('')
    for p in note.get('intro', []):
        lines += [rich(p), '']
    for sec in note.get('sections', []):
        lines.append(f'<RichText.HLGSubtitle>{_plain(sec["name"])}</>')
        for item in sec.get('items', []):
            lines.append(rich('• ' + item))
        for hero, items in sec.get('heroes', []):
            lines.append(f'<RichText.DateandSubtitle>{_plain(hero)}</>')
            for item in items:
                lines.append(rich('• ' + item))
            lines.append('')
        if lines[-1]:
            lines.append('')
    if note.get('outro'):
        lines.append(rich(note['outro']))
    return '\n'.join(lines).rstrip('\n') + '\n'


def list_title(note):
    """The title in the game's list of updates, under PATCH NOTES: without a leading "Patch notes:"."""
    title = re.sub(r'(?i)^patch notes:\s*', '', note['title']) or note['title']
    return _plain(title[:1].upper() + title[1:])


def index_text(notes):
    """One "<tag>\\t<date>\\t<list title>" line per update, newest first (no JSON parser in UE4SS)."""
    return ''.join(f'{n["tag"]}\t{n.get("date", "")}\t{list_title(n)}\n' for n in notes)
