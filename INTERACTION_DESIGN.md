# Combat Interaction System — Design

**Status: approved 2026-07-23 — implementation in progress.**

## Problem

Combat has no single notion of *"what is the player doing right now."* Five gesture paths
(spell targeting, MANUAL_SLOT targeting, hand-tray abilities, unit place, unit move, autocast)
each privately answer the same four questions — which slots are valid, how the board should look,
what happens on commit, how everything resets — wired through four independent state owners
(`Combat._phase`, `SpellCaster`'s booleans, `CombatBoard._drag_card`+preview state, `DragGhost`'s
verdict state). Fixes land on one path and miss the others; cleanup is assembled ad-hoc at every
gesture end. See the one-off-defect cluster this produced (2026-07).

## Model

### One owner: `Interaction`

A combat-scoped node (created by `Combat`, injected into board/slots) holding **the current
action** — at most one at a time. Everything the player can initiate *begins* an action on it and
*ends* through it. It emits one signal, `changed(action)` (`null` = idle), and every presentation
component derives its look from that.

### Actions declare, components react

An **action** (`Interaction.Action`) is a declarative description:

| field | meaning |
|---|---|
| `kind` | `UNIT` (place/move), `CAST` (manual target), `CAST_SLOT` (MANUAL_SLOT pick), `AUTOCAST` (move+cast hybrid) |
| `source: CardUI` | the card driving the gesture |
| `role_of(slot) → Role` | THE single rules authority: what each slot *is* under this action |
| `commit(slot)` | perform the action on a chosen slot (drop or click — same entry) |
| `animated: bool` | drag (bobbing cues) vs static selection |
| `is_drag: bool` | drag-owned (ends with the drag) vs click session (ends on commit/cancel) |
| `preview_instance` | fielded unit whose attack projection shows (null = none) |

**Roles** are the shared vocabulary between rules and presentation:
`NONE, DESTINATION, TARGET_VALID, TARGET_INVALID`.

Components own their *reaction* to a role, each in exactly one place:

- **CombatBoard** renders the whole board from the action: walks slots once,
  role → cue (`DESTINATION`→MOVE ring, `TARGET_VALID`→golden glow/reticle,
  `TARGET_INVALID`→red X, `NONE`→rest) + drop-gate border; attack preview from
  `preview_instance`; drag phantom while `is_drag`. `changed(null)` → everything resets
  **automatically** — cleanup is structural, not per-path.
- **SlotUI** answers drops by asking the action: `_can_drop_data` = "is my role committable?",
  `_drop_data` = `commit(self)`. The cue and the drop verdict come from the same predicate,
  so they can never disagree.
- **DragGhost** verdicts map from roles (`DESTINATION`→UNIT, `TARGET_VALID`→CAST_OK,
  `TARGET_INVALID`→CAST_INVALID); its existing no-ability fallback keeps spell ghosts plain.
- **Commit re-validates** by re-asking `role_of` at execution time (kept deliberately — the
  hover-gate and the execution check are the same predicate now, evaluated twice).

### Rules stay with the rules experts

`SpellCaster` keeps eligibility + execution + costs (the spell-rules expert) and **loses all
session state** (`_is_targeting`, `_pending_spell`, `_targeting_spell`, `_targeting_slot_mode`,
the `await`-signal sessions). It exposes action *factories*; `CombatBoard` keeps move legality
(`_can_drop_on_player_slot`) and placement (`do_place_unit`). Autocast composes both experts in
one action — no bespoke hybrid path.

### Phase shrinks to turn structure

`Combat.Phase` keeps `CPU_PLACE / PLAYER_PLACE / COMBAT`. `TARGETING` is deleted — "is the player
mid-gesture" is `Interaction.active()`, checked where the phase was. The
`targeting_started/ended` signal pair is replaced by `Interaction.changed`.

## Behavior preserved deliberately

- Both gesture styles everywhere: click-then-click AND drag, for every action.
- Plain moves show only valid destinations (no red X); targeted casts mark invalid slots too.
  Policy lives in each action's `role_of` (returns `NONE` vs `TARGET_INVALID`).
- Right-click cancels a click session; drag end cancels a drag action.
- Idle OPEN markers on empty own slots while placement input is live (idle presentation,
  outside any action).
- The unaffordable-placement mana flicker (Combat-level commit-fail feedback).
- `HandDropZone` stays as-is (defined, unwired) — separate decision, not silently deleted.

## Out of scope

Resolver/EffectSystem/animator/enemy AI — untouched. This is strictly the
player-gesture → presentation → commit layer.

## Migration order (each step parse-checked; regression suite + render harness at the end)

1. `Interaction` core + `CombatBoard.present()` renderer.
2. Unit place/move (drag + click-select) ported.
3. Spell + MANUAL_SLOT targeting ported (click + drag unify onto one session).
4. Autocast hybrid ported (composition of 2+3).
5. Legacy wiring deleted: `show_move_cues`, `show_move_and_cast_cues`,
   `set_slots_targetable(_by_slot)`, `SlotUI.accept_check/autocast_check/_targetable`-plumbing,
   `SpellCaster` session state, `Phase.TARGETING`.
