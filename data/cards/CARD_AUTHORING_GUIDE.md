# Card Authoring Guide

Cards are defined as JSON files inside `data/cards/`. Any `.json` file in that folder is loaded automatically at startup — no code changes required.

---

## File Format

A file can contain a single card or an array of cards.

**Single card:**
```json
{ "id": "strike", "display_name": "Strike", "cost": 1, "attack": 4, "health": 3, "speed": 5 }
```

**Multiple cards:**
```json
[
  { "id": "strike", "display_name": "Strike", "cost": 1, "attack": 4, "health": 3, "speed": 5 },
  { "id": "archer", "display_name": "Archer", "cost": 2, "attack": 3, "health": 3, "speed": 6 }
]
```

---

## Card Fields

| Field | Type | Required | Description |
|---|---|---|---|
| `id` | string | Yes | Unique identifier used in decks and code |
| `display_name` | string | Yes | Name shown on the card in-game |
| `cost` | int | Yes | Mana cost to play |
| `attack` | int | Yes | Base damage dealt per attack |
| `health` | int | Yes | Maximum and starting health |
| `speed` | int | Yes | Determines attack order — higher goes first |
| `is_king` | bool | No | Marks the card as the King unit. Defaults to false. |
| `description` | string | No | Flavour or ability text shown in the tooltip on hover. |
| `effects` | array | No | List of effects triggered at various moments. Defaults to empty. |

---

## Effects

An effect is an action that fires at a specific moment, targeting one or more cards and modifying an attribute.

```json
{
  "trigger": "on_play",
  "targeting_policy": "all_allies",
  "attribute": "attack",
  "amount": 1,
  "conditions": []
}
```

### `trigger` — when the effect fires

| Value | Description |
|---|---|
| `on_play` | When the card is placed on the board |
| `on_death` | When the card is killed |
| `on_attack` | Each time the card attacks |
| `on_damage_taken` | Each time the card takes damage |
| `permanent` | Applied once when the card enters the board |
| `on_turn_start` | Fired for the card at the start of each combat round (before attacks) |
| `on_turn_end` | Fired for the card at the end of each combat round (after attacks); statuses then count down |

### `targeting_policy` — who is affected

| Value | Description |
|---|---|
| `self` | Only the card that owns the effect |
| `single_nearest` | The nearest enemy (same logic as combat targeting) |
| `single_random` | A random enemy |
| `all_enemies` | Every enemy card currently on the board |
| `all_allies` | Every friendly card currently on the board (including self) |
| `all` | Every card on the board regardless of side |
| `manual` | A single target the player picks (for spells) |
| `attack_target` | The unit this card is striking — only meaningful on an `on_attack` effect (e.g. "apply Poison to whoever I hit") |

