# Fangs: Community Edition — notes for Claude

**Setting up your own server with this repository?** Follow `docs/SELF-HOSTING.md` and its "For AI agents" section.
The rest of this file is how the original server's maintainers work; "the user" and their OKs below mean that
server's operator, not yours.

Goal: keep FANGS playable for a small group (self-hosted backend + game servers on a VPS) and preserve it.
This is a public, non-commercial fan project: never commit game files, extracted/decompiled game
content, header dumps, or credentials found in the game. See the README disclaimer.

**Keep track of the work** (several agents often run in parallel):
- `docs/ROADMAP.md`: what is in progress, done but not deployed, live, blocked, and the user's decisions.
  Read it first; update it in the same commit as the change that moves an item.
- `docs/recon/*.md`: research findings (items, heroes, backend API, match flow). A finding that only lives
  in a chat or an agent transcript is lost: write it there.
- `docs/STATUS.md`: what exists and gotchas; `docs/clients/*.md`: per-build facts. Say which build a
  finding comes from.
- `docs/CHANGELOG.md`: what each deploy changed (commits, off switch, rollback). Every change that will reach
  players gets a line under "Next deploy" in the same commit; `server/deploy.sh` tags each deploy.

Builds: the server runs the **15 Feb 2023** build (`clients/fangs-2023-02-15-b10554626`, Shipping, encrypted
pak; key recovered locally into `work/re/`, never print or commit it). The Aug 2022 build is also supported;
the Dec 2023 playtest (`clients/playtest-main_v0_0_444`, Development build) is a reference. UE 4.26,
unversioned assets; tools in `tools/pak`, `tools/re`.

Rules:
- Never commit anything from `clients/`, `work/`, `third_party/` or `backend/data/`; never publish the
  join code, signing key, server access or the AccelByte secrets in the game's config.
- Tests run in their own network namespace with their own backend data (`tools/run/*.sh`); never touch
  `work/hosts`, `backend/data` or a running local play session. Don't edit a test script while it runs.
- Deploy (`server/deploy.sh`) only with the user's OK for that deploy, and never while people play.
- Run Python that reads game data with `python3 -I`.

Git, with several agents at once (user, 15 Oct):
- Each agent works on its own branch in its own worktree. Nobody edits `~/repos/fangs` directly, so `main` there
  never has uncommitted work.
- `main` is what is live, plus what ships next. Deploy only from `main`:
  1. Rebase your branch onto `main` and fast-forward `main` to it (`git -C ~/repos/fangs merge --ff-only <branch>`).
  2. Deploy.
  3. Commit the tag in `docs/CHANGELOG.md` and `docs/ROADMAP.md`, then push `main` and the tags.
- One deploy at a time. Before your next deploy, rebase onto `main` again: a deploy from an older base takes newer
  live work off the server (e.g. without the patch pak, players' launchers remove it).
