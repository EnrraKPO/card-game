# Deck Authoring Guide

Decks are defined as JSON files inside `data/decks/`. Any `.json` file in that folder is loaded automatically at startup — no code changes required. This mirrors how `data/cards/` works (see `CARD_AUTHORING_GUIDE.md`).

## File Format

```json
{ "id": "starter", "cards": ["king", "fire", "fire", "pawn"] }
```

| Field | Type | Required | Description |
|---|---|---|---|
| `id` | string | Yes | Unique identifier used to look the deck up in code (`DeckData.get_deck(id)`) |
| `cards` | array of strings | Yes | Card IDs, in deck order. King(s) are listed explicitly here (unlike `EncounterTemplateData.enemy_pool`, which excludes kings). |

## Notes

- The `id` must be unique across all files. Duplicate IDs silently overwrite each other.
- `RunData.create_new()` currently loads the `"starter"` deck for new runs.
- Adding alternate starting decks (e.g. for a future character-select screen) is just a new file with a different `id` — no code changes needed to load it, only to choose it.
