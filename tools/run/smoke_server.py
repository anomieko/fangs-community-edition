#!/usr/bin/env python3
"""Smoke-test a Fangs CE server like a client would: log in, create a custom-lobby session, request a
game server over the lobby WebSocket and wait until it is ready (dsNotif BUSY with ip:port).
Usage: smoke_server.py <host:port> [--name tester] [--join-code CODE]   (needs aiohttp)"""
import argparse, asyncio, base64, json, sys, time

import aiohttp


async def main(addr, name, code=''):
    base = f'http://{addr}'
    async with aiohttp.ClientSession() as http:
        basic = base64.b64encode(b'smoke:smoke').decode()
        async with http.post(f'{base}/iam/oauth/token', headers={'Authorization': f'Basic {basic}'},
                             data={'grant_type': 'password', 'username': name,
                                   'password': f'{code}:smoke-secret' if code else 'smoke-secret'}) as r:
            body = await r.json()
            if 'access_token' not in body:
                print('login failed:', body.get('errorMessage')); return 1
            tok = body['access_token']
        auth = {'Authorization': f'Bearer {tok}'}
        body = {'namespace': 'fangs', 'session_type': 'dedicated', 'username': name, 'game_version': '',
                'game_session_setting': {'mode': 'local', 'map_name': 'Smoke Test', 'max_player': 2, 'current_player': 0,
                                         'settings': {'lobby_name': 'smoke', 'lobby_owner': name, 'map_level': 'LE_Arena02_Map'}}}
        async with http.post(f'{base}/sessionbrowser/namespaces/fangs/gamesession', json=body, headers=auth) as r:
            sid = (await r.json())['session_id']
        print(f'logged in as {name}, session {sid}; requesting game server...', flush=True)
        t0 = time.time()
        async with http.ws_connect(f'ws://{addr}/lobby/', headers=auth, protocols=('wss',)) as ws:
            await ws.send_str(f'type: createDSRequest\nid: smoke-1\nmatchId: {sid}\ngameMode: local\nserverName: \n'
                              f'clientVersion: \nregion: \ndeployment: local\n')
            async for msg in ws:
                f = dict(l.split(': ', 1) for l in msg.data.split('\n') if ': ' in l)
                if f.get('type') == 'dsNotif':
                    ok = f.get('status') == 'BUSY'
                    print(f"dsNotif status={f.get('status')} server={f.get('ip')}:{f.get('port')} "
                          f"after {time.time() - t0:.0f}s {f.get('message', '')}")
                    return 0 if ok else 1
    return 1


if __name__ == '__main__':
    ap = argparse.ArgumentParser(); ap.add_argument('addr'); ap.add_argument('--name', default='smoketest')
    ap.add_argument('--join-code', default='')
    a = ap.parse_args()
    sys.exit(asyncio.run(main(a.addr, a.name, a.join_code)))
