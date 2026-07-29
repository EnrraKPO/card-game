# Combat Encounters — Design Record

**For:** future sessions, as context. **Started:** 2026-07-29 (ongoing).

---

## ⚡ SESSION BRIEF — read this first, then operate

*Written 2026-07-29 at the close of the design session, for the session that starts development.*

**Mission:** build the enemy engine designed below. The design phase is done; 18 agreed decisions
(Part 2) + the decision mechanism (17/17a/17b) + a build plan (Part 5). Do not re-litigate settled
decisions; do read their *reasons*, because the reasons are the authority when a decision turns out
to be stated too strongly.

**Where to start:** the first observable deliverable in Part 5 — *the enemy screens its Captain*.
Five parts, one implementation each. The board state (plain copyable data, no scene nodes) is the
one piece that must not be faked. Hold the objective extension test. Immediately after: the damage
spell + rules extraction — do not let them drift.

**Operating posture (user's explicit instruction):**
- **Assume every step will require reframing, and that we will refactor often.** Aim for a good
  solution, but treat each implementation as a draft that hardens through iteration — not a final
  form to defend. When reality contradicts the design doc, that's a finding to bring to the user,
  not a deviation to hide or a doc to silently rewrite.
- **Iterate WITH the user.** The strongest ideas in this design came from the user correcting
  over-hardened framings. Bring findings and friction to them early and often; short loops.
- **Difficulty is a finding, not a veto** — surface it, don't silently descope
  (memory: feedback_descoping_by_footnote, feedback_prefer_general_systems).

**Known design work still embedded in the first deliverable:**
1. The **exposure function does not exist yet** — "attack likelihood per slot from geometry +
   occupancy" is an input spec, not a function. Inventing it IS part of the deliverable; v1 will be
   wrong in a way the Combat Gym reveals. Expected.
2. Expect the single criterion to produce degenerate stacking in the Captain's lane — that is the
   deliverable doing its job (says so in Part 5).
3. **Procedural goals ("advance the rite", "spend all mana") do not naturally fit board-state
   scoring** — they're properties of the turn, not the board. The scoring story will likely need an
   amendment there. Flagged, unresolved, fine.

**Standing traps for this specific work (all hit during the design session):**
- Existing `EnemyAI`/encounter code is **placeholder** — extract seams from it, never build on it.
- No bespoke inline solutions — small in scope, complete in structure, checkable extension test.
- Don't invent vocabulary or record unagreed ideas as settled (doc rules, top of this file).
- Questions to the user: emphasis, not exclusive forks.
- Testing: pure functions headless (`tests/`), visuals via the render harness; warning-clean
  GDScript (no `:=` inferring Variant); run `tests/_runner.tscn` after touching resolution.

**State at handoff:** everything uncommitted (this doc + 5 memory notes). Commit discipline:
per-phase commits once the user approves, not per-iteration churn.

---

We are designing the combat-encounter system **from scratch. Everything is on the table.**

> ## ⚠ Rules for maintaining this document
> 1. **Only record what the user actually agreed to.** Do not write your own proposals in as
>    settled. A section that isn't marked as agreed is not a decision.
> 2. **Do not invent vocabulary.** If a term wasn't agreed, spell the idea out in plain words.
>    Invented labels ("the Arc", "the anatomy of a role") made earlier drafts opaque and let
>    unagreed ideas masquerade as design.
> 3. **The current `EnemyAI` and encounter templates are deliberate placeholder.** Part 1 is an
>    inventory of what the engine *can do*, not a set of constraints and not a foundation.
>    "This already exists so it's cheap" must not drive a design choice.
> 4. **Questions to the user must be about emphasis, not exclusive forks.** An answer says what
>    leads; it never deletes the other option.

---

## The goal (from the user's brief)

Encounters are a very important part of the game. They must:
- present a challenge to the player;
- be the game's proposal of *what to deal with and how*;
- **teach game mechanics**.

The target is a strong enemy engine that allows authoring interesting, nuanced, complex combat
events — with a CPU that makes informed decisions, has a strategy, and can use a variety of
different resources.

---

## Part 1 — Engine capability inventory (facts, NOT constraints)

Research done 2026-07-29 against the current codebase. Everything here describes the **placeholder**
implementation. Recorded so we know what the engine can physically do — not to be built upon.

### 1.1 What an encounter can vary today
Templates (`data/encounters/*.json` → `scripts/encounter_template_data.gd:99-122`) have 16 fields,
but only five change what the fight *is*: `enemy_pool` + weights, `enemy_king`, `power_bonus`,
`pick_count`, and eligibility/reward bands.

`ai` and `reward_pool` are `"default"` on **all 70 templates** — free-text boxes in the Tool because
there is nothing to enumerate. `tribes` is a Tool-only label the engine never reads.

> Encounter distinctiveness today is 100% deck contents + Captain choice.

### 1.2 Difficulty today
`power` (`encounter_template_data.gd:48-53`) is derived purely from run depth (`1.0·29·t^1.7`;
0 → ~8.9 → 29.0). It reaches four things only: deck size (+0.5/point, **+15 cards** at the final
boss), a cost-bias toward expensive cards, and `attack`/`health`/`shield` × `(1 + 0.05·power)` on
deck cards and the Captain. It does not touch abilities, effects, `strikes`, economy, or behaviour.

### 1.3 The current AI
`decide_actions(hand, board, mana) -> Array` (`enemy_ai.gd:31`) is its entire world — it cannot see
the turn number, its own deck/discard, its past decisions, or the player's hand. Four fixed
sub-planners in fixed order (spells → placements → advance-one-unit → abilities), each a local
greedy pick. The instance is long-lived (`encounter_template_data.gd:160`, reused at
`combat.gd:415-419`) so it *could* hold state; nothing does.

Its one positioning behaviour is unconditional: `_plan_advance` (`:107-119`) pulls the furthest-back
unit into the frontmost empty slot **every turn**, by design; `_plan_placements` always fills the
frontmost empty slot.

### 1.4 Round lifecycle
Entry (`combat.gd:105`) → `_begin_round` (`:382`): turn++ → player mana `(turn==1 ? mana.initial :
turn) + mana.per_turn` → **enemy mana = `_turn`, hardcoded** (`:391-392`, deliberately bypasses
`GameData.value` so player upgrades never buff the CPU) → player draw `draw.per_turn` → **enemy draw
= 1, hardcoded** → entire CPU turn (`:399`) → player phase → `_on_done_pressed` (`:573`):
`turn_start` event → attack loop → `turn_end` → shield regen → next round.

Attack loop (`:611`): all units sorted by speed ↓, owner ↑, column depth ↓, row ↓; each attacker
gets `strikes` attempts, **target re-acquired every strike** (`:654`).

### 1.5 Event vocabulary
`triggers/trigger_resolver.gd:40-41`:
```
SIMPLE: play, death, activate, turn_start, turn_end, permanent
DUAL:   attack, struck, kill, dodge, crit
```
`turn_start`/`turn_end` bracket only the **resolution phase**. Mana grant, draw and the whole CPU
turn happen outside any event window. There is no `round_start`, `combat_start`, `cast`, or `move`.

### 1.6 Win condition
`any_king_dead()` (`combat_board.gd:293-302`) — an `is_king` unit missing on either side. No turn
limit, no deck-out, no alternate condition. Two-phase bosses work by accident of this: the check
scans the *live board*, so a dying king whose `on_death` spawns another `is_king` keeps the fight
alive. Four bosses use it.

### 1.7 Hardcoded values that are currently not authorable
Enemy mana curve; enemy draw/round; enemy opening hand (4); **starting board state (no code path at
all** — always two kings in corners); who acts first (CPU always fully resolves first); end-of-round
shield regen and exhaustion reset; board size (`COLS=4, ROWS=3` consts).

### 1.8 Presentation facts
- **Combat is deterministic and computable in advance.** Act order is a fixed comparator; targeting
  is a pure function (`targeting_strategy.gd:6`), and **preview and resolution call the identical
  function** — a projection provably cannot drift from what happens.
- The existing threat preview is already **side-neutral** (`combat_board.gd:587-588`): clicking an
  enemy already shows which player unit it will hit. Constraint: it's a single pivot, torn down with
  the gesture.
- `card_ui.gd:834-950` presentation tags: localized, parameterized, auto-shedding; adding one is a
  table row plus a line.
- Status pips already display a per-round countdown with a tooltip.
- **Does not exist anywhere** (verified by repo-wide grep): any telegraph/intent/windup/charge
  concept; **an act-order/initiative display**; a combat log; any first-time-teaching facility.

### 1.9 Tribes
The 11-tribe program added exactly two engine mechanics: the `spawn` payload and the `strikes` stat.
There is no tribe-level runtime entity. Goblins, undead, trolls and golems have zero mechanical
identity. `ENEMY_SETS_HANDOFF.md` lists per-tribe AI, enemy spells, taunt/guard and timed transforms
as never-started.

---

## Part 2 — Decisions (agreed with the user)

Each records the question asked and the answer given.

### 1. Interest comes from the situation posed, not from the opponent's play
*Asked: where should an encounter's interest come from?*

An encounter is defined by **what problem it sets**, rather than by how well the CPU plays.
Reasoning: combat is deterministic and previewable, so the natural tension is "can I solve this
position" rather than "can I outguess my opponent"; and a distinct, readable situation can teach,
whereas a stronger opponent teaches nothing.

Does **not** mean the CPU should be weak or passive — see decision 3.

### 2. The CPU is an actor playing an authored role
*Asked: what is the CPU, conceptually — an opponent trying to win, an actor playing a role, or a machine?*

The CPU has an **authored agenda** and pursues it competently but not optimally. Strategy is a
property of the **encounter**, not of the AI.

Reasoning: teaching requires commitment (an optimiser abandons a lesson the moment it isn't the best
move); telegraphing requires commitment (you can only announce an intention you'll follow through
on); and authoring requires commitment (if behaviour is derived from the board, the author has no
handle on it).

Known risk, unresolved: a committed agenda the player learns to farm.

### 3. A general competence layer sits underneath, and authored decisions win
*Asked: when the player does something the authored role didn't anticipate, what happens?*

A general tactical layer handles local decisions sensibly, so the author **never has to** enumerate
the player's options.

**Corrected by the user:** this does **not** forbid authored decisions. Authoring specific behaviour
stays fully available and takes precedence; the general layer catches what the author didn't speak
to. It is a fallback, not an override.

### 4. The enemy has a roster and a budget, not a deck and a hand
*Asked: where do the enemy's units come from?*

No enemy deck, hand, shuffle or draw step. The encounter declares a **roster** of units it may field
and receives a **budget** each round; the CPU chooses what to deploy.

Reasoning: the deck/hand mirror assumes the CPU is another player, which decision 2 rejects — and
randomised draws fight commitment to a role (a cultist that draws no ritualists can't perform its
ritual, and every telegraph becomes conditional on a shuffle).

Consequences: fights become repeatable, so difficulty is tunable rather than variance-dominated; and
with no hidden deck, the enemy's whole repertoire *can* be shown to the player.

**The budget is mana** (decision 16). Open: how it scales.

### 5. Defeating the Captain is the primary objective; encounters may ADD objectives
*Asked: what creates pressure — can an encounter define its own win/loss conditions?*

**Corrected by the user after an initial mis-recording.** Defeating the enemy Captain is the primary
objective in the overwhelming majority of fights, and remains the game's core promise. Encounters
**may add** further conditions on top (a rite that costs you the fight if it completes, an ally to
keep alive, a bonus objective opening a shortcut). These are additive; they do not replace the
Captain fight. Fights with no Captain objective at all would be a rare deliberate variant.

Motivation: nothing currently forces the player to act — no clock, no turn limit, uncapped mana ramp
— so "stall and build up" is universally correct and every fight is secretly the same problem.

### 6. Teaching is emergent from legibility; we are not building a teaching system
*Asked: what does "encounters teach mechanics" mean as a system?*

No curriculum, no mandated first exposure, no tutorial layer. If fights are readable, the enemy
commits to its role, and fights are repeatable, players learn by playing.

**What this is actually rejecting:** tutorial pop-ups, walls of rules text, explaining instead of
showing. The game should be **readable through play**.

> **⚠ CORRECTED 2026-07-29.** This is about the *systems* being comprehensible — **not** about every
> *beat* being pre-announced. It does not mean nothing may surprise the player, and it does not
> require every mechanic to be telegraphed before it happens. A boss doing something you didn't see
> coming is legitimate and often desirable.

Accepted risk: first exposure is uncontrolled — a player may first meet a mechanic in a fight that
kills them.

### 7. Show the state the player reasons with; don't compute outcomes for them
*Asked: how much should the game compute for the player, given combat is deterministic?*

The player should be able to see the state they need in order to reason: each unit's current target,
the act order, stats, statuses, any active clocks. The game does **not** say "this unit will die" —
the arithmetic is the player's job, because doing it for them means optimising against an oracle
instead of learning the system.

Consequence: an act-order/initiative display is required, and currently does not exist anywhere.

> **⚠ CORRECTED 2026-07-29.** First recorded as an absolute — *"every input is always shown, nothing
> is ever hidden, no beat is ever unannounced."* **That is not what was asked for.** This decision is
> about **not doing the player's thinking for them**. It is *not* a rule that all information must
> always be surfaced, and it does **not** forbid surprises, concealed effects, or unannounced
> dramatic beats. See decision 6.

### 8. An authored role steers the CPU with an ordered list of priorities
*Asked: how does an authored role steer the competence layer?*

The encounter declares an **ordered list of goals**; the CPU satisfies them in order, playing
competently within each.

Reasoning: it is explainable by construction — every decision has a sentence — and the same
priorities can be shown to the player as what the enemy is trying to do. Continuous weights would be
more expressive but produce no explanation, which conflicts with decisions 1, 6 and 7.

Accepted limitation: strict ordering cannot say "these two matter about equally."

### 9. By default, the Captain performs the encounter's special capabilities
*Asked: when an encounter needs something that isn't a normal unit action, where does it live by default?*

The Captain enacts it — the Hierophant performs its own rite. Keeps identity concentrated in one
legible figure, and means pressuring the Captain always pressures its agenda.

Still available when a fight wants it: a dedicated killable object (an altar), or a sourceless effect
for environmental pressure — used sparingly, since a sourceless threat can only be raced, not fought.

### 10. Difficulty: a scalar is fine, because authoring accounts for it
*Asked: how should difficulty be set? — question was rejected as a false fork; the user then stated the answer.*

We can have a scalar. Content is authored so the scalar doesn't fight us: **every authored quantity
declares how it scales**, including objective thresholds and timings, not just stats. If a fight is
"kill it before it reaches 50," the author writes how the 50 scales, or gates the encounter so it
never appears where that threshold is nonsense.

No invariant system, no scaling caps, no guardrails — those solve a problem that only exists if
scaling and authoring are imagined as adversarial. And the player scales too: what matters is the
player/enemy relationship, not absolute breakpoints. If the goal is to kill a thing, a stronger deck
kills it.

### 11. An encounter's description is live state, and anything can change it mid-fight
*Raised by the user: "if we have a system that works, can't we just alter the system mid flight and bend it at will?"*

Yes. The encounter's description — roster, budget, priorities, objectives — is **runtime state, not
setup constants**. Anything that can act may write to it while the fight is running.

Therefore **there is no phase system, no timer system, no escalation system, and no "boss form"
system.** Those are all the same thing:
- a boss transforming = replace the Captain, swap in different priorities;
- a countdown = an objective with a threshold that ticks;
- the fight getting harder = the budget goes up.

The only requirement this adds is already covered by decision 7: if the description changes, the
display follows it, so the player sees it.

> Recorded because an earlier draft treated "how a fight changes over time" as a major undesigned
> feature and invented a word for it. It is a consequence of mutable state, not a design problem.

### 12. The enemy has exactly four actions; all expressiveness lives inside spells and abilities
*Stated by the user.*

The enemy can do **four things**:
1. **Place** a unit
2. **Move** a unit
3. **Play a spell**
4. **Play an ability** of one of its units

This list is **closed** and never needs extending — because **anything can be a spell.** "The Captain
transforms into a 999 HP eldrazi" is a spell. Sacrificing an ally is a spell. Raising its own budget
is a spell. Rewriting its own priorities is a spell.

**Consequences:**
- No boss-form system, no transformation feature, no sacrifice action, no "encounter-level
  capability" mechanism. Decision 11's mid-fight mutation needs no special support: it is a spell.
- The engine's action vocabulary is small and fixed; **content is where the variety lives.**
- "Hold / bank the budget" is not a fifth action — it is declining to act. Whether the CPU may
  choose that is still open.

**The hard problem this exposes.** Because a spell can do anything, the system **cannot infer what a
spell is for** by inspecting its effects. It can see that a spell sets health to 999; it cannot know
that this is a panic button to be used only when near death, or that the rite spell is the
encounter's whole point.

> Therefore the author must **declare what each spell and ability is for** — not *what it does*
> (the effect already says that), but **when it is the right thing to do, and what it accomplishes.**
> That declaration is what an ordered priority list selects over. This is the "author procedures in a
> way the system understands" problem, and it is the next thing to design.

### Also settled by 12
The Part 4 item "whether the CPU's action list stays fixed or is derived from cards" is answered:
**fixed set of four, open-ended content.**

### 13. Two mechanisms shrink the decision problem: legality gating and concealed containers
*Proposed by the user.*

**a. Author spells so they are only legal under certain conditions.** The eldrazi spell is playable
only when the Captain is near death. The system then never has to understand that it's a panic
button — it plays what is legal, and the authored conditions do the work.

> This largely dissolves the "declare what a spell is for" problem from decision 12: **"when is this
> the right play" collapses into "when is this legal,"** which is declarative and is already how
> conditions work for the player's cards.

**b. Concealed effect containers, working like the player's relics.** An effect container owned by
the encounter rather than by a card — *"intercept the Captain's death; instead spawn a 999 HP eldrazi
Captain."* This is **not an action the CPU chooses**; it fires on its own. Phase changes, last
stands and escalation need no AI involvement at all.

Concealed effects are explicitly allowed, per the correction to decisions 6 and 7 — surprise is
legitimate, and repeatable fights mean the player learns them.

**What still needs the priority list**, after both of these:
- choosing among several options when more than one is legal at once (gating keeps this set small);
- **where and at whom** — which slot to place into, which target to aim at. Legality can constrain
  this but rarely determines it, and it is most of what makes positioning read as intelligent or
  stupid.

### 14. Placement and support behaviour are properties of the UNITS, not AI decisions
*Stated by the user: "most of the content is outside of the scope of an AI decision. The point is that the encounter needs to be interesting, not that the AI needs to be smart."*

The aim is an encounter that is interesting, not an AI that is clever. Tanks up front, damage dealers
behind, support protected — because that composition makes a good fight, not because something
worked it out.

> **⚠ REFINED by the user.** An earlier draft of this said *"the AI does not reason any of this out —
> it just does it."* **That is too strong.** The AI **does read the board and make reasonably
> intelligent moves.** A tank doesn't just go "in the front row" — it goes into the slot where it
> actually **covers the unit it is protecting**. Not a sophisticated system; just sensible decisions.

**The loop:** enumerate the legal moves → check them against the ordered priorities → take the ones
that serve the highest-ranked goal.

**This makes decision 8's priorities concrete.** They are statements about **units and the states you
want them in**, ranked against each other — e.g.:

```
1. defend the damage dealers
2. don't let a damage dealer die
3. don't let a tank die
```

The *actions* fall out of the ranking rather than being authored: that list is what produces "put the
tank in this slot rather than that one" or "heal this unit rather than that one," with neither
written as an instruction.

**What this requires of the engine:** enough understanding of board geometry to know what "covers"
means — which lane shields which, what stands in front of what. On a 3×4 grid, small.

**Where "interesting" comes from:** the composition of the roster. Two tanks, a support that buffs
them, and a fragile high-damage unit behind is already an interesting problem for the player
regardless of how thoughtlessly it is deployed.

**Relationship to decision 8:** the priority list is the AI's evaluation criteria for *everything* —
routine unit handling included — not just the Captain's special procedures. Authored moments are the
same mechanism with a procedure ranked to the top.

Detail still to settle: what happens when a unit's preferred position is unavailable (front line
full, ideal slot occupied) — though under this framing that may resolve itself, since the AI is
choosing the best available move against the priorities rather than following a fixed rule.

