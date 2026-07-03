# Status Authoring Guide

A **Status** is a named, time-boxed bundle of effects applied to a card *at runtime* — a buff,
debuff, periodic effect, or event-reactive effect that rides the card for a duration and then
falls off. Statuses are **not** special-cased: a status carries the exact same `effects` array
that cards use (see `data/cards/CARD_AUTHORING_GUIDE.md`), so **anything a card effect can do, a
status can do too** — it's just applied dynamically during combat and removed on a timer.

Statuses are defined as JSON files in `data/statuses/`. Any `.json` file there is loaded at
startup (a file may hold a single status or an array of them). They are referenced by `id` from a
card/spell/charm/upgrade effect's `status` payload (see the card guide).

---

## Fields

| Field | Type | Required | Description |
|---|---|---|---|
| `id` | string | Yes | Unique identifier, referenced by effects that apply the status |
| `display_name` | string | No | Name shown in the pip tooltip (defaults from `id`) |
| `description` | string | No | Tooltip text |
| `beneficial` | bool | No | `true` (default) tints the apply VFX/pip as a buff; `false` as a debuff |
| `color` | hex string | No | Pip background colour (e.g. `"e0a93b"`) |
| `glyph` | string | No | Short glyph shown on the pip (e.g. `"↑"`, `"☠"`) |
| `default_duration` | int | No | Initial `remaining` for a `duration`-decay status, when the applier doesn't override it |
| `decay` | string | No | How it wears off (see below): `duration` (default), `stacks`, or `none` |
| `decay_phase` | string | No | When it counts down: `turn_end` (default) or `turn_start` |
| `stacking` | string | No | How a re-application combines (see below) |
| `max_stacks` | int | No | Cap for intensity stacking |
| `effects` | array | No | The effects the status carries — identical schema to card effects |

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

`decay_phase` chooses when the countdown (and any `on_turn_start`/`on_turn_end` effects) resolve:
`turn_end` (default, after attacks) or `turn_start` (before attacks). Effects fire **before** the
decay that round, so a `stacks`-decay status acts on its current count, then the count drops.

Cards — and their statuses — are rebuilt every fight, so nothing persists between combats.

---

## Examples

**Empowered** — a simple timed buff. A `modifier` effect folds into the card's Attack while the
status is active (it disappears automatically when the status falls off):
```json
{
  "id": "empowered", "display_name": "Empowered", "beneficial": true,
  "color": "e0a93b", "glyph": "↑", "default_duration": 2, "stacking": "refresh",
  "effects": [
    { "kind": "modifier", "key": "unit.attack", "amount": 2 }
  ]
}
```
> `modifier` keys: `unit.attack`, `unit.health` (max HP), `unit.speed`, `card.cost`.

**Withered** — a periodic debuff that stacks. The `on_turn_end` effect drains 1 HP each round,
and because `stacking` is `stack`, re-applying makes it drain harder:
```json
{
  "id": "withered", "display_name": "Withered", "beneficial": false,
  "color": "7a9b58", "glyph": "☠", "default_duration": 3, "stacking": "stack", "max_stacks": 9,
  "effects": [
    { "trigger": "on_turn_end", "targeting_policy": "self", "attribute": "health", "amount": -1 }
  ]
}
```

**Poison** — Slay-the-Spire poison. `decay: "stacks"` makes the **count** itself the timer: each
turn-start the unit takes damage equal to the count (the `-1` effect scaled by stacks), then the
count drops by 1, until it's gone. `stacking: "stack"` means re-applying adds to the count:
```json
{
  "id": "poison", "display_name": "Poison", "beneficial": false,
  "color": "5a8f3a", "glyph": "☠",
  "decay": "stacks", "decay_phase": "turn_start", "stacking": "stack", "max_stacks": 99,
  "effects": [
    { "trigger": "on_turn_start", "targeting_policy": "self", "attribute": "health", "amount": -1 }
  ]
}
```

A card applies these via its effect's `status` payload — e.g. a unit that poisons whoever it hits,
or a spell that withers the nearest enemy on play:
```json
{ "trigger": "on_attack", "targeting_policy": "single_nearest", "status": { "id": "poison", "stacks": 1 } }
{ "trigger": "on_play",   "targeting_policy": "single_nearest", "status": { "id": "withered", "duration": 3 } }
```

---

## Notes

- A status's `effects` use the **full** card-effect schema: `modifier` (passive stat deltas),
  triggered effects on any event (`on_play`/`on_attack`/`on_death`/`on_damage_taken`/`on_turn_*`),
  conditions, even a nested `status` payload (apply another status), and custom hooks. Stacked
  statuses scale `modifier` and triggered magnitudes by their stack count.
- Statuses are combat-runtime only — they are never saved and never carry across fights.
- `id` must be unique across all status files; duplicates silently overwrite.

## Arbitration: rewriting a pending attack (`outgoing_damage` / `incoming_damage`)

Combat does not deal attack damage as fact — it builds the **pending mutation** (a
`StatMutation`: stat `damage`, a positive magnitude), sends it through the trigger dispatch
where effects may rewrite it, and then submits whatever is left to the **Resolver** (the single
writer of all game stats — it owns the shield-first resolution; no effect or combat code knows
shields exist). An effect rewrites the pending amount with the `outgoing_damage` /
`incoming_damage` attributes (aliases — "my own strike" vs "a hit landing on me"; both edit the
same pending mutation):

- `"op": "mul"` scales the pending amount — `amount: 0` is a full block (reads as **Miss**).
- default (`add`) shifts it — **positive adds damage, negative is armor** (e.g. `amount: -3`
  shaves 3 off the hit). Scaled by stacks like any stat delta.
- The pending amount can shrink to 0 but never goes below (a blocked strike is 0, not a heal).
- Outside an arbitrated moment (no pending mutation on the context) the effect is a no-op.

**Blind** is the canonical example — when the holder attacks, 50% chance its own strike is
multiplied to nothing; one charge spent per attack (`decay: "stacks"`, `decay_phase: "attack"`):
```json
{
	"id": "blind", "beneficial": false, "glyph": "◐",
	"decay": "stacks", "decay_phase": "attack", "stacking": "stack", "max_stacks": 99,
	"effects": [
		{ "trigger": "on_attack", "targeting_policy": "self", "attribute": "outgoing_damage", "op": "mul", "amount": 0, "chance": 0.5 }
	]
}
```

Nothing persists between attacks: the pending mutation is built fresh per strike, rewritten during that
one dispatch, consumed, and discarded — so combat carries no status-specific logic and there is
no stored counter that a later, unrelated attack could accidentally spend.
