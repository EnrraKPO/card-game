# Brief: Status Annotation Pass — pricing the rest of the statuses

Status: **AUTHORED 2026-08-06 (uncommitted), suite 1491/1491 green — calibration
gated on playtest.** The eval-channel machinery (STATUS_EVAL_BRIEF.md) is built and
proven on fire (burning/ablaze). This brief walks every other status in
`data/statuses/` and says whether it needs annotations, on which channel, at which
level, and with what starting number. All proposals below are now authored as written;
the clamp guard turned out to already exist (all three consumption sites floor at 0 in
`board_scoring.gd`), so that step became a pinning test. New tests:
`_eval_status_annotation_pass` (off-disk numbers + the Group A double-count guard) and
a negative-add clamp check in `_eval_exposure_consumption`, both in
`test_enemy_engine.gd`. Numbers are starting points — the machinery is settled, the
calibration is not.

## The dividing rule (the one insight that decides everything)

`BoardState.UnitState.from_instance` captures **effective attributes** —
`inst.get_attribute("attack")` etc. — so every standing (`while`-trigger) attribute
effect is ALREADY folded into the stats the engine reads. A +1-attack-per-stack status
is fully visible today, for free.

Therefore: **annotate only what capture cannot see.** That is exactly three shapes:

1. **Interceptors** — they fire at resolution time, never touch stats (blind's miss
   chance, every barrier's block).
2. **Event-triggered effects** — ticks, heals, procs that happen in the future
   (poison's activation tick, mending's turn-start heal).
3. **Rules text with no stat footprint** — grants, spread menace, mana procs.

And the corollary is a hard rule: **never annotate a `while` attribute effect.** The
stats already say it; an annotation says it twice. This is the double-count trap, and
it is the most likely authoring mistake in this pass.

(Accepted blind spot, by design: durations. The engine reads a 2-turn +2 attack as if
permanent. Approximate correctness covers this; do not invent a duration channel.)

## The precedent (what fire authored — mirror its shape)

- `burning`: status-level `exposure +0.25`/stack (spread/lingering menace) +
  effect-level `exposure +1` flat on the tick.
- `ablaze`: identical shape.

## Triage of all 22 remaining statuses

### Group A — pure stat statuses: NO annotation (already visible)

`charged` (+atk/+spd per stack), `frenzied` (same), `slimed` (−spd per stack),
`tailwind` (+spd per stack), `empowered` (+2 atk modifier).

Nothing to author. Verify-only: eyeball one debug capture showing the buffed stats in
`UnitState` (charged is the easy fixture). If any of these got an annotation it would
be a bug, not a tuning choice.

### Group B — the damage ticks: status-level exposure adds (the burning pattern)

| status | proposal | why |
|---|---|---|
| `poison` | status-level `exposure +1`/stack | tick on activation = current stacks; per-stack add is exactly the immediate round's damage. Decay means future rounds shrink — the linear read slightly overestimates the tail; acceptable, same as burning's approximation. No effect-level flat term (unlike burning there is no spread menace to price). |
| `withered` | status-level `exposure +1`/stack | −1 health per turn-end, stacks; same math as poison without the decay. Note: `withered` and `poison` still speak the LEGACY effect format (string triggers) — irrelevant to the fold (annotations are read off the dicts, not the trigger shape), but if this pass touches the files anyway, migrating them is cheap hygiene. |

### Group C — the interceptors: the genuinely new authoring

**`blind`** — effect-level `threat mul ×0.5` on the interceptor. This is the canonical
example from STATUS_EVAL_BRIEF.md, verbatim: 50% miss chance halves expected output
regardless of stacks (stacks are CHARGES — how long it lasts, not how hard it bites).
No status-level term. First interceptor annotation, and the first time the threat
channel's mul plumbing gets a real customer — whatever increment-3 site wraps
`(base + add) × mul` around native output gets exercised here.

**`barrier` (and the block interceptor on all 6 variants)** — status-level
`exposure −2`/stack.

- Why a per-stack add and not a mul: each stack soaks exactly one incoming blow, so
  the value genuinely scales with stacks — and `StatusData` refuses muls at status
  level anyway (EvalChannels.fold_status, adds only). This is the brief's own ward
  example ("a ward that soaks a point each round: −1") scaled to blow size.
- Why −2: a blow ≈ attack × 1 in the early game (captain baseline 1–3, units 1–4);
  −2 says "one middling blow per stack." Playtest number.
- **The clamp question (must settle before shipping):** negative exposure adds can
  drive a unit's incoming reading below zero at the consumption site. Whatever spot
  in BoardScoring drinks the exposure mod must clamp `(base + add) × mul` at 0 —
  a negative incoming reading would make barriers read as HEALING and inflate
  persistence past 1. One-line guard, but it must exist before the first negative
  add ships. (Fire never hit this; all its adds are positive.)
- `stalwart_barrier` intercepts the health channel instead (shield passes through) —
  same annotation, same number; the distinction is below this model's resolution.

### Group D — the barrier riders (one line each, ON TOP of the Group C block)

| variant | rider | proposal |
|---|---|---|
| `empowered_barrier` | +1 atk while | nothing — Group A rule (stats see it) |
| `swift_barrier` | +2 spd while | nothing — same |
| `stalwart_barrier` | +1 shield while | nothing — same |
| `mending_barrier` | heal 1 at turn start | effect-level `exposure −1` on the heal effect |
| `luminous_barrier` | +1 mana when struck away | effect-level `value +0.5` — one-shot proc, mana ≈ 1 value unit, halved for "might never proc" |
| `umbral_barrier` | attacker −1 atk when struck | effect-level `value +0.5` — it lowers a FUTURE attacker's output, which is nobody's threat/exposure at capture time; a small deterrent premium on the third channel is the honest approximation. Defensible to skip in v1. |

### Group E — the blessings: heals only, skip the grants

All six (`air/darkness/earth/fire/light/water_blessing`): their stat lines
(+atk/+spd/+shield/+max_hp) are `while` effects — Group A, invisible ink, no
annotation. Their `grants` (treated-as-element) change composition-condition
eligibility, which this model cannot price honestly — **skip them** (absent =
invisible is the design's own escape hatch; a fabricated value number would be noise).
That leaves the periodic heals:

| status | proposal |
|---|---|
| `light_blessing` | effect-level `exposure −1` on the turn-start heal |
| `water_blessing` | effect-level `exposure −2` on the turn-start heal — and NOTE: the description says "heals 2 on application" but the effect fires EVERY turn start while active. Rules bug or stale description; flag to the user, don't silently pick one. |
| the other four | nothing |

### Group F — the APPLIERS (added 2026-08-06; SUPERSEDED same day by keywords)

> **Reversed 2026-08-06 (user):** the "player cards only" scope is dropped — pricing is
> relevant on enemy cards too, and they are now priced. And the price no longer lives on
> each call site: it rides the KEYWORD. `Venom X` (apply X poison) carries `threat: "$X"`,
> `Blind X` carries `value: "$X"`; every applier references the keyword and inherits a
> price that scales with the number it asks for. See SLOT_LAYER_DESIGN.md §Parameterised
> keywords. What survives from the section below is the JUDGEMENT (poison ≈ 1 damage per
> stack per round). The one-shot exclusion is no longer an authoring rule at all: the FOLD
> enforces it (`EvalChannels.is_spent`, user ruling same day — the channels price standing
> rules, recurring triggers and statuses; a spent moment is history). Every applier now
> uses the keyword, battlecries included.


A unit that applies a status per strike deals recurring damage its victim's statuses
don't show YET — the victim's exposure only prices poison already landed. So standing
appliers carry a flat effect-level `threat` add on the card's apply effect. Authored:
the 5 Blight units (`darkness_water_units.json`) and the Poison King
(`elemental_kings.json`), `threat +1` each — Poison 1 per strike sustains ≈1 extra
damage per round under the tick-equals-stacks math.

Two deliberate exclusions:

- **One-shot on-play appliers get NOTHING** (the combined Blight spell-unit): by the
  time a fielded unit is priced its battlecry already fired, and `EvalChannels`
  folds ALL card effects with no ON_PLAY exclusion — annotating one would mis-price
  the fielded body forever. Test-pinned (`darkness_water` folds neutral).
- **Enemy-tribe appliers stay unpriced** (user scope: player cards only). Cost of the
  scope: the CPU under-reads its OWN poisoners' output in `threat_against(player)`.
  Extend with the same one-line annotation when that matters.

## Order of work

1. **The clamp guard** in the exposure consumption site (Group C prerequisite,
   one line + computation test: negative add never yields negative incoming).
2. **Group B** (poison, withered) — pure data, exercises only machinery fire already
   proved. Cheapest confidence.
3. **`blind`** — first threat-mul customer; verify the mul actually wraps native
   output at the consumption site (computation test on the fold + reading, per the
   testing doctrine: never pin the pick).
4. **Group C barriers + Group D riders** — the negative adds, behind the clamp.
5. **Group E heals** — data only.
6. Playtest calibration pass over all numbers at once (same gate burning had).

## Testing doctrine (unchanged)

Computation only — fold math, channel readings, clamp behavior. NEVER pin which move
the engine picks (EVAL_CRITERIA_BRIEF.md §Testing).

## Tool authorability (added 2026-08-06 — the gap the user caught)

The annotations were NOT tool-authorable, and worse: the Tool's status serializer is a
whitelist, so merely OPENING a status in the Tool and saving would have silently
dropped the status-level `eval` block (effect-level annotations already survived —
`cleanEffectForDeploy` deep-copies and only deletes known keys). Built same day:

- **Status editor** (`Tool/public/editors.js`): "Enemy eval pricing (per stack)" group
  — three per-stack adds — and the serializer now emits `eval` (0 = absent; muls
  refused at this level, matching the game loader).
- **Effect editor** (`Tool/public/effects.js`): collapsed "+ enemy eval pricing"
  section on EVERY effect kind (interceptor for blind, named tick for burn, applier on
  a card) — three adds + three muls; `cleanEffectForDeploy` prunes neutral values
  (0 add, 1 mul) but keeps a 0 MUL (meaningful: "output erased"). Both UIs carry the
  double-count warning.
- **Save gate** (`Tool/server.js` `validateEffect` + the status case): unknown eval
  channels / non-numeric values are refused, mirroring the game's fail-loud parse.
- `STATUS_AUTHORING_GUIDE.md` documents the root `eval` field.

Verified by `node --check` only — not yet exercised in the running Tool.

## Open

- The exposure clamp's exact site (wherever the incoming measurement drinks the mod).
- Barrier's −2: blow-size estimate, playtest-gated.
- Whether umbral/luminous value premiums are worth their noise (skipping is legal).
- `water_blessing` description-vs-effect mismatch — user ruling.
- Grants pricing: deliberately skipped, revisit only if the engine visibly misplays
  around element-composition conditions.
