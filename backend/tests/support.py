"""Shared setup for the backend tests: the real backend (fangs_backend.make_app) with throwaway data on loopback
ports, and fake_host.py in place of server/run-host.sh. Nothing touches backend/data, work/, the game or Wine.

    backend/.venv/bin/python -m unittest discover -s backend/tests -v
"""
import sys
import tempfile
import unittest
from pathlib import Path

from aiohttp import TCPConnector
from aiohttp.test_utils import TestClient, TestServer

BACKEND = Path(__file__).resolve().parents[1]
FAKE_HOST = Path(__file__).resolve().parent / 'fake_host.py'
sys.path.insert(0, str(BACKEND))
import fangs_backend as fb  # noqa: E402


def backend_args(tmp, *extra):
    """The command line of a test backend: everything under `tmp`, no standby server, no join code."""
    tmp = Path(tmp)
    return fb.parse_args(['--host', '127.0.0.1', '--port', '0', '--qos-port', '0', '--host-standby', '0',
                          '--host-ports', '17777-17778', '--join-code', '', '--data', str(tmp / 'store.json'),
                          '--instances', str(tmp / 'hosts'), '--game-dir', str(tmp / 'game'),
                          '--run-host', str(FAKE_HOST), '--log', str(tmp / 'backend.jsonl'), *extra])


class BackendCase(unittest.IsolatedAsyncioTestCase):
    """A running backend with the real seed. `self.client` is a player (connects from 127.0.0.2, so not trusted as
    a game server); `self.local` connects from 127.0.0.1 like our own game servers. `self.logs`: its log entries."""
    extra_args = ()

    async def asyncSetUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.logs = []
        self.app = fb.make_app(backend_args(self.tmp, *self.extra_args), self.logs.append)
        self.server = TestServer(self.app, host='127.0.0.1')
        self.client = TestClient(self.server, connector=TCPConnector(local_addr=('127.0.0.2', 0)))
        self.local = TestClient(self.server)
        await self.client.start_server()
        await self.local.start_server()

    async def asyncTearDown(self):
        await self.client.close()
        await self.local.close()
        self._tmp.cleanup()

    async def login(self, name, secret='secret'):
        """Logs `name` in like the launcher does; returns the token response."""
        r = await self.client.post('/iam/v3/oauth/token',
                                   data={'grant_type': 'password', 'username': name, 'password': secret})
        body = await r.json()
        self.assertEqual(r.status, 200, body)
        return body

    @staticmethod
    def auth(token):
        return {'Authorization': f"Bearer {token['access_token']}"}
