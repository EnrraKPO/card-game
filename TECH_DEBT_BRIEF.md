# Tech Debt Brief — the hardening backlog

Status: **IDENTIFIED 2026-08-09, NOT YET SCOPED INTO INITIATIVES.** This is the catalogue of
tech concerns surfaced while designing dynamic (chaining/recursive) effects, at which point the
user ruled: **new feature work is parked; the stack gets hardened first.** The test that ended
the discussion: *the solution to dynamic effects should be easy — the fact that it cannot be
implemented with ease points to an architectural problem.* The feature is expected to unfold
naturally from consolidated systems, not to be assembled from moving parts.

Each concern below is a candidate cleansing initiative. Per the standing rule on scope
reversals, this brief **identifies and evidences; it decides nothing** — every keep / absorb /
kill is the user's call, made explicitly, one initiative at a time. Items are marked
**CONFIRMED** (read in the code this session) or **SUSPECTED** (pattern seen, not yet traced).

Sibling docs: `EFFECT_SYSTEM_DESIGN.md` (the original intent this stack has degenerated from),
`LOCATION_MANAGER_DESIGN.md` (the model cleanup of this kind: one authority, downstream
problems dissolve), `CHAIN_DESIGN.md` (the parked feature, unsigned draft).

---

## The disease, named once

Every concern below is one pattern: **additive migration**. A better authority gets built, the
old representation is kept "for compat," its consumers are never moved, and the codebase ends
up bilingual — every new consumer must choose which vocabulary to speak, and some choose the
dead one because it is cheaper to reach. Nothing ever finishes replacing anything. The
location-manager refactor is the counterexample that proves the cure: it deleted the old
vocabulary in the same stroke (`CardInstance.row/col` are *gone*), and the things built on it
came out simpler, not more entangled.

---

## 1. The trigger/targeting mirror vocabulary — CONFIRMED

**What:** `Effect.trigger`, `subject_filter`, `subject_elements`, `targeting_policy` are legacy
enum mirrors of what the injected `TriggerResolver` / `TargetResolver` already know
authoritatively (`effect.gd:104-111`). Dispatch never reads them; ~6 files of read-only
consumers do (`spell_caster.gd` ×7 sites, `enemy_ai.gd` ×10, `candidate_apply.gd`,
`board_state.gd`, `live_effects.gd`, `combat.gd:635`). Alongside ride the reconciliation
flags (`authored_native_trigger`, `authored_native_targets`, `_native_targets`) — one fact,
four representations.

**Sharp edge:** the mirror derivation is lossy with a permissive default —
`legacy_trigger_for` (`trigger_resolver.gd:316`) falls back to `ON_PLAY` for any event id it
doesn't recognize, and `ON_PLAY` is exactly the value the castability filters treat as a
positive match. SUSPECTED (not traced to a live defect): a native-form effect with a novel
event trigger could classify as a castable spell.

**Resolution shape:** consumers ask the resolver its actual question; mirrors and flags are
deleted. Round-trip serialization needs no mirrors — retaining the authored dict verbatim is
already the proven pattern in this same file (`_named_authored`).

## 2. SpellCaster is a second dispatcher — CONFIRMED

**What:** unit arrival goes through the one pipeline (`combat_world.gd:252` emits a `play`
GameEvent; each effect's trigger authority decides). A spell cast does not:
`_resolve_on_play` (`spell_caster.gd:127`) walks the effect list itself and calls
`apply_single` per effect — so it must reproduce the pipeline's trigger gate by hand, which
is the `!= ON_PLAY: continue` filter, which is what keeps mirror-vocabulary alive (concern 1).

**The legitimate residue:** SpellCaster's pre-cast needs are real but are *different
questions* — "what input does this resolution require from the gesture (unit pick / slot pick
/ none)?" and "could it reach anybody right now?" (the viability rule). Both belong to the
targeting socket; the code already asks the socket in its best moments
(`spell_caster.gd:212` calls `targets_resolver().resolve(...)` directly). The socket should
*declare* its input requirement; the enum peeks around these calls then die.

**Resolution shape:** a cast becomes a `play` event through the one pipeline; targeting kinds
declare gesture requirements; the classification questions disappear rather than get renamed.

## 3. Effect is a payload union object — CONFIRMED

**What:** one class, ~30 instance fields, four kinds (`MODIFIER`/`TRIGGERED`/`CUSTOM`/
`INTERCEPTOR`), where each payload species is its own field cluster: stat delta
(`attribute`/`amount`), status bundle (`status_id`/`duration`/`stacks`/`layer`), spawn bundle
(`spawn_id`/`count`), `material`, custom hook id, interceptor spec (`intercept`/`channel`/
`intercept_participant`/…), eval prices, `grants`, `tracker_spec`. `_run_effect`/`_apply`
(`effect_system.gd:193, 329`) are branch ladders over the species, including a ground-layer
pre-branch (`effect_system.gd:208`) whose own comment apologizes for existing.

**Resolution shape (conceptual, to be designed):** one small payload concept — the axes
separate cleanly as WHEN (trigger socket, healthy) / WHO-WHERE (targeting socket, healthy) /
WHAT (currently the union) / HOW MUCH (concern 5) / WHAT NEXT (concern 4). Acceptance test
for the design: chain lightning expressible as plain authored data, no new mechanism.

## 4. "What happens next" is four bespoke mechanisms — CONFIRMED, partly UNSANCTIONED

