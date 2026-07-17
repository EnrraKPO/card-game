# Critical Damage — Continuation Spec

Written after finishing Dodge end-to-end (branch `kill-event`, commits from "Dodge: attack-avoidance
as a core combat resolution form" through "Dodge: speed-badge glint uses the relic-chip effect").
This is a **planning document only** — nothing here is implemented. It maps every phase we actually
did for Dodge onto the analogous Critical Damage feature, so a fresh session can pick this up and
build it the same way, in the same order, without re-deriving the process.

**Read `scripts/resolver.gd` (dodge_chance, _dodge_config, the DODGE stat) before starting** — it's
the concrete reference implementation for almost every phase below. Where crit's design diverges
from dodge's, the divergence and its reasoning are called out explicitly.

## The seven phases, in build order

1. Core resolution (Resolver)
2. VFX + SFX cues
3. Data-driven tuning + Tool handle
4. Trigger event (`crit`) + a reactive relic
5. Grantable stat(s) + a granting relic
6. Interceptable rate + two rate-shaping relics
7. Ordering/interaction fixes + a late-discovered exclusion (mirrors "buildings don't dodge")

Each phase should land as its own commit with its own test-suite proof, exactly like Dodge did —
`git log --oneline` on `kill-event` from the dodge work is the literal template for the commit
sequence and message style.

---

## Decisions — RESOLVED with the user 2026-07-17

These were open questions; the user has answered all four. **These override anything to the
contrary in the phase text below** (the phases were drafted before the answers came in; the
important deltas are also patched inline, but if a conflict slips through, this section wins).

1. **Crit chance scales with the ATTACKER's Speed.** Not Attack (avoids double-dipping with the
   damage stat), not flat-only. Symmetry with dodge: Speed is the "precision" stat on both sides
   of an exchange — defender's speed drives dodge, attacker's speed drives crit. Config terms are
   therefore `fixed_pct` + `per_speed_pct` (× attacker speed), with `per_speed_diff_pct`
   available-but-zero, mirroring dodge's shape exactly. Knock-on: the Phase 2 badge glint is the
   **Speed** badge (`flash_stat_proc("speed")` on the attacker), not Attack — speed is what caused
   the crit.
2. **Two knobs, asymmetric scaling.** `crit_chance` = speed-scaled per decision 1.
   `crit_multiplier` = flat tunable base + its own foldable/grantable `crit_multiplier_bonus`
   stat; NO stat scaling on the multiplier. Both remain interceptable queries.
