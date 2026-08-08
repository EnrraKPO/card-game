# Location Manager — Design & Implementation Guide

Status: **DESIGN AGREED 2026-08-08 (user); BUILT 2026-08-08 on branch `location-manager`,
NOT YET PLAYTESTED.** §2 records decisions settled in discussion — do not reopen them. §3 is
the survey of what exists (verify, don't re-survey). §5 is the increment plan, §6 the
verification strategy, §7 the scope fences. §9 records what was built and the two places the
as-built differs from the plan.

This initiative is to be developed **to full extent before anything else is pursued**
(user, 2026-08-08). The whole game ends up on one placement implementation.

Sibling docs: `EFFECT_SYSTEM_DESIGN.md` (effect pipeline), `SLOT_LAYER_DESIGN.md` (the
ground layer and the position-first targeting ruling this completes), `CHAIN_DESIGN.md`
(bouncing effects — the feature that motivated this, explicitly downstream and NOT agreed).

---

## 1. What this is

Board placement — "what is where" — is currently owned by several different things at once.
This initiative consolidates it into **one authority that is the sole container of board
coordinates**, so that nothing else in the game ever stores, derives, or reasons about a
position again.

It is a **consolidation**, not a feature. When it is done the game should behave
identically, and the placement question should have exactly one answer in exactly one place.

## 2. The settled model (the WHY)

**2.1 One authority owns board coordinates. Everything else borrows.** Exactly one
structure stores placement. Everywhere else coordinates are asked for, used, and discarded
— never kept. A unit does not know where it is. A slot does not know where it is. A
presenter does not remember where it drew something. They ask.

This is the existing house rule ("a thing stores only facts it is the authority on; if
anything outside can invalidate it, install a rule that it asks") reaching the one place it
had not reached. A unit is not the authority on its own position — the board moves it.

**2.2 The docking model.** Anything that sits on the board is a **dockable**. The manager
records that a dockable is docked at a **location**, and answers two questions: *where is
this thing* and *what is at this location*. Dockables never hold a location.

**2.3 The manager's ignorance is total and uniform.** It does not know what a unit is, and
it equally does not know what a slot is. It never sees inside a dockable. A slot's statuses
are invisible to it for the same reason a unit's health is.

The **one** exception is the layer (2.5), and that stays honest only while the layer is an
opaque tag the dockable declares. The manager files by it and compares tags. If the manager
ever contains a list of known layer types, or branches on which layer something is, the
ignorance has leaked.

**2.4 Slots are ordinary dockables, not a special case.** A slot's identity *is* its
location and it never undocks — but that is a property of the slot, not a rule the manager
knows. (An earlier "the slot dissolves into the address" idea was rejected: a slot carries
state, so it is a thing that sits somewhere.)

**2.5 The manager is layer-aware, and that makes collisions unrepresentable.** One dockable
per location per layer. Today "two units in one cell" is prevented by everyone who moves
anything being careful; under this it is structural. Docking onto an occupied address is a
**bug, not a situation**: assert, refuse, carry on (user ruling — matches the fail-loud
house rule).

**2.6 A location is one bundled value, and it includes the board side.** Never loose
components. Handing back separate row and column values is how the current material-delivery
defect got written — someone had a row and a column, needed a side, and took one from the
allegiance channel (§3). A bundled value makes that class of mistake hard to write.

**2.7 A location outlives whatever was docked at it.** This is why the effect system speaks
in locations rather than in units: a bouncing effect leaps *from the square where it just
killed someone*. Nothing is docked there any more, and "what is nearest to here" must still
have an answer.

**2.8 Two doors onto the same query.** Give it a **dockable** and it resolves that thing's
location internally; give it a **location** directly. A unit uses the first and never
touches a coordinate. Effects use the second, for 2.7.

**2.9 The manager answers "what is here", never "what is a valid target".** Emptiness is an
answer, not a miss. The manager cannot know what valid means; the caller does. Because the
ground layer has something at every real address, *nothing at all* coming back can only mean
the address was not real — so a legal whiff and a bug stop looking alike.

**2.10 Distance and preference are two different things** (settled last, and it corrects an
earlier framing). The existing `dist` is not a distance — it is a *preference ordering*
wearing a distance's clothes ("column depth dominates, lane offset breaks ties"). A real
distance is symmetric and has no notion of "forward"; that function must be told which side
you are on before it can answer.

- The **manager owns distance** — pure, symmetric, no opinion about facing.
- **Attack targeting keeps its preference ordering**, unchanged, as the game rule it is.

Consequence: who attacks whom does not move, and a bouncing effect does not inherit a
charging unit's sense of forward.

**2.11 Scope boundary: board coordinates only.** Screen positions — where a card is drawn,
where a dragged ghost floats — are a different space that happens to use the same two
letters. They are not swept in.

## 3. What is scattered today (survey 2026-08-08 — verify, don't re-survey)

**Two records of the same fact.** `CardInstance.row/col/owner` stores a unit's position,
*and* `CombatWorld.player_grid/enemy_grid` stores who is where. Kept in agreement by hand.
A 2D array indexed by row and column IS a coordinate store — so the grids fold INTO the
manager rather than sitting beside it, or the refactor swaps two authorities for two others.

**Three separate proximity implementations:**
- `TargetingStrategy.dist` (`scripts/targeting/targeting_strategy.gd:43`) — attack targeting.
- `TargetResolver.board_distance` (`scripts/triggers/target_resolver.gd:376`) — effect
  targeting; a hand-copy whose comment states it reproduces the first "so attack targeting
  and effect targeting agree on what nearest means."
- `CombatWorld._nearest_empty` (`scripts/combat_world.gd:298`) — spawn fallback search.

**One adjacency implementation:** `CombatCascade._spread_destination`
(`scripts/combat_cascade.gd:282`) — orthogonal neighbours on the same half, bounds-checked
inline.

**Two ad-hoc "position of a thing" extractions:** ground delivery under a resolved unit
(`EffectSystem._ground_status_at`, `scripts/effect_system.gd:283`) and spread's "ground"
branch (`combat_cascade.gd:288-290`).

**The conflation defect:** `EffectSystem._ground_status_at_coords`
(`scripts/effect_system.gd:266`) derives which *half of the board* a picked square is on
from `TriggerResolver.anchor_owner` — the **allegiance** channel. Spatial side and allegiance
usually agree, which is why it works. They are not the same question.

**Validity checked by hand, everywhere, spelled differently:** `under.row < 0`
(`effect_system.gd:215`), the bounds guard in `TargetResolver.unit_at_coords`
(`target_resolver.gd:351`), spread's neighbour bounds, `_nearest_empty`'s bounds. Off-board
units carry a sentinel position; "not on the board" becomes *not in the manager*.

**Coordinate channels already on the context:** `EffectContext.anchor_side/row/col`
(`effect_context.gd:30-32`, set only by ground dispatch, read only by the `at_location`
targeting kind) and `manual_row/col` (`:23-24`). These are the partial, honest start that
this initiative finishes.

**Precedent worth knowing:** `StatMutation.target` is `Object` and `Resolver` dispatches on
target species — the codebase already carries untyped things and branches on what they turn
out to be. This is the pattern §4.3 deliberately improves on (one façade instead of every
call site casting).

## 4. The design

### 4.1 The location value
One bundled, immutable value: **side, row, column**. Side is *which half of the board*
(spatial addressing), never allegiance. Minted only by the manager — from a dockable, from a
player's pick, from a geometry result. Nothing assembles one out of loose integers.

Validity ("is this a real cell") is answered here, once, replacing the hand-rolled guards
listed in §3.

### 4.2 The manager
Owns the mapping in both directions, per layer:
- *where is this dockable* → location, or nothing (a relic has no location; that stops being
  a case papered over and becomes an honest absence).
- *what is docked at this location, on this layer* → dockable, or nothing.

Plus dock / undock / move, with 2.5's assert on collision.

**It lives inside the combat world, not as a global.** Simulations copy the whole world to
try out plans; a globally reachable manager would silently share placement between a
simulation and the real board. It is copied with the world, and the existing reference remap
(`CombatWorld.copy`, `StatusInstance.copied`) extends to it.

**Dockables hold no back-reference to the manager** (build decision; user delegated internal
engineering). A copied unit holding a reference to the *original* world's manager would
report positions from the wrong board — silently, and only inside simulations, which is the
worst place for a bug to hide. Callers reach the manager through the world they are already
holding.

**Iteration order is fixed.** Simulations re-run and must reproduce results exactly.

### 4.3 The façade — coordinates ↔ game objects
The one thing that speaks both languages. The manager hands back something it only knows as
"a docked thing"; the façade knows the piece layer yields units and the ground layer yields
slots, and hands back the real object. Type knowledge lives here and nowhere else; callers
never cast. A third layer would only teach the façade.

### 4.4 Geometry — coordinates in, coordinates out
Pure functions, no knowledge that any *thing* exists: distance between two locations, the
cells around one, the row or column through one, the cells ordered by distance from one.

**No flood-fill / painting algorithm.** An expanding search is only required when nearness
depends on *reachability* — when something can stand in the way, so distance must be walked
rather than computed. The board has no obstruction (§7). Distance is a formula, and
sort-by-distance gives the same answer for a fraction of the complexity. At twelve cells per
side, any performance argument for something cleverer is imaginary; choose on clarity.

**Predicates never enter geometry.** Geometry yields an ordered list of locations; the caller
walks it, asks the façade what is there, and applies its own conditions. Geometry never sees
a condition; the caller never does arithmetic.

**Ship the minimum:** distance, and cells-ordered-by-distance. Rows, columns, radial, cone
and diagonal are the vocabulary this is *shaped for*, not what it ships with.

### 4.5 What `holder` keeps
`holder` is a bundle of three answers. Position lifts out; the other two stay, and still need
an object:
- **Whose side** — the allegiance anchor. Already lifted out separately, for relics.
- **Identity** — self-targeting ("heal yourself"), the trigger gate ("react only to my own
  actions"), and provenance: who gets credit for a kill (and so the gold and experience),
  whether a crit rolls, and whether an interceptor like Blind applies.

### 4.6 The effect-side socket (increment four)
An effect names two things it understands — a **location policy** (where it resolves *from*:
the holder's location, the target's, the last one hit, a picked square) and a **geometry
procedure** — and gets back game objects. It then runs its conditions and mutations exactly
as it does today. At no point does an effect see a coordinate.

This subsumes, as authored policy rather than code: ground delivery under a unit, spread's
"the floor beneath me", material delivery to a picked square, and the nearest-target search.

Material delivery becomes one readable thing: ask for the contents of the target location on
both layers; merge into the unit if there is one, otherwise place on the ground.

## 5. Increments (each leaves the game playable)

1. **Placement consolidates.** The manager becomes the sole store; the grids fold into it.
   Existing position reads keep working by forwarding, so nothing else changes yet.
   **This one cannot be partial** — a half-conversion is two authorities, which is the state
   being left.
2. **Loose coordinates die.** Callers stop handling separate rows and columns and pass
   bundled locations. This is what kills the recombination bug class (§3's conflation defect).
3. **Geometry consumers migrate**, one at a time: attack targeting (distance only — its
   preference ordering is untouched, §2.10), effect targeting, spread's adjacency, the spawn
   search. Each is independently checkable, and each is where a real behaviour change could
   sneak in.
4. **The effect location-policy socket** (§4.6). The new capability, and hopping's prerequisite.

## 6. Verification — proving nothing changed

A refactor that is supposed to change nothing needs to *demonstrate* it, and this touches
attack targeting, the most playtested behaviour in the game.

- **Replay comparison, the sharp instrument:** combat is deterministic under the seeded
  `CombatRng`, and the enemy engine already replays whole fights on world copies. Capture a
  set of fight outcomes before the change and re-run them after; a behaviour-preserving
  refactor reproduces them exactly.
- **The suite** must stay green throughout — this touches the resolution layer, so the run is
  mandatory (Arbitration Layer house rule).
- Increment 3 is the risk concentration: migrate one consumer per commit, replay after each.

## 7. Scope fences (OUT — do not build, do not stub)

- **Unifying the two mirrored halves into one coordinate space.** The halves face each other
  with mirrored row numbering (units are opposite when rows *sum* to a constant). A single
  space would be tidier, and it is explicitly parked (user) — it changes the manager's
  internals, never its interface, so it stays deferrable.
- **Facing / directional shapes.** A cone needs an orientation as well as an origin. Facing
  is a property of a shape, not of a location; it plugs in above this work (user ruling).
- **Obstruction / line of fire.** Nothing blocks anything today. If it ever does, §4.4's
  conclusion is what gets revisited.
- **The per-piece attack patterns** (rook, bishop, knight, queen) are shapes living in
  another subsystem with their own vocabulary. Not pulled in — but §4.4's vocabulary should
  be designed knowing they exist, or the second shape system gets built while eliminating the
  second location system.
- **Revisiting the attack preference ordering.** §2.10 keeps it bit-identical. Changing it is
  a balance decision, separately, later.
- **Bouncing / chain effects.** Downstream. `CHAIN_DESIGN.md` is a draft, not an agreement.
- **Screen/layout positions** (§2.11).

## 8. Practicalities

- Godot not on PATH: `"/d/Godot/Godot_v4.6.3-stable_win64_console.exe" --headless --editor
  --quit --path /d/Godot/CardGame` = parse check (grep `SCRIPT ERROR|Parse Error|ERROR:`).
  ALWAYS pass the absolute `--path`.
- New `class_name` scripts need a headless `--import`/editor pass before the test runner
  sees them.
- Suite: `... --headless --path /d/Godot/CardGame res://tests/_runner.tscn`.
- Warnings are errors in the user's editor: fully typed GDScript, no `:=` inferring Variant,
  typed `for` loops.
- Edit files with the harness Edit/Write tools only (PowerShell corrupts encoding).
- Commit discipline: planned phases get one commit per increment, when green and approved.

---

## 9. As built (2026-08-08, branch `location-manager` — not playtested)

**The files.** `scripts/board/board_location.gd` (§4.1 — interned, immutable, side+row+col),
`location_manager.gd` (§4.2), `board_geometry.gd` (§4.4), `board_facade.gd` (§4.3).
`CombatWorld.locations` holds the manager; the grids and the slot dictionary are gone, and
`player_grid`/`enemy_grid` survive as derived readings for the callers that still speak that
shape. `EffectContext`'s boards derive from the world rather than snapshotting it, so a
dispatch still sees a unit that died two effects ago as gone.

**Suites.** `test_locations` (the layer's own contract), `test_location_parity` (§6 — the
pre-refactor formulas, frozen, checked over all 576 address pairs), `test_location_socket`
(§4.6). Full suite green throughout.

**Verification actually performed** (§6): the exhaustive formula parity above; a replay of
the CPU planner against the pre-refactor tree on the same fixture and seed, which planned
identical actions in identical order at identical cost (159ms vs 157ms); the full suite; the
spawn and combat smokes; and a render of the combat screen with a unit selected, confirming
the declared preview world, the target crosshair and the menace derivation all still read.

### 9.1 Two places the as-built differs from the plan

**Targeting moved in increment 1, not 3.** §5 has the geometry consumers migrating after
placement consolidates, but attack targeting could not wait: the board's move preview works
by asking "who would this unit hit from over there", and the old answer was to write the
pivot's coordinates onto the pivot, run the query, and put them back. With no coordinates on
a unit, a hypothetical is a second PLACEMENT — so strategies take a `LocationManager` rather
than a grid, and the mutate-restore trick is gone. The preference ordering itself is
bit-identical, and §6's parity suite is what says so.

**The socket's ground layer sits BESIDE the `status_layer: "ground"` key, not instead of
it.** §4.6 says the socket subsumes ground delivery as authored policy. It can: `{"kind":
"at_location", "layer": "ground"}` resolves to slots and delivers through the ordinary
targeting path. Every ground status authored so far is still spelled with the layer key, and
that mechanism is untouched — a policy that says "author it the new way from here" does not
license deleting the one the data uses.

### 9.2 Open, and deliberately not built

- **Materials never land ON the ground.** §4.6 describes material delivery as "merge into the
  unit if there is one, otherwise place on the ground". An empty pick still SPAWNS the
  material as a unit, which is what it has always done; ground-borne materials are not a
  mechanic that exists, and inventing one is a design decision, not a refactor.
- **The enemy engine's `BoardState` keeps its own row/col.** It is an explicit frozen
  projection for scoring, not a placement store — it is captured FROM the manager and never
  written back. §3's survey did not name it, so it was left alone.
- **`EnemyEngine.decide_actions` still takes grid arrays.** Its emitted ACTIONS carry
  addresses; its entry signature is the last grid-shaped seam, and `CombatWorld.adopt_grid`
  is the honest bridge marked for removal with it.
