# Encounter Authoring Guide

Encounter templates are defined as JSON files inside `data/encounters/`. Any `.json` file in that folder is loaded automatically at startup — no code changes required (same pattern as `data/cards/` and `data/decks/`).

A template describes an enemy *card pool* to sample from, not a fixed list — every time a node using this template is entered, a fresh enemy deck is drawn, so the same node type plays differently across runs.

## File Format

```json
{
  "id": "goblin_warband",
  "node_type": "combat",
  "min_floor": 0,
  "max_floor": 999,
  "weight": 1,
  "enemy_king": "goblin_warlord",
  "enemy_pool": [
    { "id": "goblin_cutter", "weight": 3 },
    { "id": "goblin_warboss", "weight": 1 }
  ],
  "pick_count": [18, 24],
  "ai": "default",
  "reward_pool": "default"
}
```

| Field | Type | Required | Description |
|---|---|---|---|
| `id` | string | Yes | Unique identifier (not currently looked up by id, but useful for debugging/authoring clarity) |
| `node_type` | string | Yes | `combat`, `elite`, or `boss` — which map node type this template can serve |
| `min_floor` / `max_floor` | int | No | Inclusive floor-eligibility band. Defaults to `0`/`999` (always eligible) |
| `weight` | float | No | Relative chance of being picked when multiple templates are eligible for the same node_type + floor. Defaults to `1` |
| `enemy_king` | string | No | Card id placed in the enemy's king slot — the win-condition unit. Defaults to `"king"` (the generic crown King). Tribe fights name a themed **Captain** (an `is_king` + `enemy_only` card, e.g. `goblin_warlord`, or a tougher `hobgoblin_tyrant`/`gorthok` for elites/bosses). Do **not** also list it in `enemy_pool` |
| `enemy_pool` | array | Yes | Weighted candidate cards for the enemy *deck* (the king/captain is separate — see `enemy_king`). Sampled **with replacement**, so the same card can appear more than once. Size the deck generously via `pick_count` so the CPU doesn't run dry mid-fight |
| `pick_count` | `[min, max]` | Yes | Inclusive random range for how many cards are drawn from the pool per instantiation. Tribe fights use ~14–24 so the opponent keeps applying pressure rather than emptying its hand |
| `gold_reward` | `[min, max]` | No | Inclusive random range of gold granted on win. Defaults to `[0, 0]` |
| `exp_reward` | int | No | Profile experience granted on win, toward upgrade points. Defaults to `1`; author higher for special fights (e.g. elites/bosses) |
| `ai` | string | No | Key into `EnemyAI.from_key()`. Defaults to `"default"` |
| `reward_pool` | string | No | Key into `EncounterTemplateData.resolve_reward_pool()`. Defaults to `"default"` (any non-king card) |

## Adding variety

Multiple templates can share the same `node_type` and overlapping floor bands — one is chosen at random (weighted by `weight`) each time. This is the intended way to introduce, say, an "early game" combat flavor (floors 0–3) alongside a "late game" one (floors 4+), without touching any code: just add another file with a narrower `min_floor`/`max_floor`.

## Notes

- The `id` must be unique across all files.
- A missing/unparseable file logs a `push_error` and is skipped — it won't crash the game, but any node_type left with zero templates will fail loudly when a node of that type is entered.
- See `scripts/encounter_template_data.gd` for the loader and `scripts/enemy_ai.gd` / `EncounterTemplateData.resolve_reward_pool()` for the `ai`/`reward_pool` registries.
