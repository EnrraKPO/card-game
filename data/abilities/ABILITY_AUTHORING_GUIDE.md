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
| `autocast` | bool | No | Autocast-capable (default false) — an AUTHORED FACT kept through the demolition. The quick-cast mechanism it drives (arming + drag-fire) is razed and returns on the rebuilt ActivatedEffect |

## Effects — FORGOTTEN (effect-cleanse, 2026-08-11)

**Do not author `effects` on an ability.** The old effect language is burned; ability
payloads re-author on the rebuilt **ActivatedEffect** — the runtime structure whose "when"
is a COST GATE, invoked and paid for, with its own target resolver conducting the gesture
(`TARGETING_DESIGN.md` §7). Each ability's `description` is its re-authoring brief; the old
payload spellings live in git history.

## Presentation

For now abilities present **card-like in the hand tray**, alongside cards (an interim UX,
informational while activation is rebuilt): the entry shows the ability's name, mana cost
and description, with art from `assets/abilities/<id>.png` (placeholder until authored).

## Example

```json
{
  "id": "castling",
  "display_name": "Castling",
  "description": "Grants one unit without a Barrier a Barrier that blocks the next damaging attack.",
  "cost": { "mana": 1, "tap": true }
}
```

A card holds it with:

```json
{ "id": "rook", ..., "abilities": ["castling"] }
```
