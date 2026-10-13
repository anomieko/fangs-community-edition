#!/usr/bin/env python3
"""Build the season-data "AvailableAugments" list for a client build.

  augments.py <extracted pak root (…/MOBA/Content)> <out.json>

The client only offers augments that the backend lists in AvailableAugments: BP_MOBAInstance
.MapAugmentDetails turns each {"Item": <DT_MOBALoot row>, "Owner": <hero>} into
AugmentDetailMap/AugmentRevDetailMap, and the HUD and loadout screens skip items missing there.
It also adds the item to the hero's preview asset (HeroCollection.GetPreviewHeroByName(Owner)).
Owner is the HeroName of the preview asset that already lists the item, so the per-hero pools stay
as the build shipped them; rows no hero lists get Owner "Generic" (matches no hero).
Uses work/bin/bpdump/BpDump (UAssetAPI) to read the assets.
"""
import json, subprocess, sys, tempfile
from pathlib import Path

BPDUMP = Path(__file__).resolve().parents[2] / 'work/bin/bpdump/BpDump'


def dump(asset):
    with tempfile.TemporaryFile('w+') as out:
        subprocess.run([str(BPDUMP), '--raw', str(asset)], stdout=out, stderr=subprocess.DEVNULL, check=True)
        out.seek(0)
        return json.load(out)


def import_name(d, index):
    return d['Imports'][-index - 1]['ObjectName'] if isinstance(index, int) and index < 0 else None


def main(content, out):
    content = Path(content)
    loot = dump(content / 'DataContent/DataTables/DT_MOBALoot.uasset')
    table = next(e for e in loot['Exports'] if 'Table' in e.get('$type', ''))['Table']['Data']
    rows = []                                   # (row name, item object name), table order
    for row in table:
        item = next((import_name(loot, p['Value']) for p in row['Value'] if p['Name'].startswith('LootItem_')), None)
        if item:
            rows.append((row['Name'], item))

    owner = {}                                  # item object name -> HeroName
    for asset in sorted((content / 'Experimental/Heroes').glob('*/DA_*_Preview.uasset')):
        d = dump(asset)
        for e in d['Exports']:
            props = {p['Name']: p for p in e.get('Data') or []}
            if 'HeroName' not in props:
                continue
            for a in props.get('Augments', {}).get('Value') or []:
                v = a.get('Value')
                name = (v.get('AssetPath', {}).get('AssetName') or '').rsplit('.', 1)[-1] if isinstance(v, dict) \
                    else import_name(d, v)
                if name:
                    owner.setdefault(name, props['HeroName']['Value'])

    seen, augments = set(), []
    for row, item in rows:
        if item in seen:                        # a few items have two rows; the first one wins
            continue
        seen.add(item)
        augments.append({'Item': row, 'Owner': owner.get(item, 'Generic')})
    Path(out).write_text(json.dumps(augments, indent=0) + '\n')
    heroes = sum(a['Owner'] != 'Generic' for a in augments)
    print(f'{out}: {len(augments)} augments ({heroes} hero, {len(augments) - heroes} generic)')


if __name__ == '__main__':
    main(*sys.argv[1:3])
