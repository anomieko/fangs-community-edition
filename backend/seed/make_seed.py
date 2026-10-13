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
# Maps present in the playtest pak; names for unlocalized ones are ours.
maps = [('The Garden of Vermilia', 'LE_Arena02_Map'), ('Dragon Arena', 'LE_Arena06_Map'),
        ('Arena', 'LE_Arena01_Map'), ('Payload', 'LE_Payload03_Map'), ('Payload II', 'LE_Payload04_Map')]
version_data = {
    'Servers': [server], 'UnlockAllHeroes': True, 'UnlockAllSkins': True, 'EnableAllMounts': True,
    'AvailableGameModes': ['Custom', 'Casual', 'Training', 'Tutorial', 'Bots'],
    # WB_CreateLobby.SelectGameMode: Duel=2, 2vs2=4, Battle=6, 4vs4=8, 5vs5=10, 6vs6=12, Trio=3, Solo=1, AI=bots
    'AvailableCustomModes': ['Battle', 'Duel', '2vs2', '4vs4', '5vs5', '6vs6', 'Trio', 'Solo', 'AI'],
    'AvailableMaps': [{'Name': n, 'Map': m, 'Custom': True} for n, m in maps],
}
records = {
    'FANGSConfig': {'NoServerMessage': 'FANGS revival server',
                    # GetMobaVersion() spelling not yet confirmed — provide both.
                    'main_v0_0_444': version_data, '0.0.444': version_data},
    'season': {}, 'HeroLevelRewards': {}, 'Mission': {},
    'Justice': {'justiceSchema': '1.1', 'subsystemEnabled': False, 'pollTimeSeconds': 600, 'resetTimeHours': 24,
                'afkPenaltyEnabled': False, 'crashPenaltyEnabled': False, 'dodgePenaltyEnabled': False,
                'leavingPenaltyEnabled': False, 'partyPenaltyEnabled': False,
                'afkPenaltyTiers': [], 'crashPenaltyTiers': [], 'dodgePenaltyTiers': [], 'leavingPenaltyTiers': []},
}
out = Path(__file__).with_name('game_records.json')
out.write_text(json.dumps(records, indent=1))
print(f'wrote {out}')