3. **Crit never procs on zero damage — crit resolves AFTER interception.** The pipeline is
   dodge → interception → crit → shield split. Crit only rolls if the post-interception amount
   is > 0, and the multiplier applies to the final resolved amount. This makes the barrier
   question moot by construction: a Barrier-blocked hit is 0 damage → no crit roll, no `crit`
   event, no crit VFX; the barrier is consumed as an ordinary block. Generalizes to any future
   negation effect with no special-casing. Accepted consequence: defensive interceptors shape the
   base hit and crit multiplies what's left — anti-crit defense goes through the interceptable
   `crit_chance` / `crit_multiplier` queries instead (Steady Hand Ward's design is unaffected).
4. **No building exclusion, either direction.** A rook can land a critical hit and can be
   critically hit. State this in the Phase 1 commit message so it reads as deliberate.

### Proof-relic coverage matrix (REQUIRED deliverables, per user)

Every mechanical surface of Crit must be proven by an actual authored relic in
`data/relics/relics.json`, not just by unit tests — one relic per case, minimum five relics
total. This mirrors how each dodge capability got a shipping relic as its proof. The phases
below each specify their relic(s); this table is the completeness check:

| # | Case to prove                        | Relic (specified in)                  |
|---|--------------------------------------|---------------------------------------|
| 1 | Crit chance modifier (grantable stat)| Eagle-Eye Charm (Phase 5, Relic A)    |
| 2 | Crit damage multiplier modifier      | Executioner's Edge (Phase 5, Relic B) |
| 3 | Crit as an effect TRIGGER (`crit` event) | Berserker's Momentum (Phase 4)    |
| 4 | Crit interception — multiply chance  | Warlord's Fury (Phase 6, Relic A)     |
| 5 | Crit interception — deny outright    | Steady Hand Ward (Phase 6, Relic B)   |

Do not mark the feature done until all five exist, are acquirable in-game, and each has its
matching test.

---

## Phase 1 — Core resolution (Resolver)

**Dodge reference:** `Resolver._submit`, `Resolver.dodge_chance`, `Resolver._dodge_config`,
`StatMutation.DODGE_BONUS`, the `dodge_enabled` toggle, `Effect.FOLDABLE_ATTRS` /
`Effect.CARD_ATTR` additions, `CardInstance.get_attribute("dodge_bonus")`. Also read the
**Phase 7 fix** below before writing this phase — the ordering lesson from dodge (resolve BEFORE
interception) directly informs where crit sits in the pipeline.

**Design.** Critical damage is a resolution-layer concern, not an effect — same status as dodge.
It belongs in `Resolver._apply_damage` / `_submit`, gated to `StatMutation.DAMAGE` on
`CH_ATTACK` only (poison/effect damage never crits, mirroring "poison/effect damage never
dodges").

**Pipeline placement** (per resolved Decision 3 — crit comes AFTER interception):

```
_submit(m: DAMAGE, CH_ATTACK)
  1. DODGE check (existing) — target evades outright, short-circuits, no interception at all
  2. _intercept(m)          — Blind, Barrier, relics rewrite the base amount
  3. CRIT check (new)       — ONLY if m.amount > 0 after interception: roll
                               crit_chance(attacker, target); on success multiply the final
                               resolved amount by crit_multiplier(attacker)
  4. _apply_damage           — shield-first split, as today
```

Layers: evasion → defense → offense-spike → mitigation. A fully-negated hit (Barrier, any future
negation) deals 0 → never rolls crit → no `crit` event, no crit VFX. Defensive interceptors shape
the base hit, then crit multiplies what's left; the dedicated anti-crit levers are the
interceptable `crit_chance` / `crit_multiplier` queries themselves.

**New stats (`stat_mutation.gd`):**
```gdscript
const CRIT_CHANCE_BONUS := &"crit_chance_bonus"       # stored/foldable, percentage points
const CRIT_MULTIPLIER_BONUS := &"crit_multiplier_bonus" # stored/foldable, percentage points added to the multiplier
const CRIT := &"crit_chance"        # transient interceptable QUERY (mirrors StatMutation.DODGE)
const CRIT_MULT := &"crit_multiplier" # transient interceptable QUERY (the damage multiplier itself)
```

**New CardInstance.get_attribute cases** (mirrors the `dodge_bonus` case exactly):
```gdscript
"crit_chance_bonus":    return modifiers.get("crit_chance_bonus", 0) + LiveEffects.bonus(self, "crit_chance_bonus")
"crit_multiplier_bonus": return modifiers.get("crit_multiplier_bonus", 0) + LiveEffects.bonus(self, "crit_multiplier_bonus")
```

**New `Effect.CARD_ATTR` entries:**
```gdscript
"unit.crit_chance_bonus":     "crit_chance_bonus",
"unit.crit_multiplier_bonus": "crit_multiplier_bonus",
```
And both added to `Effect.FOLDABLE_ATTRS`.

**`Resolver.crit_chance(attacker, target) -> float`** (mirrors `dodge_chance` almost exactly, but
note the PARTICIPANT ROLES ARE SWAPPED relative to dodge — flag this loudly in code comments,
it's the one place someone will get confused copying the dodge pattern):
- Dodge's transient `StatMutation` has `target` = the defender (the one whose evasion we're
  querying) and `source` = the attacker. Interceptor `participant: "target"` therefore means
  "the dodger."
- Crit's transient `StatMutation` should have **`target` = the attacker** (the one whose crit
  chance we're querying) and **`source` = the defender being struck**. Interceptor
  `participant: "target"` therefore means "the unit landing the crit" — NOT the unit being hit.
  This is intentional (the mutation's `target` field always means "whoever this quantity belongs
  to"), but it inverts attacker/defender roles relative to dodge_chance's mutation, so write a
  comment on `crit_chance` explaining this explicitly, the way `dodge_chance`'s docstring
  explains its own participant wiring.

```gdscript
static func crit_chance(attacker: CardInstance, target: CardInstance = null) -> float:
    if attacker == null:
        return 0.0
    var cfg := _crit_config()
    var pct := float(cfg["fixed_pct"])
    pct += float(cfg["per_speed_pct"]) * float(attacker.get_attribute("speed"))  # Decision 1
    # per_speed_diff_pct term available-but-zero, mirroring dodge's optional terms
    pct += float(attacker.get_attribute("crit_chance_bonus"))
    var m := StatMutation.make(attacker, StatMutation.CRIT, maxi(0, int(round(pct))),
            target, StatMutation.CH_ATTACK)
    _intercept(m)
    return clampf(minf(float(m.amount), float(cfg["max_pct"])), 0.0, 100.0) / 100.0
```

**`Resolver.crit_multiplier(attacker) -> float`** — same shape, its own interceptable query, base
multiplier + `crit_multiplier_bonus` fold, its own `_intercept` pass on stat `CRIT_MULT`.

**Data-driven tuning config** (`data/combat_tuning.json`, add a `"crit"` sibling to `"dodge"`):
```jsonc
{
  "dodge": { /* existing */ },
  "crit": {
    "fixed_pct": 5,
    "per_speed_pct": 1,        // Decision 1: chance scales with attacker Speed; tune the ratio
    "per_speed_diff_pct": 0,
    "max_pct": 75,
    "multiplier": 2.0,        // total damage = base * multiplier on a crit
    "multiplier_max": 5.0     // ceiling, mirrors dodge's max_pct — no relic makes a hit infinite
  }
}
```
`Resolver._crit_config()` mirrors `_dodge_config()` (lazy-cached, `DEFAULT` fallback dict,
partial-file tolerant). `Resolver.crit_enabled` master switch mirrors `dodge_enabled`, defaulted
`true`, flipped `false` in `tests/_runner.gd::_clean_env()` exactly like dodge's.

**`Outcome` additions** (mirrors `Outcome.dodged`):
```gdscript
var crit: bool = false        # this hit was a critical — the seam for VFX/SFX/event hooks
var crit_bonus_damage: int = 0 # how much extra the crit added, for presentation
```

**Where the multiplier actually applies** — AFTER the general `_intercept(m)` call, per the
pipeline above (Decision 3): if `m.amount > 0` post-interception, roll
`crit_chance(attacker, target)`; if it hits, multiply `m.amount` by `crit_multiplier(attacker)`,
round, record `crit = true` and `crit_bonus_damage = new_amount - old_amount` on the eventual
Outcome, then continue into `_apply_damage`'s shield-first split. If the post-interception amount
is 0, skip the roll entirely — no crit flag, no event, no VFX.

---

## Phase 2 — VFX + SFX cues

**Dodge reference:** `VFXEvent.DODGE` / `VFXEvent.dodge()`, `scripts/vfx/effect_dodge.gd`
(`VFXEffectDodge`), the `combat_dodge` entry in `data/vfx/vfx.json`, the `attack_dodge` entry in
`data/sounds/sounds.json`, the `combat._apply_attack_damage` branch on `outcome.dodged`, and the
later **speed-badge glint fix** (`CardUI.flash_stat_proc`, reusing the relic-chip pop+brighten
effect — read `scripts/card_ui.gd::flash_stat_proc` before designing this, don't repeat the
square-Panel-sheen mistake).

**Design.** Unlike a dodge (which replaces the damage number with "Dodge!" because nothing
landed), a crit **still deals real damage** — the cue needs to sit ALONGSIDE the normal
`health_damage` / `shield_hit` VFX, not replace it. Two things read a hit as critical:

1. **A "Critical!" label** — bold, hot color (orange/red, distinct from the cyan `DODGE_COLOR`
   and the grey Miss color), popping near the damage number. New `VFXEvent.Type.CRIT` +
   `VFXEvent.crit(card)`, new `VFXEffectCrit` (`scripts/vfx/effect_crit.gd`) — a float label
   ("Critical!") plus maybe a bigger/bolder rendering of the accompanying damage number (a `crit`
   flag threaded onto the `HEALTH_DAMAGE` VFXEvent so `VFXEffectHealthDamage` can render it in the
   hot color / larger font when true — check whether `_float_label` needs a size/weight parameter
   added, or whether a second overlapping label is simpler).
2. **The ATTACKER's Speed badge glints** — mirrors the dodge speed-badge glint EXACTLY:
   `card.flash_stat_proc("speed")` on the attacker's CardUI, reusing the already-generic method
   (no new VFX code needed here). Speed — not Attack — because per Decision 1 the attacker's
   Speed is what drove the crit. Same badge dodge glints, but on the attacking card, so the two
   cues don't collide.

**vfx.json entry:**
```jsonc
{
  "id": "combat_crit",
  "display_name": "Critical Hit",
  "category": "combat",
  "renderer": "custom",
  "behavior": "float_label",
  "params": { "color": "ff6a3d" },
  "placeholder": false,
  "sfx": "attack_crit",
  "concept": "An attack lands unusually hard — needs to read as a POWERFUL escalation, distinct from a normal hit and from the target's own Dodge cue.",
  "prompt": "Sprite sheet of a sharp red-orange impact burst, jagged energy crack radiating outward, 6 frames on transparent background, 2d game effect"
}
```

**sounds.json entry:** `attack_crit` — a heavier, punchier impact than the normal hit sound
(`combat_health_damage`'s sfx) and clearly distinct from `attack_dodge`'s whoosh — a "crunch" or
"thud", one-shot, ~0.4s. Follow the existing sounds.json `concept`/`prompt` field conventions.

**combat.gd wiring** — in `_apply_attack_damage`, after computing `outcome`, alongside the
existing shield/health VFX block (not instead of it):
```gdscript
if outcome.crit:
    _vfx.play(VFXEvent.crit(t_card))
    a_card.flash_stat_proc("speed")   # a_card is the attacker's CardUI — Speed drove the crit
```
Confirm the local var name for the attacker's CardUI in `_apply_attack_damage` (it's `a_card` in
the existing dodge wiring's sibling code) before writing this.

---

## Phase 3 — Data-driven tuning + Tool handle

**Dodge reference:** `data/combat_tuning.json`, `Resolver.DODGE_DEFAULT` / `_dodge_config()`,
the `⚡ Dodge` button + modal in `Tool/public/index.html` / `Tool/public/app.js`
(`openCombatTuningModal`, `renderCombatTuningModal`, the speed-vs-speed heat grid), and the
`/api/combat-tuning` GET/POST pair in `Tool/server.js` (`getCombatTuning`).

**Design.** Extend the SAME modal and the SAME endpoint rather than adding new ones — the tuning
file already groups by feature (`{"dodge": {...}}`), so `{"crit": {...}}` is a sibling key on the
same JSON, and `/api/combat-tuning` should read/write both in one round trip (`getCombatTuning()`
returns `{dodge: {...}, crit: {...}}`; the POST body may contain either or both keys, each merged
independently — mirror the existing per-key `num(v, fallback)` merge pattern).

**Tool UI** — two reasonable shapes, pick one when implementing:
- (a) One modal, two tabs/sections ("Dodge" / "Crit") — avoids toolbar clutter.
- (b) A second button `💥 Crit` opening its own modal, structurally identical to
  `renderCombatTuningModal` but with a chance×multiplier live preview instead of dodge's
  speed-vs-speed grid (e.g. a chance slider + multiplier slider + a single live "expected damage
  multiplier" readout: `1 + chance × (multiplier − 1)`).

Recommend (b) for a first pass — it's a smaller diff (copy-paste-adapt the existing modal
function) and matches how dodge's own handle was added as an incremental sibling button rather
than folded into an existing one.

---

## Phase 4 — Trigger event (`crit`) + a reactive relic

**Dodge reference:** `GameEvent` docs + `subject()` (dodge case), `TriggerResolver.DUAL_EVENTS`,
the `combat._broadcast(GameEvent.make(&"dodge", attacker, target))` call site, `_event_ctx`'s
`dodge` branch, and the Zephyr Charm relic (`data/relics/relics.json`) + its
`tests/test_triggers.gd::_dodge_event` test.

**Design — subject() is the ATTACKER, not the target (this is the opposite of dodge/struck/kill).**
Dodge/struck/kill are all framed from the AFFECTED party's perspective (passive voice — "it was
struck," "it died," "it dodged"), so their `subject()` returns `destination`. Crit is framed from
the ACTING party's perspective ("it landed a crit"), matching `attack`'s convention, so:

```gdscript
# in GameEvent.subject():
func subject() -> CardInstance:
    if (id == &"struck" or id == &"kill" or id == &"dodge") and destination != null:
        return destination
    return origin   # crit falls through here, same as attack — origin IS already the default
```
No new branch needed — `crit` just needs to NOT be added to that destination-returning list,
because origin is already the fallback. Document this explicitly (a future reader will assume
every dual event needs a subject() case; crit is the one that doesn't).

Register `&"crit"` in `TriggerResolver.DUAL_EVENTS`. Emit it from `combat.gd` right after the
crit VFX (Phase 2), mirroring the `dodge` broadcast placement:
```gdscript
if outcome.crit:
    await _broadcast(GameEvent.make(&"crit", attacker, target))
```
`_event_ctx`: add a `crit` branch exposing `ctx.attack_target = event.destination` (mirrors the
`attack` branch, not the `struck`/`dodge` one — again because crit's subject is the origin, so
the thing worth exposing to a reacting effect is who got hit, i.e. the destination).

**Sample relic** (mirrors Zephyr Charm's shape — dual-event trigger, one participant gated by
composition + allegiance, targets the participant that fired it):

```jsonc
{
  "id": "berserkers_momentum",
  "display_name": "Berserker's Momentum",
  "description": "Whenever an allied fire unit lands a critical hit, it gains 1 Attack.",
  "color": "d9502f",
  "letter": "B",
  "price": 110,
  "effects": [{
    "kind": "triggered",
    "trigger": {
      "kind": "dual_event", "event": "crit",
      "origin_conditions": [{"composition": ["fire"]}, {"allegiance": "ally"}]
    },
    "targets": {"kind": "participant", "participant": "origin"},
    "attribute": "attack", "amount": 1
  }]
}
```
Note `origin_conditions` (not `destination_conditions` like Zephyr Charm) and
`participant: "origin"` (not `"destination"`) — the direct consequence of crit's subject being
the attacker.

**Test** (`tests/test_triggers.gd::_crit_event`, mirrors `_dodge_event`): `GameEvent.subject()`
returns origin; the relic resolver fires for an allied fire attacker's crit, stays silent for a
non-fire ally and for an enemy fire unit's crit (anchored to the player); end-to-end
`EffectSystem.trigger_global` dispatch actually bumps the attacker's Attack by 1.

---

## Phase 5 — Grantable stat(s) + a granting relic

**Dodge reference:** `dodge_bonus` (Phase 1 of the dodge work, done as its own commit), the Gale
Sigil relic ("All your air units get +25% Dodge"), `tests/test_dodge.gd::_dodge_bonus_fold`.

**Design.** This phase is mostly already folded into Phase 1 above for Crit (`crit_chance_bonus`
+ `crit_multiplier_bonus` are specified there, since crit's two-axis nature made it natural to
build the stat plumbing alongside the core resolution rather than as a strictly later phase like
dodge did). What's left here is purely the **content**: two granting relics, one per axis, each
its own commit+test mirroring Gale Sigil's shape.

**Relic A — chance:**
```jsonc
{
  "id": "eagle_eye_charm",
  "display_name": "Eagle-Eye Charm",
  "description": "All your air units get +25% Crit chance.",
  "color": "c9a13a",
  "letter": "E",
  "price": 110,
  "effects": [{
    "kind": "modifier", "key": "unit.crit_chance_bonus", "amount": 25,
    "conditions": [{"composition": ["air"]}]
  }]
}
```

**Relic B — magnitude** (the genuinely new axis dodge never had — worth its own relic to prove
`crit_multiplier_bonus` independently):
```jsonc
{
  "id": "executioners_edge",
  "display_name": "Executioner's Edge",
  "description": "All your darkness units deal +50% Critical damage.",
  "color": "5a2a6b",
  "letter": "X",
  "price": 120,
  "effects": [{
    "kind": "modifier", "key": "unit.crit_multiplier_bonus", "amount": 50,
    "conditions": [{"composition": ["darkness"]}]
  }]
}
```
(`crit_multiplier_bonus` reads as percentage points added to the multiplier — e.g. base 2.0×
+ 50 → 2.5×; pin down the exact unit convention — "points of multiplier ×100" vs "raw multiplier
delta" — when writing `Resolver.crit_multiplier`, and keep it consistent with how `multiplier` is
authored in `combat_tuning.json`.)

**Tests** (`tests/test_crit.gd::_crit_chance_bonus_fold` / `_crit_multiplier_bonus_fold`, mirror
`_dodge_bonus_fold`): written modifier folds into `get_attribute`; the relic's standing modifier
reaches an allied air/darkness unit only (not off-composition allies, not enemies); the bonus
flows into `crit_chance()` / `crit_multiplier()` respectively; remember the **pawn/chess-piece
gotcha** from dodge's own test-writing — a `CardData.build_from_dict` test unit needs a
`chess_pieces` entry or it's classified as a SPELL and the stat fold silently skips it (see
`FOLDABLE_ATTRS`/spell-exclusion note in `LiveEffects._contributes`). Don't lose an hour to that
again.

---

## Phase 6 — Interceptable rate + two rate-shaping relics

**Dodge reference:** `Resolver.dodge_chance`'s `_intercept(m)` call (already specified as part of
Phase 1 above for crit — both `crit_chance` and `crit_multiplier` are interceptable queries from
the start, unlike dodge where interception was a distinct later commit). Cyclone Totem / Trueshot
Sigil relics, `tests/test_dodge.gd::_dodge_interception`.

**Design.** Same as Phase 5 — the plumbing (the `_intercept(m)` call inside `crit_chance` /
`crit_multiplier`) is specified in Phase 1, so this phase is content + tests only, exactly
mirroring Cyclone Totem (scale up an allied trait) and Trueshot Sigil (cancel for enemies) but
remembering **the participant-role swap from Phase 1**: for `crit`, `participant: "target"` means
the ATTACKER (the query's own owner), not the defender.

**Relic A — scale up:**
```jsonc
{
  "id": "warlords_fury",
  "display_name": "Warlord's Fury",
  "description": "Your fire units have 3x Crit chance.",
  "color": "c9502f",
  "letter": "W",
  "price": 140,
  "effects": [{
    "kind": "interceptor", "intercept": "crit_chance", "op": "mul", "amount": 3,
    "of": {"participant": "target", "relation": "ally"},
    "conditions": [{"composition": ["fire"]}]
  }]
}
```
(`intercept: "crit_chance"` must match `StatMutation.CRIT`'s string value exactly — confirm the
const's actual StringName spelling when implementing, the same way `intercept: "dodge"` had to
match `StatMutation.DODGE`.)

**Relic B — cancel:**
```jsonc
{
  "id": "steady_hand_ward",
  "display_name": "Steady Hand Ward",
  "description": "Enemy units cannot land critical hits.",
  "color": "6b6b7a",
  "letter": "S",
  "price": 130,
  "effects": [{
    "kind": "interceptor", "intercept": "crit_chance", "op": "mul", "amount": 0,
    "of": {"participant": "target", "relation": "enemy"}
  }]
}
```

**Test** (`tests/test_crit.gd::_crit_interception`, mirrors `_dodge_interception`): 3× applies to
a fire ally only; cancel zeroes an enemy attacker's crit chance while leaving an ally's intact;
the `max_pct` cap still bounds an amplified rate (a 5× interceptor against a high base still
clamps).

---

## Phase 7 — Ordering/interaction fixes + the building question

**Dodge reference:** the barrier-consumption bug (`git log` message "Fix: resolve dodge before
interception so it doesn't spend a barrier") and the "buildings don't dodge" follow-up. Both
arrived AFTER the feature initially shipped, as user-reported tension. Crit's spec above tries to
preempt both classes of issue up front instead of discovering them the same way — but treat this
phase as the checkpoint to verify they actually hold once real code exists, not as optional.

**Checklist to verify once Phase 1–6 are built:**

1. **Dodge takes priority over crit.** A dodged attack must never also register as a crit — verify
   the dodge check really does short-circuit before the crit roll in `_submit`/`_apply_damage`
   (Phase 1's pipeline ordering). Test: force `dodge_enabled` tuning to 100% and `crit` tuning to
   100%, submit a damage mutation, assert `outcome.dodged == true` and `outcome.crit == false`.
2. **A fully-blocked hit never procs crit (and still consumes Barrier).** Decision 3 made
   concrete as a regression test: force crit chance to 100%, apply a Barrier to the target,
   submit the damage — assert `outcome.crit == false`, no `crit` event was broadcast, no crit
   bonus damage, AND the barrier status is gone afterward (consumed as an ordinary block; only
   dodge preserves it). Companion positive case: a partially-reduced hit (e.g. Blind) that still
   deals > 0 damage DOES roll crit, and the multiplier applies to the reduced amount. Write these
   BEFORE they can regress, since the dodge/barrier issue was only found by the user in play.
3. **Buildings.** Per Open Decision #4's recommended default (no exclusion), write a test proving
   a building attacker CAN crit and a building defender CAN be crit against — the inverse of
   `test_dodge.gd::_building_never_dodges`, proving the decision was deliberate rather than
   untested.
4. **Re-run the full suite** (`tests/_runner.tscn`) after each phase — it was the ground truth for
   every dodge phase (ended at 446/446) and should stay the checkpoint here too.

---

## Summary checklist (mirrors the dodge commit sequence)

- [x] Phase 1 commit: core resolution — `crit_chance`/`crit_multiplier` queries, both stats,
      both `CARD_ATTR`/`FOLDABLE_ATTRS` entries, `Outcome.crit`/`crit_bonus_damage`,
      `crit_enabled` toggle wired into `tests/_runner.gd`, pure-arithmetic + deterministic-roll
      tests, `data/combat_tuning.json` gets a `"crit"` key.
- [x] Phase 2 commit: VFX (`VFXEvent.CRIT`, `VFXEffectCrit`, `combat_crit` vfx.json entry) + SFX
      (`attack_crit` sounds.json entry) + combat.gd wiring (crit VFX + `flash_stat_proc("speed")`
      alongside the real damage numbers, not replacing them) + parse-check (these files aren't in
      the automated suite — `load()` them via a throwaway `--script` check like the dodge work did).
- [x] Phase 3 commit: Tool handle — extend `/api/combat-tuning` to carry `crit`, extend or sibling
      the `⚡ Dodge` modal.
- [x] Phase 4 commit: `crit` trigger event (subject = origin, register in `DUAL_EVENTS`, combat
      broadcast + `_event_ctx` branch) + Berserker's Momentum relic + `_crit_event` test.
- [x] Phase 5 commit: Eagle-Eye Charm (chance) + Executioner's Edge (multiplier) relics +
      `_crit_chance_bonus_fold` / `_crit_multiplier_bonus_fold` tests.
- [x] Phase 6 commit: Warlord's Fury + Steady Hand Ward relics + `_crit_interception` test.
- [x] Phase 7 commit(s): the three interaction tests from the checklist above, written proactively
      rather than reactively — this is the one place we're explicitly trying to avoid repeating a
      dodge mistake instead of just mirroring dodge's success.

Full regression suite (`tests/_runner.tscn`) should stay green throughout; it was 393/393 before
Dodge started and 446/446 when Dodge finished — expect a similar-sized growth here (dodge added
~53 tests across its `test_dodge.gd` + `test_triggers.gd` additions).
