#!/usr/bin/env python3
"""Generates backend/seed/game_records.json — the global CloudSave game records the client
expects at login. Values are reconstructed from the Blueprint code that reads them
(see docs/recon/backend-api.md). Usage: make_seed.py <public-host:port>"""
import json, sys
from pathlib import Path

host = sys.argv[1] if len(sys.argv) > 1 else '127.0.0.1:8080'
base = f'http://{host}'
server = {
    'Name': 'Local', 'Alias': 'local', 'Region': 'local',
    'MatchMaker': f'{base}/matchmaker', 'CasualMatchMaker': f'{base}/matchmaker',
    'MatchMakerLink': f'{base}/matchmaker', 'MatchMakerABLink': f'ws://{host}/matchmaker',
    'MatchMakerABRanked': 'ranked', 'MatchMakerABCasual': 'casual', 'MatchMakerABBeginner': 'beginner',
    'Allocation': 'local', 'ZeuzIMSProject': 'fangs-local', 'SessionManagerUrl': f'{base}/zeuz',
    'ABArmadaDeploymentName': 'local',
    # The client builds lambda URLs as FANGSApiBaseURL + "/dev/" + <route>; routes are relative names.
    'FANGSApiBaseURL': f'{base}/fangsapi', 'CreatePlayerURL': 'create-player',
    'VivoxTokenURL': 'vivox-token', 'UpdatePlayerInfoURL': 'update-player-info',
    'UpdateRegionURL': 'update-region', 'UpdatePlayerSettingsURL': 'update-player-settings',
    'UpdateLoadoutsURL': 'update-loadouts',
}
# Arena maps in the Feb 2023 pak. Names as the game's own FANGS_LOC_EN (map_*_title); the client
# localizes known maps itself, the names here show for matchmade games and unlocalized maps.
maps = [('Embersong', 'LE_Arena02_Map'), ('Stormheart', 'LE_Arena06_Map'), ('Arena', 'LE_Arena01_Map'),
        ('Crownwatch', 'LE_Payload03_Map'), ('Payload II', 'LE_Payload04_Map')]
# DT_Heroes rows of the released heroes (the remaining rows are unfinished: no names, no owner class).
heroes = ['Berserker', 'ShieldGirl', 'Lancer', 'Gunslinger', 'Backstab', 'FireMage', 'IceMage', 'LightningArcher',
          'DemonGirl', 'WoodenSword', 'BookMage', 'Sidekick', 'BattleMonk', 'CatSupp', 'BigBoi']
# Heroes the developers never released, playable as a separate "Unreleased" group (FangsBoot keeps them apart in the
# menus and shows a notice): DT_Heroes row, name (Withergrim, Ellis and Nuali are their names in the game's texts).
# BladeMaster is left out: a grey mannequin without abilities (DT_Heroes still enables it).
unreleased = [('Warlock', 'Withergrim'), ('Priest', 'Ellis'), ('WaterBlade', 'Nuali'), ('Scythe', 'Scythe'),
              ('Sniper', 'Sniper')]


def augments(name):
    return json.loads(Path(__file__).with_name(name).read_text())


# Every skin, sticker, sigil, banner, title and mount of a build (tools/re/cosmetics.py); the backend puts them all
# in its catalog and entitles everyone to them. The lobby only lists skins named in AvailableSkins.
cosmetics_feb = augments('cosmetics-feb2023.json')
# XP per account level and per hero mastery level (tools/re/levels.py): the backend levels players up after each
# match; the hero screens show mastery progress against HeroLevelRewards.
levels = augments('levels-feb2023.json')


# THE switch for the old Shard system (docs/recon/shards.md). True: on the arena maps Shards are carried and turned in
# at a Capture Zone and Health Shrines are channeled again, as in Aug 2022 (FangsHost on the game servers reads
# CEOldShards below), and the nine artifacts made for them are restored ("_old_shards", "_old_health_shrines" in the
# restore list). False: the Feb 2023 game as shipped (Shards are destroyed, walk-over health pickups) and those nine
# artifacts are parked. Server only: change, deploy.
OLD_SHARDS = True
# With the old Shards on: Shard captures also speed the Aspect up for the capturing team (Feb 2023's leftover formula:
# x1.5 per capture, reset every round). 'off' (the Feb 2023 game: nothing raises the count); 'mask_of_speed' (Aug 2022:
# only captures by a carrier with Mask of Speed, which was "Rocket Fuel" then); 'every_capture'.
OLD_SHARDS_ASPECT_SPEEDUP = 'off'
OLD_SHARD_GROUPS = ('_old_shards', '_old_health_shrines')   # restore-list keys restored only while OLD_SHARDS


# Cut content back in play: items the developers took out of the in-match pick lists although they still work.
# restore-feb2023.json lists DT_MOBALoot rows per hero ("Generic": boons and artifacts, every hero); each is
# verified in a match before it goes in. Keys starting with "_" are not restored (parked), except OLD_SHARD_GROUPS
# while OLD_SHARDS (Generic items). itempaths-feb2023.json (tools/re/itempaths.py) gives their objects.
def restore_groups(restore_file):
    """(hero, rows) of the restore list that are on: hero lists, plus the old-shard groups while OLD_SHARDS."""
    for hero, rows in augments(restore_file).items():
        if hero in OLD_SHARD_GROUPS and OLD_SHARDS:
            yield 'Generic', rows
        elif not hero.startswith('_'):
            yield hero, rows


def offered_augments(all_file, paths_file, restore_file, heroes):
    """AvailableAugments: the items the game's own in-match pools offer (these heroes and the shared one) plus the
    restored ones. The menus list every item they are sent, so the full table would show cut, unfinished and
    other-map items, some even under the wrong hero (an item's owner class can be a leftover)."""
    pools = augments(paths_file)['pools']
    keep = {row for h in ['Generic', *heroes] for row in pools.get(h, [])}
    keep |= {row for _, rows in restore_groups(restore_file) for row in rows}
    return [a for a in augments(all_file) if a['Item'] in keep]


