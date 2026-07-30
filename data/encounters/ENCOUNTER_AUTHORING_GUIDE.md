# Encounter Authoring Guide

Encounter templates are defined as JSON files inside `data/encounters/`. Any `.json` file in that folder is loaded automatically at startup — no code changes required (same pattern as `data/cards/` and `data/decks/`).

A template describes an enemy *card pool* and the share each unit takes of the deck, not a fixed list — every time a node using this template is entered a fresh enemy deck is composed, sized to the fight's difficulty.

The composition is **procedural, not random** (user call 2026-07-30): weights are apportioned by largest remainder, so an entry always lands within one card of its exact share. Randomness survives only as a tiebreak for the leftover cards when two shares come out equal. Two fights from the same template differ by a card or two, never in character — the previous sampler could hand you an all-fodder fight and a no-fodder fight from the same weights.

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
    { "id": "goblin_warboss", "weight": 1, "min_power": 8 }
  ],
  "pick_count": [18, 24],
  "ai": "default",
  "reward_pool": "default"
}
```

| Field | Type | Required | Description |
|---|---|---|---|
| `id` | string | Yes | Unique identifier (not currently looked up by id, but useful for debugging/authoring clarity) |
| `node_type` | string | Yes | `combat`, `elite`, or `boss` — which map node type this template can serve. `test` is a fourth value for debug-only content: it is never generated onto a real map, and lists in its own "Test Dummies" section in the Combat Gym instead of Combat/Elite/Boss |
| `min_floor` / `max_floor` | int | No | Inclusive floor-eligibility band. Defaults to `0`/`999` (always eligible) |
| `weight` | float | No | Relative chance of being picked when multiple templates are eligible for the same node_type + floor. Defaults to `1` |
| `enemy_king` | string | No | Card id placed in the enemy's king slot — the win-condition unit. Defaults to `"king"` (the generic crown King). Tribe fights name a themed **Captain** (an `is_king` + `enemy_only` card, e.g. `goblin_warlord`, or a tougher `hobgoblin_tyrant`/`gorthok` for elites/bosses). Do **not** also list it in `enemy_pool` |
| `enemy_pool` | array | Yes | The units the enemy *deck* is built from (the king/captain is separate — see `enemy_king`). The deck is **apportioned**, not rolled: each entry gets its share of `pick_count` cards, so the same card appears as many times as its weight earns. Size the deck generously so the CPU doesn't run dry mid-fight. Each entry is `{ "id", "weight", "min_power" }` — see below |
| `enemy_pool[].weight` | float | No | This unit's **share** of the deck, relative to the other unlocked entries — weight 3 of a total 12 means a quarter of the cards, in every fight. Defaults to `1`; `0` means "not in this fight". **A weight means exactly what it says at every difficulty** — nothing reweights the pool behind your back (the old cost skew was removed 2026-07-30) |
| `enemy_pool[].min_power` | float | No | The difficulty this unit is **anchored** to: it stays out of the fight entirely until the encounter's power reaches this value. Defaults to `0` (in from the very first fight). This is the one way difficulty shapes the *mix*: pull the heavy units up so early fights are made of the cheap ones, and let the weights alone decide the ratio once everything is unlocked. At least one entry must be unanchored, or the roll has nothing to draw from (the generator falls open on the whole pool and warns) |
| `pick_count` | `[min, max]` | Yes | Inclusive random range for how many cards are drawn from the pool per instantiation. Tribe fights use ~14–24 so the opponent keeps applying pressure rather than emptying its hand |
| `gold_reward` | `[min, max]` | No | Inclusive random range of gold granted on win. Defaults to `[0, 0]` |
| `exp_reward` | int | No | Profile experience granted on win, toward upgrade points. Defaults to `1`; author higher for special fights (e.g. elites/bosses) |
| `ai` | string | No | Key into `EnemyAI.from_key()`. Defaults to `"default"` |
| `survival_weights` | object | No | Role→weight entries layered over the enemy engine's stock survival-weight table (`BoardScoring.STOCK_SURVIVAL_WEIGHTS`) — e.g. `{ "fodder": 0.5 }` means "in this fight, fodders are precious". Keys are role tags (`captain`/`tank`/`dps`/`support`/`burst`/`fodder`), `default` (untagged units), or a specific card id. Values are the unit's survival priority: the engine protects units in proportion to `weight × likelihood of dying`. **All stock weights are provisional and have not been playtested** — they were tuned against scenarios staged in the engine's own test suite, so the tests agreeing with them is not evidence they are right. On those staged boards the stock captain weight (1.75) reads as threat-dependent: moderate threat and the king walks to the front line to absorb hits for valued units, heavy threat and it commits to the back column. Roughly, `{ "captain": 1.0 }` authors a recklessly sponge-like king and `{ "captain": 2.5 }` one that never shares a hit. Expect to retune from real fights. Empty/omitted = stock behaviour |
| `personality` | string | No | **Who the CPU is in this fight** — the id of an authored enemy personality (`data/enemy_personalities.json`, edited in Tool ▸ 🧠 Enemy AI). A personality is a set of eval weights: how much this opponent fears dying, how hard it pushes to spend its mana, whether it reaches for damage. Defaults to `"default"` (the stock character); an unknown id degrades to it with a warning, so renaming a personality never breaks a fight. See the section below |
| `reward_pool` | string | No | Key into `EncounterTemplateData.resolve_reward_pool()`. Defaults to `"default"` (any non-king card) |

## Difficulty: what power changes, and what it doesn't

`power` is how deep the fight is (a convex ramp over run depth, plus the template's own
`power_bonus`). It changes exactly three things:

1. **Deck size** — `pick_count` plus `POWER_SIZE_GROWTH` (0.5) cards per point of power.
2. **Which units are in the pool at all** — every entry whose `min_power` the fight has reached.
3. **Per-card stats** — `CardData.scaled` grows the drawn cards' numbers.

It does **not** touch the ratio between unlocked entries. That was true until 2026-07-30, when a
cost skew silently reweighted the pool by card cost as power climbed: on `test_dummies` it took
the weight-3 fodder from 2.08 cards per deck down to 1.75, while pushing the weight-1 group heal
from 0.82 up to 3.83 — the rarest authored entry became the most common card in the deck. Anchors
replace it, because an anchor is a statement an author makes and can read back.

## Personalities: who the opponent is

The enemy engine picks its moves by scoring every legal option against weighted criteria. A
**personality** is a named set of those weights — the whole authoring surface for enemy
character. They live in `data/enemy_personalities.json` and are authored in Tool ▸ 🧠 Enemy AI,
where each fight can also be assigned one.

Two kinds of entry, a tool distinction rather than an engine one:

- **Core traits** — every personality has all of them, and can only re-price them: fear of
  dying, fear of being worn down, formation instinct, hunger for the board, use-your-mana,
  reluctance to tap, never-sit-on-a-hand. A trait left blank keeps the stock number, so a new
  personality starts as the default enemy and is edited away from it.
- **Quirks** — opt-in leans a personality either carries or doesn't. Today there is one,
  *maximize damage output* (how hard it reaches for the most damaging option available). A
  quirk that is not carried is not in the scorer at all, which is not the same as weighting it
  zero: it stops being part of who that enemy is.

A personality also carries its own `survival_weights` table — **which** units its fear of dying
is afraid of losing. An encounter's own `survival_weights` still layer on top for that one
fight, so a per-fight amendment always wins over the character's standing ordering.

`"default"` is the stock character and cannot be deleted; editing it moves every enemy that
hasn't been given its own personality. **Every shipped personality is a starting point — none
have been playtested.**

## Adding variety

Multiple templates can share the same `node_type` and overlapping floor bands — one is chosen at random (weighted by `weight`) each time. This is the intended way to introduce, say, an "early game" combat flavor (floors 0–3) alongside a "late game" one (floors 4+), without touching any code: just add another file with a narrower `min_floor`/`max_floor`.

## Notes

- The `id` must be unique across all files.
- A missing/unparseable file logs a `push_error` and is skipped — it won't crash the game, but any node_type left with zero templates will fail loudly when a node of that type is entered.
- See `scripts/encounter_template_data.gd` for the loader and `scripts/enemy_ai.gd` / `EncounterTemplateData.resolve_reward_pool()` for the `ai`/`reward_pool` registries.
