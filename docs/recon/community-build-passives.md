# Passives that stop for a whole match (community patch, 17 Oct)

A community member's reports, via the user:
- Wylde had "0 ammo entire game";
- Fiorne's 0 Bunny Stacks "stays broken all match";
- Rowan's passive "stops healing for the rest of the game".

A community member's guess: "something relating to all passives in general". This file has what decides whether a hero's passive
runs in the Feb 2023 build, the likely trigger, the fix (`tools/patch/patches/community-passives.json`, not enabled),
and the evidence. Branch `cp-passives`, on top of `fiorne-restore`.

## How a passive lives

- A hero's passive is a gameplay ability that is started once and then keeps running: Wylde's
  `BP_GA_Gunslinger_P`, Fiorne's `GA_Lancer_P`, Rowan's `BP_GA_WoodenSword_P` and the others, children of
  `Shared/BP_GA_Passive_Base`. While it runs, it listens: round starts, damage done, item events. Granting and
  starting it is native (`DA_<Hero>_P.GrantedAbility`, `BP_OnGiveAbility`). No Blueprint starts it again.
- Some heroes have more abilities of the same kind, which also run all match:
  - Wylde's ammo goes through `BP_GA_Gunslinger_Reload`, which listens for the reload events. The passive's round-start
    fill sends one of them.
  - Fiorne's Bunny Stacks are `BP_GA_Lancer_Ammo` (`Shared/BP_GA_Template_Ammo`), granted by her passive.
- **Measured** (`tools/run/test_passives.sh`, 17 Oct, four matches). These abilities keep the same spec handle and
  `ActiveCount` 1 all match, sampled every 250 ms by the game server:
  - Wylde's passive (`#73`) and reload (`#77`), Fiorne's passive (`#4`) and stack system (`#110`);
  - through a death and respawn, three round changes (one with the hero dead), and an augment lock-in while Wylde was
    shooting the dummies, which also equipped an heirloom (Ammo Sprite: max ammo 6 → 9).

  So each is granted and started **once per match**, at spawn, and nothing starts it again. A first start that fails,
  or a later stop, leaves it off for the rest of the match. That fits all three reports.

## What stops one for good

| Way | Where | Heroes |
|---|---|---|
| **Refused start**: `ActivationBlockedTags` = `State.Dead`, `State.Channeling`, `Effect.LockCasts`. The passive won't start while its hero is dead, channeling (Shards, Health Shrines) or cast-locked (stuns, charms, knock-ups). In the same builds every other passive has `Ability.Passive`, inherited from `BP_GA_Passive_Base` | class defaults, `cdo_feb.json` | **Wylde, Fiorne, Rowan, Somnia, Zoey**; unreleased Priest, Priestess, Sniper |
| **Ends itself at its start**: no player state on the pawn yet, or the commit fails, and then `K2_EndAbility()` | `Shared/BP_GA_Passive_Base` (`ExecuteUbergraph` L10-L1441, :52); `Gunslinger/Passive/BP_GA_Gunslinger_Reload` (L2294-L3582, :167); `Shared/BP_GA_Template_Ammo` (:93) | every hero's passive; Wylde's reload; ammo/stack systems (Fiorne, unreleased PetSum, Sniper) |
| **Set up only on a round event**: the listener only fills or resets on the event; a missed event waits for the next round | `BP_GA_Template_Ammo` `OnRoundStart_CountDownEndDel`/`OnPreRoundEndDel` (:85, :88); `BP_GA_Gunslinger_P.ForceReloadRoundStart` on `OnRoundStart_CountDownEndDel` (:158) and `OnRoundStart` (:318); `BP_GA_Gunslinger_Reload` on `Player.OnRoundStartMulticast` (:164); BattleMonk P (:93), Berserker P (:72), FireMage P (:554), IceMage P (:115), ShieldGirl P and Sidekick P (pre-round event, :63, :61), LightningArcher P (round end, :139) | per round, not per match |
| **Restart mid-round** of Fiorne's stack system by her passive's safety net `CheckAmmoSystemIsInit` | `Lancer/P/GA_Lancer_P` :663-693 | Fiorne. Fixed in `fiorne.json` (the stack system sets itself up when it starts) |

No ability cancels `Ability.Passive` by tag: every `CancelAbilitiesWithTag` in the Feb build was checked.

**The likely trigger.** The three heroes reported are exactly heroes whose passive refuses to start while the hero is
dead, channeling or cast-locked. No other hero's passive has that restriction. If the native code starts or restarts a
passive at such a moment, the passive stays off until the match ends. Candidates:
- the start at spawn;
- an equipment change;
- channeling a Shard, which came back on 14 Oct with the old Shard system;
- a Health Shrine;
- a stun.

