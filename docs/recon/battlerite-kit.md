# What a Battlerite reverse-engineering kit teaches us

On 16 Oct 2026 a friend shared the kit they use to study Battlerite (Stunlock, Unity 5.4.0p3, Mono). It's a local copy,
outside this repo. Nothing from it is copied here: this file has what we learned from it and what we checked in our
own build. The checks are on the Feb 2023 build unless a line names another one.

**What the kit is.**
- Agent instructions: one skill with general Unity judgment, one per game, and an onboarding protocol for a new game.
- `TOOLS.md`, a tool index: path, CLI or GUI, when to reach for each tool, how to discover its flags.
- Wrappers for Ghidra and AssetRipper that write a structured `result.json`.
- Offline decoders for Battlerite's own formats:
  - the gameplay database `Gameplay.go.bin`, with a whole-file byte-identical roundtrip;
  - a bit-packed effect bytecode: all 2,861 programs decode, 0 failures;
  - a protobuf bundle index;
  - the MurmurHash3 field-name hash.
- A champion → ability → animation/effect catalog.
- A Unity 6 viewer that plays every ability with the game's own animations and a port of its effect VM, plus a
  headless capture over all 252 abilities that writes frames and a per-ability timeline JSON.

## What doesn't carry over

- **Unity and .NET tools:** ilspycmd, dnSpy, AssetRipper, AnimeStudio, Cpp2IL, Il2CppDumper, the shader translator and
  Unity's MD4 script IDs. The UE equivalents are what we already use: UAssetAPI (`tools/bpdump`, `tools/patch`) and our
  own pak tools.
- **The viewer.** The kit rebuilds the game in another engine to watch abilities. We run the real game under Wine, so
  `tools/run/test_hero.sh` already plays that role.
- **Ghidra does carry over.** Ghidra 12.1.4 in the kit runs on Linux: the `linux_x86_64` decompiler is included and so is
  `support/analyzeHeadless`. It needs JDK 21, which isn't installed here. If we adopt it, we download it from upstream
  and check the release digest, rather than run binaries that came in a zip.

## What we already do the same way

- Hash anchors per build: `clients/*.sha256`, provenance in `docs/clients/`.
- Cross-build diffs: `work/cc-audit/` compares Aug 2022, Feb 2023 and Dec 2023. The kit compares Battlerite's
  per-version `Old/` data sets the same way.
- Byte-identical roundtrip before patching: `AssetPatch roundtrip`.
- Patches that state the value they expect: `docs/PATCHING.md`.
- Offline decoders. The kit never runs the game's own code to read data.
- An all-abilities headless run: `test_hero.sh`.
- Only stopping processes we started. The kit's wrappers stop only their own child processes; our test scripts stop
  only their own run's processes (`tools/run/headless.sh`).
- Recipes in git, game content never committed. The kit's `.gitignore` is a whitelist: `/*`, then `!` per tracked
  folder.

## Checked in our build because of it

### Our extract is incomplete (the kit's habit: count outputs against an independent list)

- `work/extract-2023-02-15` has 19,364 `.uasset` headers but only 2,580 of the pak's 19,377 `.uexp` files.
- A tool that reads an asset without its `.uexp` dies inside UAssetAPI with
  `ArgumentOutOfRangeException: count ('-1192')`. It doesn't say which file is missing. This happened with
  `BpDump --raw` on 155 of the 245 montages.
- Fresh from the pak (`pakextract.py`), all 773 animation assets (montages, sequences) parse, with 0 failures.
- The missing `.uexp` files total 6.0 GB (`.ubulk`: 3,585 files, 6.4 GB more). Anyone surveying assets should extract
  what they read from the pak, or the extract should be completed once.

### Ability timing is cast time + event percent, like Battlerite (decoded, not checked in a match)

- **Battlerite:** an ability has `CastTime`. Its anticipation animation is stretched to the cast time, and the release
  comes at the execute clip's `NormalisedTimeOfRelease`. That's from the kit's port of `ActionAnimationController`.
- **FANGS does the same:**
  - the ability's class defaults hold `CastTime` and an `EventPercent` (in `FMontageData`);
  - the native task `UMOBAWaitCastTime` runs the cast (121 ability Blueprints);
  - `UMOBABlueprintLibrary::GetMontagePlayRateFromEvent(Montage, EventPercent, CastTime)` picks the play rate that puts
    the montage's event point at the end of the cast;
  - `GetMontageWaitTime` gives the matching wait.
  - Their bodies are native and not read yet: the UHT dump only has stubs.
- **No animation sends gameplay events.** We surveyed the notifies of all 773 animation assets:
  - visual effects: `BP_PlayVFX` 122, `TimedNiagaraEffect` 3;
  - footsteps: `Step` 32;
  - FMOD sounds: 29 + 1 + 1;
  - `CameraShake` 1, `Flap` 1.
- Every `PlayMontageAndWaitForEvent` call we could parse (66) passes an empty `EventTags`.
- Gameplay events come from Blueprint code (`SendGameplayEventToActor`, 85 calls). Examples: `Ability.Teleport`,
  `Ability.JumpDisplacement`, `Input.<slot>.Released`.
- **What changes because of it:**
  - An ability's timing is numbers in its class defaults (`CastTime`, `…EventPercent`). These are readable with
    `BpDump --raw` and patchable with `set-default`.
  - Imported or new animations don't need gameplay-event notifies.
  - A Battlerite `(CastTime, NormalisedTimeOfRelease)` maps directly onto `(CastTime, EventPercent)`.

### Where ability visuals live

