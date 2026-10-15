# Ranked: the game's Ranked mode and our skill-based matchmaking

Build: **15 Feb 2023** (paths under `work/bp-2023-02-15/MOBA/Content/`) unless noted. Backend: `backend/skill.py`
(rating math), `backend/allocator.py` (queue decision), `backend/ranked.py` (store, settlement, leaderboard),
`backend/matchmaker.py` (Ranked and Casual queues). Tests: `tools/test/test_ranked.py`,
`tools/test/test_ranked_queue.py`, `tools/run/test_ranked.sh` (two real clients).

Decision (the user, 15 Oct 2026): Ranked uses skill ratings; Casual stays quick matches with no rating (the
population is small). Custom lobbies change no rating either.

## What the client does

- **The Ranked tile** (Play → game mode, `UI/MainMenu/WB_ChoseGameMode`, tile `WB_GameModeTallBtn`): enabled by
  `CheckIfEnabled` (l.84-146) only if FANGSConfig `AvailableGameModes` contains `"Ranked"` (our seed:
  `RANKED` in `make_seed.py`), `Mastery.MatchesWon >= required_wins` (**10**, class default of both widgets; no
  config overrides it), the party has at most **2** members, and every party member has 10 wins
  (`CanPartyPlayRanked`, from `FPartyMemberDetails.Wins`: each member's client reports its own `MatchesWon` over
  party signaling, which `social.py` relays). Otherwise the tile is greyed with "You must win {N} more games to
  unlock Ranked!" / "Ranked is limited to a maximum party size of 2".
- `CloudPlayerInfo.Mastery` is `PROFILE_MASTERY_KEY` merged in by `WB_AccountMenu` (l.1168-1170); wins from any mode
  count (Casual, Custom, Ranked).
- **Queue id**: `SetRankedMode` sets `MapGameMode = 3` and calls `WB_PlayMenu.PlayGameMode`, which re-runs
  `WB_AccountMenu.SetLambaEndPoints`: mode 3 joins `MatchMakerABRanked` (`"ranked"`), Casual joins
  `MatchMakerABCasual` / `MatchMakerABBeginner` (`"casual"` / `"beginner"`, by `BP_FL_MOBADetails` "Is Novice").
  The client sends `QueueJoinRequest {"id": "ranked", "attributes": [{"entry": {"key": "map", "value": <mode name>}}]}`;
  party members queue with the leader's `partyToken` (the leader's `ReportGameMode` sets their mode).
- **Hero select is a draft in mode 3**: rounds of pairs `[0,1] [2,3] [4,5] [6,7]` (`GS_Lobby_GameState`
  `DraftRankOrderJSONStr`), 16 s per round instead of 64 s, `HeroSelectTime` 24 instead of 64
  (`BP_GM_Lobby_GameMode` l.179-183), "Position N" label, locked heroes visible; no bans. Each client sends its
  own `MapGameMode` to the lobby (`InitLobbyState`), so Ranked and Casual players must never share a match.
  A round ends when `Min(slots in rounds 0..step, MaxPlayers)` players have locked in (`GS_Lobby_GameState.
  GetDraftRoundLimit`, `BP_GM_Lobby_GameMode` l.~21642); after 16 s without that the server ends the lobby for
  everyone ("A player has not locked in a hero", `error_player_didnt_lockin`). Seen in `tools/run/test_ranked.sh`
  when the picks came 26 s late. Full 1v1 / 2v2 / 3v3 / 4v4 lobbies fit the order. FangsHost's "everyone picks at
  once" override (`ALL_PICK`) only replaces `DraftOrderJSONStr`/`DraftOrderBJSONStr` (Casual/Custom), not the
  Ranked order. Risk: when a matched player never joins, FangsHost starts the lobby with those present after 45 s
  and a draft round can wait on the missing player's slot (untested).
- **Ratings shown**: the profile always shows `ranked_rating` (`WB_ReputationMenu.UpdateRankings` →
  `CalcOnlineRank(true, …)`: 90 × (mu − 2 sigma)); the end screen shows the change of `ranked_rating` in mode 3,
  `casual_rating` otherwise (`WB_EndResults` l.328-345); match history uses `ranked_rating` for RANKED entries.
  The arena server's own rating chain (`BP_AC_MatchReport.BuildPlayerRatings`, `SubmitLeaderboardUpdates`) is
  dead in this build (its CloudSave calls are compiled out).

