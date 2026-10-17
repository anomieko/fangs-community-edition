# Changing the game's data: the patch pak

Permanent changes to the game itself go into one extra pak file, `FangsCE_P.pak`. Examples are an ability's numbers,
which effect it applies, or a small edit to its Blueprint code. Servers and players load the same file. First use: the
CC revert (`tools/patch/patches/ccrevert.json`, research in `docs/recon/cc-changes.md`).

UE4SS hooks (FangsHost, FangsBoot) are still the tool for behaviour that needs new logic. Use the pak for anything
that is a different value, a different effect class or a different call.

## How it works

- UE 4.26 loads every `.pak` in `MOBA/Content/Paks`. A pak whose name ends in `_P` loads after the game's own pak, and
  its files replace the game's.
- **Only the recipe is in git.**
  - The repo holds the patch files (names and numbers, like the recon docs) and the tools.
  - `tools/patch/build.sh` builds the pak from your own game files: it takes the assets out of the game's encrypted
    pak, applies the patches and packs the results.
  - The pak contains game data, so it is never committed, like everything else from the game.
- **Players and servers get the same file.**
  - `server/deploy.sh` builds the pak into the player download folder (`overlay/MOBA/Content/Paks/FangsCE_P.pak`).
  - The launcher installs it, updates it and removes it with the other player files.
  - The game servers copy it from that same folder: `FANGS_PAKS` in `server/docker-compose.yml`, used by
    `server/run-host.sh`.
  - Clients therefore show the patched numbers in tooltips and predict the patched behaviour.
- **A patch fails instead of guessing.** Every edit states the value it expects to find (`from`, `uses`, `count`), so
  a patch can't silently apply to another build or to a file that has changed.

## Pieces