### 15. Tanking is emergent. Formation falls out of a protect-ranking plus the targeting projection
*Stated by the user.*

The engine can already determine the entire targeting situation for a unit in a given slot — so it
can tell **what would happen if a unit were placed at any slot**.

The AI therefore:
1. places the unit it most wants to protect in the slot where it is **least likely to take damage**;
2. places a unit it cares *less* about protecting so as to reduce the chance of the first unit being
   damaged **further** — accepting that the second unit takes hits instead, because protecting the
   first is ranked higher.

> **Step 2 is tanking. "Tank" is not a role and needs no tag** — it is a *description of what
> happened* to a unit ranked low on the protect list whose body absorbed attacks meant for something
> ranked higher.

**What this collapses:**
- **How do you refer to units in a priority?** By their place in the ranking — the ranking *is* the
  reference. No battlefield-role vocabulary (tank / DPS / support) is needed for positioning.
- **What state do you ask for?** *Not taking damage.* That single axis generates front lines,
  screens, protected backlines and sacrificial blockers without any of them being named.
- **Why the AI can stay simple:** it is not doing tactics. It scores candidate placements against a
  projection it already computes — try the placements, see where the damage lands, prefer the
  arrangement that puts it on units you care less about.

**Known gap:** a protect-ranking generates *formation* only. It cannot express offensive goals ("kill
their support") or procedural ones ("advance the rite", "spend everything now"). So the priority list
likely holds **more than one kind of goal**, with protection being the kind that generates
positioning. Not yet designed.

### 16. The budget is mana. No banking. "Spend it all" is a priority, not a rule
*Stated by the user.*

- **Mana is the budget** — not a separate resource. Decision 4's "budget" means mana.
- **No banked budget for now.** Unspent mana does not carry over; it is wasted, not saved.
- **"Spend all your mana" sits in the ordered priority list** — not necessarily the highest entry.

**Consequence:** restraint comes for free. If protecting something outranks spending, the AI declines
to dump everything, and no banking mechanism has to exist to produce that behaviour.

This also settles the open question "may the CPU decline to act" — it may, but only because a
higher-ranked priority outweighed spending, never as a saving strategy.

**Further evidence that the priority list is the single steering mechanism:** it now holds at least
protection goals *and* resource goals, so goal kinds are entries in one list rather than separate
systems.

### 17. How the enemy decides: simulate each candidate move, score the resulting board
*Proposed by the user. This is the core mechanism.*

For each decision:
1. **Enumerate candidates** — every legal move of the four kinds, across every valid slot and every
   possible target. An ability is tested against *every* possible target.
2. **Simulate** each candidate on a copy of the board, **including firing all triggered effects**.
3. **Score** the resulting board state against the priority list → a *goal alignment* value. The
   evaluation considers the actual board state and the current targeting situation.
4. **Rank** all candidates.
5. **Pick** the highest — or one at random from the pool within some delta of the best.

> **The key move is evaluating the resulting STATE rather than classifying the ACTION.** This is what
> makes the system content-general: the AI never needs to know what a spell is *for*. It applies it
> and looks at what the world became. Any effect anyone ever authors is handled, including
> interactions nobody anticipated.

**This answers the question decision 8 left open:** priorities run against **board states**. A
priority is a way of scoring a hypothetical board.

**It subsumes decision 15.** Tanking-by-emergence isn't separate positioning logic — it is what falls
out when the scorer prefers boards where the high-priority unit isn't being targeted. Placement needs
no special treatment.

**It largely retires the need for decision 13a's legality gating as a *reasoning* device** — gating
remains useful for authoring intent, but the AI no longer depends on it to avoid nonsense plays.

#### The real constraint: rules must be separable from presentation

Simulation requires a version of the rules that runs **synchronously, mutates a throwaway copy, fires
all triggered effects, and touches nothing on screen.** Current resolution is threaded through
animations, VFX and awaits. **This separation is the structural engineering work in this proposal.**
It pays for itself beyond the AI — a headless rules layer is also what makes fights testable.

On volume: roughly a few hundred candidates per decision, a handful of decisions per turn — low
thousands of simulations. Likely fine if each is cheap. If it isn't, **prune candidates cheaply
before simulating** rather than capping arbitrarily afterwards.

#### Deliberately NOT doing: searching player responses

The user raised escalating to consider all possible player moves. **Recommended against — for design
reasons, not performance.** Modelling the player's replies turns the enemy into an *optimiser*, which
decision 2 rejected. An actor pursuing an agenda asks *"what does the world look like after I do
this"*; an opponent trying to win asks *"what will they do about it."* One ply keeps it characterful.
Deeper search would make it play better and read worse.

#### 17a. Scoring does NOT run combat — it measures the position statically
*Raised by the user: "if the simulation has to run combat, it won't work unless all available plays are made first, otherwise the combat simulation is non-representative."*

Two things were being conflated. Keep them separate:

| | |
|---|---|
| **Simulate the move** | Apply the effect to a board copy, let triggered effects fire, see what the board becomes. **Cheap, necessary**, and what gives content-generality. |
| **Simulate combat** | Run actual resolution to find out who dies. **Don't.** Mid-turn the board is not the board combat will run on — the enemy hasn't finished placing and the player hasn't placed at all — so the measured outcome is an artefact of an incomplete position. It is also the expensive part. |

**Scoring reads the position statically**, from the board plus the targeting projection, with no
resolution:
- who is currently targeting whom;
- how much incoming damage is aimed at a given unit;
- whether that unit survives it (incoming vs. health + shield);
- how much of the enemy's output is aimed at things it wants dead.

> These are measurements of a **position**, not predictions of an **outcome** — so they stay
> representative no matter how many plays remain on either side, and each successive placement
> re-scores a stable quantity instead of chasing a noisy simulated result.

#### 17b. Score slot EXPOSURE, not concrete targeting
*Raised by the user: "we can't just evaluate who attacks me, I have no means to tell that. All we can tell is how likely am I to be attacked at this slot."*

A concrete projection (*"unit X will attack unit Y"*) is **unreliable** — the player can shuffle their
units and re-target at will, so the enemy has no business predicting it.

What the enemy *can* know is a property of **its own board**: **how exposed is this slot** — how
likely something standing here is to be attacked. Computable from geometry and occupancy; independent
of the player's choices.

**The model:**
- On every check, run over the enemy's own units and evaluate **how likely each is to be attacked at
  its current slot**.
- The same computation tells you which slots **cover** which — occupying a forward slot is what
  *reduces* the exposure of the slots behind it, and so informs follow-up placements.
- The most crowded / most forward slots carry the highest likelihood of being attacked.

> The job reduces to: **place valuable units in low-exposure slots and expendable ones in
> high-exposure slots.** Tanking still emerges — a tank is simply what you are willing to put in the
> exposed slot.

**Evaluating the player's existing units is secondary** and not worth the cost at this stage.

#### Geometry-only exposure is DELIBERATE, and targeting policies are where "intelligence" is tuned
*Stated by the user.*

A purely geometric exposure map assumes forward slots are the dangerous ones, so it is **blind to
targeting policies that bypass the front line** — a leaper reaches the back regardless of what stands
in front of it.

**This is intentional and is the initial setting.** We deliberately let leaping units reach valuable
targets, **so the player learns what leaping units are worth.** If the enemy defended against them,
the player's leaper would stop being good and that lesson would never land — and it would force
meta-game strategies early, before the player has a meta to game with.

> Run geometry tests only. That is what **creates the environment for targeting policies to surface**
> as meaningful player tools.

Greater sophistication — factoring in what the player's units actually do — stays available for a
later stage, as a per-encounter dial rather than a fix.

#### "Intelligence" is a family of dials, not one slider
*Observation consolidating three decisions.*

| Dial | Low (default) | High |
|---|---|---|
| **Search depth** | one ply — instinctive | two plies — anticipates the player |
| **Scoring method** | static position measurement (17a) | real combat resolution — genuinely calculating |
| **Exposure model** | geometry only (above) | aware of the player's actual targeting policies |

All three default low and can be raised **per encounter**. Each is a **characterisation tool, not a
difficulty tier** — a wary boss that plays around leapers is a *character*, and it lands harder
precisely because everything before it didn't.

**Accepted inaccuracy.** Static scoring ignores speed order, kill sequencing (a unit that dies before
acting never deals its damage), multi-strike, and value that only appears mid-combat such as
on-attack triggers. It will sometimes misjudge a trade. Acceptable: decision 2 asked for an actor
rather than an optimiser, and decision 1 said the AI needs to place sensibly and read well, not play
strongly.

Running real resolution stays available on the depth dial below, for a boss that should genuinely
calculate.

#### Depth is a dial, not an architecture
*Raised by the user.*

The same machinery handles any depth: evaluating player replies ("what if they move that unit"), and
evaluating the enemy's own follow-ups recursively ("what if I do this **and then** this"). **Nothing
about the model changes with depth — only how far it runs.**

So the recommendation above (stay at one ply) is a **policy choice, revisitable at any time, not an
architectural commitment.** The mechanism stays available whether or not we use it.

**Better still, depth can be per-encounter — as characterisation.** A mindless swarm evaluates one
ply and reads as instinctive; a scheming boss searches two and genuinely anticipates the player.
Under decision 2, **search depth becomes part of who the Captain is**, which turns the "deeper search
reads as calculating" concern into a tool rather than a drawback.

*Practical note:* with a few hundred candidates per decision, two plies is already tens of thousands
of simulations and three is impractical without real pruning. Architecturally unbounded; practically
one or two plies plus cheap pruning.

#### Still to settle
- **How multiple priorities combine — DIRECTION SET by the user (2026-07-29):** strict lexicographic
  ("fall through only on ties") is **ruled out**. The user's governing example: "Captain doesn't die"
  ranked highest, "high-value unit doesn't die" nearly as high — a much-lower-health HVU **must be
  able to outweigh** marginal Captain protection. So combination is **soft**: priority order sets
  weights, and each criterion carries **urgency** (likelihood of the bad outcome — e.g. incoming
  potential vs current health), so weight × urgency lets a critical lower priority beat a comfortable
  higher one. This amends decision 8's "satisfies them in order" phrasing; the ordering survives as
  the source of weights, not as a hard gate. Exact function: to be hardened in deliverable 2.
- **The random pick trades against repeatability** (decision 4). A small amount is probably good for
  feel, but it is a real trade, not free.
- Whether a turn's actions are chosen **greedily one at a time** (cheap, but misses two-card combos
  such as buff-then-place) or as short sequences.

