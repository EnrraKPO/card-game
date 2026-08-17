# Effect System Design — the rebuilt foundation

Status: **DESIGN SETTLED 2026-08-10 (user-ratified); rebuild begins with the attack
system.** This document began as the targeting rebuild's anchor and grew, by settled
rulings, into the design of the whole effect layer. It replaces the rulings-log form of
itself: supersessions are resolved into final positions here, and the paths considered
and rejected are preserved in the Decision Record.

Ground truth for the starting state: the demolition is complete (branch
`targeting-cleanup`) — all targeting deleted, combat inert. The quarantine table that
briefly held the razed behavior as red checks was itself DELETED in the Great Purge
(2026-08-11, test doctrine: "only tests that validate systems that won't change may
pass" — red throwaway checks included). The rebuild's requirements live in this document
and in the NEEDS blocks at every razed seam; each phase ships its own native suite as it
lands, and the exit criterion is §14. (Riders and restrikes — damage follow-ons and per-stack repeat rolls — were
DELETED outright rather than quarantined: never user-designed, disavowed 2026-08-09;
their rows were never spec. If damage follow-ons or stack-depth are ever wanted, they are
designed first, as payload delivery rules. The status `spread` mechanism — chance-gated
per-stack propagation with arrival follow-ons, accreted in the same burning-ground work —
followed them under the same ruling, 2026-08-11: cleansed now, designed and signed off
before it is ever rebuilt.)

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

> **⚠ READ FIRST — AMENDMENT 1 (2026-08-14, SIGNED) IS AT THE END OF THIS DOCUMENT.**
> Large parts of this instrument no longer describe the system. Every affected passage
> carries an **[a1]** mark; no original word has been removed. Anything marked **[a1]**
> is not ground for anything.

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
| **InterceptorEffect** | rewrites | pending-mutation gate (in the Arbitrator) | — | rewrite of the proposal |

> **⚠ [a1] VOID IN PART.** The *What* column for TriggeredEffect and ActivatedEffect
> ("operation payloads") and the whole InterceptorEffect row describe machinery that no
> longer exists — payloads, the Arbitrator, and pending mutations were all vaporized.
> The four-structure split itself STANDS. See Amendment 1.

**Effect containers** — Unit, Spell card, Relic, Status, Upgrade — are plain holders.
Any container may hold any mix of the four structures; there is no container taxonomy
and never will be. (Corollary: an activated or passive effect usable/live *from hand*
is just a container holding a structure — no new mechanism.)

TriggeredEffect and ActivatedEffect are together the **actions**: they take place at a
given time and finish, and they are the only structures that point (own a target
resolver). PassiveEffect is a presence; InterceptorEffect is a gatekeeper. Targeting
serves the actions exclusively.

## 2. The action anatomy: trigger-anchored, one resolution, N payloads

> **⚠ [a1] THE PAYLOAD HALF OF THIS SECTION IS VOID.** Payloads were vaporized as cursed
> 2026-08-14. Everything here about what an action *delivers* — the payload species
> roster, delivery rules, attack-as-a-payload-kind, the amount — describes nothing that
> exists, and nothing replaces it until the follow-up initiative is signed. What STANDS:
> the trigger is the anchor; one anchor, at most one resolution; targetless effects; and
> auto-attack as an authored named effect referenced by id. See Amendment 1.

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
- **Attack is a payload kind — and a GAME MECHANIC (refined 2026-08-11, signed §8.1 of
  the attack pitch).** The payload owns the *delivery* (routing, the authored amount);
  the mechanic owns the *striking*: ~~`StrikeEngine` is the one-blow protocol's single
  home (emit `attack` → propose to the Arbitrator → decay tick → emit `struck` →
  `dodge`/`crit` news), invoked by the attack payload exactly as the status payload
  invokes StatusEngine~~ **[a1] NEVER EXISTED — STRUCK.** No `StrikeEngine` was ever
  built, in this generation or any other; the sentence entered sourced to the cursed
  §8.1 of the attack pitch and describes nothing. Dodge and crit are likewise gone
  (nuked 2026-08-13) — the effect system happens to use the mechanic, it never owns
  it. Vocabulary: "attack" is the NUMBER (the stat and its namesakes); "strike" is the
  DEED (one blow). Nothing above the payload knows attacks are special. Two proofs of
  decoupling: (A) a unit's act need not be an attack; (B) an attack payload can ride
  any action ("when played, make an attack" — or "counter-attack on dodge", the same
  engine through the same payload).
- **Auto-attack is a TriggeredEffect** on the `act` event — and (re-ruled 2026-08-11) an
  **explicitly authored NAMED EFFECT**, never synthesized from a card field: the attack
  family — **one effect per POLICY** (nearest_attack — né melee_attack, renamed by
  signature 2026-08-12 since "melee" is not an axis — + the leap/wounded/tank/threat
  variants; there is NO ranged_attack — ruled 2026-08-12: ranged-ness is presentation,
  derived from the policy: stat-hunting policies fly the bolt, geometric ones lunge, and
  `CardData.ranged` dies as a flag) — is authored once in the library (`data/effects/`)
  and units reference it by id, the same reference-by-id pattern abilities and statuses
  use. `CardData.target_policy` is deleted; the policy lives inside the referenced
  effect's target resolver. A card referencing no attack simply doesn't attack.
  Dependency made explicit: "HOW MUCH = my attack stat" is a runtime value — resolved by
  the mutator (§12.6).

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
- **Standing state: the current — computed on read (user-ratified 2026-08-11).** A
  resolver's current is not continuously maintained state; it is derived fresh at the
  moments someone actually reads it, and there are exactly two: **(A) the trigger
  moment** — the owning action resolves against the world as it stands right then — and
  **(B) the interactive idle** — previews, crosshair/menace cues, and reverse queries
  ("am I being targeted?") while play waits for input. Mid-cascade nobody reads a
  current, so nothing re-engages and stale-current rulings are unnecessary by
  construction. Manual resolvers stay empty until conducted. Reverse queries consult
  whichever resolvers are alive right now (a mid-aim spell's resolver truthfully
  registering on its target IS the aim-preview cue). ~~Resolver instances are owned by a
  CombatWorld and copied with it.~~ **[a1] NEVER PERFORMED — STRUCK.** A resolver is
  stateless and holds nothing; the world is supplied per call. Ownership by a world was
  never built and is not needed while the current is derived on read, as ruled above.
  Resolution and delivery admit no gap: events are
  post-hoc news (the arbitration layer's hard rule), so a reaction to an action exists
  only after that action's ~~payloads~~ **[a1]** consequences landed — nothing can
  invalidate a resolution between the read and the landing. Pre-delivery interference is the interceptor
  stream's job, and interceptors rewrite amounts, never targets.
- **Owned by the pointing behavior, never the entity.** A unit does not own a resolver —
  its auto-attack (a TriggeredEffect) does; a spell's played-effect does; an ability
  does. Entities carry behaviors; behaviors point. Lifetime is not a resolver concern:
  a resolver lives exactly as long as its owner. Authored data only ever declares (the
  card's `target_policy` string, the effect's `targets` dict); instantiation belongs to
  whoever materializes the behavior into the world.
- **Sole authority — and no anticipatory queries (user-ratified 2026-08-11).** No
  external component peeks at the decision process — the interaction layer must never
  read targeting declarations to anticipate gestures. Sharpened: nothing evaluates
  candidates prior to resolution, period. The prohibit-non-ops viability rule survives
  *relocated to execution*: an invocation whose resolution comes up empty (or whose
  manual pick could never complete) REJECTS — nothing lands, no cost paid, the same
  path as cancellation. The hand does not predict castability (the grey-out cue is
  given up — an accepted UX trade, revisitable as presentation later); the enemy
  engine discards candidate moves whose simulated resolution rejects.
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
3. ~~**Delivery conditions** — each payload's: "does this payload apply to what was
   resolved?" Kind fitness ("I apply to units") is simply a payload's first delivery
   condition. A resolver may return mixed kinds with each payload fitting its own slice
   ("create a Pawn on an empty slot" / "add a Pawn to a unit's composition"); a payload
   not applying is SELECTION, not failure. No connivance between payload and resolver —
   not even statically.~~
   **[a1] VOID** — the third seat rode the payload and went with it. The grammar and the
   first two seats STAND; the third has no holder until the follow-up initiative gives
   consequences a form.

Self-exclusion ("not me") is an IDENTITY comparison, not allegiance — a separate
structural mechanism, parked.

## 5. Allegiance

**Definition:** membership in a combat party (two parties per fight). "Ally"/"enemy" are
not properties of anything — they are *comparisons* between the candidate's party and
the anchor's. Slots derive theirs from the board half they sit in.

**Ownership:** the object itself carries its allegiance, stamped at creation by whatever
creates it — a constructor argument, not a reporting duty. No manager (a manager earns
its existence by managing *change*; a birth fact that nothing invalidates passes the
widget-state-ownership rule carried on the object). ~~Mutation, if ever wanted, is already
provided for: the Arbitrator is the single writer of all stats — side-switching
would be an ordinary StatMutation through the existing gate.~~ **[a1] VOID — there is no
gate. The Arbitrator and StatMutation were vaporized; nothing in the game writes a fact
today. Allegiance mutation waits on the follow-up initiative like every other write.**

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
retracted: it is not a targeting verb. The fold's checks rebuild on the
condition grammar alone (predicates over unit + holder/owner anchors), a scope
*reduction* for targeting. The passive system also owns its own liveness and fold — the
current inert `While` type-tag interpreted by four other systems dies with the rebuild.
The two-layer read survives: Layer 1 composition grants settle as a per-unit fixed
point; Layer 2 folds stats under the stratification guard.

**Nothing is cached, and no lifetime object exists (user rulings, 2026-08-11).** Any
live effect may affect any other live effect, so any stat alteration invalidates
everything — a fine-grained cache is intractable and a coarse one worthless; the old
implementation's cached composition snapshot was never sanctioned and is void. Every
read derives fresh from the containers that exist at that moment (the unit's statuses,
its card, its charms, the run set) and discards the result. Liveness is each container
species' own fact, owned by its governing system (StatusEngine expiry, fielded-ness,
run membership) — an expired container is simply not encountered by the walk, so
staleness is impossible by construction and the old EffectTracker has no successor.
Per-stack scaling, if a payload wants it, is authored in the payload's own amount
semantics — never a lifetime concern.

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

**The spell play is the second payer (re-ruled 2026-08-11, reversing §11's earlier
position).** A spell's own effects are an ActivatedEffect whose cost gate is the card
itself + mana, invoked by the play action; `played` is emitted as news for bystanders —
exactly the invoked-directly pattern above, with a different cost. THE usability rule
(`usable_by`-style pure query) widens to serve both payers.

## 8. The interception system

> **⚠ [a1] THIS SECTION IS VOID IN WHOLE.** It describes a stream inside the Arbitrator,
> pending StatMutations, and dodge/crit rate queries — none of which exist. Interception
> has been a stub since 2026-08-11 and its subject matter was vaporized after it. Ruled
> 2026-08-14: interception is not a design constraint on the rebuild; it is a feature
> that will take its socket if the architecture lands correctly. Nothing here is ground
> for anything. See Amendment 1.

An InterceptorEffect watches **pending StatMutations inside the Arbitrator**,
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
  mana, emit `played` as news). A **spell is simply a card that doesn't stick to the
  board** — and (re-ruled 2026-08-11) its own effects are an **ActivatedEffect invoked
  by the play** (cost: the card itself + mana), never TriggeredEffects on its own
  `played` event: a cancellable, pre-cost manual pick cannot be a reaction to post-hoc
  news (§11 records the argument). Bystanders still hear `played` as an ordinary
  post-hoc event. "Cast" retires as a mechanism word.
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
- **Auto-attack synthesized at fielding from `CardData.target_policy`** — rejected
  2026-08-11 (pitched, corrected at sign-off): the auto-attack is an ordinary authored
  named effect referenced by the unit; no synthesis special case, and the field dies.
