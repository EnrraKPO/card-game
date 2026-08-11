# Status Authoring Guide

A **Status** is a named, time-boxed bundle of effects applied to a card *at runtime* — a buff,
debuff, periodic effect, or event-reactive effect that rides the card for a duration and then
falls off.

> **Effects — FORGOTTEN (effect-cleanse, 2026-08-11).** Do not author `effects` on a status.
> The old effect language is burned; status payloads re-author in the rebuilt effect system's
> schema (`TARGETING_DESIGN.md` is the authority; a status is an ordinary effect CONTAINER
> there). What this guide still governs is the status's own lifecycle — decay, stacking,
> presentation, and eval pricing — which survives intact. Each status's `description` is its
> re-authoring brief; the old payload spellings live in git history.

Statuses are defined as JSON files in `data/statuses/`. Any `.json` file there is loaded at
startup (a file may hold a single status or an array of them). They will be referenced by `id`
from a container's status payloads once the rebuilt effect system lands.

---

## Fields

| Field | Type | Required | Description |
|---|---|---|---|
| `id` | string | Yes | Unique identifier, referenced by effects that apply the status |
| `display_name` | string | No | Name shown in the pip tooltip (defaults from `id`) |
| `description` | string | No | Tooltip text |
| `beneficial` | bool | No | `true` (default) tints the apply VFX/pip as a buff; `false` as a debuff |
| `aura` | bool | No | `true` draws a persistent "protected"-style frame over the card (in the status's `color`) while the status is active — for statuses whose presence should read at a glance (e.g. Barrier) |
| `color` | hex string | No | Pip background colour (e.g. `"e0a93b"`) |
| `glyph` | string | No | Short glyph shown on the pip (e.g. `"↑"`, `"☠"`) |
| `default_duration` | int | No | Initial `remaining` for a `duration`-decay status, when the applier doesn't override it |
| `decay` | string | No | How it wears off (see below): `duration` (default), `stacks`, or `none` |
| `decay_phase` | string | No | When it counts down: `turn_end` (default) or `turn_start` |
| `stacking` | string | No | How a re-application combines (see below) |
| `max_stacks` | int | No | Cap for intensity stacking |
| `eval` | object | No | Enemy-engine pricing, PER STACK (folded × stacks at capture): `{"threat": n, "exposure": n, "value": n}` — adds only, muls are refused at this level. The flat, stack-blind half (and any mul, e.g. blind's `threat_mul`) goes on the carried effect's own `eval`. Absent = the stacks contribute nothing beyond the effects' flat annotations. NEVER price a `while` stat effect's stats — captured stats already say it (double count). See `STATUS_EVAL_BRIEF.md` / `STATUS_ANNOTATION_BRIEF.md`. |

## `stacking` — re-applying onto a card that already has the status

| Value | Behaviour |
|---|---|
| `refresh` (default) | Reset the timer to the longer of the two; intensity stays 1 |
| `extend` | Add the new duration onto the remaining timer |
| `stack` | +1 stack (scales every effect's magnitude); refresh the timer, up to `max_stacks` |
| `independent` | Keep a separate instance |

## `decay` — how the status wears off

| Value | Behaviour |
|---|---|
| `duration` (default) | The `remaining` timer (starts at `default_duration`) counts down 1 each round; expires at 0. Intensity (`stacks`) is independent. |
| `stacks` | The stack **count** counts down 1 each round; expires at 0 stacks. The count is the magnitude (effects scale by it) — Slay-the-Spire poison. |
| `none` | Never wears off; lasts the whole fight. |
| `intercept` | A stack is spent each time one of the status's **interceptor** effects actually rewrites a mutation (see the Interceptors section); expires at 0 stacks. A rewrite that changes nothing spends nothing — so a Barrier ignores a whiff (a Blinded attacker's 0-damage miss). Not phase-driven; `decay_phase` is ignored. |

`decay_phase` chooses when the countdown (and any `on_turn_start`/`on_turn_end` effects) resolve:
`turn_end` (default, after attacks) or `turn_start` (before attacks). Effects fire **before** the
decay that round, so a `stacks`-decay status acts on its current count, then the count drops.

Cards — and their statuses — are rebuilt every fight, so nothing persists between combats.

---

## Examples

**Empowered** — a simple timed buff (lifecycle only; its Attack payload re-authors in the
new schema and disappears automatically when the status falls off):
```json
{
  "id": "empowered", "display_name": "Empowered", "beneficial": true,
  "color": "e0a93b", "glyph": "↑", "default_duration": 2, "stacking": "refresh"
}
```
(Its old payload — a `unit.attack` modifier folding while active — returns as a PassiveEffect
contribution in the new language.)

**Withered** — a periodic debuff that stacks (the round-end 1 HP drain re-authors in the new
schema; because `stacking` is `stack`, re-applying makes it drain harder):
```json
{
  "id": "withered", "display_name": "Withered", "beneficial": false,
  "color": "7a9b58", "glyph": "☠", "default_duration": 3, "stacking": "stack", "max_stacks": 9
}
```

**Poison** — Slay-the-Spire poison. `decay: "stacks"` makes the **count** itself the timer: each
turn-start the unit takes damage equal to the count (a per-stack tick payload, re-authored in
the new schema), then the count drops by 1, until it's gone. `stacking: "stack"` means
re-applying adds to the count:
```json
{
  "id": "poison", "display_name": "Poison", "beneficial": false,
  "color": "5a8f3a", "glyph": "☠",
  "decay": "stacks", "decay_phase": "turn_start", "stacking": "stack", "max_stacks": 99
}
```

A card applies a status through a STATUS PAYLOAD on one of its own effects — authored in the
new language once the rebuild lands (the payload names the status id, stacks, duration; the
status's own lifecycle fields above do the rest).

---

## Notes

- Statuses are combat-runtime only — they are never saved and never carry across fights.
- `id` must be unique across all status files; duplicates silently overwrite.

## Interceptors: rewriting a mutation before it commits

> The old spellings are burned with the effect language (do not author them; git history is
> the reference). The SEMANTICS below are the arbitration layer's living spec and survive
> the rebuild untouched: channels, the three interceptable passes, re-flooring, and
> `decay: "intercept"`'s spends-only-when-it-changes-something rule. InterceptorEffect
> re-authors them in the new schema (TARGETING_DESIGN.md §8).

Every stat change in the game is a **StatMutation** submitted to the **Resolver** (the single
writer — it owns the shield-first damage resolution; no effect or combat code knows shields
exist). An **interceptor** is a standing rewrite that fires *inside* that gate: it is NOT an
event reaction — it matches pending mutations declaratively and adjusts the amount before it
commits. An interceptor is defined by:

- **what it rewrites** — the mutation stat (a hit's damage, a health change, the shield
  share, status stacks being applied, a side stat, an additive attribute);
- **provenance** — the mutation's channel; an attack-only interceptor ignores poison ticks
  and spell damage;
- **whose side** — whether the holder must be the mutation's *source* (Blind sits on the
  attacker) or its *target* (armor and barriers sit on the receiver);
- **the operation** — multiply (×0 = full block, reads as **Miss**) or shift (negative is
  armor that shaves the hit, scaled by stacks);
- **an optional chance**, rolled per matching mutation.

A damage amount is re-floored at 0 after every rewrite — a blocked strike is 0, never a heal.

### A hit resolves in three interceptable passes

The hit's damage is first gated as its **pre-split total**. Once that settles, the Resolver
apportions it shield-first, and each share becomes its own pending mutation **on the hit's
channel** — the shield share and the health share — gated again before committing. Shares
are always reductions (re-clamped after every rewrite, so "take less" can zero a wound but
never flip it into a heal), and a rewritten share never redistributes to the other. So
"block attack damage **that would reach Health**, letting shield absorption pass" is one
interceptor on the health share, no sign conditions — that is **Stalwart Barrier**, and
because a rewrite that changes nothing spends nothing, a hit fully eaten by the shield
doesn't consume the charge (`decay: "intercept"`). Direct health changes (poison, heals)
are health mutations on their own channels and never pass through the split.

The two canonical shapes: **Blind** — a source-side attack-channel block at 50% chance, one
charge spent per attack (`decay: "stacks"`, `decay_phase: "attack"`). **Barrier** — the
defender-side counterpart, a target-side block that spends itself only when it actually
stops something (`decay: "intercept"`), stacks as extra charges, and shows a persistent
protected frame (`aura`).

Nothing persists between strikes: the mutation is built fresh, intercepted inside the gate,
committed, discarded. Combat carries no status-specific logic — it just submits and presents
the outcome (the Resolver reports which containers intercepted, so the right pip glints).
