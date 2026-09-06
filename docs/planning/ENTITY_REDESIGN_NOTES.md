# Entity Redesign — session notes, 2026-09-01/02

Fact dump of the design conversation. Working notes, not ruling text; the
scratchpad (ENTITY_REDESIGN_SCRATCHPAD.html) is the articulation surface, this
file is recovery material for whatever it doesn't yet state. Each fact is
labeled: **ruled** (Enrra's word given), **mint** (proposed, unruled),
**superseded** (overturned in the same conversation).

## Scope

- **ruled** — The initiative is a significant redesign of the effect system,
  plus the resolution of non-trivial voids found in the canonical docs. Not a
  small-scope patch of the draft. The draft's structure is superseded material
  feeding the new document, not a frame constraining it.
- **ruled** — The verbatim-carry / transcription mode is dead. The document is
  authored from the system; signed docs and conversation are inputs, not text
  owed preservation.

## The template

- **ruled** — The entity template defines each kind: stat ids (public mutable
  and read-only), container names, appointed effects. It is architectural, not
  content: content builds on it, it must be fixated, changes only alongside
  the document by revision.
- **ruled** — Entities have dual representation (game + authoring Tool), so
  the template is a contract in a common language: one shared file, each
  runtime holding its own typed wrapper (game: `EntityTemplate` with
  `KindTemplate` entries and `of(kind)` lookup; Tool: JS mirror). Loud refusal
  at load. No copy of any list outside the file. Path/format unappointed.
- **ruled** — The kind's appointed effects live in the template entry — this
  closed the "append seat" open. Effects is the template's only
  content-bearing property.
- **ruled** — Parse seats are three: template wrapper at startup; catalogue
  validation + index building at content load (before any fight); EntityBaker
  instantiating effects per bake. Rationale for startup load: the catalogue
  load needs the template before any bake exists; re-parsing per bake redoes
  identical work and moves failure mid-fight.

## Entities

- **ruled** — One entity class; kind as data (`game`, `side`, `slot`, `unit`,
  `spell`, `status`, `relic`). Concrete classes are empty shells and go;
  static seam guarantees become runtime refusals.
- **ruled** — No kind inheritance. Cardness is a borne fact: bears `cost`.
  `unit` and `spell` each declare cost and author their own play and burial
  (they were never truly shared).
- **ruled** — Ownership replaces allegiance: every entity bears its owner, one
  of `player` / `opponent` / `game` — an identity value, NOT a reference to a
  side entity. Birth fact, never rewritten. Copies as a value (no remap).
  Ripple: `is_ally` / `is_enemy` become owner comparisons — lands with the
  conditions material.
- **ruled** — The definition reference is an entity member: readable, never
  written. Definition facts answer through it; no definition fact is entity
  state.
- **ruled** — "Definition" is the term (over "envelope" — vague; over
  "authored object" — instance vibes). A definition is *the authored form of
  an entity*; many entities bake from one definition.
- **ruled** — Two authoring levels, no property in both: template entry =
  type-appointed; definition = instance (kind, id, display name, stat values,
  composition, tags, effects). The Game sits as a kind whose effects (base
  rules) are template-appointed, with one authored definition carrying stat
  values.

## The bake

- **ruled** — An entity comes into existence only through the bake.
  `EntityBaker`: static, stateless, `bake(definition, owner, world) → entity`.
  Static matches the engine/authority pattern (self-sufficient inputs). Two
  callers: genesis; procedures resolving mid-play existence, handing the baked
  entity to the mint primitive. Baker builds, primitive commits existence,
  procedure decides.
- **mint** — Unstated stat value defaults to zero (commentary in scratchpad;
  awaits ruling).

## Tags

- **ruled** — `tags`: an open array of names on the definition. Renamed from
  "birth facts" (A7/T1 still say "birth facts" — future amendment at the trim
  pass). No roster, no declaration, no template governance; content mints
  freely; inert tags lawful; conditions read via `has_tag`.
- **ruled** — "Code behavior" is not a concept: no code seam consumes a tag.
  What code reads today (king → fight end; building → dodge/Move exemptions)
  gets redesigned: fight-end becomes an authored effect; building exemptions
  need authored carriers. Both are opens.
- **ruled** — `building`, `king`, `elements` were never tags — they are
  components.

## Composition

- **ruled** — Composition mechanics are THE core feature of the game. Double
  role: recipe (what a card is MADE OF, for minting by component mix) and
  gameplay variable (queryable by effects). The recipe is immutable — not
  really a "member" of the card. Only cards get compositions.
- **ruled** — Seat: the definition, not the entity. Entities expose their
  definition at read time; entities without composition yield nothing;
  conditions answer false by absence. Composition is NOT an anatomy member.
- **ruled** — Shape: ONE array of component ids (not two): twelve-id closed
  vocabulary (6 elements + 6 chess pieces) in the shared contract file;
  duplicates legal (fire-fire king); order carries nothing; caps 2 elements +
  2 pieces at parse. It has always functioned like a char[] of components.
- **ruled** — Composition is identity: at most one definition per composition;
  index (sorted key → definition) built at catalogue load; duplicate claim
  refused loudly (current code silently overwrites — the redesign turns this
  into refusal); minting by composition = one index fetch; unclaimed key →
  derivation formula (deck-layer scope, statement seat unappointed).
- **ruled** — Composition-altering effects are TRANSFORMATION, not mutation:
  changing composition changes identity — a new entity baked from the new
  composition's definition replaces the old in its housing. Its procedure
  (request, what survives the swap — health, statuses, taps — events) enters
  when content demands. T1 immutability stands untouched.
- Current-code facts (read 2026-09-01): composition lives in CardData
  (`elements` + `chess_pieces` arrays); `composition_key` = sorted joined id;
  `_by_composition` map; authored composition may omit stats and inherit
  derived (formula: cost = sum of component costs, attack 2n, health 3n,
  speed 2); `is_building` = has rook; royalty = king or queen; rook-building
  derived abilities (Castling / material); rarity, offer weight, charm
  capacity read composition. `is_king` (win condition) is a SEPARATE bool from
  the `king` chess piece — the conflation is an open.

## Triggers (§7 outcome)

- **ruled** — `ActivationTrigger extends Trigger`. The journey: two peer
  classes → ITrigger interface + condition-block containment → one class with
  mode flag → **inheritance**, on the fact that the axial test is AUGMENTED,
  not replaced (the activated trigger fires event E and holds on occasions
  named E carrying it by reference — name test still true, merely redundant on
  the self-fired path). "ListeningTrigger" name dropped: the base needs no
  qualifier.
- **ruled** — Trigger members: event (name), EventDataConditions list, entity
  entries list; each list a policy all/any. Entity entry = cluster of entity
  conditions sharing one subject + route (source/target/holder/world) +
  negate; any-fold over the yield.
- **ruled** — ActivationTrigger additions: the fire (mints ask event named by
  its own event member, carrying itself as ActivationEventData; reference
  identity); the carries-me axial test; the two command questions (do you
  activate — fixed; activatable now — live, side-effect-free, affordability
  among conditions). Commander: activatable-now, then fire; event name never
  leaves the effect.
- **ruled** — Required-members law upheld: `has_component.count` is required,
  not defaulted. Rationale: markup is the complete statement; defaults hide
  values in code and drift silently.
- **mint, unruled** — No opposite condition kinds are authored; negate is the
  only negative form.
- **pending ratification** (carried from draft) — behavior-name riding
  ask/engaged events for bystander discrimination; ActivationTrigger's
  authored form (markup syntax) awaits §8.
- Deleted as redundant law: condition purity clause ("writes nothing…") — the
  definition ("one question, answered true or false") is the law;
  effect-level Lifecycle covers immutability of all parts.

## Authoring discipline (ruled through correction this session)

- The document's referent is the SYSTEM, never the conversation. This
  session's failures were notes-of-a-conversation disguised as a document;
  the prose default came from transcription + imitation.
- Concept before term: rule what a thing is/does before spending its name.
  Grounding bottoms out in THIS document (it is THE entity document —
  "entity" itself is grounded by its anatomy section, not borrowed from Core,
  whose entity text is scheduled for the cleanse).
- Function before composition: state what a thing does; a definition is not a
  member enumeration. A spec doesn't enumerate non-capabilities (the
  hippos rule).