- **"Resolver" as the arbitration layer's class name** — renamed **Arbitrator**
  (2026-08-11): three unrelated "resolvers" was a naming hazard; "resolver" now belongs
  only to TriggerResolver and TargetResolver.
- **Load-time payload↔resolver kind cross-check** — rejected; it would forbid legitimate
  mixed-kind clusters and create static connivance between blind parts.
- **A trigger that splits payload subsets onto different targets** — rejected on
  empirical evidence (2026-08-10 scan: 93 multi-effect owners; the 27 apparent splits
  were 24 per-payload-condition groups on one shared pick, 2 dying `side` blocks, 1
  self-reference that is naturally two triggers).
- **Allegiance owned by the deck** — rejected (the deck's job is holding/granting
  cards); **allegiance tracker/manager** — rejected (nothing to manage); resolved as a
  carried birth fact.
- **"Spell effects are TriggeredEffects on `played`"** — REVERSED 2026-08-11, restoring
  the once-rejected "activated (cost: card+mana)". The cancellation rule forced it: a
  manual pick is cancellable with no cost paid, but a reaction to the post-hoc `played`
  event fires only after the cost was paid and the card left hand — you cannot cancel a
  reaction to news. Framing the spell's own effects as triggered would force the play
  mechanism to inspect and conduct a triggered effect PRIOR to its event's dispatch.
  The card's own effects are invoked by the play (§7); bystanders hear `played` as news.
