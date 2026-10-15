# Review findings

Ledger for the review sprint (`docs/review/SPRINT.md`). Only findings that survived verification are listed.

Columns: severity (high: players stuck, data lost, or a security hole; medium: wrong behavior in a reachable case;
low: an edge case or a clarity problem), rubric criterion, state (*open*, *fix now*, *later*, *won't fix: reason*,
*fixed in `<commit>`*).

## Baseline

Taken 15 Oct 2026 at `6f26b44` (ruff 0.17.1, Python 3.12, aiohttp 3.14).
- Python: 26 tracked files. Pyflakes (`ruff --select F`): `backend/` 0; tools 8 (unused imports, one unused variable).
  Broader set (E,F,W,B,SIM,PLE,PLW,ASYNC,RUF; line length 130): 223 over the repo, mostly one-line `;`/`:` statements
  and long lines. Those that point at behavior: 8 un-kept `asyncio.create_task` results in `backend/` (RUF006),
  one blocking `open` in an async function (`hosts.py`), three zero-width spaces written literally in `social.py`.
- Unit tests: `test_ranked.py` 14 OK (41 s), `test_ranked_queue.py` 7 OK (moved from `tools/test/` to
  `backend/tests/`). Nothing else in `backend/` had unit tests; the other flows were covered only by headless game
  tests (`tools/run/*.sh`, need the game). Three ranked tests need the research checkout `../elommr` and skip
  without it (CI). On production's versions (Debian trixie: Python 3.13.5, aiohttp 3.11.16) the same tests pass.
- Shell (shellcheck), Lua (luacheck), Go (go vet): see the ops review; luacheck and Go aren't installed yet.

## Findings

(filled in after phase 1 verification)
