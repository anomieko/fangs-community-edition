#!/usr/bin/env python3
"""Map a build's items and heroes to the objects a mod needs to put cut items back in play.

  itempaths.py <extracted pak root (…/MOBA/Content)> <out.json>

{"items": {DT_MOBALoot row: item asset object path}, "heroes": {DT_Heroes row: character class name}}.
In a match the item picker offers the hero pawn's PossibleItems (hero items) and GenericItems (boons, artifacts):
arrays of these item assets. make_seed.py turns backend/seed/restore-<build>.json (item rows to restore, per hero)
into object paths with this map; FangsBoot appends them to the player's pawn.
Uses work/bin/bpdump/BpDump (UAssetAPI); needs the .uexp files next to the .uasset ones.
"""
import json, sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cosmetics import dump, field   # noqa: E402


def table(d):
    return next(e for e in d['Exports'] if 'Table' in e.get('$type', ''))['Table']['Data']


def main(content, out):
    tables = Path(content) / 'DataContent/DataTables'
    loot = dump(tables / 'DT_MOBALoot.uasset')
    imports = loot['Imports']
    items = {}
    for row in table(loot):
        ref = field(row, 'LootItem')
        if not (isinstance(ref, int) and ref < 0):
            continue
        obj = imports[-ref - 1]
        package = imports[-obj['OuterIndex'] - 1]['ObjectName']
        items.setdefault(row['Name'], f"{package}.{obj['ObjectName']}")
    heroes = {}
    for row in table(dump(tables / 'DT_Heroes.uasset')):
        path = (field(row, 'HeroClass') or {}).get('AssetPath', {}).get('AssetName') or ''
        if path:
            heroes[row['Name']] = path.rsplit('.', 1)[-1]
    Path(out).write_text(json.dumps({'items': items, 'heroes': heroes}, indent=0) + '\n')
    print(f'{out}: {len(items)} items, {len(heroes)} heroes')


if __name__ == '__main__':
    main(*sys.argv[1:3])