### 18. Role tags as an authoring layer: tag content, get working behaviour for free
*Proposed by the user — the answer to "a quick, easy, efficient way to author behaviours."*

Units are tagged with a role — **tank, support, damage dealer, high-value target** — and spells are
tagged likewise, so content **routes naturally into the system**. A **stock priority script** then
"just works" for as long as units are tagged appropriately. The priority script can be customised
when an encounter wants a real personality; most encounters won't need to.

**The layering, which must not be lost:**

```
tags  →  stock priority script  →  ranked priorities  →  simulate & score states  →  action
```

- Tags **do not drive behaviour directly.** They configure the priority list; the priority list is
  what the simulation scores against.
- **The engine stays tag-agnostic.** It scores board states and knows nothing about the word "tank".
- **Decision 15 is unaffected** — tanking still *emerges*. The tag merely saves writing out "this
  unit sits low on the protect list" by hand.

**Payoff:** most encounters need **no behaviour authoring at all**. Tag the units and a default
priority script produces sensible play. Custom priorities are for signature encounters.

**Guard rail:** tags must stay a *convenience*, never load-bearing for correctness. If the AI ever
*requires* a spell to be tagged "heal" in order to use it sensibly, decision 17's content-generality
is lost — an untagged or oddly-tagged effect must still be handled correctly, just perhaps less
cheaply. Tags are legitimate as **pruning hints**; they must not be required knowledge.

