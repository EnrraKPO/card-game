# Ability Authoring Guide

An **activated ability** is *effects with a cost instead of a trigger*: the player (or the
enemy AI) chooses to pay and fire it, where triggered effects fire on events. Abilities are
defined as JSON files in `data/abilities/` (any `.json`, single or array) and referenced by id
from an effect container — a card's `"abilities": ["castling"]` today; statuses can hold them
too (`abilities` on a status definition, ported to the carrier while the status is active —
temporary by nature).

Abilities are **transient**: present while their holder is fielded, or until removed. They are
not cards — they live in no pool, deck, or collection.

## Fields

| Field | Type | Required | Description |
|---|---|---|---|
| `id` | string | Yes | Unique identifier, referenced by containers |
| `display_name` | string | No | Shown on the tray entry (defaults from `id`) |
| `description` | string | No | Tooltip text |
| `cost` | object | No | `{ "mana": int, "tap": bool }`. `tap` (default **true**) spends the holder's action for the round (it neither attacks nor taps again until the round refresh); a tapped holder's tap-costed abilities are not offered at all |
| `material` | string | No | For material-delivery abilities: the composition key delivered (read by the `deliver_material` hook) |
| `autocast` | bool | No | Autocast-capable (default false). The widget shows corner brackets; right-click / long-press ARMS it (max 1 armed per unit). While armed, dragging the holder unit onto a valid target fires the ability on it, paying the normal cost — the unit does not move. Only meaningful on movable holders with manually-targeted effects |
| `effects` | array | No | The ordinary effect schema — triggers are ignored (`on_play` by convention); targeting policies, conditions and payloads work exactly as on cards |

## Presentation

For now abilities present **card-like in the hand tray**, alongside cards (an interim UX): the
entry shows the ability's name, mana cost and description, with art from
`assets/abilities/<id>.png` (placeholder until authored). Activating one routes through the
same targeting flows as spells — ineligible targets don't light up. The effects resolve with
the **holder** as their source (the rook grants the Barrier).

## Example

```json
{
  "id": "castling",
  "display_name": "Castling",
  "description": "Grants one unit without a Barrier a Barrier that blocks the next damaging attack.",
  "cost": { "mana": 1, "tap": true },
  "effects": [
    {
      "trigger": "on_play", "targeting_policy": "manual",
      "conditions": [ { "status": "barrier", "present": false } ],
      "status": { "id": "barrier", "stacks": 1 }
    }
  ]
}
```

A card holds it with:

```json
{ "id": "rook", ..., "abilities": ["castling"] }
```