**What:** follow-on behaviour is scattered: `riders` (damage carries a status,
`effect.gd:145`), restrikes (`per_stack_chance` stack-repetition, `effect_system.gd:59`), the
spawn queue, the `chance` gate. Each is a narrow bespoke answer to the one general question
"what does a resolution do next."

**Governance note (user, 2026-08-09):** riders and restrikes were never designed or signed
off by the user — they accreted during the burning-ground work. They are the named exhibits
of the accretion pattern; the audit should assume they are not the only unsanctioned
mechanisms in the tree.

**Resolution shape:** one continuation concept, designed on purpose; existing mechanisms get
explicit keep / absorb / kill decisions. (This is also where the parked dynamic-effects
feature will eventually live: an effect invoking an effect, with parameters and recursion.)

## 5. Magnitudes are parse-baked floats — CONFIRMED (and self-acknowledged)

**What:** `amount` is a float fixed at parse time. Runtime scaling is threaded ad hoc:
`amount_scale` parameters through the dispatch calls, the `per_stack` bool — whose own
comment (`effect.gd:126`) calls it a **"THROWAWAY SEAM"** superseded "when amounts-as-
expressions arrives" — and `NamedEffects.$X`, a parse-time macro substitution that can never
see a runtime value (which is exactly why the registry must refuse recursion,
`named_effects.gd:117`). "X = the damage that actually landed" is unrepresentable.

**Resolution shape:** amounts become evaluable values (literal / parameter / event-derived /
minimal arithmetic), bound at resolution. Kills `per_stack`, `amount_scale` threading, and
the parse-time-only limitation of `$X` in one stroke. Keep the expression surface ruthlessly
small and fail-loud at load.

## 6. Five dispatch entry points in EffectSystem — CONFIRMED

**What:** `trigger`, `trigger_grouped`, `trigger_global`, `trigger_global_grouped`,
`trigger_carrier_grouped` (`effect_system.gd`) — five near-duplicate loops, each with private
quirks (the `_holder_shaped` fence, `owner_anchor` mutation as a side effect on the shared
context, grouped-vs-flat shapes). Every dispatch-level fix must be applied in up to five
places.

**Resolution shape:** one dispatch spine; grouping-for-presentation and run-scope anchoring
become parameters or wrappers, not siblings.

## 7. Results are untyped dicts with an implicit contract — CONFIRMED

**What:** effect results are `Dictionary` with ad-hoc keys accumulated over time
(`restrike_stack`, `rider_applied`, `status_applied`, `spawned`, `interceptions`, …). The
presentation layer's contract with resolution is implied by whoever reads which key.

**Resolution shape:** a typed result (or at minimum one documented schema with a single
constructor), so presentation consumes a contract instead of spelunking.

## 8. Legacy placeholder AI still in tree — CONFIRMED in tree, scope SUSPECTED

**What:** `enemy_ai.gd` is the historical action-vocabulary AI, superseded by the encounter
engine (which prices actions by simulating the real rules and needs no effect classification
at all). It is one of the largest consumers of the mirror vocabulary (~10 read sites). What
still calls into it — and whether anything does in a live path — has not been traced this
session.

**Resolution shape:** trace live callers; then delete or quarantine. Its mirror reads
otherwise keep concern 1 artificially load-bearing.

## 9. Bilingual authored data — CONFIRMED, content-wide

**What:** the authored JSON speaks two trigger/targeting schemas: the legacy string form
(`"trigger": "on_play"`-style — **~147 occurrences across 29 data files**, all card sets,
charms, relics, upgrades, statuses) and the native dict form. Both parse losslessly and
round-trip byte-faithfully, which is precisely what lets both live forever. The authoring
guides themselves still document the legacy form.

**Resolution shape:** pick the surviving schema, migrate the content in one mechanical pass
(with the Tool's serializer, not by hand), update the guides, and make the parser fail loud
on the dead form. Until this happens, concern 1's round-trip flags cannot die.

## 10. Leftover legacy geometry vocabulary — CONFIRMED, bounded

**What:** deliberately-left bridges from the location-manager refactor, recorded in its §9:
`EffectContext._player_board/_enemy_board` (the 2D grids "the older targeting paths still
speak in" — consumed by `target_resolver.gd` and `effect_hooks.gd`), `BoardState`'s own
row/col projection, `EnemyEngine.decide_actions` taking grid arrays via
`CombatWorld.adopt_grid`. Known, bounded, and honest — but they are the same bilingual
pattern, and each is a place where a future consumer can pick the dead vocabulary.

**Resolution shape:** finish the location migration outward: targeting and hooks speak
locations; the grid projections become private to the one consumer that still needs them, or
die.

---

## Dependency sketch (not an order — the order is the user's call)

- Concern **2** (one dispatch path) unlocks **1** (mirrors die) — and **1** is blocked until
  **8**/**9** stop needing the old vocabulary. These four form one natural initiative:
  *"one dispatch, one vocabulary."*
- Concern **3** (payload shape) + **4** (continuation) + **7** (result contract) form the
  second: *"one payload."* Depends on the first only loosely.
- Concern **5** (value model) is the third and is the direct prerequisite the parked
  dynamic-effects feature was waiting on; it lands best after 3/4 define what a payload is.
- Concern **10** is a bounded independent sweep, schedulable anytime.

The parked feature (`CHAIN_DESIGN.md`) re-enters only after the relevant initiatives land,
and should then cost approximately nothing — that outcome is the success criterion for this
whole backlog.