Watch that the tag vocabulary stays small; these tend to grow into a hidden ontology that ends up
competing with the priority list as the source of truth.

---

## Part 3 — Corrections the user has issued (read these)

1. **The existing enemy AI and encounters are placeholder.** Don't account for them; don't let
   "the mechanism already exists" drive design.
2. **Don't frame questions as exclusive forks.** Tiers, procedural scaling and role sophistication
   don't exclude each other; neither did custom objectives and the Captain fight.
3. **The Captain is central, not a minor thing.** An earlier draft quietly demoted it by treating
   "kill the Captain" as just one option among many.
4. **Don't invent things that haven't been agreed**, and don't stack invented labels — it made the
   writing incomprehensible.
5. **Go slow. One question at a time.** Consider and evaluate; don't rush to schemas or formats.

---

## Part 5 — Build plan (agile: small but scalable)

The core piece is **simulate a play, evaluate the outcome**. Build the smallest version that proves
the whole loop, then widen along three independent axes.

### Step 0 — Extract the rules from the presentation

**Do not write a simulator.** Pull resolution into a pure layer that runs synchronously, mutates a
plain board state, fires triggered effects, and touches nothing on screen — then make the **live game
its first customer and the AI its second**.

> Two implementations *will* drift, and when they do the AI decides using rules the game doesn't
> have. That class of bug is close to undebuggable. One rules layer, two callers.