| Piece | What it does |
|---|---|
| `tools/patch/patches/<name>.json` | One patch: the build it is for, `enabled`, and the edits per asset, each with a `why` |
| `tools/patch/build.sh <game-dir> [patch...]` | Builds `work/patch/<build>/FangsCE_P.pak` (`OUT=` elsewhere). With no patches named, it uses the enabled ones for that build |
| `tools/patch/AssetPatch` (C#, UAssetAPI) | Applies the edits. Its `info`, `calls`, `props` and `roundtrip` commands help you write a patch; `rewrite-check`, `reshape-check` and `nop` check the code rewriter |
| `tools/pak/pakwrite.py` | Writes the pak: v11, unencrypted, laid out like UnrealPak's |
| `server/install-paks.sh` | Puts the paks of `FANGS_PAKS` into a copy of the game and removes the ones it put there before |
| `FANGS_PAKS=<dir>` | Patch paks for game servers (`run-host.sh`), test clients (`tools/run/headless.sh`) and local play |
| `tools/run/test_patch.sh` (+ `.lua`) | A two-player match that proves the pak loads and logs every CC/lock effect on both heroes. `STEPS=<file>` adds a hero's own steps; `tools/run/test_fiorne.sh` (+ `.steps`) is Fiorne's: health, Bunny Stacks, a Space chain with her speed every 50 ms, a mid-round restart of her stack system |

Requirements on the machine that builds the pak: .NET 10, `third_party/UAssetAPI` (see the README), the game install,
and the AES key in `work/re/` (the `PAK_KEY` env var points elsewhere).

## Making a change

1. **Find it.**
   - The Blueprint pseudocode is in `work/bp-2023-02-15/` (made with `tools/bpdump`).
   - `work/cc-audit/ctx.sh <path> <regex>` shows the same code in the Aug 2022, Feb 2023 and Dec 2023 builds.
   - Write what you find into `docs/recon/`.
2. **Look at the asset.** Extracted assets are in `work/extract-2023-02-15/`; `tools/pak/pakextract.py` gets others.
   ```
   work/bin/assetpatch/AssetPatch info  <asset.uasset>            # imports and their uses, class defaults, functions
   work/bin/assetpatch/AssetPatch calls <asset.uasset> '*' [call]  # every call, with arguments as the edits match them
   work/bin/assetpatch/AssetPatch props <asset.uasset> [export]    # the exports; or every value stored in one, by path
   ```
   `tools/patch/build.sh` builds `work/bin/assetpatch` the first time it runs.
3. **Write the edits.** Add them to a patch file in `tools/patch/patches/`, either a new file or an existing one. Give
   each asset a `why` that a player could read. New patches start with `"enabled": false`.
4. **Build:** `tools/patch/build.sh clients/fangs-2023-02-15-b10554626 <patch>`. It prints each edit with the old and
   new value, and stops at the first edit that doesn't match.
5. **Test.**
   - `PATCHES=<patch> tools/run/test_patch.sh` runs automatically. Set the heroes and abilities with `HERO_A`,
     `HERO_B`, `ULT_A`, `LMB_B`, `CAST_A` and `CAST_B`.
   - The test puts the target where the caster aims: each hero's replicated `UpdatedPointerLocation` is the world
     point under that player's mouse. For an ability that lands at the pointer, set `AIM_A=<its range>`.
   - `PATCHES=none` is the control run without the pak.
   - Then play it: `tools/play/local.sh stop`, then `PATCHES=<patch> CLIENT_DIR=clients/fangs-2023-02-15-b10554626
     tools/play/local.sh <name>`. The local backend's game servers get the same pak.
6. **Ship it.**
   - Set `"enabled": true`, add a line under "Next deploy" in `docs/CHANGELOG.md` and update `docs/ROADMAP.md`, all
     in one commit.
   - The next deploy (with the user's OK) builds the pak, and players get it the next time they start the launcher.
7. **Off switch / rollback:** set `"enabled": false` and deploy. With no patch enabled, no pak is built, and the
   launcher removes the old one from players' installs.

## Edits

| `op` | Fields | What it changes |
|---|---|---|
| `set-default` | `property`, `from`, `to` | A float, int or bool in the class defaults (`Default__<Class>_C`). Only values stored in that class's own defaults (the tool says "found 0" otherwise). For an ability's `Base…`/`Modified…` pair, set both: `ResetAbilityAttributes` derives the modified value from the base one. |
| `rename-call` | `from`, `to`, `count`, optional `function` | Calls to a Blueprint function of another class, e.g. `BP_FL_MOBA_AbilitySystemFunctionLibrary_C.MakeRootEffectSpec` → `MakeStunEffectSpec`. These calls are by name (`EX_VirtualFunction`) and resolved when they run. The new function must take the same arguments. |
| `rename-import` | `from`, `to`, `uses` | A reference to another object, e.g. a `TSubclassOf` default from `BP_GE_Root_C` to `BP_GE_Stun_C`. Rename the class, its `Default__` object and its package together. Imports whose class is the renamed one are updated too: the game checks an import's class. |
| `set-call-arg` | `function`, `call`, `arg`, `from`, `to`, `count`, optional `match` | One argument of the matching calls in one function: a number, `true`/`false`, a variable that function already uses, or `self.<name>`, a variable of the Blueprint's class. A byte or int literal stays one (`VelocityOnFinishMode` `0` → `1`). An argument of another size (a variable for a number) moves the code after it; `Reshape` moves the offsets (see "Rewriting functions"). `match` (`{"<arg index>": "<text>"}`) narrows the calls down. Arguments are written the way `AssetPatch calls` prints them. |
| `replace-text` | `key`, `from`, `to`, optional `count` (1) | Text in a string table entry, e.g. a tooltip in `UI/Localization/LOC_EN_*`. Match the raw text, including its `<RichText…>` markup. The game ships English only. |
| `set-export-prop` | `export`, `path`, `from`, `to` | One value anywhere in the asset: a component template (`wer_GEN_VARIABLE`), a value nested in the class defaults (a gameplay effect's `Modifiers[0].ModifierMagnitude.ScalableFloatMagnitude.Value`), a data asset's field. `export` is the export's name, or as much of its outer path as makes it unique (`<outer>.<name>`, `NE_Astrada_Shift.UpdateScript_17.NiagaraDataInterfaceVectorCurve_1`); `AssetPatch props <asset>` lists every export's path. `path` joins property names with dots; `[i]` picks an array element; a Vector, Rotator, Vector2D or LinearColor ends in a component (`BoxExtent.Y`, `ColorOptions.Color.B`). Values: numbers, `true`/`false`, enum names as `AssetPatch props` prints them (`"EGameplayModOp::Override"`). `AssetPatch props` lists the paths. |
| `recolor-curve` | `export` (an emitter of a Niagara system), `from`, `to` (R, G, B) | One emitter's colour: every colour or vector curve under it whose first sample is `from` gets `to`, scaled per sample by the old sample's brightest channel (same fade, one hue; alpha kept). A cooked curve keeps only its baked table (`ShaderLUT`), which is what the game samples. The emitter's colour comes from these curves: a system's user parameters (`User.Color`) only count where a script reads them (`AssetPatch props <asset> <script>` lists what each script reads). A wrong `from` lists where the emitter's curves start. |
| `copy-default` | `from` (an asset path), `property`, optional `rename` | Adds a class default copied from the same property of another asset's class defaults, renaming names in it. Example: the ult charm's `GameplayCues` onto the generic charm, with the cue tag renamed. The property must not be set in the target yet, and the copied value must not reference other objects. `build.sh` extracts the `from` asset too. |
| `insert-call` | `function`, `call`, optional `args`, optional `inherited`, and `at` (`start`, `end`) or `before`/`after` (a call in that function) | Adds a call to one of the Blueprint's own functions as a new statement, e.g. Rowan's `ApplyUnstoppable` at the start of `Lock Pre Dash`. `at: end` puts it before the final return, so it runs on every way out. A parent Blueprint's function (e.g. `Clear Stacks and Listeners` of `BP_GA_Template_Ammo`) needs `"inherited": true` and takes no arguments: its parameters aren't in this asset. `before`/`after` name a call that exactly one statement of the function makes. `args` are literals typed by the called function's parameters (numbers, `true`/`false`, `self`, `nullptr`) or variables the function already uses; no output parameters. Not into an ubergraph yet (see "Rewriting functions"). |
| `remove-call` | `function`, `call`, `count` | Removes the statements that are a call to `call` (not those that use its result); a jump to a removed statement lands on the next one. |
| `soundwave-audio` | `media`, `sha256`, `source`, `doc`, optional `gain_db` | Only in a new SoundWave asset (see "New sounds"): puts the audio file `media` into it, encoded to Ogg Vorbis with ffmpeg (the template's channels and sample rate, `gain_db` applied), with its duration and sample count. `sha256` must match the file. |
| `insert-play-sound` | `function`, `before`, `attach_arg`, `sound`, optional `volume`, `attenuation` | A new statement before the one call to `before` in `function`: `GameplayStatics.SpawnSoundAttached(sound, <argument attach_arg of that call>, …, volume, attenuation)`. Its imports are added, and listed in the function's create-before-serialization dependencies as the cooker does. |
| `set-tags` | `property`, `from`, `to` (lists of tags), optional `export` (default: the class defaults) | Replaces the tags of one gameplay tag container, e.g. an ability's `ActivationBlockedTags`. `from` must list the stored tags in their stored order (the tool prints them when it doesn't match); `to` may be empty. Only a container stored in that export. |
| `set-name-const` | `function`, `from`, `to`, `count` | Name constants in one function, e.g. a gameplay tag literal: `Data.Heal` → `Data.Heal.MissingMultiple` (a SetByCaller tag), `VFXPack.Skill1.AOEVFX` → `VFXPack.Skill2.AugmentVFX` (another effect of the hero's VFX pack). Same size. |
| `set-branch` | `function`, `call`, optional `match`, `from`, `to` (`true`/`false`), optional `count` (1) | The constant branch (`if (!true)` / `if (!false)`) right before the statement that calls `call` with `match`ing arguments, e.g. the dash payload flag `AddGameplayTag(…, Event.Identifiers.CanBeCrowdControlled)` behind `if (!true)`: `false` skips the statement. One byte. |
| `insert-copy` | `function`, `copy`, optional `match`, optional `args`, `before`/`after`, optional `anchor-match` | Inserts a copy of the one statement that calls `copy` (`match` narrows it by its arguments), with some arguments of the copied call changed (`{"<index>": "<new>"}`: as `set-call-arg` makes them; a gameplay tag literal takes the new tag), before or after the one statement that calls another function (`anchor-match` narrows it). Example: a second `AssignTagSetByCallerMagnitude` on the same spec with another tag and value. The copy may hold no code offsets. |
| `wrap-call-arg` | `function`, `call`, `arg`, `from`, `count`, `with`, optional `args` | Puts a call around one argument of the matching calls, e.g. `Add_FloatFloat(r, 1.0)` → `Add_FloatFloat(Multiply_FloatFloat(r, 0.5), 1.0)` (Rayo's Stormlense ramp). `with` must already be called somewhere in the asset (its call node is reused); `args` are its further arguments. The statement grows, and the code offsets after it move along. |
| `replace-call-arg` | `function`, `call`, `arg`, `from`, `count`, `to` (an `insert-code` expression) | Like `set-call-arg`, but the new argument may have another size, e.g. a vector literal `{"vec": [5, 240, 162]}` in place of a property read (Ethryn's shield push keeps its old box). |
| `rename-prop-ref` | `function`, `from`, `to`, `count`, optional `call` | Points property reads at another property of the same owner, e.g. `MOBAProjectile.ProjectileSphere` → `ProjectileInteractionsSphere`. With `call`, only in statements that make that call. Same size. |
| `insert-code` | `function`, `at` (`start`, `end`) or `before`/`after` (a call in that function), `code` | New statements, built from a small JSON form (below), inserted as a block; works in ubergraphs. Engine (`/Script`) functions it calls are added as imports when the asset lacks them. |

What a patch can't do (yet):
- Add functions or variables. New statements (`insert-call`, `insert-copy`, `insert-code`, `insert-play-sound`)
  can only use variables the function or class already has, engine functions (`/Script`) and, for
  `insert-play-sound`, the new sound asset; no other reference to a game asset (`/Game`) is added.
- Add a value the asset doesn't store. A value equal to its default isn't saved, so `set-default` and `set-export-prop`
  only change values that are there (`AssetPatch props` shows them).

## Rewriting functions

`insert-call` and `remove-call` add and remove whole statements. The code offsets that point into the function are
moved along with them (`Splice` in `tools/patch/AssetPatch/Rewrite.cs`). In a cooked 4.26 Blueprint, code offsets live
in these places:
- the function's own jumps: `EX_Jump`, `EX_JumpIfNot`, `EX_PushExecutionFlow`, `EX_Skip`, `EX_SwitchValue` (each case
  and the end);
- for an ubergraph (`ExecuteUbergraph_<Class>`), also in other functions:
  - every event stub calls it with its entry point, an int constant;
  - latent actions resume it through `FLatentActionInfo.Linkage`, an `EX_SkipOffsetConst` in the struct constant next
    to the function's name; -1 means "resume nowhere";
  - a function's `EventGraphCallOffset`, the last 4 bytes of its export data, names an offset when
    `EventGraphFunction` is set (0 in this build).

`EX_Context`'s skip count is the size of its own sub-expression. Statements that move unchanged keep it.

`Reshape` (`tools/patch/AssetPatch/MoreOps.cs`) is the same for a statement changed in place, e.g. `set-call-arg`
putting a variable where a number was: offsets into unchanged statements move by the change before them; an offset
into the changed statement must be the start or the end of an expression that is still there (a switch's case or
its end) and moves with that expression, or the edit is refused.

A jump to the statement where code is inserted lands on the inserted code, so the new code runs wherever that
statement used to.

How it is checked:
- `AssetPatch rewrite-check <dir>`: for every function of every Blueprint under `<dir>`, it inserts a 1-byte statement
  (at the start, the middle and the end). That moves every offset after it. Then it removes the statement again, and
  the asset must write back byte for byte. On the Feb build's `MOBA/Content` (16 Oct): 1,779 assets, 20,486
  functions, 61,458 runs, 0 failed. Every kind of offset above was moved, except `EventGraphCallOffset`, which this
  build doesn't set.
- `AssetPatch reshape-check <dir>`: in every function with a number argument and a variable, the number becomes the
  variable (another size, through `Reshape`) and then the number again; the asset must write back byte for byte. On
  the Feb build (16 Oct): 3,174 functions, 0 failed (37 of them with a switch's offsets inside the changed statement).
- `AssetPatch nop <asset> <function> <statement> <out-dir>` writes a copy with that 1-byte statement in place. Its
  decompile (`tools/bpdump`) must equal the original's, with the moved offsets set back. Checked with the statement
  at the start of the ubergraph of `GS_MOBA_Battle`, `BP_PC_MOBA_PlayerController`, `WB_HUD`, `WB_PreRoundSelection`,
  `BP_PlayerChar`, `BP_PC_Lobby_PlayerController` and Rowan's `BP_GA_WoodenSword_Skill1`: 0 differences, covering
  2,564 jump labels, 374 entry points and 29 latent actions.
- In a match (16 Oct): a test patch (not in the repo) put `insert-call` `ApplyUnstoppable` at the start of Rowan's
  `Lock Pre Dash`, as Aug 2022 had it. In `tools/run/test_patch.sh`, which now also logs `BP_GE_AntiDisplacement_Duration`
  as ANTI-CC, the game server showed Rowan with ANTI-CC from the start of his Dourling Dive (109.69 s) until it ended
  (110.23 s). In the control run without the pak, the same dash gave only the ability lock (109.75-110.38 s). The game
  loaded and ran the rewritten function without errors.

`insert-code`'s JSON form (`tools/patch/AssetPatch/Code.cs`):

| Kind | Form | Bytecode |
|---|---|---|
| variable | `{"local": name}`, `{"self": name}` | a copy of an existing use of that variable |
| literal | `{"str": s}`, `{"bool": b}`, `{"float": f}`, `{"int": n}`, `{"vec": [x, y, z]}` | the constant |
| pure engine call | `{"math": "/Script/Engine.KismetStringLibrary:Contains", "args": [...]}` | `EX_CallMath` |
| member call | `{"on": expr, "call": "/Script/Engine.SceneComponent:SetRelativeScale3D", "args": [...]}` | `EX_Context` + `EX_FinalFunction` |
| statement | `{"do": expr}`, `{"let-obj": local, "value": expr}`, `{"set-bool": {"on": expr, "prop": name}, "value": b}` | the call, `EX_LetObj`, `EX_LetBool` through a context |
| condition | `{"if": expr, "then": [statements]}` | `EX_JumpIfNot` past the block |

Pure static library functions are called with `EX_CallMath`, as the compiler does (`KismetMathLibrary::…` in the
decompile); non-pure static ones (`KismetArrayLibrary.Array_Add`) need the library's default object as context, which
`insert-code` doesn't write yet.

Not done yet:
- `insert-call` into an ubergraph (`insert-code` does it).
- Copying code from another asset, e.g. a function as the developers fixed it in the Dec 2023 build. Its names,
  imports and property references have to be re-created in the target, as `copy-default` does for values.

## New sounds

The game plays most sounds through FMOD, and Unreal's own audio next to it: the pak has 678 cooked `SoundWave` assets
with inline Ogg Vorbis audio, and Blueprints call `GameplayStatics.SpawnSoundAttached` with the attenuation
`/Game/UI/Audio/Sfx/Atten_Default` (Ishir's cast cue). A patch can add a sound the same way:
- **A new asset:** an entry in `assets` with `"template": "<one of the game's assets>"` is a new asset at its `path`.
  - `build.sh` extracts the template.
  - `AssetPatch` copies it and renames its package and object (`/Game/...` and the asset name), then applies the edits.
- **`soundwave-audio`** fills a SoundWave copy with an audio file:
  - The cooked layout after the properties (4.26): `bCooked`, the format count, the format name (e.g.
    `OGG10000-1-1-1-1-1`), the bulk data header, the Ogg payload and `CompressedDataGuid`.
  - Flags 0x48 (inline, single use). The offset field counts from the start of the `.uasset`, so `AssetPatch` lays
    the asset out once to compute it.
- **The audio file is never in git.** It sits in `work/media/` and the patch states its sha256 and where it came from.
  - `build.sh` passes `PATCH_MEDIA_ROOT` (the repo).
  - A missing file fails the build with a message saying where to get it. `server/deploy.sh` runs with `pipefail`, so
    the deploy stops too.
  - A deploy needs the file in the deploying checkout's `work/media/`.
- **`insert-play-sound`** plays the sound where the game already plays one, e.g. next to an FMOD event:
  `SpawnSoundAttached` attached to the same component.
- **Testing a sound:** test clients run with `-nosound`, so the engine has no audio device and plays nothing. A client
  with sound on but every Wine audio driver disabled hung at startup (tried 16 Oct). What a test can show is that the
  sound loads (the engine reads the cooked audio when it loads the asset, `-nosound` or not) and that the call runs (a
  UE4SS hook on the native `GameplayStatics:SpawnSoundAttached`): `tools/run/test_ishir.sh`. Hearing it takes a real
  game.

## Things learned

- UAssetAPI re-saves the Feb 2023 Blueprint assets byte for byte (`AssetPatch roundtrip`, checked on all 10 CC
  assets).
- In UAssetAPI a name (`FName`) is an index into its own asset's name map. A value copied from another asset needs
  every name re-created in the target (`copy-default` does that).
- A gameplay cue whose effect asset was deleted can come back: the cue notify (`BP_GC_…`) and its tag in
  `Config/DefaultGameplayTags.ini` often survive. Put the tag into an effect's `GameplayCues`.
- Calls into Blueprint function libraries are not imports. They are calls by name on the library's default object,
  so switching such a call only changes the name.
- `LockAbilities(0)` locks until something calls `UnlockAbilities`: 0 means "no timeout". A timeout ends the lock
  (the lockout effect gets that duration).
- The pak format:
  - v11 with the path hash index. The path hash is FNV-64 over the lowercase UTF-16 path, with the index's seed
    added to the offset basis; verified against the game's own pak.
  - The full directory index lists every parent directory.
  - The game checks the SHA-1 of each index, which `pakwrite.py` writes.
  - Encrypted paks: `tools/pak` uses pycryptodome, or the `cryptography` package if pycryptodome is missing.
