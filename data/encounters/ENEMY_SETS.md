# Enemy Sets — the tribe roster (branch `enemy-sets`, 2026-07-21)

Eleven tribes plus rare easter-egg encounters, authored across `data/cards/enemies_*.json`,
`data/encounters/*.json`, and `data/statuses/` (slimed / frenzied / tailwind are new). Every
unit is `enemy_only` with art at `assets/cards/enemies/<id>.png`. Totals: **40 combat / 15
elite / 9 boss templates**, all riding the existing floor/stage bands + power scaling.

Two engine mechanics were added for this content (see the card guide):
- **`spawn` payload** — on-death splits, per-round summons, and **two-phase bosses** (a dying
  king spawning its next `is_king` form keeps the fight going).
- **`strikes` stat** — multi-attack; each strike re-acquires its target.

| Tribe | Identity | Signature moments | Boss |
|---|---|---|---|
| Slimes | split-on-death cascades, absorption | Colossal→Giant→Green→Droplet chain; Gluttonous eats fallen allies | **Slimeon, the Boundless** → phase 2: his boiling core (fast, 2 strikes) |
| Beasts | enrage, Frenzied stacks, kill-feeding | Boar/Bear grow when hit; wolves Frenzy on kills; Hyena profits from every death | **Ragnor, the Endless Hunger** (+2 atk & heal 4 per kill) |
| Harpies | speed, dodge, multi-strike, Tailwind | Twin-Talon double strike; Galecaller hastes the flock; Aellai grows off dodges | **Kyrraxa, the Hundred-Gale** (3 strikes, 25% dodge) |
| Aliens | shields, side-draw tech, replication | Probes make the CPU draw on death; Aegis Nodes project Barriers; tractor-drain Abductor | **The Mothership** (fabricates drones) → phase 2: Command Saucer |
| Insects | swarm, cocoons, aura | Sealed Cocoon self-ripens & hatches on ANY death; Locust aura; broodmothers | **Zellixa, the Hive Queen** (lays a cocoon each round) |
| Pirates | chaos kegs, kill ledgers, grog | Powder Monkey damages BOTH sides; Sea Cook heals crew; First Mate notches kills | **The Kraken, Debt Collector** (3 tentacle strikes) |
| Cultists | sacrifice economy | Willing Offering wants to die; Blood Priest converts ally deaths to attack | **Hierophant Ozmun** → phase 2: **Vhal'Zhoth**, the god he dug up (10 atk, 2 strikes) |
| Trolls | regeneration | Everything heals every round; Old Gorge (elite) heals 4 + enrages | — (elite tribe) |
| Fairies | dodge, Blind, trickery | Queen Mab blinds whoever hits her; Puck steals speed for himself | — (elite tribe) |
| Dinosaurs | crit, retaliation, endgame stats | Raptor +crit; Stegoback thorns; Compies keep coming (50%) | **TYRANNUS, the Extinction** (9 atk ×2 strikes, heals 5 per kill) |
| Corporate | buzzword warfare | Interns draw on death ("exit interview"); Consultant debuffs BOTH sides | **The CEO** (hires interns, takeover stacks) → phase 2: **The Golden Parachute** |

**Easter eggs** (combat templates at weight ~0.06–0.07 — rare surprises, better-than-normal
rewards): *Surprise Concert: BIAS world tour* (idols: Tailwind choreo, blinding high notes,
sacrificial fans), *Mutant League Scrimmage* (four-armed linemen, mascot aura, rogue referee),
*The Furniture Uprising* (mimic den — the Landlord slams doors on attackers; loot to match).

Classic tribes got expansion templates in `classic_expansion.json` (sapper crews, grave
robbers goblin×undead mix, gravetide, foundry line, vampire court); four cross-band extra
elites live in `extra_elites.json`.

Balancing posture (per the program brief): stage-1 fodder sits just under a common pawn
(1/2/1); endgame non-captains push to ~6/12; bosses to 9-attack double-strikers. The
depth-driven `power` scaling still multiplies on top.