This is the only structural commitment in the design. It pays for itself beyond the AI: a headless
rules layer is what makes fights testable.

### Step 1 — The vertical slice: two action kinds, one criterion

> **The move simulation is still required.** 17a/17b removed *combat* simulation, **not** move
> simulation. Applying the candidate and letting triggers fire is what makes the system
> content-general — it is the only way to know what an arbitrary authored effect did, and the whole
> reason the AI never needs to be told what a spell is *for*. Trivial for placement; **critical for
> effects.**

- a **copyable board state** with no scene nodes;
- **apply one candidate** synchronously, with triggered effects firing;
- **enumerate placements — plus one simple spell** (direct damage is enough), tested against every
  target;
- **score statically** (per 17a/17b — no combat run, no concrete targeting): **the Captain's slot
  exposure**, reduced by occupying the slots that cover it;
- take the best; **execute through the existing presentational path**.

**Why include a spell:** placement alone would prove the scoring loop while barely exercising the
rules extraction — the risky, structural part. That is backwards for a first slice: it builds
confidence in the cheap half and leaves the expensive half unvalidated. One damage spell forces the
effect path end to end from day one. A spell that kills a player unit also *changes the exposure
map*, so it exercises the scoring side properly too.

**Why that criterion:** most obvious criteria are degenerate alone — *"minimise damage to my units"*
is best satisfied by placing nothing, and *"maximise damage dealt"* ignores position. Protecting the
Captain is non-degenerate (doing nothing doesn't help, so it motivates action) and it directly
produces screening. So the **first slice already demonstrates decision 15's emergent tanking**, with
one criterion, one action kind, no tags and no priority list. It is also the enemy's most natural top
priority given decision 5.

### The first observable deliverable — small in scope, COMPLETE IN STRUCTURE

**Observable result:** in the Combat Gym, the enemy stops filling slots mechanically front-to-back
and places bodies where they **screen its Captain**. First time it looks like it means something.

> **⚠ The trap to avoid.** Placement needs no rules extraction, so it is tempting to compute exposure
> inline over a copied occupancy grid and get a result fast. **That is a bespoke heuristic bolted
> onto the old AI, not the first slice of the real system.** The deliverable stays small in *scope*
> and complete in *structure*: every part of the final pipeline exists, with one implementation each.

| Part | Day one | How it grows |
|---|---|---|
| **Board state** | plain copyable data, **no scene nodes** | never changes — everything depends on it |
| **Candidate enumeration** | one generator: placements | one generator per action kind |
| **Apply candidate** | placement only, **behind the seam effects will use** | route through the real rules layer |
| **Scoring** | a list of criteria, one entry: **protection-weighted exposure** (below) | add entries; edit weights |
| **Selection** | rank, pick best, random tie-break | add the delta pool |

**Cannot be faked or deferred: the board state.** If it is a scene-coupled grid copied inline,
nothing can be built on it and the slice is a dead end. Everything else may start as a single-case
implementation *provided it sits behind the seam it will widen into*.

**The criterion's required form (user-mandated, so the next step is granted by construction):**
the day-one criterion is NOT a bespoke "Captain slot exposure" function. It is the general
**protection-weighted exposure over all own units** — `Σ protect_weight(unit) × exposure(slot)`,
minimized — with day-one weights `Captain = 1, all others = 0`, which *is* "screen the Captain".

> **The immediate next step after the deliverable is rebalancing protection across units** by giving
> other units nonzero weights — a **data change, zero structural change**. This must include the
> Captain itself doing some tanking when the weights say so (fragile high-value unit outweighs a
> big-HP Captain → the best-scoring arrangement puts the Captain forward). Decision 15's logic
> running in both directions. Decision 18's tags later plug in here: tags assign these weights in bulk.

**Objective extension test — hold to this, it is checkable rather than aspirational:**
- adding the damage spell must require **one new candidate generator** + letting apply-candidate call
  the effect system, and must touch **nothing** in scoring or selection;
- adding a second criterion must touch **nothing but the criteria list**;
- **rebalancing unit protection (including Captain-as-tank) must touch nothing but the weights.**

If either forces edits elsewhere, the seam is in the wrong place — fix it then, while it is cheap.

**Expected to learn:** this criterion alone will likely make the enemy stack units in the Captain's
lane, since that is literally what minimises its exposure. If it looks strange, the deliverable is
doing its job — it tells us the criterion needs a counterweight far sooner than a design discussion
would have.

### Deliverable 2 — two criteria, soft combination (user-mandated, the critical de-risk)

Run **"Captain doesn't die"** (highest) and **"high-value unit doesn't die"** (nearly as high) as two
criteria. **Required observable:** a much-lower-health high-value unit outweighs marginal Captain
protection — the enemy visibly protects the dying HVU even at some cost to Captain coverage.

This de-risks the combination model (soft weights + urgency, above) — the most consequential
unresolved piece. It needs one new measurement the first deliverable lacks: **survivability**
(incoming potential vs current health), since "much lower health" is what drives the flip.

Per the extension test, this must touch **nothing but the criteria list** (plus adding the
survivability measurement to the shared measurement vocabulary). If it needs more, the seam is wrong.

**Then immediately:** the damage spell and the rules extraction. Do not let these drift — placement
alone builds confidence in the cheap half while leaving the structural half unvalidated.

### Step 2+ — Widen along three axes, independently

| Axis | Widening |
|---|---|
| **Actions** | move, then ability, then spell |
| **Scoring** | more static measurements; the ordered comparison; the delta pool |
| **Authoring** | tags + stock priority script → custom priority lists → concealed containers |

> **Protect this invariant:** adding an action kind must not touch scoring; adding a criterion must
> not touch simulation; adding tags must not touch either. If a change crosses two axes, the seam is
> in the wrong place.

---

## Part 4 — Not yet designed

- **What a priority looks like as a board-state score.** Decision 17 settles that priorities score
  hypothetical board states; it doesn't settle what they can measure. Protection ("is this unit being
  targeted / likely to die") is understood; offensive ("kill their support") and procedural
  ("advance the rite", "spend your mana") goals still need a form as state measurements.
- **Splitting the rules engine from presentation** — the prerequisite for decision 17.
- **How the enemy's mana scales** across a run (decision 16 settles what the budget *is*, not its curve).
- **How the player sees what the enemy is up to** — what's shown and how much. Note decision 7 was
  corrected: this is not a requirement that everything be ambient.
- **Starting board state** — whether fights can begin with units already placed (no code path today).
- **Whether the enemy can choose who its units attack**, or whether that stays automatic (each
  unit's targeting policy + position) so that positioning is the only way to influence it. Changing
  this would alter the auto-battler premise for both sides.
- **Difficulty tiers and map placement** — how an encounter declares where it belongs.
- **Authoring format** — deliberately deferred until the design is settled.
