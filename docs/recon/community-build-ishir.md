# Community patch: Ishir's shotgun sound (built 16 Oct 2026)

a community member's wish (community patch list, Q24 and the second PDF): a shotgun sound when the mark of Ishir's ult (Sever
Spirit) pops, "not overly loud", using a clip a community member linked on myinstants.com. The clip has no stated licence, and we
ship what's in the patch to every player. **The user decided on 16 Oct to use a community member's clip anyway** ("a community member's clip
anyway is fine").

Patch: `tools/patch/patches/community-ishir.json` (`"enabled": false`), branch `cp-ishir`.

## The clip (never in git)

- Source page: https://www.myinstants.com/en/instant/snd-shotgun-blast-64603/
- File: https://www.myinstants.com/media/sounds/snd-shotgun_blast.mp3, downloaded 16 Oct.
- sha256 `07319952c8a9c37f3a0a09c5b055c877c6426f62ded48d5111bd740af9e7ee58`, 32,543 bytes.
- MP3, 44.1 kHz stereo, 1.96 s.
- Local path: `work/media/shotgun-clip/snd-shotgun_blast.mp3`, in the checkout that builds or deploys. The patch
  checks the sha256. A missing file stops `build.sh`, and so `server/deploy.sh`, with a message saying where to get it.
- Loudness: the clip is −9.0 LUFS with peaks at 0 dBFS. The game's own UE gun sounds are −16.1 to −17.3 LUFS
  (`Gun__Revolver__Shot_SND6028*`) and `CannonFire` is −18.0. With `gain_db` −10 the shipped sound is **−19.2 LUFS,
  peak −8 dBFS**, about 3 dB quieter than the revolver shots. Change `gain_db` to tune it.

## When the mark "pops"

- `BackStab/Skill3/BP_GA_ShadowMarkDebuff` (on the marked enemy, server):
  - adds up the damage the enemy takes during the mark;
  - when its delay ends, `DoDamage` deals a percentage of it, and the mark effect ends.
- The mark's gameplay cue `BackStab/Skill3/BP_GC_UltimateMark` (a `GameplayCueNotify_Actor`, on every client) then
  runs `OnRemove`. It destroys the mark's VFX and plays the FMOD event `LifetimeEndSFX` (`Backstab_Skill3_Lifetime_END`)
  attached to the enemy's mesh.
- That's the pop players see and hear, so the shotgun plays there, just before the FMOD end sound.

## How a new sound gets in (route)

- The game's sounds are FMOD banks (`MOBA/Content/FMOD/`). Adding a new FMOD event means building a bank, and we have
  no tooling for that.
- Unreal's own audio is used next to FMOD:
  - the pak has 678 cooked `SoundWave` assets with inline Ogg Vorbis audio;
  - Ishir's own cast cue `BP_GC_BackStab_Skill3_CastSFX` calls `GameplayStatics.SpawnSoundAttached` (with no sound
    since Feb) with the attenuation `/Game/UI/Audio/Sfx/Atten_Default`.
- So:
  - **A new SoundWave**, `/Game/FangsCE/Audio/SFX_Ishir_ShotgunPop`: a copy of the game's `CannonFire` SoundWave
    (`Environment/MapAssets/CTF/CannonFire`, 48 kHz stereo, inline Ogg), renamed. The clip is encoded to Ogg Vorbis at
    48 kHz stereo with the gain, and its `Duration` and `TotalSamples` are set. Edit `soundwave-audio`, `docs/PATCHING.md`
    "New sounds".
  - **The call:** `insert-play-sound` adds `GameplayStatics.SpawnSoundAttached(SFX_Ishir_ShotgunPop, <the marked
    enemy's mesh>, None, 0, 0, KeepRelativeOffset, false, 1.0, 1.0, 0, Atten_Default, nullptr, true)` to `OnRemove`,
    right before the FMOD call, inside its "the target is a hero" branch. Decompiled after the edit:

    ```
    if (!K2Node_DynamicCast_bSuccess) goto L302;
    GameplayStatics::SpawnSoundAttached(SFX_Ishir_ShotgunPop, K2Node_DynamicCast_AsMOBABase_Char.Mesh, Name("None"), FVector(0.0, 0.0, 0.0), FRotator(0.0, 0.0, 0.0), 0, false, 1.0f, 1.0f, 0.0f, Atten_Default, nullptr, true);
    CallFunc_PlayEventAttached_ReturnValue = FMODBlueprintStatics::PlayEventAttached(self.LifetimeEndSFX, ...);
    L302:
    return ReturnValue;
    ```

- Same pak for players and servers. The server never hears it; the cue runs on clients.

## Checks

- Built pak (`build.sh … community-ishir`): the new SoundWave's payload decodes as Vorbis, 48 kHz stereo, 1.96 s. Its
  offset field (924) is where the payload starts in the file. The cue's new imports are `GameplayStatics`,
  `SpawnSoundAttached`, the SoundWave and `Atten_Default`, and its jump moved with the inserted statement (L184 → L302).
