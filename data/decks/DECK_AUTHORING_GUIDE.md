# Deck Authoring Guide

Decks are defined as JSON files inside `data/decks/`. Any `.json` file in that folder is loaded automatically at startup — no code changes required. This mirrors how `data/cards/` works (see `CARD_AUTHORING_GUIDE.md`).

## File Format

```json
{ "id": "king", "cards": ["pawn", "pawn", "bishop", "knight", "rook", "queen"] }
```

| Field | Type | Required | Description |
|---|---|---|---|
| `id` | string | Yes | Unique identifier used to look the deck up in code (`DeckData.get_deck(id)`) |
| `cards` | array of strings | Yes | Card IDs, in deck order. Do **not** list the King — the King is placed onto the board by `CombatBoard.place_kings`, not drawn from the deck. |

## Decks are seeded from King templates

These JSON files are **templates** — read-only seeds, not the deck the player runs with.
When a King is unlocked, the profile copies its template into a first-class, editable
**owned deck** (`OwnedDeck`, stored in `ProfileData.decks`). A run takes a deep-copied
snapshot of the *selected owned deck* (`RunData.create_new` → `profile.get_selected_deck()`),
so run-time edits (forge charms, "?" upgrades) never write back to the saved deck.

A template's `id` should match a King's card id, since unlocking that King seeds from it:

- `king.json` — the basic King's chess deck (8 Pawns, 2 Bishops, 2 Knights, 2 Rooks, 1 Queen).
- Future elemental Kings drop in as e.g. `fire_king.json` — same skeleton, infused with the element. No code changes needed; unlocking the King seeds a deck from it.

`FALLBACK_ID` (`"king"`) is used to seed if a selected King has no template file yet.

The King is an **attribute** of an owned deck (`king_id`), not its identity — the player
may hold several decks per King and edit each independently. "Picking a deck" picks its King.

## Notes

- The `id` must be unique across all files. Duplicate IDs silently overwrite each other.
- The collection grows by **unlocking Kings**, not by free deckbuilding. Per-King deck tampering (the Laboratory) is a later, tightly-gated layer.