- Form follows the content's structure: unconnected rulings are a list, not
  prose. Formatting is a decision to make, not a default to inherit.
- No minted metaphors mid-explanation ("thing-question", "address" — score
  0). Use established terms.
- One subject per statement, stated whole with effort — all the relevant
  information, only the relevant information.
- Every mint must be declared as a mint (rulable, possibly wrong) — unmarked
  mints inside settled-looking text read as hallucination and ARE the
  hallucination mechanism.
- Future workflow (Enrra, 2026-09-02): dump the transcript's facts to notes
  FIRST, then articulate the proper document from them.

## Document state

- ENTITY_BEHAVIOR.html: gained "Redesign stance" + "Scouted opens" commentary
  sections (2026-09-01). Otherwise untouched by this session.
- ENTITY_REDESIGN_SCRATCHPAD.html: stance, opens (11), outline (9 sections),
  worked pieces §1–§7 re-derived whole 2026-09-02. §8 (Behaviors) and §9 (The
  kinds) unauthored. An earlier §9 kinds table (per-kind stats/containers/
  effects incl. Game frame+strike numbers) was authored then deleted with the
  "garbage batch" — recoverable from git only if committed (it was not);
  reconstruct from Combat Frame §4/§6 + Kind Rosters when §9 is authored.
- Nothing committed to git this session.