- Missing clip: `FAILED: the sound file work/media/shotgun-clip/snd-shotgun_blast.mp3 is missing. Download it from …`.

## Match test (`tools/run/test_ishir.sh`, 17 Oct)

Alice is Ishir and bob is Rowan, in a two-player custom match with the patch on both clients and the game server.
Both clients hook the native `GameplayStatics:SpawnSoundAttached` and run the mark cue's `OnRemove` for bob, the edited
function that the end of a real mark runs (`RUN=ishir-d`, `ishir-e`). Each client logged:

```
SpawnSoundAttached(SFX_Ishir_ShotgunPop, attached to CharacterMesh0 of BP_WoodenSword_Char_C_…)
asset loaded: SoundWave /Game/FangsCE/Audio/SFX_Ishir_ShotgunPop.SFX_Ishir_ShotgunPop, 1.960 s, 2 channels, 48000 Hz
```

The edited `OnRemove` runs the new call with the new sound, attached to the marked hero. The engine loads the cooked
SoundWave with the duration, channels and sample rate the patch wrote; loading reads the inline Ogg payload.

**Not shown by a test:**
- **Hearing it.** Test clients run with `-nosound`: the engine has no audio device, and `SpawnSoundAttached` returns no
  component. A client with sound on but every Wine audio driver disabled hung at startup (`RUN=ishir-a`). Audibility
  and loudness need one real game: Ishir ults someone and waits for the mark to pop.
- **The natural trigger.** Fired from a script, the ult didn't mark bob: it searches enemies around the pointer and
  waits for recasts (`ishir-b`, `ishir-c`). The mark effect applied from Lua on the server didn't stick either
  (`BP_GE_ShadowMark` through `MakeOutgoingSpec` + `SetSpecDuration` + `BP_ApplyGameplayEffectSpecToSelf`: 0 effects
  right after). The cue's `OnRemove` is where the game plays its own FMOD end sound for the pop, so the new call sits
  on the same path.

`AssetPatch rewrite-check` on the Feb build: 0 failed. The ops add no code to `Rewrite.cs`.

## Twice for the Ishir player (23 Oct)

The user's report: "ishir ult gun sfx is firing twice (once on press, once on deathmark procc/explosion.) remove the
first one (when he just pressed ult)".

**Cause.** The ult (`BP_GA_Backstab_Skill3`, `NetExecutionPolicy` 0 = LocalPredicted) puts the mark on in its first cast
(`ApplyMarkToTarget`: `K2_ApplyGameplayEffectSpecToTarget(BP_GE_ShadowMark, AbilityTargetDataFromActor(self.Target))`),
right on the press. Ishir's own client predicts that effect on the enemy: the mark cue starts (`OnActive`). When the
server's answer arrives, the client drops its predicted copy, and that runs the cue's `OnRemove`, where the shotgun is.
The server's own mark then starts the cue again, and its real pop runs `OnRemove` a second time. Other players only
ever get the server's mark: one shotgun, at the pop. Whether the predicted copy's removal runs `OnRemove` is a race
(GAS skips it when the server's copy got there first), so with real ping it happens more often than locally.
The game's own FMOD sounds of the mark (`LifetimeSFX`, `LifetimeEndSFX`) were doubled for Ishir the same way.

**Fix** (`community-ishir.json`, `BP_GA_Backstab_Skill3`): only the server applies the mark. Both
`AbilityTargetDataFromActor(self.Target)` calls in `ApplyMarkToTarget` get
`SelectObject(self.Target, nullptr, IsServer(self))`, so on a client the target data holds no actor and nothing is
predicted (`replace-call-arg`; `insert-code` expressions gained `{"null": true}` and `{"this": true}` for it).
Decompiled:

```
CallFunc_AbilityTargetDataFromActor_ReturnValue_1 = AbilitySystemBlueprintLibrary::AbilityTargetDataFromActor(KismetMathLibrary::SelectObject(self.Target, nullptr, KismetSystemLibrary::IsServer(self)));
```

Ishir's own screen shows the mark when the server's arrives (50 ms later in the local test, about one ping in a real
game) instead of at the press. Damage, the debuff ability and every other player's view are unchanged.

**Test** (`MODE=ult tools/run/test_ishir.sh`: alice = Ishir presses R as a player does, twice; bob stands where the ult
searches; both clients log every start and end of the mark cue and every shotgun play, `test_ishir_ult.steps`):

| Run | alice (Ishir), cast 1 | alice, cast 2 | bob |
|---|---|---|---|
| `ishir-ult2` (live patch) | press 270.69: `OnActive`; 270.74: **shotgun + `OnRemove`**, `OnActive`; pop 274.37: shotgun + `OnRemove` | press: `OnActive` ×2 (no extra shotgun: the race went the other way); pop: shotgun | one shotgun per cast, at the pop |
| `ishir-ult3` (with the fix) | press 270.84; 270.89: `OnActive` (the server's); pop 274.54: shotgun + `OnRemove` | press 283.15; 283.17: `OnActive`; pop 286.84: shotgun | one shotgun per cast, at the pop |
