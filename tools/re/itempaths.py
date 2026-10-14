#!/usr/bin/env python3
"""Map a build's items and heroes to the objects a mod needs to put cut items back in play.

  itempaths.py <extracted pak root (…/MOBA/Content)> <out.json>

{"items": {DT_MOBALoot row: item asset object path}, "heroes": {DT_Heroes row: character class name},
 "pools": {hero: [rows in its pawn's PossibleItems], "Generic": [rows in BP_PlayerChar's GenericItems]}}.
In a match the item picker offers the hero pawn's PossibleItems (hero items) and GenericItems (boons, artifacts):
arrays of these item assets. make_seed.py turns backend/seed/restore-<build>.json (item rows to restore, per hero)
into object paths with this map (FangsBoot appends them to the player's pawn), and offers only pooled and
restored items in AvailableAugments: the menus list every item they are sent, cut and unfinished ones included.
Uses work/bin/bpdump/BpDump (UAssetAPI); needs the .uexp files next to the .uasset ones.
"""
import json, sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cosmetics import dump, field   # noqa: E402


def table(d):
    return next(e for e in d['Exports'] if 'Table' in e.get('$type', ''))['Table']['Data']


def pool(asset, prop):
    """Item object names in a character Blueprint's default <prop> array."""
    d = dump(asset)
    names = []
    for e in d['Exports']:
        for p in e.get('Data') or []:
            if p['Name'] == prop:
                names += [d['Imports'][-v['Value'] - 1]['ObjectName'] for v in p.get('Value') or []
                          if isinstance(v.get('Value'), int) and v['Value'] < 0]
    return names


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
    row_of = {}
    for row, path in items.items():
        row_of.setdefault(path.rsplit('.', 1)[-1], row)   # an item with two rows: the first one
    chars = Path(content) / 'BluePrints/Character'
    pools = {'Generic': [row_of[n] for n in pool(chars / 'BP_PlayerChar.uasset', 'GenericItems') if n in row_of]}
    for hero, cls in heroes.items():
        asset = chars / (cls[:-2] + '.uasset')
        if asset.exists():
            pools[hero] = [row_of[n] for n in pool(asset, 'PossibleItems') if n in row_of]
    Path(out).write_text(json.dumps({'items': items, 'heroes': heroes, 'pools': pools}, indent=0) + '\n')
    print(f'{out}: {len(items)} items, {len(heroes)} heroes, pools: ' +
          ', '.join(f'{h} {len(r)}' for h, r in pools.items() if r))


if __name__ == '__main__':
    main(*sys.argv[1:3])