- **A general amount/expression grammar** (value species + combinators: "half of",
  "X per stack") — rejected 2026-08-11 for per-need mutator species under one
  contract (§12.6): each need is an encapsulated species that derives its own value
  from the delivery context; no combinator language exists to rot.
- **Pre-resolution candidate evaluation** (the castability grey-out, any-legal-play and
  is-candidate-valid as contract queries) — rejected 2026-08-11: execution rejects on
  failed resolution instead; prohibit-non-ops is enforced at the invocation, not the
  offer. Eligibility survives only INSIDE manual conduct, gating what a pick may
  appoint.
- **Interception as a trigger kind** — deferred (user's conceptual position recorded in
  §8); kept a separate structure at this scope.
- **Continuously maintained currents re-engaging at settle points** — superseded
  (2026-08-11): currents are computed on read; with only two read moments (trigger,
  interactive idle) the settle-point concept and its mid-cascade death rulings are
  unnecessary.
- **Build-first anchor (attack resolver before design)** — deferred 2026-08-10 in favor
  of design-first; now satisfied: the design is settled and the attack system is the
  first build.

## 12. Open questions (design-complete is not spec-complete)

1. **The resolver contract's exact shape** — NARROWED (user-ratified 2026-08-11) to the
   single-issue frame: a target resolver answers ONE question — *what am I pointing
   to?* — as an array of game objects; empty is literally empty, and all other states
   derive. Two entry points only: **resolve** (automatic; the trigger-moment and
   interactive-idle reads) and **conduct** (manual; suspend for the pick,
   cancel/reject). No candidate-enumeration, viability, or validity queries exist in
   the contract (§3, §11). The return type is settled: `Array[GameEntity]` — the
   shared base of CardInstance and BoardSlot (renamed from StatusCarrier 2026-08-11:
   the base carries the two universally shared facts, status pinning and
   pointability). Still open: only the exact input set (world + spatial/allegiance
   anchors + authored params).
