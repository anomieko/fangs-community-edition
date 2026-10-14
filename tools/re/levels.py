#!/usr/bin/env python3
"""Build the level tables (XP per account level and per hero mastery level) for a client build.

  levels.py <extracted pak root (…/MOBA/Content)> <out.json>

DT_Levels (account: XP needed to leave level N, row N) and DT_HeroLevels (hero mastery, same). The backend levels
players up from finished matches with them; the seed serves the hero table as HeroLevelRewards (Tier<N>.Xp),
which the hero screens read. Uses work/bin/bpdump/BpDump (UAssetAPI); needs the .uexp files next to the .uasset.
"""
import json, sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cosmetics import table_rows, field   # noqa: E402


def xp_column(asset):
    rows = sorted(table_rows(asset), key=lambda r: int(r['Name']))
    if [int(r['Name']) for r in rows] != list(range(1, len(rows) + 1)):
        sys.exit(f'{asset}: rows are not 1..n')
    return [int(field(r, 'XP')) for r in rows]


def main(content, out):
    tables = Path(content) / 'DataContent/DataTables'
    data = {'Account': xp_column(tables / 'DT_Levels.uasset'), 'Hero': xp_column(tables / 'DT_HeroLevels.uasset')}
    Path(out).write_text(json.dumps(data) + '\n')
    print(f"{out}: {len(data['Account'])} account levels, {len(data['Hero'])} hero levels")


if __name__ == '__main__':
    main(*sys.argv[1:3])
