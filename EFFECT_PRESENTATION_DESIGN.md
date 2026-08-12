# Effect Presentation Design

**Status: DRAFT v4 — awaiting Enrra's sign-off. One open question (§7). Nothing
below is implemented.**

---

## 1. The problem

Presentation decides how effects look by reading inside them — scanning their
payloads (the concrete game changes an effect carries, such as "deal damage")
and type-checking their targeting (`combat.gd:715`, `combat.gd:725`,
`card_data.gd:556`).

The root cause is not discipline but accessibility: the whole effect object is
handed into presentation code (`combat_cascade.gd:56`), its internals readable
by anyone holding it. Any rule against reading is policing, and policing fails
at one discretional call.

## 2. The principle

**Presentation never asks "do I fire now?" or "what do I do now?"
A system tells presentation: "you do this now." Every single time.**

No effect-shaped object ever crosses into presentation. Peeking is not
forbidden — it is unwritable.

## 3. The solution

Every effect has two presentations — appointed by the effect itself, or filled
by the defaults of §4. Each is a plain name — a word, not a structure — so
naming them reveals nothing of the effect's insides.

**The windup** is how the actor performs the act: the lunge across the board,
the projectile fired, the flare on the acting card.

**The contact** is what this effect landing looks like on the recipients.

A windup always plays in two steps: it **opens** before the effect applies,
and it **closes** after. Many windups have nothing to close with, and that is
normal — the closing step is simply empty for them.

The order of events is fixed in one place, the cascade, as three consecutive
lines that already exist (`combat_cascade.gd:56-58`): the windup opens, the
rules apply the payloads, then the contact plays together with the windup's
closing step. The only change to those lines is their cargo: they carry the
two names instead of the effect object.

The landing is not visually bare today, and none of that changes here. A
reticle snaps onto each affected recipient, tinted by what happened to it, and
a hit burst plays — alongside the damage numbers, misses, and crits. Call all
of this the universal readouts. They derive from outcomes — from what actually
happened, never from which effect did it — they belong to every blow, and they
route through nothing.

## 4. Defaults

An effect that appoints no windup gets the shared default: **the glint**, the
soft flare that already marks "this card's effect is firing" for every trigger
today.

An effect that appoints no contact is looked up under its own name — the id it
was authored with. If nothing is found under that name, the landing shows
nothing extra — silently. Enrra delegated this choice; silent is the ruled
behavior.

## 5. The windups and who appoints them

Three windups are proposed. Their choreography exists in the game today; what
is new is that each becomes a named thing an effect can appoint.

**The lunge** is the melee windup. Its opening is the physical approach: the
actor crosses to the target, strikes, and rebounds. Its closing is the
withdrawal — the walk back home, played over the landing visuals.

**The bolt** is the shot windup. Its opening fires a projectile from where the
actor stands. It has nothing to close.

**The glint** is the soft windup. Its opening is the flare on the acting card.
It has nothing to close.

The five attack effects appoint theirs: `nearest_attack` and `leap_attack`
take the lunge; `wounded_attack`, `tank_attack`, and `threat_attack` take the
bolt. Every other effect falls to the default glint.

Changing what any effect looks like later means changing these appointments —
data, never consumer code.

## 6. The demolition

Everything effect-presentation related that is not a necessary part of the
exact solution above is demolished in the same stroke (Enrra's ruling) — no
survivors, nothing kept "for later." By name:

- `_delivers_blow` (`combat.gd:715`) — deleted. Choreography plays because a
  windup is named, not because payloads were counted.
- `_fires_bolt` (`combat.gd:725`) — deleted. The windup's name says bolt or
  lunge.
- `targeting_line()` (`card_data.gd:556`) — the producer of the tooltip's
  one-line targeting description — deleted as it exists today. Its replacement
  is the open question of §7.

One visible feature dies with the demolition: today the projectile colors
itself by the attacker's elements,
which requires reading the attacker card. Enrra ruled the feature dropped at
this scope. Projectiles fly uncolored.

## 7. OPEN QUESTION — the card description text

Card tooltips today append a one-line description of the unit's targeting
("attacks the nearest enemy"). The mechanism that produces it reads effect
internals and dies in the demolition.

**Where this line comes from in the new system is unresolved and awaits
Enrra's ruling.** A proposal to attach it to the contact was put forward and
not sanctioned; the question is open.

## 8. The names

Every new thing the solution creates, each stated in plain words first:

The two names an effect appoints are authored as two new optional fields on
the effect, called `windup_presentation` and `contact_presentation` — Enrra's
naming: descriptive over short.

The effect exposes each resolved name — appointed, or default — through one
method apiece: `windup_presentation_id()` and `contact_presentation_id()`.
These are the effect speaking outward; no caller ever reaches in.

The presentations themselves are defined in one data file,
`data/presentations.json`, with a windups section and a contacts section.

What an entry contains, at this scope: a windup entry is a name bound to one
of the three choreographies of §5 — the file ships with exactly the three. A
contact entry describes what plays on each recipient when the effect lands —
and at this scope the contacts section ships **empty**: no effect shows
anything extra on landing beyond the universal readouts, which is exactly
today's behavior. The section exists so future visuals (and §7's answer, if it
lands here) have their lawful place. A contact, once one exists, plays once
per recipient.

One loader reads that file at startup and refuses malformed or duplicate
content, the same way the effect library already behaves. It is called
`PresentationLibrary` (`scripts/effects/presentation_library.gd`) and answers
two questions: give me the windup with this name, give me the contact with
this name.

One existing structure must be understood to see where the change lands. The
game can run a whole fight with no visuals — simulations do exactly that,
running the real rules on invisible copies of the board. This works because
the rules never speak to the screen; they speak to a **presenter**: one object
holding the show-this-moment functions the cascade calls. Two presenters exist
today: `CombatPresenter`, the silent one that shows nothing (simulations use
it), and `LivePresenter`, the one live fights use, which forwards each moment
to the visible combat scene through two functions Combat exposes for the
purpose — those two receive the names as well.

Today, the presenter's windup and results functions are handed the whole
effect object. They will receive the two presentation names instead. After
this change, no presentation code in the codebase is handed an effect at all.

## 9. Scope

This document cleanses the presentation peek only. The rest of phase 4 is
untouched: the seam where the board asks which unit an attacker would strike
(find_target), the annotated debts waiting in the board script (the NEEDS
blocks in `combat_board.gd`), and giving each attack its own distinct visuals. Nothing here stands on the cursed additions of
ATTACK_SYSTEM_DESIGN.html; every statement stands on the 2026-08-12
conversation alone.

---

## Sign-off

**Enrra's ruling:** *(unsigned)*

*Amendments are appended strictly below this line, each delivered to Enrra so
it can't be missed. The body above is immutable once signed.*
