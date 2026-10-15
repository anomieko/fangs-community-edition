# Review sprint (October 2026)

An external code review of this repository is planned. This sprint reviews and fixes everything we would not
want a reviewer to find first. The goal: wherever a reviewer starts reading, the code is correct when things fail,
small, readable and tested. It is open about its limits, and every behavior change traces to a decision.

Findings ledger: `docs/review/FINDINGS.md`. The sprint is listed in `docs/ROADMAP.md` (In progress).

## Schedule and safety (decided 15 Oct)

The review is on 16 Oct and centers on the backend (`backend/`). Players are on the live server tonight. Rules:
- All sprint work happens on branch `review` (worktree `../fangs-review`). `main` stays what is deployed, so a
  deploy tonight can't pick up sprint work by accident. `review` is merged only after the checks below pass and the
  user agrees.
- Tests come before fixes. Existing behavior is pinned by tests first, then each fix comes with its own test.
- No refactors of shipped code beyond what a verified finding needs (no file splits or renames the night before).
  The one exception: `fangs_backend.make_app()` / `parse_args()`, split out of `main()` unchanged, so tests run the
  real app wiring.
- No deploy, restart or load test on the VPS. Local headless tests run only in their own namespace, as always.
- Before merging: unit tests, plus the headless regression (`tools/run/test_lobby.sh`, `test_queue.sh`,
  `test_social.sh`, `test_chat.sh`, `test_ranked.sh`, `test_match.sh`) on the `review` branch.
- Order of work: backend test suite and CI; verified high and medium backend findings; `docs/ARCHITECTURE.md`;
  everything else after the review.

## Rubric

Every component is checked against these criteria. The first five are the common failure modes of fast,
agent-assisted code, so they come first.

- **R1 One lifecycle.** Every way a game, lobby, match, party or session ends goes through one path that frees the
  players and the state. Ways to end: normal end, crash, boot failure, timeout, disconnect, backend restart, deploy.
  No feature has a second path that skips it.
- **R2 No silent removals.** Every removed feature, mode or behavior traces to a recorded decision (ROADMAP Decisions,
  CHANGELOG). Behavior that only matters for a small population is kept on purpose and documented. Example: what
  happens when more matches form than there are server slots.
- **R3 Minimal.** No dead code, duplicate helpers, unused options or defensive code for states that can't happen.
- **R4 Readable.** Module boundaries follow responsibilities, so a newcomer finds where X happens within a minute.
  Names say what things are; comments say why.
- **R5 Correct under concurrency.** State stays consistent at every `await`, and when a task raises or is cancelled.
- **R6 Secure for its threat model.** The threat model: a small invite-only group, a public VPS. Check auth, input
  validation, paths, resource limits and secrets.
- **R7 Persistence and recovery.** Writes are atomic. What survives a restart and what is lost is stated.
- **R8 Tested.** Logic that doesn't need the game has unit tests; game flows have headless tests; tests are
  deterministic and isolated.
- **R9 Hygiene.** No game content, keys or credentials in the tree or in history. Linters are clean, or each
  exception carries a reason.

## Phases

0. **Baseline.** Linters (ruff, shellcheck, luacheck, go vet/staticcheck), a secrets/content scan of the tree and
   history, and test inventory. Numbers go into the ledger so the sprint can show before and after.
1. **Review (read-only).** One fresh reviewer per component, plus three cross-cutting audits: the lifecycle failure
   matrix (R1), every removal in history against the decisions (R2), and hygiene (R9). Every finding has `file:line`,
   a concrete failure scenario and a severity. Then every finding gets a separate adversarial check that reproduces
   it (ideally as a failing test) or refutes it. Only verified findings enter the ledger.
2. **Triage with the user.** Each finding gets one of: fix now, later, or won't fix (with the reason). Anything that
   changes what players see is the user's decision.
3. **Fix.** One finding per commit, with a test that fails before the fix and passes after it. Refactors are their
   own commits and keep behavior unchanged (the tests show it). No drive-by changes, and no behavior removed without
   a decision. A backend unit-test suite (aiohttp test client, fake host spawner) lets the matchmaker and host
   lifecycle run without Wine. CI runs the linters and unit tests on every push.
4. **Second review.** A fresh reviewer reads the sprint's own diff. Then the full headless regression runs
   (`tools/run/*.sh`, own network namespace), followed by one deploy with the user's OK, outside play hours.
5. **Reviewer packet.** `docs/ARCHITECTURE.md` (components, request flows, where state lives, how a game ends), how to
   run the tests, a known-limitations list, and a short factual note on how the project was built.

## Components

| Id | Scope | Bar |
|---|---|---|
| A | Backend core: `backend/fangs_backend.py` (routes, store, auth, records, sessions, downloads, lobby WebSocket) | full |
| B | Matchmaking and rating: `backend/matchmaker.py`, `allocator.py`, `skill.py`, `ranked.py` | full |
| C | Game server lifecycle: `backend/hosts.py`, `server/run-host.sh`, `tools/ue4ss/Mods/FangsHost` | full |
| D | Social: `backend/social.py` (friends, presence, parties, chat) | full |
| E | Player side: `launcher/`, `tools/ue4ss/Mods/FangsBoot`, `player/` | full |
| F | Ops: `server/` (Dockerfile, entrypoint, deploy, harden), `docs/SERVER.md` | full |
| G | Tools and tests: `tools/run`, `tools/test`, `tools/re`, `tools/pak`, `tools/bpdump` | tests reliable; research tools lighter |
| X | Cross-cutting: lifecycle matrix (R1), removal audit (R2), hygiene (R9) | full |

## Exit criteria

- Every verified high and medium finding is fixed, or deferred with a reason in the ledger.
- Linters are clean. Unit tests run in CI and pass.
- Every cell of the lifecycle matrix is covered by a test or written reasoning.
- The removal audit is complete, and each removal has a decision.
- The headless regression passes, and the result is deployed (with the user's OK).

## Status

Last updated: 2026-10-15.
- Phase 0 and phase 1: started 15 Oct.
