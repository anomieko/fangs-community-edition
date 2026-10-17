"""The players' patch notes as a PDF to post, from a notes file in backend/patchnotes/ (the same file the game's PATCH
NOTES tab shows; backend/patchnotes.py has the format).

Usage: uv run --with reportlab python -I tools/patchnotes/build_pdf.py backend/patchnotes/<file>.json [out.pdf]
(default out: work/patchnotes/<file>.pdf). Fonts: Noto Sans, and DejaVu Sans for the arrows Noto Sans lacks (Arch:
noto-fonts, ttf-dejavu; Debian: fonts-noto-core, fonts-dejavu-core).
"""
import json
import sys
from pathlib import Path

from reportlab.lib import colors
from reportlab.lib.pagesizes import letter
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.units import inch
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import (
    BaseDocTemplate, Flowable, Frame, KeepTogether, ListFlowable, ListItem, PageTemplate, Paragraph, Spacer,
)

FONT_DIRS = ['/usr/share/fonts/noto', '/usr/share/fonts/truetype/noto', '/usr/share/fonts/TTF',
             '/usr/share/fonts/truetype/dejavu', '/usr/share/fonts/dejavu']


def font(name, file):
    for d in FONT_DIRS:
        if (Path(d) / file).is_file():
            return pdfmetrics.registerFont(TTFont(name, str(Path(d) / file)))
    sys.exit(f'font {file} not found in {", ".join(FONT_DIRS)}')


font('Sans', 'NotoSans-Regular.ttf')
font('Sans-Bold', 'NotoSans-Bold.ttf')
font('Sans-Italic', 'NotoSans-Italic.ttf')
font('Arrow', 'DejaVuSans.ttf')   # Noto Sans has no arrows
pdfmetrics.registerFontFamily('Sans', normal='Sans', bold='Sans-Bold', italic='Sans-Italic', boldItalic='Sans-Bold')

INK = colors.HexColor('#1d1b20')
MUTED = colors.HexColor('#5b5763')
ACCENT = colors.HexColor('#8c1d40')
SOFT = colors.HexColor('#f6f1f3')

S = {
    'title': ParagraphStyle('title', fontName='Sans-Bold', fontSize=26, leading=31, textColor=INK),
    'subtitle': ParagraphStyle('subtitle', fontName='Sans', fontSize=12, leading=17, textColor=MUTED),
    'body': ParagraphStyle('body', fontName='Sans', fontSize=10.5, leading=15, textColor=INK),
    'section': ParagraphStyle('section', fontName='Sans-Bold', fontSize=16, leading=20, textColor=ACCENT,
                              spaceBefore=10, spaceAfter=6),
    'hero': ParagraphStyle('hero', fontName='Sans-Bold', fontSize=12.5, leading=16, textColor=INK),
    'item': ParagraphStyle('item', fontName='Sans', fontSize=10, leading=14.2, textColor=INK),
    'outro': ParagraphStyle('outro', fontName='Sans-Italic', fontSize=10.5, leading=15, textColor=MUTED),
}


def arrows(text):
    return text.replace('→', '<font name="Arrow">→</font>').replace('−', '<font name="Arrow">−</font>')


def bullets(items):
    return ListFlowable(
        [ListItem(Paragraph(arrows(t), S['item']), leftIndent=12, value='•') for t in items],
        bulletType='bullet', start='•', leftIndent=12, bulletFontName='Sans', bulletFontSize=9,
        bulletColor=ACCENT, spaceBefore=0, spaceAfter=0)


class Card(Flowable):
    """A soft background with an accent bar behind a group of flowables; kept on one page."""

    def __init__(self, items, pad=9):
        super().__init__()
        self.items, self.pad = items, pad

    def wrap(self, aw, ah):
        self.aw = aw
        self.sizes = [it.wrapOn(self.canv, aw - 2 * self.pad - 4, ah) for it in self.items]
        self.h = sum(h for _, h in self.sizes) + 2 * self.pad
        return aw, self.h

    def draw(self):
        c = self.canv
        c.setFillColor(SOFT)
        c.roundRect(0, 0, self.aw, self.h, 6, stroke=0, fill=1)
        c.setFillColor(ACCENT)
        c.rect(0, 0, 3, self.h, stroke=0, fill=1)
        y = self.h - self.pad
        for it, (_, h) in zip(self.items, self.sizes):
            y -= h
            it.drawOn(c, self.pad + 4, y)

    def split(self, aw, ah):
        return []


def on_page(canv, doc):
    canv.saveState()
    canv.setFont('Sans', 8)
    canv.setFillColor(MUTED)
    canv.drawString(doc.leftMargin, 0.45 * inch, doc.footer)
    canv.drawRightString(doc.pagesize[0] - doc.rightMargin, 0.45 * inch, f'Page {doc.page}')
    canv.restoreState()


def build(note, out):
    subtitle = note.get('subtitle', '')
    doc = BaseDocTemplate(str(out), pagesize=letter, leftMargin=0.85 * inch, rightMargin=0.85 * inch,
                          topMargin=0.75 * inch, bottomMargin=0.8 * inch, title=note['title'],
                          author='FANGS Community Edition', subject=subtitle)
    doc.footer = 'FANGS Community Edition · ' + (subtitle.split('·')[-1].strip() or note.get('date', ''))
    frame = Frame(doc.leftMargin, doc.bottomMargin, doc.width, doc.height, leftPadding=0, rightPadding=0,
                  topPadding=0, bottomPadding=0)
    doc.addPageTemplates([PageTemplate(id='p', frames=[frame], onPage=on_page)])
    story = [Paragraph(arrows(note['title']), S['title']), Spacer(1, 4), Paragraph(arrows(subtitle), S['subtitle']),
             Spacer(1, 12)]
    for p in note.get('intro', []):
        story += [Paragraph(arrows(p), S['body']), Spacer(1, 6)]
    for sec in note.get('sections', []):
        head = Paragraph(arrows(sec['name']), S['section'])
        if 'items' in sec:
            story.append(KeepTogether([head, Card([bullets(sec['items'])])]))
            story.append(Spacer(1, 6))
        else:
            first = True
            for name, items in sec['heroes']:
                card = Card([Paragraph(arrows(name), S['hero']), Spacer(1, 3), bullets(items)])
                story.append(KeepTogether([head, card]) if first else card)
                story.append(Spacer(1, 7))
                first = False
    if note.get('outro'):
        story += [Spacer(1, 10), Paragraph(arrows(note['outro']), S['outro'])]
    doc.build(story)


if __name__ == '__main__':
    if len(sys.argv) not in (2, 3):
        sys.exit(__doc__)
    src = Path(sys.argv[1])
    out = Path(sys.argv[2]) if len(sys.argv) == 3 else Path(__file__).resolve().parents[2] / 'work/patchnotes' / (src.stem + '.pdf')
    out.parent.mkdir(parents=True, exist_ok=True)
    build(json.loads(src.read_text(encoding='utf-8')), out)
    print('->', out)
