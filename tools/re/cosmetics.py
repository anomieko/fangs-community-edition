#!/usr/bin/env python3
"""Build the cosmetics list (every skin, sticker, sigil/avatar, banner, title, mount) for a client build.

  cosmetics.py <extracted pak root (…/MOBA/Content)> <out.json>

The backend puts all of them in its catalog and gives every player an entitlement for each (inventory class =
first categoryPath segment: Skin, Sticker, Sigil, Banner, Title, Mount); the seed sends the skins as the
season's AvailableSkins ([{"Item": SkinID, "Owner": hero}]), which the lobby's skin list is built from.
Sources: DataTables DT_HeroSkins (SkinID, Hero; a hero's default skin has SkinID == hero and needs no item),
DT_Stickers / DT_Sigils (row names), DA_BannerCollection / DA_TitleCollection / DA_MountCollection (BannerId,
TitleId, MountId). Uses work/bin/bpdump/BpDump (UAssetAPI); needs the .uexp files next to the .uasset ones.
"""
import json, re, subprocess, sys, tempfile
from pathlib import Path

BPDUMP = Path(__file__).resolve().parents[2] / 'work/bin/bpdump/BpDump'
ID = re.compile(r'^[A-Za-z0-9_]{1,32}$')   # what the backend's update-player-info accepts


def dump(asset):
    with tempfile.TemporaryFile('w+') as out:
        subprocess.run([str(BPDUMP), '--raw', str(asset)], stdout=out, stderr=subprocess.DEVNULL, check=True)
        out.seek(0)
        return json.load(out)


def table_rows(asset):
    d = dump(asset)
    return next(e for e in d['Exports'] if 'Table' in e.get('$type', ''))['Table']['Data']


def field(row, prefix):
    for p in row['Value']:
        if p['Name'].split('_')[0] == prefix:
            return p.get('Value')


def collection_ids(asset, key):
    text = json.dumps(dump(asset))
    return list(dict.fromkeys(re.findall(r'"Name": "%s[^"]*", [^{}]*?"Value": "([^"]+)"' % key, text)))


def main(content, out):
    tables = Path(content) / 'DataContent/DataTables'
    skins, seen = [], set()
    for row in table_rows(tables / 'DT_HeroSkins.uasset'):
        skin, hero = field(row, 'SkinID'), field(row, 'Hero')
        if skin and hero and skin != hero and skin not in seen:     # a hero's default skin is no item
            seen.add(skin)
            skins.append({'Item': skin, 'Owner': hero})
    out_data = {
        'Skin': skins,
        'Sticker': [r['Name'] for r in table_rows(tables / 'DT_Stickers.uasset')],
        'Sigil': [r['Name'] for r in table_rows(tables / 'DT_Sigils.uasset')],
        'Banner': collection_ids(tables / 'DA_BannerCollection.uasset', 'BannerId'),
        'Title': collection_ids(tables / 'DA_TitleCollection.uasset', 'TitleId'),
        'Mount': collection_ids(tables / 'DA_MountCollection.uasset', 'MountId'),
    }
    ids = [s['Item'] for s in skins] + [i for k, v in out_data.items() if k != 'Skin' for i in v]
    bad = [i for i in ids if not ID.match(i)]
    if bad or len(ids) != len(set(ids)):
        sys.exit(f'unexpected ids: {bad[:5]} / duplicates: {len(ids) - len(set(ids))}')
    Path(out).write_text(json.dumps(out_data, indent=0) + '\n')
    print(out + ': ' + ', '.join(f'{len(v)} {k.lower()}s' for k, v in out_data.items()))


if __name__ == '__main__':
    main(*sys.argv[1:3])
