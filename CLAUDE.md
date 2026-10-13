# Fangs: Community Edition — notes for Claude

Goal: keep FANGS playable (custom lobbies on a self-hosted backend + game servers) and preserve it.
This is a public, non-commercial fan project: never commit game files, extracted/decompiled game
content, header dumps, or credentials found in the game. See the README disclaimer.

- `clients/playtest-main_v0_0_444/` is the **Closed Playtest** build — a UE 4.26.2 *Development*
  build. A different "target" client version may be added later; always say which client a
  finding comes from. Per-client facts live in `docs/clients/*.md` — read before re-doing recon.
- Pak is unencrypted + uncompressed v11; use `tools/pak/`. Assets: unversioned headers, tagged props, UE 4.26.
- Never commit anything from `clients/`, `work/`, `third_party/` or `backend/data/`; never publish the
  AccelByte secrets found in the pak's `DefaultEngine.ini`. Start with `docs/STATUS.md`.
- Run Python that reads game data with `python3 -I`.