> **Effects apply to everyone.** Every policy above affects Kings, Queens, and ordinary units
> equally — there is no royalty exemption. So an `all_allies` buff reaches your King, an
> `all_enemies`/`single_nearest`/`manual` effect can hit the enemy King, and a `manual` spell lets
> the player pick any unit. (Kings are still the win/lose condition and persist across fights — that
> hasn't changed.)

### `attribute` — what is modified

| Value | Description |
|---|---|
| `health` | Current health. Negative amount deals damage, positive heals (capped at max) |
| `attack` | Attack power |
| `speed` | Attack order priority |
| `cost` | Mana cost |

### `amount` — how much to change

An integer. Positive values buff, negative values debuff or deal damage.

### `status` — apply a Status to the targets (optional)

Instead of (or in addition to) a one-shot `attribute` change, an effect can apply a **Status** — a
named, time-boxed bundle of effects that rides the card for a duration (see
`data/statuses/STATUS_AUTHORING_GUIDE.md`). Any triggered effect can apply one; it lands on every
target the `targeting_policy` resolves.

```json
{
  "trigger": "on_play",
  "targeting_policy": "single_nearest",
  "status": { "id": "withered", "duration": 3, "stacks": 1 }
}
```

| Field | Type | Description |
|---|---|---|
| `id` | string | The status to apply (must exist in `data/statuses/`) |
| `duration` | int | Optional — overrides the status's own default duration |
| `stacks` | int | Optional — stacks to add (default 1; combines per the status's stacking rule) |

### `conditions` — filter valid targets (optional)

A list of conditions that must **all** pass for a target to be affected. If omitted or empty, all candidates from the targeting policy are affected.

```json
"conditions": [
  { "attribute": "speed", "comparator": "gte", "value": 5 }
]
```

**`attribute`** — any card attribute listed above (`health`, `attack`, `speed`, `cost`)

**`comparator`** — how to compare the attribute value against `value`

| Value | Meaning |
|---|---|
| `gt` | Greater than |
| `gte` | Greater than or equal |
| `lt` | Less than |
| `lte` | Less than or equal |
| `eq` | Equal |
| `neq` | Not equal |

**`value`** — the integer threshold to compare against

---

## Examples

**Berserker** — gains +2 ATK the moment it's played:
```json
{
  "id": "berserker",
  "display_name": "Berserker",
  "cost": 2, "attack": 3, "health": 4, "speed": 4,
  "effects": [
    { "trigger": "on_play", "targeting_policy": "self", "attribute": "attack", "amount": 2 }
  ]
}
```

**Commander** — gives every ally +1 ATK on play:
```json
{
  "id": "commander",
  "display_name": "Commander",
  "cost": 3, "attack": 1, "health": 6, "speed": 2,
  "effects": [
    { "trigger": "on_play", "targeting_policy": "all_allies", "attribute": "attack", "amount": 1 }
  ]
}
```

**Plague Doc** — deals 2 damage to all enemies with SPD ≥ 5 on play:
```json
{
  "id": "plague_doc",
  "display_name": "Plague Doc",
  "cost": 2, "attack": 1, "health": 3, "speed": 3,
  "effects": [
    {
      "trigger": "on_play",
      "targeting_policy": "all_enemies",
      "attribute": "health",
      "amount": -2,
      "conditions": [
        { "attribute": "speed", "comparator": "gte", "value": 5 }
      ]
    }
  ]
}
```

**Martyr** — gives all surviving allies +2 ATK when it dies:
```json
{
  "id": "martyr",
  "display_name": "Martyr",
  "cost": 2, "attack": 2, "health": 4, "speed": 3,
  "effects": [
    { "trigger": "on_death", "targeting_policy": "all_allies", "attribute": "attack", "amount": 2 }
  ]
}
```

**Vampire** — heals 2 HP after each attack:
```json
{
  "id": "vampire",
  "display_name": "Vampire",
  "cost": 3, "attack": 3, "health": 3, "speed": 5,
  "effects": [
    { "trigger": "on_attack", "targeting_policy": "self", "attribute": "health", "amount": 2 }
  ]
}
```

**Brute** — gains +3 ATK when damaged to 3 HP or below (enrage):
```json
{
  "id": "brute",
  "display_name": "Brute",
  "cost": 2, "attack": 2, "health": 6, "speed": 2,
  "effects": [
    {
      "trigger": "on_damage_taken",
      "targeting_policy": "self",
      "attribute": "attack",
      "amount": 3,
      "conditions": [
        { "attribute": "health", "comparator": "lte", "value": 3 }
      ]
    }
  ]
}
```

**A card with multiple effects** — heals on attack AND buffs allies on death:
```json
{
  "id": "paladin",
  "display_name": "Paladin",
  "cost": 4, "attack": 3, "health": 7, "speed": 3,
  "effects": [
    { "trigger": "on_attack",  "targeting_policy": "self",       "attribute": "health", "amount": 1 },
    { "trigger": "on_death",   "targeting_policy": "all_allies", "attribute": "attack", "amount": 3 }
  ]
}
```

---

## Composition cards (element / chess-piece combos)

A card with `elements` and/or `chess_pieces` is a **composition** card. If you author one but
**omit its stats** (`cost`/`attack`/`health`/`speed`/`display_name`), it inherits the derived
values for that composition — so you can attach effects to a combo without restating its numbers:

```json
{
  "id": "darkness_water_pawn",
  "elements": ["darkness", "water"], "chess_pieces": ["pawn"],
  "effects": [
    { "trigger": "on_attack", "targeting_policy": "attack_target", "status": { "id": "poison", "stacks": 1 } }
  ]
}
```

Any stat you *do* specify is respected; the rest are derived. (Fully-statted combo cards — see
`chess_combined.json` — keep working exactly as before.) Use the canonical id: elements and pieces
sorted alphabetically, e.g. `darkness_water_bishop_pawn`, not `..._pawn_bishop`.

## Notes

- A card can have any number of effects.
- Multiple conditions on one effect are AND logic — all must pass.
- OR logic can be expressed as two separate effects with the same trigger and policy but different conditions.
- The `id` must be unique across all files. Duplicate IDs will silently overwrite each other.
- Cards must be added to a run's deck to appear in play. The starter deck is defined in `data/decks/starter.json` (see `data/decks/DECK_AUTHORING_GUIDE.md`).
