# Map Authoring Guide

`data/map/node_weights.json` controls the odds of each node type appearing on a given floor of the procedurally generated map. Any `.json` file in `data/map/` is loaded automatically at startup (same pattern as `data/cards/`, `data/decks/`, `data/encounters/`).

Floor 0 is always Combat, the last floor is always Boss, and the second-to-last floor is always Elite — these are structural map-shape rules and stay hardcoded in `MapData._pick_type()`, not content. Every other floor rolls against this weight table.

## File Format

```json
[
  { "min_floor": 1, "max_floor": 999, "weights": { "combat": 0.45, "rest": 0.20, "event": 0.15, "shop": 0.20 } }
]
```

| Field | Type | Required | Description |
|---|---|---|---|
| `min_floor` / `max_floor` | int | Yes | Inclusive floor band this row applies to |
| `weights` | object | Yes | Map of node-type key (`combat`, `rest`, `event`, `shop`) to relative weight |

Weights don't need to sum to 1 — they're normalized against their own total when picked, so you can add a new type at any relative scale without rebalancing the others.

Forge is intentionally absent from this table — it's a permanently available action from the map screen (see `map.gd`), not a node you roll into.

## Adding a new floor band

Add another row with a different `min_floor`/`max_floor` and its own `weights` — e.g. to make Shop nodes rarer early and more common later, add two rows with non-overlapping bands and different `shop` weights. The first row whose band contains the floor wins, so keep bands non-overlapping.

## Adding a new node type

1. Add a value to `MapNodeData.Type` and a label/color in `MapNodeData`.
2. Add a key for it to `weights` here.
3. Add the string→enum mapping in `MapData._str_type()`.
4. Give it a `NodeKind` (see `scripts/node_kinds/`) so entering it does something.