def restored(paths_file, restore_file):
    paths = augments(paths_file)
    return [{'Class': '*' if hero == 'Generic' else paths['heroes'][hero],
             'List': 'GenericItems' if hero == 'Generic' else 'PossibleItems', 'Item': paths['items'][row]}
            for hero, rows in restore_groups(restore_file) for row in rows]


version_data = {
    'Servers': [server], 'AvailableHeroes': heroes + [h for h, _ in unreleased], 'UnlockAllHeroes': True, 'UnlockAllSkins': True, 'EnableAllMounts': True,
    'AvailableGameModes': ['Custom', 'Casual', 'Training', 'Tutorial', 'Bots'],
    # WB_CreateLobby.SelectGameMode: Duel=2, 2vs2=4, Battle=6, 4vs4=8, 5vs5=10, 6vs6=12, Trio=3, Solo=1, AI=bots
    'AvailableCustomModes': ['Battle', 'Duel', '2vs2', '4vs4', '5vs5', '6vs6', 'Trio', 'Solo', 'AI'],
    'AvailableMaps': [{'Name': n, 'Map': m, 'Custom': True} for n, m in maps],
    # matchmade games: the lobby server picks one at random (GS_Lobby_GameState.GetRandomMap)
    'CasualMaps': [{'Name': n, 'Map': m} for n, m in maps if m in ('LE_Arena02_Map', 'LE_Arena06_Map')],
    'RankedMaps': [{'Name': n, 'Map': m} for n, m in maps if m in ('LE_Arena02_Map', 'LE_Arena06_Map')],
    # The HUD and loadout screens only offer augments listed here (no EnableAugmentProgress: all unlocked).
    # Generated per build from its DT_MOBALoot and hero preview assets by tools/re/augments.py.
    'AvailableAugments': offered_augments('augments-feb2023.json', 'itempaths-feb2023.json', 'restore-feb2023.json',
                                          heroes + [h for h, _ in unreleased]),
    'AvailableSkins': cosmetics_feb['Skin'],
}
# Aug 2022 build: no LE_Payload04_Map in its pak, no "AI" custom mode in its create-lobby screen
alpha7_data = {**version_data,
               'AvailableCustomModes': [m for m in version_data['AvailableCustomModes'] if m != 'AI'],
               'AvailableMaps': [m for m in version_data['AvailableMaps'] if m['Map'] != 'LE_Payload04_Map'],
               'AvailableAugments': augments('augments-alpha7.json'), 'AvailableHeroes': heroes}
del alpha7_data['AvailableSkins']   # its skin ids differ; it keeps the default skins
records = {
    # Keyed by the client's MOBA/Content/Data/version.txt. Known builds:
    #   main_v0_0_444            Closed Playtest, Dec 2023 (app 1831080)
    #   Playtest021523v1_v0_0_02 FANGS build 10554626, 15 Feb 2023 (app 1717990)
    #   alpha7.0.7.51            Closed Playtest Alpha 7 hotfix, build 9396481, 26 Aug 2022 (app 1831080)
    'FANGSConfig': {'NoServerMessage': 'Fangs: Community Edition server',
                    **{v: version_data for v in ('main_v0_0_444', 'Playtest021523v1_v0_0_02')},
                    'alpha7.0.7.51': alpha7_data},
    'season': {}, 'Mission': {},
    'HeroLevelRewards': {f'Tier{n}': {'Xp': xp, 'Bonus': False} for n, xp in enumerate(levels['Hero'], 1)},
    'CELevels': levels,   # not read by the client
    # Not read by the client: FangsBoot gets it from /fangsapi/*/restored-items and adds the items to the player's hero.
    'CERestoredItems': {'Playtest021523v1_v0_0_02': restored('itempaths-feb2023.json', 'restore-feb2023.json')},
    # Not read by the client: FangsHost (game servers) reads it from the backend's records: the old Shard system on/off.
    'CEOldShards': {'Enabled': OLD_SHARDS, 'AspectSpeedup': OLD_SHARDS_ASPECT_SPEEDUP},
    # Not read by the client: FangsBoot gets it from /fangsapi/*/unreleased-heroes.
    'CEUnreleasedHeroes': {'Playtest021523v1_v0_0_02': unreleased},
    # Not read by the client: name styles in the main menu's online list (FangsBoot), lowercase name -> style.
    'CENameStyles': {'anomie': 'rainbow'},
    # Not read by the client: the backend's catalog per AccelByte namespace (Feb/Dec builds use "fangs", Aug
    # "fangsbeta"). Item class = key (the categoryPath), item id = title = entitlement name.
    'CECatalog': {'fangs': {**{k: v for k, v in cosmetics_feb.items() if k != 'Skin'},
                            'Skin': [s['Item'] for s in cosmetics_feb['Skin']]}},
    'Justice': {'justiceSchema': '1.1', 'subsystemEnabled': False, 'pollTimeSeconds': 600, 'resetTimeHours': 24,
                'afkPenaltyEnabled': False, 'crashPenaltyEnabled': False, 'dodgePenaltyEnabled': False,
                'leavingPenaltyEnabled': False, 'partyPenaltyEnabled': False,
                'afkPenaltyTiers': [], 'crashPenaltyTiers': [], 'dodgePenaltyTiers': [], 'leavingPenaltyTiers': []},
}
out = Path(sys.argv[2]) if len(sys.argv) > 2 else Path(__file__).with_name('game_records.json')
out.write_text(json.dumps(records, indent=1))
print(f'wrote {out}')
