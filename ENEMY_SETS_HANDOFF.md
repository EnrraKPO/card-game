# Enemy Sets — wrap-up handoff (branch `enemy-sets`, 2026-07-21)

The overnight build stopped at the wrap-up point. This documents exactly where things stand
and **everything that was planned but not done**, so you can decide what happens next.
Roster/mechanics overview: `data/encounters/ENEMY_SETS.md`.

## What is DONE and verified

- **Engine**: `spawn` effect payload (queued, flushed after death sweeps, powers splits /
  per-round summons / two-phase bosses) and the `strikes` multi-attack stat (foldable,
  target re-acquired per strike). Both documented in the card guide, Tool vocab synced
  (including previously-missing dodge/crit foldables and dodge/crit dual events).
- **Verification**: suite at **585 passed / 26 failed — the 26 (and the Tool api_test
  `kinAnchorMode` crash) are PRE-EXISTING on main**, bit-identical before my first commit.
  +20 new suite cases (spawn parse/round-trip, strikes fold). `tests/_spawn_smoke.tscn`
  proves on a real board: a split reclaims its corpse slot, a dying boss king spawns its
  phase-2 form and the fight continues, strikes read on fielded units. It uses an
  in-memory profile — unlike `_combat_smoke`, it can never touch a save slot.
- **Content**: 11 tribes + 3 easter-egg encounters — **40 combat / 15 elite / 9 boss
  templates**, 3 new statuses (slimed, frenzied, tailwind), ~120 cards, all loading clean.
- **Art**: ~120 Krea 2 illustrations deployed to `assets/cards/enemies/`. Pipeline:
  `node tools/enemy_art_gen.mjs <manifest> <outdir>` against ComfyUI at
  `http://127.0.0.1:8000` (NOT 8188 — that's AudioGen). All prompt manifests preserved in
  `tools/enemy_art_manifests/` (delete a PNG + rerun to regenerate).

## NOT done — the outstanding list

### Needs doing before this ships
1. **Visual inspection of ~57 images.** Slimes, beasts, harpies, insects, aliens, pirates,
   and cultists (through the Prophet) were each inspected for quality/concept/left-facing —
   all passed, zero flips needed. **Not yet inspected**: trolls (7), fairies (8), dinos (9),
   corporate (11), K-Pop (6), football (6), mimics (5), and the last two cultists
   (`cult_hierophant`, `cult_elder_god`). They're generated and deployed but nobody has
   looked at them. Check facing (should be left) and concept; the Tool's ⇋ flip button or a
   System.Drawing `RotateFlip` handles any wrong-facing ones.
2. **Godot import pass.** New PNGs import when the editor regains focus once (or
   `Godot_console --headless --editor --quit --path D:\Godot\CardGame`).
3. **Playtest.** Nothing has been played in the real game. Priority fights to try:
   any slime combat (split cascades + board-full fizzle), the Slimeon boss (phase-2 king
   swap mid-combat, the highest-risk new path), an insect fight (cocoon self-ripening,
   Locust aura), a harpy fight (multi-strike animation cadence — three full lunge
   sequences per Kyrraxa turn may feel slow; if so, a compressed flurry animation is the
   fix), and one easter egg (force via `weight` bump).

### Planned features that were never started
4. **VFX polish.**
   - `summon_materialize` is still a `placeholder: true` library entry — spawns currently
     cue a plain ring. A designed materialize look (+ its `summon_token` sfx exists) would
     sell splits and phase changes hard.
   - No dedicated cue for the multi-strike flurry or for the spawn RESULT dict in
     `VFXPlayer.play_results` (spawn results currently just glint the source card).
   - Per-tribe death variants (`death_<tribe>`) — the `tribe` field is wired on every new
     card, but no tribe-flavored cue entries were authored.
5. **Status pip icons** for slimed / frenzied / tailwind — glyph+color fallback active
   (`~`, `!`, `≋`); the Tool generates proper pips to `assets/ui/status/<id>_status.png`.
6. **Per-tribe enemy AI.** Everything uses `"default"`. The `EnemyAI.from_key` registry is
   the extension point; sketched personalities: cultists holding Willing Offerings in the
   kill zone, slimes preferring front-loaded walls, alien commander shield-prioritizing,
   Kraken focus-firing the weakest column.
7. **Enemy spells.** The AI already casts spells; no tribe got any. Sketched: slime
   *Mitosis* (spawn 2 greens on a target slot), cultist *Dark Offering* (kill own unit,
   buff all), corporate *Restructuring* (both sides discard/draw).
8. **Spawn × power scaling.** Spawned units arrive at BASE stats — deliberately, so splits
   don't snowball with depth — while deck units get `CardData.scaled`. If deep-floor slime
   fights feel too easy relative to their pool, route `_spawn_from_queue` through the
   encounter's power like `place_kings` does.
9. **Tool authoring UI for `spawn`.** Server-side validation accepts the payload (saves
   won't be rejected), but the effect-builder UI has no spawn row yet — authoring spawn
   effects today means editing JSON.

### Design ideas parked (discuss before building — per house rules)
- **Taunt/guard** positional mechanic (no way to protect the backline yet; several tribes
  wanted a true tank).
- **Timed transform** — the cocoon fakes metamorphosis via self-damage + on-death spawn; a
  first-class "after N rounds, become X" would also serve boss phase timers.
- **Mind control / owner swap** (alien abduction fantasy) — big arbitration-layer feature.
- **Instigator provenance** ("dies from poison *I* applied") — already deferred in the
  statuses design; would unlock cleaner cultist/venom payoffs.
- More easter eggs on the shortlist: *The Quackening* (rubber ducks), a merchant-gone-mad
  fight, goat-men, zombie-expansion proper (current undead expansion just remixes
  placeholder units).
- **Second wave of tribes** from the original brief never reached: worms/wurms (burrowing =
  spawn-relocation), bandits, monkeys, mutants, spirits (ethereal = high dodge + barrier).

### Housekeeping notes
- Your live Tool session's uncommitted edits (`data/cards/air_air_units.json`,
  `Tool/workspace/edits.json`) were deliberately left out of every commit.
- Card JSONs don't carry `tool.art` recipes — regeneration goes through the manifests in
  `tools/enemy_art_manifests/` (same prompts, new seeds) or the Tool per-card.
- The elite/boss "epic" mapping: "epic encounters" = the existing `elite` node type, as
  planned; no fourth tier was added.
