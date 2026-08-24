# Chaining Effects — Design & Implementation Guide

Status: **DRAFT — NOT AGREED, NOT BUILT, AND DOWNSTREAM.** This was written early in the
2026-08-08 discussion and the user did NOT sign it off. The conversation then went upstream
and established that placement must be consolidated first — see
`LOCATION_MANAGER_DESIGN.md`, which is the agreed initiative and takes priority.

Read this only as a record of early thinking. Its §2.1 ("a chain is not a new targeting
kind — it is a relocating anchor plus repetition") survived and was sharpened; the rest,
including the authored shape in §5.1 and the anchor-widening plan, predates the location
model and should be re-derived on top of it rather than implemented as written. The four
user rulings recorded in §2.3, §2.4, §2.6 and §5.3 (walk not plan; leap from a corpse but
never onto one; hops count units struck; the arc ships with the rules) were answers to
questions asked too early, and the user is free to withdraw them.

Since written, the effect pipeline this draft assumed was DELETED whole (effect-cleanse,
2026-08-11): any chain mechanic now re-derives on `TARGETING_DESIGN.md`'s vocabulary
(where a chain would be a resolver with a relocating current), not on Effect/EffectSystem.

Sibling docs: `LOCATION_MANAGER_DESIGN.md` (the prerequisite), `EFFECT_SYSTEM_DESIGN.md`
(the PRIOR generation's effect pipeline — superseded by `TARGETING_DESIGN.md`),
`SLOT_LAYER_DESIGN.md` (the position-first targeting ruling, §2.4).

---

## 1. What this is

An effect that lands on a target, then seeks a NEW target **from where it just landed** —
the classic chain lightning. The defining property, and the reason it is not merely a
multi-target effect: hop N+1's target is chosen relative to hop N's *geometric position*,
not the caster's.

## 2. The settled model (the WHY)

**2.1 A chain is not a new targeting kind.** It is the existing nearest-search, run
repeatedly, with the anchor relocating to whatever it just hit and a memory of where it has
been. Three primitives, each already half-present:

- **Relocating anchor** — `EffectContext.anchor_*` exists, but only ground dispatch sets it
  and only `AT_LOCATION` reads it; `Auto` always measures from `holder`
  (`target_resolver.gd:110`). The anchor becomes ordinary resolution state that *every*
  distance search honours, defaulting to the holder. This is exactly the extension point
  `SLOT_LAYER_DESIGN.md` §2.4 declared ("richer providers feeding the SAME primitive, never
  a new targeting kind"), and it closes a live inconsistency between two resolvers about
  what "here" means.
- **Repetition** — `_restrikes` (`effect_system.gd:65`) already repeats a whole effect and
  stamps each result for presentation. Same shape, different iterator.
- **Visited memory** — the only genuinely new state.

**2.2 ONE anchor, not two.** The anchor stays the coordinate triple
(`anchor_side/row/col`). A chain hop sets it from the unit it just struck. There is no
second "anchor unit" field: a unit anchor would be a different concept wearing the same
name, and the ground layer's anchor has no unit at all. Consequence: `board_distance` is
refactored to take coordinates, with the current `(holder, cand)` signature surviving as a
thin wrapper. **The metric itself is unchanged** — its cross-side branch only ever reads
`holder.owner/row/col` already.

**2.3 The chain WALKS; it does not plan** (user ruling). Apply hop 1, then search for hop 2
against the board as it now stands. The path is blind to its own future and honest about
its past: a hop that opens a gap changes the rest of the route. Consequence, accepted: the
full path cannot be previewed before commit — the player aims the seed and trusts the arc.
Sims are unaffected (they run the real rules on world copies).

A hop that lands for zero — intercepted away, fully absorbed — **does not** end the chain.
Only the stop conditions in §2.6 do.

**2.4 A hop leaps FROM a corpse, never ONTO one** (user ruling). A unit killed by the chain
is still a valid place to jump from — the bolt reached that cell — but dead units are not
valid candidates. Implemented as an implicit alive gate **on hop candidates only**; global
targeting is untouched (corpses linger on the grid until `_sweep_dead`,
`combat_world.gd:264` — latent for AoE today, unmissable for chains).

**2.5 The `targets` socket describes only the SEED.** Its whole existing vocabulary is
reused unchanged, so chain-off-a-manual-cast, chain-off-your-attack-target, and
chain-off-a-relic all arrive free. Propagation is a sibling block on the effect, beside
`riders` and `spread` — repetition of a whole effect is the same axis as `per_stack_chance`,
and that lives on `Effect` too.

**2.6 `hops` counts UNITS STRUCK, seed included.** `hops: 3` with `falloff: 0.5` on a base
of 6 deals 6 → 3 → 2. The chain ends at whichever comes first:
- `hops` reached;
- no candidate passes the conditions, the alive gate, the visited set, and `range`;
- the hop's amount rounds to 0 (nothing left to carry — and the implicit viability
  condition would refuse it anyway; see `Effect._install_viability`).

**2.7 Falloff is computed from the BASE, never chained.** `amount_hop = round(base *
falloff^i)`, `i` 0-based. Stateless and pure: no rounding drift, and hop N's number is
answerable without replaying hops 1..N-1. (6 → 3 → 2, since `round(1.5) = 2`.)

**2.8 Deliberately NOT unified with `spread`.** `StatusData.spread` is also propagation
with a destination provider, but it is per-stack, per-phase, random, and status-owned; a
chain is sequential, within-one-resolution, and effect-owned. Share the provider
*vocabulary*, keep the mechanisms apart — a propagation super-concept built on two samples
would be speculative generality.

## 3. What this gets for free

Because a chain is a loop around the *existing* single-shot resolution, everything
downstream is untouched and works on the first hop and the last alike:

- `Resolver` single-writer, interceptors, provenance/`cause`, `kill` events.
- **`Effect.riders`** — a chaining bolt that chills each unit it touches needs no new
  machinery. Each hop is its own damage INSTANCE, so the one-roll-per-instance rule (§4.4b
  of `SLOT_LAYER_DESIGN.md`) already says the right thing.
- The implicit viability condition, all authored conditions, ground-layer delivery, the
  result-dict contract.
- **The enemy engine: zero work.** Sims run the real rules on world copies, so a chain is
  valued correctly by construction. `eval` annotations stay hand-authored and flat, as ever.

## 4. Two pre-existing defects to fix on the way

- **`Auto`'s random criterion calls `pool.shuffle()`** (`target_resolver.gd:107`) — Godot's
  global RNG, not `CombatRng.shuffle`. Non-reproducible across sim and real. Latent today;
  load-bearing the moment a random hop exists.
- **`amount_scale: int`** (`effect_system.gd:194`) must widen to float for falloff. Contained
  — the rounding happens once, at the mutation.

## 5. The build

### 5.1 `Effect.chain` — the authored block

```json
{ "trigger": "on_play",
  "targets": { "kind": "manual", "conditions": [{ "allegiance": "enemy" }] },
  "attribute": "damage_taken", "amount": 6,
  "chain": { "hops": 3, "criterion": "nearest", "falloff": 0.5 } }
```

| Field | Default | Meaning |
|---|---|---|
| `hops` | required, ≥ 2 | Total units struck, seed included (§2.6). |
| `criterion` | `"nearest"` | Reuses `Auto`'s vocabulary: `nearest` \| `random`. |
| `falloff` | `1.0` | Per-hop multiplier off the base (§2.7). |
| `range` | unbounded | Max hop distance **in cells**; no candidate in range ends the chain. |
| `revisit` | `false` | `true` allows ping-ponging between already-struck units. |
| `conditions` | seed's | Hop-candidate predicates; absent = inherit the seed's. |

`range` in cells is deliberate: `board_distance` scales same-side distance by `ROWS`
(`target_resolver.gd:378`), which is an internal commensurability trick, not an authoring
unit. Note the metric degrades to plain Manhattan when anchor and candidate share a side —
which *is* the chain-among-enemies case, so it is already geometrically honest here.

Round-trips byte-faithfully through `to_dict` like every other block.

### 5.2 `EffectSystem` — the walk

One loop in `_run_effect`, wrapping the existing per-target application:

```
seed = targets_resolver().resolve(...)     # unchanged
for each seed target:                      # normally one; a fan-out seed chains from each
    anchor = target coords; visited = {target}
    apply(target, base)
    for i in 1..hops-1:
        cand = nearest/random alive, unvisited, in-range, condition-passing unit from anchor
        if none or round(base * falloff^i) == 0: break
        apply(cand, base * falloff^i);  anchor = cand coords;  visited += cand
```

Results carry `"hop": i` — the `restrike_stack` precedent (`effect_system.gd:74`) — so
presentation can sequence the arcs and only the arcs that fired.

### 5.3 Presentation — the arc

Per-hop arc playback sequenced off the `hop` index, building on the existing `projectile`
VFX. A chain you cannot see land is untestable in play, which is why this is in scope here
and was fenced out of the slot layer.

### 5.4 Content

One authored `chain_lightning` card, plus a `chain` entry in `named_effects.json` if the
shape proves reusable at authoring time (not before — the registry earns entries, it is not
seeded with them).

## 6. Tests

Rules tests pin behaviour normally (the computation-only doctrine is the *enemy engine's*,
and does not apply here): hop ordering, the alive gate, the visited set, `range` cutoff,
falloff arithmetic including the round-to-0 stop, riders firing per hop, a chain that runs
out of candidates early, and determinism of the random criterion under a fixed seed.

Suite must stay green — this touches the resolution layer, so the run is **mandatory**
(`Arbitration Layer` house rule).

## 7. Scope fences (OUT — do not build, do not stub)

- **`chain` + `status_layer: "ground"`** — load-time `push_error`. A ground chain is a
  coherent idea (a walking fire) but an untested one; fail loud rather than guess.
- **`chain` + side targets** — load-time `push_error`. A player has no position to hop from.
- **Path preview in the targeting UI** — precluded by the walk ruling (§2.3), not deferred.
- **Chain-specific enemy-engine work** — nothing. See §3.
- **A propagation super-concept over `spread`** — see §2.8.
- **Typed/elemental damage** — still a separate concern with no plans (standing user call).

## 8. Practicalities

- Godot not on PATH: `"/d/Godot/Godot_v4.6.3-stable_win64_console.exe" --headless --editor
  --quit --path /d/Godot/CardGame` = parse check. ALWAYS pass the absolute `--path`.
- Suite: `... --headless --path /d/Godot/CardGame res://tests/_runner.tscn`.
- Warnings are errors: fully typed GDScript, no `:=` inferring Variant, typed `for` loops.
- Edit with the harness Edit/Write tools only (PowerShell corrupts encoding).
- Planned phase → one commit when green and approved.
