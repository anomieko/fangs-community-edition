"""Players' patch notes: backend/patchnotes.py and GET /fangsapi/<stage>/patch-notes (FangsBoot's PATCH NOTES tab)."""
import json
import tempfile
import unittest
from pathlib import Path

from support import BACKEND
from test_api import API, ApiCase

import patchnotes

SHIPPED = BACKEND / 'patchnotes'


def note(tag, date, title='T', **extra):
    return {'tag': tag, 'date': date, 'title': title, 'subtitle': 'S', 'intro': [], 'sections': [], **extra}


class Render(unittest.TestCase):
    def test_bold_is_the_default_style_between_medium_runs(self):
        self.assertEqual(patchnotes.rich('<b>Fiorne</b> is back, 900 → 700.'),
                         'Fiorne<RichText.Useragreetxt> is back, 900 » 700.</>')
        self.assertEqual(patchnotes.rich('a <b>b</b> c'),
                         '<RichText.Useragreetxt>a </>b<RichText.Useragreetxt> c</>')

    def test_tag_characters_from_the_text_cannot_open_a_style(self):
        self.assertNotIn('<x>', patchnotes.rich('<x>not a style</x>'))

    def test_a_note_renders_title_sections_and_heroes(self):
        text = patchnotes.render(note('deploy-1', '2026-10-17', 'Big one', intro=['Hi.'],
                                      sections=[{'name': 'General', 'items': ['<b>A:</b> b']},
                                                {'name': 'Heroes', 'heroes': [['Rose', ['50 → 75']]]}],
                                      outro='Bye.'))
        self.assertTrue(text.startswith('<RichText.Title>Big one</>\n<RichText.DateandSubtitle>S</>\n'))
        for line in ('<RichText.HLGSubtitle>General</>', '<RichText.Useragreetxt>• </>A:<RichText.Useragreetxt> b</>',
                     '<RichText.DateandSubtitle>Rose</>', '<RichText.Useragreetxt>• 50 » 75</>',
                     '<RichText.Useragreetxt>Bye.</>'):
            self.assertIn(line, text.splitlines())

    def test_every_shipped_notes_file_loads_and_renders(self):
        files = sorted(SHIPPED.glob('*.json'))
        self.assertTrue(files, 'backend/patchnotes/ has no notes')
        loaded = patchnotes.load(SHIPPED)
        self.assertEqual(len(loaded), len(files), 'a notes file without tag or title, or not JSON')
        for n in loaded:
            with self.subTest(tag=n['tag']):
                self.assertRegex(n['tag'], r'^deploy-\d{4}-\d\d-\d\d-\d{4}$')
                self.assertRegex(n.get('date', ''), r'^\d{4}-\d\d-\d\d$')
                self.assertNotIn('→', patchnotes.render(n))   # the game fonts have no arrow

    def test_the_list_title_drops_patch_notes(self):
        self.assertEqual(patchnotes.list_title(note('d', '', 'Patch notes: the Community Patch')), 'The Community Patch')
        self.assertEqual(patchnotes.list_title(note('d', '', 'Hotfix → Fiorne')), 'Hotfix » Fiorne')

    def test_newest_first_and_broken_files_skipped(self):
        with tempfile.TemporaryDirectory() as d:
            for name, n in (('a.json', note('deploy-a', '2026-10-17')), ('b.json', note('deploy-b', '2026-11-02')),
                            ('c.json', {'no': 'tag'})):
                Path(d, name).write_text(json.dumps(n))
            Path(d, 'd.json').write_text('{not json')
            self.assertEqual([n['tag'] for n in patchnotes.load(d)], ['deploy-b', 'deploy-a'])


class Endpoint(ApiCase):
    async def asyncSetUp(self):
        self._notes = tempfile.TemporaryDirectory()
        for n in (note('deploy-2026-10-17-1223', '2026-10-17', 'The Community Patch'),
                  note('deploy-2026-10-20-1800', '2026-10-20', 'Follow-ups')):
            Path(self._notes.name, n['tag'] + '.json').write_text(json.dumps(n))
        self.extra_args = ('--patchnotes', self._notes.name)
        await super().asyncSetUp()

    async def asyncTearDown(self):
        await super().asyncTearDown()
        self._notes.cleanup()

    async def test_the_list_newest_first_without_a_login(self):
        self.assertEqual(await self.call('GET', f'{API}/patch-notes'),
                         (200, 'deploy-2026-10-20-1800\t2026-10-20\tFollow-ups\n'
                               'deploy-2026-10-17-1223\t2026-10-17\tThe Community Patch\n'))

    async def test_one_update_as_rich_text(self):
        status, text = await self.call('GET', f'{API}/patch-notes?tag=deploy-2026-10-17-1223')
        self.assertEqual(status, 200)
        self.assertTrue(text.startswith('<RichText.Title>The Community Patch</>'))
        self.assertEqual((await self.call('GET', f'{API}/patch-notes?tag=deploy-nope'))[0], 404)

    async def test_json_for_tools(self):
        status, body = await self.call('GET', f'{API}/patch-notes?format=json')
        self.assertEqual((status, [n['tag'] for n in body]), (200, ['deploy-2026-10-20-1800', 'deploy-2026-10-17-1223']))


if __name__ == '__main__':
    unittest.main()