- Effects come from two places:
  - `BP_PlayVFX` notifies on montages. The Niagara system comes from the caster's VFX pack, chosen by `VFXPackTag` and
    `Index`, with caster/ally/enemy variants and a team colour. When there is no pack, the notify uses its
    `PreviewNiagara`. The system is attached at `SocketName` (`BP_AnimNotify_PlayVFX`). Battlerite has the same
    ally/enemy split (`CastEffectAlly`/`CastEffectEnemy`).
  - gameplay cues (`BP_GC_*`).
- Montages with VFX notifies, per hero folder:

| Hero (folder) | Montages | With VFX notifies |
|---|---:|---:|
| Berserker | 18 | 11 |
| OwlDude (Tufts) | 16 | 10 |
| BackStab | 13 | 9 |
| FireMage | 14 | 7 |
| Bigboi, WoodenSword | 10, 9 | 7, 7 |
| CatSupp, Lancer, Priest, Warlock | 13, 17, 11, 10 | 6 each |
| Gunslinger | 20 | 4 |
| DemonGirl, IceMage, ShieldGIrl | 12, 9, 15 | 2 each |
| BattleMonk | 13 | 1 |
| BookMage, LightningArcher, WaterBlade, Sniper, Scythe | 9, 10, 14, 6, 1 | 0 |

- Somnia's and Rayo's visuals therefore come only from cues. Sniper's flat yellow placeholder effects
  (`docs/recon/heroes.md`) aren't in its animations either: look at its cues and projectiles.

### For `docs/recon/foreign-heroes.md` (branch `foreign-heroes-recon`, not merged)

From the kit's notes, which are grounded in the decompiled loaders:
- **The current gameplay database is `Battlerite/Gameplay.go.bin`.** `Old/<version>/` holds per-gameplay-version copies
  that the client loads for old replays: 155-168 of each set's 184 files are identical to the current ones.
- **"Kits are data, not code" is only partly true.** A champion consists of:
  - records in `Gameplay.go.bin`, with inheritance;
  - C# handler classes per type id in `MergedUnity.dll` (`[GameObjectTypeId]`, with spawn/update/destroy functions);
  - effect bytecode (`EffectDefinition`) for the visuals.
- **Timing needs no new notifies** (see above). Battlerite's anticipation/release maps onto FANGS's
  `CastTime`/`EventPercent`.
- **The kit's ability catalog is a ready spec sheet** for a mechanics-only kit. It lists, per champion and ability: cast
  and post-cast times, cast mode, projectile speed, range, radius, damage and CC durations. The rights section stands
  as written.

## Ideas worth taking, by value for effort

1. **Coverage receipts.** Every tool that reads a corpus reports how many files it read, skipped (and why) and failed,
   compared against the pak list. Check missing `.uexp` files up front with a clear error. Cheap, and it prevents
   conclusions drawn from silent partial reads. The kit caught an export that wrote 3,035 files instead of 93,337 only
   by comparing counts: the export tool had reported success.
2. **An ability catalog per build,** like the kit's `catalog.py`. It would map hero → abilities (pawn's
   `ActivatableAbilities`) → class defaults (`CastTime`, `EventPercent`, cooldown, cost) → montages and their notifies →
   effects with their CC tags and SetByCaller durations → cues → Niagara/FMOD → icons and names. Output: JSON per build
   and a diff between builds.
   - Unreleased heroes: what each ability references that is missing or a placeholder.
   - The Aug → Feb balance changes beyond CC.
   - Checking tooltips against the real numbers.
   - What a port from the Dec build would drag along.
3. **An ability timeline from the showcase and patch tests,** like the kit's `TimelineRecorder`. Per ability: activation,
   montage and play rate, effects applied and removed (tags, durations), cues, end, written as JSON. `test_patch.lua`
   already logs CC/lock effects; generalising it gives a baseline that a patch-pak run or another build can be diffed
   against. Heavy: only when nobody plays.
4. **An import-closure check for porting Dec 2023 assets** (ROADMAP "Newer builds"). Walk a Dec asset's imports and
   report the packages, classes and Blueprint functions that are missing or changed in Feb. The kit's
   `build_viewer.py` computes the same kind of closure.
5. **Ghidra headless, targeted.** Decompile only the functions that `tools/re/xref.py`/`natives.py` find, from a list of
   addresses. The kit's post-script decompiles every function, which is too slow for an 88 MB exe. First candidates:
   - `GetMontagePlayRateFromEvent` (the timing formula);
   - why replication stays at ~20-25 Hz (`docs/recon/server-performance.md`);
   - the server CloudSave functions compiled out of the client.
   Needs JDK 21 and Ghidra from upstream (the user's OK to install).
6. **Run receipts for `tools/run` tests.** A `result.json` with the inputs (build, pak hash, seed), each check and its
   result. A missing receipt counts as a failure. Each wrapper gets one negative test: the kit's AssetRipper wrapper
   first reported a text file as a successful export.
7. **Documentation habits:**
   - give each recon claim its evidence level: file seen, decoded, seen in a match, or inference;
   - a short tools index for agents (tool, CLI/GUI, when to use, how to discover its flags), with the kit's clause
     "this file is not the manual; if it and the tool disagree, the tool wins".

Smaller:
- The kit indexes FMOD banks (FSB5 name tables → event paths). FANGS ships 42 banks in `MOBA/Content/FMOD/Desktop`:
  - one per released hero;
  - one each for three unreleased heroes, `Priest`, `Warlock` and `Waterblade`;
  - none for Scythe or Sniper.
  `Alchemist.bank` matches no `DT_Heroes` row listed in `docs/recon/heroes.md`. The same index would show which
  ability sounds the unreleased heroes have.
