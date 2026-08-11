# Effect System Design — the rebuilt foundation

Status: **DESIGN SETTLED 2026-08-10 (user-ratified); rebuild begins with the attack
system.** This document began as the targeting rebuild's anchor and grew, by settled
rulings, into the design of the whole effect layer. It replaces the rulings-log form of
itself: supersessions are resolved into final positions here, and the paths considered
and rejected are preserved in the Decision Record.

Ground truth for the starting state: the demolition is complete (branch
`targeting-cleanup`) — all targeting deleted, combat inert, and the quarantine table in
`tests/_runner.tscn` (180 checks after the content strip, 2026-08-11) is the rebuild's
specification and regression net. Driving that table to zero — resolution rebuilt AND
content re-authored — and deleting it is the exit criterion.

The **effect-cleanse pass** (2026-08-11) executed the combat-only rows of §10's deletion
map ahead of the rebuild: SpellCaster and all three ON_PLAY dispatcher clones, the
Transient kind + `applies_on_use`, the ability spell-costume's combat half
(arming/tap/autocast/token-cast; the informational tray/tooltip views and `usable_by`
survive), the `ON_ACTIVATE`→`act` rename, and the `side` target kind (side payloads
validate as targetless, the dead form refused at load).

The **content strip** (2026-08-11, user ruling): ALL authored effect payloads are
FORGOTTEN, never migrated — 377 blocks stripped from every container in `data/` (cards,
abilities, statuses, relics, charms, upgrades, innates; named effects reduced to
id+description shells). Effects are re-authored natively in the new schema as the rebuild
reaches each container; git history holds the old blocks as reference, and card
descriptions remain as the re-authoring briefs. The §12 Q4 migration question is thereby
DISSOLVED — there is nothing to migrate; the verbatim round-trip fields are deleted and
`to_dict` emits no targeting. Old profile saves cross the divide once on load
(`ProfileData.EFFECT_SCHEMA`): deck overrides and charms are scrubbed and the slot's
in-flight run is discarded. Still standing, deliberately: `effect.gd`'s parse (the
tests' authoring language until each suite converts), the passive fold, ModifierSet,
and `EffectCondition`.