Wylde's ammo goes through his **reload** ability (`BP_GA_Gunslinger_Reload`). It also starts once and refuses to start
while he is channeling, dead or **casting** (`ActivationBlockedTags` [`State.Channeling`, `State.Dead`,
`State.Casting`]). Without it no fill or reload reaches his gun: 0 ammo all match.

**Not reproduced.** The first start at spawn didn't fail in any test, and the tests found no moment that starts these
abilities again. What makes the first start fail in real games remains open. Candidates:
- a hero who is cast-locked, dead, channeling or (for the reload) casting at that moment;
- a pawn without a player state yet (late or slow loaders, reconnects);
- a failed commit.

The second way would hit every hero alike, while the reports name only heroes with the restriction.

## The fix (patch pak)

`tools/patch/patches/community-passives.json`, `"enabled": false`, new AssetPatch edit `set-tags`
(`tools/patch/AssetPatch/Tags.cs`, `docs/PATCHING.md`):
- `ActivationBlockedTags` [`State.Dead`, `State.Channeling`, `Effect.LockCasts`] → [`Ability.Passive`] on the passives of
  Wylde, Fiorne, Rowan, Somnia and Zoey, and of the unreleased Priest, Priestess and Sniper;
- Wylde's reload: [`State.Channeling`, `State.Dead`, `State.Casting`] → [] (none). The reload itself stays gated
  inside the running ability (`Can Reload`, the reload events), so a reload still can't happen mid-cast.

They behave like every other hero's passive: a start can't be refused because the hero is dead, channeling or
stunned. A passive only listens, so it never needed those blocks. Abilities you cast keep theirs.

Builds together with the others: `tools/patch/build.sh clients/fangs-2023-02-15-b10554626 ccrevert fiorne
community-passives` (`fiorne.json` edits `GA_Lancer_P` too, on other values). `AssetPatch rewrite-check` on Wylde's
folder: 0 failed. The edited assets re-save byte for byte (`AssetPatch roundtrip`).

Not in this patch (needs evidence first):
- letting the passive base, Wylde's reload and the ammo template start without a player state. That's a size-neutral
  `set-call-arg` (`BooleanAND(PlayerState valid, Char valid)` → `(Char valid, Char valid)`), but item effects read
  `self.MOBAPlayerState`, and that's only set at the start;
- a "restart if not running" each round. It needs a call with a gameplay-tag literal, which `insert-call` can't write
  yet.

## Tests

`tools/run/test_passives.sh`: `test_patch.sh` with alice = Fiorne (team A) and bob = Wylde (team B), then
`tools/run/test_passives.steps`. The game server logs to `passives.log`, every 250 ms when something changes, for each
hero:
- whether the passive runs;
- ammo / stacks, health;
- the blocking tags;
- the round.

Then each hero in turn stands in front of the enemy turret, dies, and the round is ended, so the hero is dead at the
round change.

| Run | Patch | Result |
|---|---|---|
| `pas-obs2` | none (control) | blocked tags `State.Dead,State.Channeling,Effect.LockCasts` on both passives. Alice (Fiorne) died to the turret at 327 s, and the round ended at 333 s with her dead. Round 0+1: her passive still running, stacks 3. Bob (Wylde): passive running and ammo 6 → 5 → 6 across both rounds. |
| `pas-fix2` | `community-passives` | the server loaded the patched tags (`[Ability.Passive]` on both). Same as the control: alice dead at the round change, still running, stacks 3; bob's ammo fine. No change in behaviour where nothing failed |
| `pas-obs3` | none (control) | a round change; then on the augment screen bob shoots the dummies (6 s) while he equips Ammo Sprite and locks in, and alice locks in with an heirloom; then bob dies at the turret before the next round change. Every spec handle and `ActiveCount` unchanged all match (passive `#73`, reload `#77`, alice `#4`, `#110`). Ammo 6 → 9 max with Ammo Sprite, fills and reloads normally |
| `pas-fix3` | `community-passives` incl. the reload | same as `pas-obs3`, same handles, ammo and stacks normal: the patch changes nothing where nothing failed |

Earlier runs (`pas-obs`, `pas-fix`) had helpers that did nothing: a damage or stun spec applied through UE4SS from
Lua didn't land. Their only use: the patch is loaded (blocked tags read `[Ability.Passive]` on the server), and the
passives ran.