## Our model (from the user's matchmaking research, generalized to n vs n)

Gaussian team rating in the TrueSkill family: each player has mean `mu` and uncertainty `sigma` (new: 1500 / 450),
a team performs as the average of its players plus a party-size offset (TrueSkill 2's squad effect; per member
0 / 60 / 100 / 140 for party sizes 1-4, uncalibrated hypotheses), per-player performance noise 400, process noise
20 per game, and a bounded "reopening" to sigma 300 when a confident player's recent results keep missing the
prediction (20+ games, score >= 3). Win/loss only: no kills or damage in the rating. All players of a game are
updated from one frozen snapshot. Not in it: TrueSkill 2's experience and quit terms, per-mode correlations.
Display: the game's 25 / 8.33 scale (54 rating units per display unit), so a new player shows 750 rank points
as before.

Queue (`allocator.py`): the oldest ticket anchors a bounded search; a lobby needs every ticket's mean within its
own wait-earned band of the lobby centre (100 → 800 rating units), the teams' sorted players pairwise within twice
the smaller band, the favorite's mean-strength chance at most 55% (→ 70% with the youngest ticket's wait),
provisional players (< 10 games or sigma > 350) balanced, and mirrored party shapes before uneven ones (60 / 180 /
300 s). Best split by `((p − .5) / .1)² + .05 (span / 800)²`. Physical sides by a random bit.

Checked against the research's own fixtures (when its checkout sits next to this repo): its 6 rating examples, the
party worked example and all 71 dev-queue scenarios reproduce exactly through our port (`tools/test/test_ranked.py`).

## Measurements (15 Oct 2026, local machine)

- **CPU**: one queue decision takes ~1.5 ms with 8-16 ranked players queued, 10 ms with 24, 23 ms with 40 (worst
  of 3 waits). The matchmaker decides at most once per second and only while a full game's worth of ranked players
  is queued; settling a result is a few dozen float operations. No measurable load on the game servers.
- **Simulated community** (24 players with hidden skills spread like a real group, sd 300; 400 sessions of 8-14
  queuing over two minutes; `simulate()` in `tools/test/test_ranked.py`):

  | widening (`--ranked-widen-speed`) | rating vs true skill (r) | true favorite's win chance | ranked wait median / 90% |
  |---|---|---|---|
  | 1 (research: widest at 480 s) | 0.85 | 60.0% | 274 / 390 s |
  | 2 (widest at 240 s) | 0.95 | 59.2% | 150 / 220 s |
  | 4 (widest at 120 s) | 0.81 | 61.4% | 86 / 138 s |
  | Casual (first eight, teams as they come) | – | 69.6% | 32 / 73 s |

  In a pool this small waiting buys little (nobody better arrives), so a faster schedule keeps the fairness
  and halves the wait. r varies run to run (one seed); fairness and waits are stable.
- A ranked queue can wait for good: 7 players at 1500 and one at 2400 never form a game (the 70% cap). The 2400
  plays once others of similar skill queue.

## End to end (15 Oct 2026, `tools/run/test_ranked.sh`, Feb 2023 build, two GPU-headless clients, 1 vs 1)

Both clients (10 wins each) saw the Ranked tile enabled (`CheckIfEnabled` true, no sub-label), chose it
(`MatchMakerJoinQueueId` "ranked", MapGameMode 3), were matched at once (50%), accepted, drafted and locked in
within the 16 s round, played on Stormheart (from `RankedMaps`) until the server's surrender; FangsHost saved a
mode-3 result and the backend settled it: 1500 → 1689.8 / 1310.2, sigma 450 → 408 (the model's value for two new
players in a 1 vs 1), winner's `MatchesWon` 10 → 11, nothing written to the stored `PROFILE_RATINGS_KEY`.
The game servers read each player's rating from the exported records (FangsHost `GetServerPlayerRatings` →
`records/players/<uid>/PROFILE_RATINGS_KEY.json`): the export writes the served Ranked rating there, not the old
stored casual one (second run: winner 28.514 / 7.556 on the game's scale).

The server runs `--ranked-widen-speed 2` (`server/entrypoint.sh`; the user, 15 Oct).

## Open

- The end screen's rank change in mode 3 (`WB_EndResults`, after Continue): not captured yet; it should show our
  served `ranked_rating`.
- Party effects (60 / 100 / 140) are untested guesses; with Ranked parties capped at 2 only the duo value (60)
  matters.