Sibling docs: `TECH_DEBT_BRIEF.md` (the disease catalogue this design answers),
`EFFECT_SYSTEM_DESIGN.md` (the prior generation's intent), `LOCATION_MANAGER_DESIGN.md`
(the model cleanup this one imitates: one authority, downstream problems dissolve).

---

## 1. The shape of the whole

The old system packaged three mechanisms into one `Effect` structure and paid for it with
four trigger "kinds," inert sentinel resolvers, `is_standing()` type-tags, a spell
costume around abilities, and a second dispatcher. The new design splits at the root:

**Four sibling structures**, each with its own rules, none a kind of another:

| Structure | Nature | When | Who | What |
|---|---|---|---|---|
| **TriggeredEffect** | reacts | trigger resolver (event gate) | target resolver | operation payloads |
| **ActivatedEffect** | is invoked | **cost gate** (nothing to listen for) | target resolver | operation payloads |
| **PassiveEffect** | is present | membership predicate (read-time) | — | continuous contributions |
| **InterceptorEffect** | rewrites | pending-mutation gate (in the Resolver) | — | rewrite of the proposal |

**Effect containers** — Unit, Spell card, Relic, Status, Upgrade — are plain holders.
Any container may hold any mix of the four structures; there is no container taxonomy
and never will be. (Corollary: an activated or passive effect usable/live *from hand*
is just a container holding a structure — no new mechanism.)

TriggeredEffect and ActivatedEffect are together the **actions**: they take place at a
given time and finish, and they are the only structures that point (own a target
resolver). PassiveEffect is a presence; InterceptorEffect is a gatekeeper. Targeting
serves the actions exclusively.

## 2. The action anatomy: trigger-anchored, one resolution, N payloads

The authored unit reads as a sentence: *"When [event], if [conditions]: deliver
[payloads] to [the targets]."*

- **The trigger is the anchor** because dispatch is event-driven: an event fires, the
  runtime asks "who reacts?", and that lookup is answered by triggers alone. The
  authored shape is isomorphic to the dispatch flow — no classification or translation
  layer (the layer that rotted into SpellCaster's second dispatcher).
- **One anchor, at most one resolution** — hence at most one gesture. All payloads under
  the anchor land on that one resolution's targets; sharing the outcome's *identity* is
  what makes "deal 3 to a random enemy and stun IT" expressible. Payloads that don't
  share the target are simply another trigger, on the same event if need be. Grouping
  exists solely for shared resolution identity — never for convenience.
  (Empirical basis: a full scan of authored data found 47 same-trigger groups sharing
  one targeting across multiple payloads and ZERO needing two genuine searches under
  one anchor — see Decision Record.)
- **Payloads are small dumb species** — damage, status, spawn, draw — carrying delivery
  rules only. Conditions may attach per payload. Effects may be **targetless**: a
  payload whose recipient is derivable (draw/discard/mana/max_mana land on the holder's
  own side via the allegiance anchor) authors no target at all.
- **Attack is a payload kind, not a ruleset.** The strike mechanics (dodge, interception
  ordering, crit-after-interception) live inside the attack payload's delivery rules,
  the way the status payload owns stacking. Nothing above the payload knows attacks are
  special. Two proofs of decoupling: (A) a unit's act need not be an attack; (B) an
  attack payload can ride any action ("when played, make an attack").
- **Auto-attack is a TriggeredEffect** on the `act` event: the unit's innate action —
  *when I act → attack payload → my policy's targets*. Dependency made explicit: "HOW
  MUCH = my attack stat" is a runtime value; this conscripts amounts-as-evaluable-values
  (TECH_DEBT_BRIEF §5) into this rebuild's chain.

## 3. The targeting layer

A **target resolver** answers exactly one question: *what am I pointing to?* It does not
act, does not know about payloads, and has no lifetime of its own.

- **Per-need resolvers, one shared contract.** Many narrow resolvers — one per real
  need — not few general ones stretched over cases. Generality lives in the contract;
  specificity lives in the resolvers. One authored schema names the resolver and its
  parameters. The auto-attack policies (nearest/leaper/wounded/tank/threat) are resolver
  names like any other; effect `auto: nearest` and attack policy `nearest` can be one
  resolver. The attack-preference ordering evicted from `board_geometry.gd` ("column
  depth dominates, lane offset breaks ties") lives inside this layer.
- **Transparent and pure.** Inputs in, targets out — a pure function over a passed-in
  world. No live-global reads: previews, hypotheticals, and simulations all query
  resolvers against declared/copied worlds.
- **Standing state: the current.** Each live resolver holds its current resolution
  (possibly empty), re-engaging on board changes as soon as it has enough information;
  manual resolvers stay empty until conducted. Reverse queries — "am I being
  targeted?" — consult whichever resolvers are alive right now (a mid-aim spell's
  resolver truthfully registering on its target IS the aim-preview cue). Resolver
  instances and currents are owned by a CombatWorld and copied with it; re-engagement is
  driven from the arbitration layer's single-writer settle points, never mid-cascade
  signals.
- **Owned by the pointing behavior, never the entity.** A unit does not own a resolver —
  its auto-attack (a TriggeredEffect) does; a spell's played-effect does; an ability
  does. Entities carry behaviors; behaviors point. Lifetime is not a resolver concern:
  a resolver lives exactly as long as its owner. Authored data only ever declares (the
  card's `target_policy` string, the effect's `targets` dict); instantiation belongs to
  whoever materializes the behavior into the world.
- **Sole authority, to all extents, including pre-cast.** Every "is this a valid
  target" / "is there any legal play" (the prohibit-non-ops viability rule) is a query
  INTO a resolver. No external component peeks at the decision process — the interaction
  layer must never read targeting declarations to anticipate gestures.
- **The resolver conducts its own manual gesture.** The targeting pass runs before
  payloads land; a manual resolver suspends for its pick and is cancellable (nothing
  lands, no cost paid). The pick-provider is injected: the player's Selection UI in live
  play, the enemy engine for CPU casts, a scripted provider in simulations. Kept
  restriction: at most one distinct manual gesture per cast, validated at load.

### The authored vocabulary the resolvers must serve

Preserved verbatim through the demolition (`effect.gd`'s NEED comment), minus the dead
`side` kind:

- **self / participant** (event origin | destination) — a direct reference, no search
- **auto** (nearest | random, count N) — an automatic pick among condition-passing units
- **all** (+ allegiance conditions) — everyone the conditions admit
- **manual** — the unit the player picks; conditions are the eligibility gate
- **manual_slot** — a picked square (possibly empty), own-side only (the rebuilt
  authority owns this rule; the old code left it in the UI layer)
- **at_location** (from / shape / layer / half / count) — position-first
- plus the auto-attack policies: nearest / leaper / wounded / tank / threat

## 4. Conditions: one grammar, three seats

"Condition" names three different questions, each owned by the role that asks it. One
predicate grammar (`EffectCondition` survives) serves all three; each role evaluates its
own without knowing the others exist. There is **no cluster-level conditions field**.

1. **Firing conditions** — the trigger's: "does this cluster react?", asked once against
   the event. Conditions belong to trigger *implementations* (the Simple/Dual shape,
   endorsed as-is: Simple gates one participant list, Dual gates origin and destination
   independently) — which is what lets a trigger condition care about anything.
2. **Eligibility conditions** — the target resolver's: "is this candidate valid?", part
   of the resolver's authored declaration. Predicates split into candidate-intrinsic
   (kind, attributes, statuses, composition) and anchor-relative (ally/enemy/own-side);
   the anchor is supplied ONCE by the resolver's engagement to every evaluation
   uniformly — no predicate finds its own anchor. (The old owner-−1-vs-real-anchor split
   must be unwritable, not rare.)
3. **Delivery conditions** — each payload's: "does this payload apply to what was
   resolved?" Kind fitness ("I apply to units") is simply a payload's first delivery
   condition. A resolver may return mixed kinds with each payload fitting its own slice
   ("create a Pawn on an empty slot" / "add a Pawn to a unit's composition"); a payload
   not applying is SELECTION, not failure. No connivance between payload and resolver —
   not even statically.

Self-exclusion ("not me") is an IDENTITY comparison, not allegiance — a separate
structural mechanism, parked.

## 5. Allegiance

**Definition:** membership in a combat party (two parties per fight). "Ally"/"enemy" are
not properties of anything — they are *comparisons* between the candidate's party and
the anchor's. Slots derive theirs from the board half they sit in.

**Ownership:** the object itself carries its allegiance, stamped at creation by whatever
creates it — a constructor argument, not a reporting duty. No manager (a manager earns
its existence by managing *change*; a birth fact that nothing invalidates passes the
widget-state-ownership rule carried on the object). Mutation, if ever wanted, is already
provided for: the arbitration Resolver is the single writer of all stats — side-switching
would be an ordinary StatMutation through the existing gate.

**The anchor:** every cluster binds one allegiance anchor at materialization — the
holder's side for board-held effects, the player's side for run-scoped containers
(relics/upgrades), per the standing two-anchor model. It is allegiance only; the spatial
anchor ("nearest to whom") is a separate input.

## 6. The passive system

Passive ("while"/standing) effects are a **field**, not an action: they affect the world
as a whole, and their reach is a read-time membership predicate — never a target
resolver. Search, pick, gesture, and "current targets" are engagement concepts,
incoherent on a hot per-read fold that must also answer out of combat (deck screens,
shop costs). Their payloads are **continuous contributions** only — stat bonuses and
composition grants; never one-shot operations, which need a moment, and the fold has no
moments.

The demolition NEED comments called standing membership "targeting's second verb" —
retracted: it is not a targeting verb. The fold's quarantined checks rebuild on the
condition grammar alone (predicates over unit + holder/owner anchors), a scope
*reduction* for targeting. The passive system also owns its own liveness and fold — the
current inert `While` type-tag interpreted by four other systems dies with the rebuild.
The two-layer read survives as built: Layer 1 composition grants settle as a per-unit
fixed point into a cached snapshot; Layer 2 folds stats under the stratification guard.

## 7. The activated system

An ActivatedEffect is invoked and paid for — its "when" is "when someone pays," so a
cost gate stands where the trigger resolver would. This gives the ability a real runtime
body at last: today's ability has *no runtime object* (static `AbilityData`, a
presentation-only fake card, armed/tap state smeared onto the holder, a source-swap at
cast time) — the ActivatedEffect instance on its holder is that missing container, and
the spell-costume hacks die with it. The healthy part survives: one usability rule
(`usable_by`-style pure query) consulted by every presenter and gate alike.

An activation still **emits** an event through the one pipeline — for bystanders
("whenever an ability is activated…") — but the activated effect does not receive its
own activation as a dispatched event; it is invoked directly. Activation is a mechanism,
not a trigger wearing a cost.

## 8. The interception system

An InterceptorEffect watches **pending StatMutations inside the arbitration Resolver**,
pre-commit — a different stream from events (events ≠ mutations is the arbitration
layer's hard rule; events are post-hoc news, proposals are interceptable). Its verb is
**rewrite-in-chain**: each matching interceptor fires in order on the prior result, with
floors clamped after each step — never consume-INSTEAD (which would break stacked
defensive relics). It has no target resolver: whom it scrutinizes is its own
participant/condition data held against the mutation. It also rewrites never-landing
rate queries (dodge chance, crit chance, crit multiplier).

Kept OUTSIDE the trigger vocabulary so "trigger resolver" never spans two streams with
opposite temporal semantics. (User position, recorded for a future initiative:
interception "should be a trigger — it just is." Deferred, not overruled.)

## 9. The language

Three moments, three verbs, no overlap:

- **Played** — a card leaves hand and enters the world: every card, one uniform act (pay
  mana, emit `played`). A **spell is simply a card that doesn't stick to the board** —
  its effects are TriggeredEffects on the played event; conceptually identical to a unit
  card in every other way. "Cast" retires as a mechanism word.
- **Acts** — a unit takes its main turn action at its speed-ordered moment; the act is
  *typically* the auto-attack, but attack is never the moment's name. Renames today's
  `activate`/`ON_ACTIVATE` event to `act` — the current word collides with the ability
  mechanism, which is exactly the attack/activation conflation to kill.
- **Activated** — an ActivatedEffect is paid for and invoked; the word belongs to the
  ability mechanism exclusively.

## 10. What this design deletes

Each hack maps to a structural absence the design fills:

| Dies | Because |
|---|---|
| SpellCaster's second dispatch (`_resolve_on_play` walking effect lists) | plays emit events through the one pipeline |
| `Transient` trigger kind + `applies_on_use()` | activation is its own mechanism; plays are events |
| `While` as inert type-tag + `is_standing()` lookups | the passive system owns its liveness and fold |
| The ability spell-costume (`display_card`, source swap, state on holder) | ActivatedEffect is the runtime container |
| The `side` target kind (all authored uses are `of: own`) | targetless payloads; the payload names its recipient |
| Trigger/targeting mirror vocabulary + round-trip flags (TECH_DEBT §1) | consumers ask resolvers; one surviving schema |
| The `Effect` payload-union object (~30 fields, TECH_DEBT §3) | four structures, dumb payload species |
| `ON_ACTIVATE` naming | renamed `act`; "activate" belongs to abilities |
| Legacy authored schema (~147 occurrences, TECH_DEBT §9) | one surviving schema, migrated mechanically, dead form refused at load |

## 11. Decision record (rejected & superseded)

- **Few general resolvers stretched over cases** — rejected for per-need resolvers under
  one contract.
- **CombatSide as a target kind** — rejected; every authored use was `of: own`; the
  payload kind names its recipient. Opponent-directed side payloads, if ever, are a
  payload variant.
- **Pre-resolved manual targeting** (interaction layer reads declarations in advance) —
  rejected; the resolver conducts its own gesture via an injected pick-provider.
- **Persistent/ephemeral resolver taxonomy** — rejected; lifetime is the owner's, full
  stop.
- **A bespoke "auto-attack object"** — superseded; the pointing behavior is a
  TriggeredEffect.
- **Load-time payload↔resolver kind cross-check** — rejected; it would forbid legitimate
  mixed-kind clusters and create static connivance between blind parts.
- **A trigger that splits payload subsets onto different targets** — rejected on
  empirical evidence (2026-08-10 scan: 93 multi-effect owners; the 27 apparent splits
  were 24 per-payload-condition groups on one shared pick, 2 dying `side` blocks, 1
  self-reference that is naturally two triggers).
- **Allegiance owned by the deck** — rejected (the deck's job is holding/granting
  cards); **allegiance tracker/manager** — rejected (nothing to manage); resolved as a
  carried birth fact.
- **"Spell cast effects are activated (cost: card+mana)"** — superseded; spells are
  ordinary cards whose effects trigger on played.
- **Interception as a trigger kind** — deferred (user's conceptual position recorded in
  §8); kept a separate structure at this scope.
- **Build-first anchor (attack resolver before design)** — deferred 2026-08-10 in favor
  of design-first; now satisfied: the design is settled and the attack system is the
  first build.

## 12. Open questions (design-complete is not spec-complete)

1. **The resolver contract's exact shape** — inputs (world, owner, authored params; what
   "enough information to engage" means precisely), the target return type, the full
   query set (current · is-candidate-valid · any-legal-play · gesture conduct).
2. **Engagement settle points** — the precise definition on the arbitration layer's
   single-writer choke; the rule for deaths mid-cascade (unit-leaves-play-instantly
   doctrine vs. a striker's current).
3. **Manual conduct details** — the pick-provider interface, suspension, cancellation
   unwinding, eligibility service to the UI.
4. **The surviving authored schema** — which form lives; the mechanical migration
   (Tool's serializer) of ~147 legacy occurrences; load-time refusal of the dead form.
5. **The payload handoff** — what resolution hands to payload delivery; kept narrow so
   the payload redesign (TECH_DEBT §3/4/7) can proceed without reopening targeting.
6. **Amounts as evaluable values** (TECH_DEBT §5) — conscripted by the attack payload
   ("my attack stat"); scope to be set when the attack rebuild reaches it.

## 13. The rebuild path

First build: **the attack system** — the purest exercise of the design. The `act` event;
the unit's innate TriggeredEffect; the `nearest` resolver with a current, engaging and
re-engaging at settle points; reverse queries feeding the crosshair/menace cues; the
attack payload carrying the strike mechanics through the arbitration Resolver. No
gestures, no schema migration, no payload redesign required. Done = the auto-attack
slice of the quarantine table green and removed.

## 14. Exit criterion

The quarantine table in `tests/_runner.tscn` is driven to zero and deleted. Until then,
its 121 checks are this design's acceptance suite.