2. ~~**Engagement settle points**~~ — RESOLVED (user-ratified 2026-08-11): currents are
   computed on read, and the only reads are the trigger moment and the interactive idle
   (§3). Settle points as a maintained-state concept are gone; the deaths-mid-cascade
   question dissolved with them (a resolution is read against the live world at its
   moment, and events-are-post-hoc means nothing fires between resolution and landing).
3. **Manual conduct details** — the pick-provider interface, suspension, cancellation
   unwinding, the zero-eligible auto-reject; pick eligibility lives INSIDE conduct
   (gating what the tap may appoint), never as a service exposed outside it.
4. ~~**The surviving authored schema**~~ — DISSOLVED by the content strip (2026-08-11,
   "forget all effects — we author them again"): nothing migrates; every effect is
   re-authored natively as the rebuild reaches its container, and loaders + the Tool's
   save gate refuse the dead form.
5. **The payload handoff** — what resolution hands to payload delivery; kept narrow so
   the payload redesign (TECH_DEBT §3/4/7) can proceed without reopening targeting.
   **[a1] STILL OPEN, and now the live question:** there is no payload to hand to. What
   a resolution hands to whatever carries consequence is owed to the follow-up
   initiative.
6. ~~**Amounts as evaluable values**~~ **[a1] VOID — the mutator was vaporized
   2026-08-14 and this item describes nothing that exists. It is the clause under which
   the 2026-08-13 forgery was found: the delivered code made the mutator a value
   supplier and moved the emitting into the payload. Reopened, unanswered, and owed to
   the follow-up initiative named in Amendment 1.** (TECH_DEBT §5) — RESOLVED (user-ratified
   2026-08-11): **the mutator**. Every payload value slot — numeric amounts AND
   identities (which stat, which status, which card: "deliver [material]", "apply
   [amount] [status]") — is filled by a mutator: per-need species under ONE contract,
   the targeting doctrine verbatim (generality in the contract, specificity in the
   species; NO general expression language, ever). A literal is the trivial species,
   not a separate path. Lifecycle: **parameterized at parse** (the payload's parser
   `new()`s the species with its authored params — one stateless immutable instance
   shared by every fielded copy, the TriggerResolver precedent), **fed at delivery**
   (the action's executor — the only party holding all the facts — assembles the
   context and calls `produce`), **derives on the spot** (the species' own logic; the
   executor never knows how), **emits concrete StatMutations** to the Arbitrator.
   The context is the four facts and stays a DUMB PLATE (facts only, no
   logic, no caching — the deleted `effect_context.gd` is the cautionary tale):
   world · holder + EXPLICIT allegiance anchor (holder is null for run-scope
   containers; holder-reading species are refused at load there) · occasion (the
   GameEvent for triggered, the invocation for activated) · recipient (per-recipient
   evaluation, forced by plural resolutions). Events carry no magnitudes today; a
   species needing one ("heal the damage just taken") adds it to the event at its
   emission point — parked until wanted. Species roster is content-driven, never
   speculative: day one is the literal species and the holder-stat species the
   auto-attack needs.
7. **Effect-level enemy-eval pricing — DEFERRED (user ruling 2026-08-11, post-hoc
   problem).** The old schema let an effect carry flat/mul prices on the enemy engine's
   channels (threat/exposure/value — STATUS_EVAL_BRIEF.md); that half died with the
   layer. Status-level PER-STACK pricing survives (StatusData.eval, adds only). Until
   the new schema decides where effect-level pricing lives, re-authored effects are
   simply unpriced — invisible to enemy planning, never wrong. Revisit once payloads
   exist to price.

## 13. The rebuild path

First build: **the attack system** — the purest exercise of the design. The `act` event;
the unit's innate TriggeredEffect; the `nearest` resolver with its current computed on
read (trigger moment + interactive idle, §3); reverse queries feeding the
crosshair/menace cues; ~~the
attack payload carrying the strike mechanics through the Arbitrator~~ **[a1] VOID — no
payload, no Arbitrator**. No
gestures, no schema migration, no payload redesign required. Done = the attack system's
own native suite green in `tests/_runner.tscn`.

> **⚠ [a1] STATE OF THE REBUILD, 2026-08-14.** Everything on this path landed EXCEPT the
> striking itself: the `act` event, the authored named effects, the five target-resolver
> policies, the current computed on read, and the crosshair/menace cues are all built and
> green. What is gone is what an action *does* when it arrives — and with it every write
> in the game. See Amendment 1.

## 14. Exit criterion

Every phase of this design has landed with its own native test suite green in
`tests/_runner.tscn`, and every NEEDS block at a razed seam has been either fulfilled or
explicitly retired by a ruling recorded here. (The quarantine table that once served as
the acceptance suite was deleted 2026-08-11 under the test doctrine — accepted knowingly:
there is no executable tripwire for razed behavior until each phase ships its suite.)

---

# Amendment 1 — the consequence half is void

~~**Tendered 2026-08-14. AWAITING SIGNATURE.** Until signed, this amendment states nothing;
the body above remains the instrument as executed.~~

**SIGNED OFF 2026-08-14 (Enrra).** This amendment is executed and is binding text. The
body above is read subject to it: every passage marked **[a1]** is void or struck as
stated here, and the instrument as amended is what performance is measured against.

## Why

Between 2026-08-13 and 2026-08-14 the machinery that carried out what an effect *does*
was demolished by ruling: the mutation `channel` and the single writer that carried it,
then the `Payload` and `Mutator` structures entire. This document was written when all of
it existed, so it now asserts, in an executed instrument, a system that is not there.

An instrument containing false statements cannot be performed against. This amendment
makes it legal again. **It does so by voiding, never by restating.** The replacements are
not designed; writing what they might become into a signed contract would be the very
disease this engagement exists to prevent.

## What it does

**One — corrects two statements that were false about what was built.** These were never
demolition casualties; they never matched reality:

- **§3 — "Resolver instances are owned by a CombatWorld and copied with it."** STRUCK.
  Never performed. Resolvers are stateless, shared by reference, and take the world per
  call. Ruled 2026-08-14: the built shape stands, and the derive-on-read clause in the
  same paragraph — which is performed faithfully — is what the design actually rests on.
- **§2 — `StrikeEngine`.** STRUCK. It never existed in any generation. The sentence
  entered sourced to the cursed §8.1 of the attack pitch.

**Two — voids what described the vaporized machinery.** Marked **[a1]** at each site:
the §1 structure table's *What* column and InterceptorEffect row; §2's payload half;
§3's "payloads landed"; §4's third condition seat; §5's allegiance-mutation gate; §8 in
whole; §12 items 5 and 6; §13's attack payload.

**Three — leaves history intact.** The content-strip narrative, the deletion map (§10),
the Decision Record (§11) and the resolved-question scratches record decisions taken at
their dates. They remain true *as history* and are not voided. Only statements asserting
what the system **is** are void.

## What still stands

Unaffected and performed: the four-structure split; the trigger layer; the whole
targeting layer including per-need resolvers, the current computed on read at exactly two
moments, allegiance as a birth fact, and the sole-authority rule; the authored vocabulary;
auto-attack as a named effect referenced by id; the passive system; the language of §9.
The Action trigger kind, the main-action holder and the target poll rest on these and are
unaffected.

## The follow-up initiative

**Arbitration and the mutation of facts are addressed in a follow-up initiative.** How a
fact changes, who issues the change, who executes it, and what announces at the moment it
commits are open questions owed to that initiative and to no other document. Nothing may
be built on the voided passages above in the meantime, and nothing in this amendment
prejudges what that design will be.

Until it is signed and performed, **no fact in the game changes** — every write site sits
inert by ruling.

---

*Tendered by the contractor. **Signed off by Enrra, 2026-08-14**, in conversation: "The
document is signed off."*
