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
| `description` | string | No | Flavour or ability text shown in the tooltip on hover. While the effect system is rebuilt, this is also the card's RE-AUTHORING BRIEF — what its effects should do when written in the new language. |
| `abilities` | array | No | ACTIVATED ABILITIES this card holds, by id — definitions live in `data/abilities/` (see `ABILITY_AUTHORING_GUIDE.md` there). How rook buildings offer Castling and the materials; any card may hold abilities. A rook building with none authored falls back to the derived rule (Castling for pure rooks, a synthesized material delivery for its remainder). |
| `ranged` | bool | No | Fires a projectile at its auto-attack target instead of the melee lunge. Authored per-card, never derived from composition. |
| `role` | string | No | Battlefield-role tag for the enemy engine (`fodder`/`tank`/`dps`/`support`/`burst`) — an identity statement, ONE per unit. The encounter's survival-weight table resolves it into a protection weight (see `data/encounters/ENCOUNTER_AUTHORING_GUIDE.md`, `survival_weights`). Never load-bearing: an untagged unit falls to the table's `default` entry. Kings need no role — `is_king` already reads as "captain". |

---

## Effects — FORGOTTEN (effect-cleanse, 2026-08-11)

**Do not author `effects` on any card.** The old effect language (triggers, targeting
policies, payload dicts) is burned: every authored payload was stripped from `data/`, and
the runtime no longer executes anything written in it — an old-language block is inert
bytes at best.
Effects return container by container as the rebuilt effect system lands — four sibling
structures (Triggered / Activated / Passive / Interceptor) with per-need target resolvers,
authored in the schema that rebuild defines. `TARGETING_DESIGN.md` at the repo root is the
authority; the old schema's reference lives in git history, and each card's `description`
is its re-authoring brief.

---

## Composition cards (element / chess-piece combos)

A card with `elements` and/or `chess_pieces` is a **composition** card. If you author one but
**omit its stats** (`cost`/`attack`/`health`/`speed`/`display_name`), it inherits the derived
values for that composition — so you can author a combo without restating its numbers:

```json
{
  "id": "darkness_water_pawn",
  "elements": ["darkness", "water"], "chess_pieces": ["pawn"]
}
```

Any stat you *do* specify is respected; the rest are derived. (Fully-statted combo cards — see
`chess_combined.json` — keep working exactly as before.) Use the canonical id: elements and pieces
sorted alphabetically, e.g. `darkness_water_bishop_pawn`, not `..._pawn_bishop`.

## Notes

- The `id` must be unique across all files. Duplicate IDs will silently overwrite each other.
- Cards must be added to a run's deck to appear in play. The starter deck is defined in `data/decks/starter.json` (see `data/decks/DECK_AUTHORING_GUIDE.md`).
