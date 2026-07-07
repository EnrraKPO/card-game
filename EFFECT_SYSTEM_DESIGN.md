# Effect System Redesign — One Effect, Transparent Containers

Status: STAGES 1 + 2 IMPLEMENTED (stage 1 merged to main; stage 2 on branch
`effect-stage2`) — contract + Tracker + the one evaluator (stage 1); owner model,
relation dissolution (self target kind / allegiance conditions / trigger `of` gates),
fired() channel replacing owner stamping, Tool wording + run-scope affordance (stage 2).
247/247 green on tests/_runner.tscn; Tool suites ALL PASS.
Deferred: Tool NATIVE-form emission (allegiance/self/of + status while/tracker editor)
needs server.js vocab+validation and editors.js, which carry unrelated uncommitted work.
Stage 3 (composition-as-derived) pending.
Note: the tracker kind classes landed as `ContainerTracker`/`StacksTracker` (a bare
`Container` inner class hides Godot's native Control class).
Origin: the `charged.json` bug (a correct `relation: self` condition silently killed a
status's stat effects) exposed that MODIFIER-kind effects never got the resolver-era
treatment and grew four parallel delivery paths. This document replaces the modifier
category with one unified model, agreed conceptually in discussion (2026-07-07).

---

## 1. Ontology

**An Effect is trigger + targeting + payload.** One schema, one parser, one pipeline.
An effect does not know, and does not care, which container holds it. At resolve time it
receives context (holder unit, tracker, board) from whoever is resolving it — the same
context regardless of origin.

**The only lifetime distinction is the presence of a track record:**

- **Untracked** — when the trigger fires, the payload is computed, applied through the
  Resolver (single-writer rule intact), and the effect is spent. History. May be baked
  into a permanent sum for computational efficiency; nothing ever needs to find it again.
- **Tracked** — the effect is never deposited anywhere. It remains live inside its
  container and contributes at **read time**, evaluated against the board **as it is
  right now**. It ceases when — and only when — its Tracker destroys it.

There is no "modifier" category, no "aura" concept, no per-container semantics. A relic's
"your units have +1 health", a status's "+1 attack per stack", a future unit's "units in
my row get +2" are the same object with different containers and targeting.

**No stale state.** Live contributions are recomputed from current state on every read.
Nothing is cached that could desync; a unit that starts (or stops) matching a live
effect's target set is included (or excluded) at the very next read, with no bookkeeping.

---

## 2. The three types

### 2.1 Effect
```
Effect:
    trigger    # WHEN — a TriggerResolver (existing, unchanged), plus one new temporal
               # kind: {"kind": "while"} = live until my tracker dies
    targets    # WHO — a TargetResolver (existing, unchanged), full condition vocabulary
    payload    # WHAT — attribute + amount today; composition et al. later (§8)
    tracker    # HOW LONG — authored ON the effect (absent = untracked/baked). See §2.3.
```

### 2.2 EffectContainer — the skipped architectural decision, now made
Today five classes hold `effects: Array` by convention with four bespoke delivery paths.
The contract becomes a real type:

```
EffectContainer:
    effects()  -> Array[Effect]      # what I hold
    holder()   -> CardInstance|null  # which unit is "self"/holder for my effects
    fired(e)                         # blind upward signal from an effect that just
                                     # triggered; container decides the reaction
                                     # (glint pip/chip, nothing) — see §2.2 note
```

**Owner (SETTLED, stage 2).** Every container also carries an `owner()` — a SIDE, the
allegiance anchor — distinct from `holder()`, the identity anchor. A status FORWARDS its
carrier's owner (ruling: carrier-forwarded, not applier-owned; an applier-owned variant
would be an explicit authored opt-out if ever designed). Relics/upgrades: owner = the
player, holder = null. Consequences — the relation condition form is DISSOLVED:
  • `self` was targeting in a condition costume → becomes the `self` TARGET KIND
    ({"targets": {"kind": "self"}} = the holder), and the trigger resolver's participant
    gate (whose event I react to) becomes a structural field, not a condition.
  • `ally`/`enemy` were allegiance predicates → become owner-based ALLEGIANCE conditions,
    valid in EVERY container (a relic's "your units" = ally — replaces the hardcoded
    owner-0 run-scope guard with authorable data; legacy shim synthesizes it).
  • `ally` includes the holder itself (same-side check; do not "fix" this later).
  • Only `self` is inexpressible without a holder — the Tool hides it for run-scope
    content; the loader rejects it loudly.
  • Conditions then contain only true predicates (stat / status / composition /
    allegiance) and evaluate with (tested unit, owner) — no holder parameter.

**Container ≠ Tracker.** The container does NOT provide the tracker — the tracker is
authored on the effect (§2.3). A container's obligations end at the three members above.
Its *existence* is passively observable, and a tracker MAY bind to it when the effect
goes live — but that binding is created and resolved entirely inside the tracker object.
The effect doesn't care; the container doesn't care either.

Typical holder mapping (the only per-container fact the system consumes):

| container | holder()        |
|-----------|-----------------|
| card      | itself          |
| status    | carrier         |
| relic     | null (run)      |
| upgrade   | null (run)      |

**Charms are NOT a runtime container** (kept as designed): a charm is an authored
override baked into the card definition at deck build (`DeckCard.make_instance`). The
card is then the container of the resulting effects.

**Transparency rule:** the `owner_kind`/`owner_id` stamping on effects (typed knowledge
of the origin) is removed from Effect. In its place, the relationship is a blind upward
channel: an effect holds an opaque reference to its container and may signal it — e.g.
`fired()` when the effect triggers. The container decides what that means (glint the
status pip, glint the relic chip, nothing). The effect knows THAT it has a container and
can signal it; it never knows WHAT the container is. That is the entire relationship.

### 2.3 Tracker
```
Tracker:
    valid()     -> bool   # queried on EVERY read; monotonic — once false, false forever
    intensity() -> int    # current magnitude multiplier; 1 unless the kind says otherwise
```

The tracker is **defined on the effect** (authored data), instantiated when the effect
goes live, and owns its own wiring. Authored kinds:

- `container` (the default for `while` effects) — valid while the container the effect
  went live in still exists. The binding to that container is captured at instantiation
  and resolved privately by the tracker; neither effect nor container participates.
- `stacks` — binds to its host's stack count: valid while > 0, intensity = current
  count. This is how per-stack scaling is expressed — as authored data, NOT as evaluator
  logic keyed on the container being a status. No per-container-type effect behavior
  exists anywhere in the system.
- (future kinds as designs need them: `duration`, `combat`, … — each a new tracker
  object, zero evaluator changes.)

No tracker authored = untracked = the baked path.

- **Pull is correctness:** the evaluator never sums a contribution without `valid()`.
  A dead tracker's effects are inert even before cleanup runs. Stale state is
  unrepresentable.
- **Push is hygiene:** decay phases / combat end / relic removal destroy the tracker and
  remove its effects from the enumeration (and drive the visible lifecycle — the pip
  disappearing IS the destruction). Correctness never depends on push happening promptly.

**Existence vs applicability — the semantic line:**
- Tracker validity is **one-way** (destruction, not suspension).
- Targeting/conditions are **two-way** (re-evaluated every read; a unit may leave and
  re-enter a target set freely).
- The same condition vocabulary expresses both; *placement* decides the meaning. A
  condition that should permanently end an effect belongs in the tracker; one that
  should gate it belongs in the targeting.

---

## 3. Evaluation semantics

```
get_attribute(u, attr) =
      base(u, attr)                      # authored data (incl. charm bakes)
    + baked(u, attr)                     # CardInstance.modifiers — written history
    + Σ  e.amount × e.tracker.intensity()
         for each active container c,
         for each live ("while") effect e in c.effects()
         where e.tracker.valid()
           and u ∈ e.targets.resolve(now, holder = c.holder())
           and e.payload.attribute == attr
```

**Enumeration sources** (one evaluator, replacing three folds): every unit on the board
(its card-innate live effects + its statuses) and the run set (relics + upgrades). Adding
a container type later = implement the contract; the evaluator does not change.

**Stratification rule (agreed):** condition evaluation sees the unit as valued by
`base + baked + condition-FREE live effects`. Condition-bearing live effects are
invisible to condition checks. This makes evaluation deterministic and order-independent
and prevents oscillation ("+2 attack while attack < 5" at attack 4 stably yields 6).
This replaces the `_in_modifier_condition` re-entrancy hack with a documented semantic.

**Attribute naming across temporal modes:** payload attribute names are the triggered
vocabulary ("attack", "health", "speed", "cost"). Semantics of "health" differ by mode
exactly as they already do implicitly: a *when*-effect on health writes current health
(damage/heal through the Resolver); a *while*-effect on health contributes to **max**
health (current health is untouched — today's status behavior, kept).

**Globals:** GLOBAL-scope numbers (e.g. `reward.king_piece_chance`) ride the same
container enumeration — `GameData.value` folds live global-payload effects from run-scope
containers. `ModifierSet` as a separate aggregate dissolves into the enumeration.

**Performance:** deliberately uncached. Board scale (≤ 24 units, a handful of statuses
each) makes the scan trivial; caching would reintroduce the staleness class this design
eliminates. Revisit only with a measured problem.

---

## 4. Authoring schema

New native form — a live effect is an ordinary effect whose trigger is `while`. Identity
is structural (the `self` target kind / the trigger's `of` participant gate); conditions
are predicates only (stat / status / composition / allegiance / card_type / has_element):

```json
{ "trigger": { "kind": "while" },
  "targets": { "kind": "self" },
  "tracker": { "kind": "container" },
  "attribute": "attack", "amount": 2 }

{ "trigger": { "kind": "event", "event": "death", "of": "self" }, ... }   // reacts to own death
{ "targets": { "kind": "all", "conditions": [ { "allegiance": "ally" } ] } }  // "your units" — works holderless
```

(`"tracker": {"kind": "container"}` is the default for `while` effects and may be
omitted.) `charged.json` after — +1 attack and +1 speed per stack, live, scaling
authored via the `stacks` tracker rather than any status-specific evaluator logic:

```json
{
    "id": "charged",
    "display_name": "Charged",
    "decay": "stacks", "stacking": "stack", "max_stacks": 9,
    "effects": [
        { "trigger": {"kind": "while"}, "targets": {"kind": "all", "conditions": [{"relation": "self"}]},
          "tracker": {"kind": "stacks"}, "attribute": "attack", "amount": 1 },
        { "trigger": {"kind": "while"}, "targets": {"kind": "all", "conditions": [{"relation": "self"}]},
          "tracker": {"kind": "stacks"}, "attribute": "speed",  "amount": 1 }
    ]
}
```

**Lossless legacy mapping (zero forced migration — the trigger-resolver playbook):**
`from_dict` maps the old forms onto the new model:
- `{"kind": "modifier", "key": "unit.attack", ...}` → while-trigger effect, attribute
  "attack"; targets = self-relation and tracker = `stacks` when loaded from a status
  file, targets = all-player-cards and tracker = `container` when loaded from a run
  container — i.e. exactly today's hardcoded scopes and stack-scaling, now expressed as
  data. (This per-source defaulting lives ONLY in the legacy parse shim — a data
  migration aid. The runtime itself has no per-container-type behavior; natively
  authored effects state their targets and tracker explicitly.)
- legacy `filter` `{"kind": "unit"|"spell"}` → new `card_type` condition form;
  `{"has_element": true}` → new `has_element` condition form.
- the dangling `permanent` trigger string → `while`.
Round-trips byte-faithfully like the trigger migration (legacy in → legacy out).

**Vocabulary additions** (conditions): `card_type`, `has_element` (absorb `filter`);
positional forms (`same_row`, …) added when the first positional effect is designed.

**Load-time validation — fail loud, never silently closed:**
- relation-form condition in a holderless (run-scope) container → `push_error` at load.
- `while` trigger with a non-foldable payload (status application, custom hook,
  manual targeting) → `push_error` at load.
- unknown attribute / condition keys → `push_error` at load.

---

## 5. What gets deleted

| item | today | fate |
|---|---|---|
| `Effect.Kind.MODIFIER` + `scope` + `key` + `CARD_ATTR` | effect.gd | gone (legacy parse maps in) |
| `matches_card` + `filter` + `_in_modifier_condition` | effect.gd:360-391 | gone (targeting + stratification) |
| `StatusEngine.modifier_bonus` | status_engine.gd:17 | gone → one evaluator |
| `ModifierSet.card_bonus` / `GameData.card_bonus` | modifier_set.gd:54 | gone → one evaluator |
| `ModifierSet.total_add` global fold | modifier_set.gd:44 | absorbed by enumeration |
| `owner_kind`/`owner_id` on Effect | effect.gd:129 | replaced by opaque container ref + `fired()` signal |

**Untouched:** TRIGGERED dispatch (EffectSystem), INTERCEPTOR kind and the arbitration
layer (Blind, pending-mutation rewrites), Resolver as the single stat writer — live
contributions are reads, never mutations, so the arbitration memory's hard rules are not
in play except that the regression suite must pass.

---

## 6. Migration map (data & code)

Data (small): `data/statuses/*.json` (6 files — work unchanged via legacy mapping;
re-author to native form opportunistically), `data/upgrades/arcana.json` (one `filter`),
plus the Tool/ authoring app's status editor (Tool/ authors statuses; its schema
knowledge needs the native form added).

Code call sites: `card_instance.gd:59-65` (get_attribute feeds), `status_engine.gd`,
`modifier_set.gd`, `game_data.gd` (card_bonus/value), `effect.gd` (kind machinery),
combat's VFX cue read of owner_kind (dispatch context instead).

## 7. Staging (each step lands green on tests/_runner.tscn)

1. **Contract + evaluator.** Introduce EffectContainer + Tracker as wrappers over the
   existing classes; route `get_attribute` through the one evaluator; legacy mapping in
   `from_dict`; delete the three folds + `matches_card`. Behavior-identical except the
   charged-class bug is fixed (holder now exists at evaluation).
2. **Native authoring + validation.** `while` trigger kind, `card_type`/`has_element`
   conditions, load-time fail-loud, Tool editor support, re-author statuses natively.
3. **(Deferred) composition-as-derived.** Route composition reads through the same lens;
   unlocks "pawn units lose their pawn component". Nothing in steps 1–2 blocks it.

## 8. Test plan

- Existing regression suite tests/_runner.tscn — mandatory after every step (resolution
  layer touched).
- New: container transparency (identical effect via status / relic / card-innate yields
  identical numbers); pull-validity (carrier dies mid-round → contribution gone at next
  read with no cleanup having run); stack intensity live-scaling (3→2→1 decay);
  stratification determinism (condition-bearing effects can't see each other, order of
  load irrelevant); legacy round-trip (old modifier JSON in → same JSON out, same
  numbers as before the redesign).
