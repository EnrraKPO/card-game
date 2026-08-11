class_name BoardScoring
extends RefCounted

# Scores a hypothetical board state against the encounter's priorities (design decision 17:
# priorities are ways of scoring a board). Static POSITION measurement only — no combat
# resolution, no concrete "X will attack Y" projection (17a/17b).
#
# THE VALUATION SYSTEM: before ANY value-related eval runs, a whole valuation pass prices
# every unit on BOTH sides (run_valuation). Per unit, two stages:
#   · RAW VALUE — what the unit DOES: attack × strikes, abilities, effects, speed, plus
#     arbitrary per-card enhancers. Health/shield count only minimally (the pool's real
#     worth — absorbing damage — is persistence's job) and role tags are not consulted
#     (roles unfold naturally from stats). Current health plays NO part here — a wounded
#     queen is worth the same raw as a fresh one.
#   · PERSISTENCE — how likely it is to still be there after the turn: current health +
#     shield against its expected incoming share under the EXPECTED-DAMAGE model — each
#     attacker discounted by what it will live to throw (delivery) and raised by its
#     expected crits, each defender crediting its own dodge (see run_valuation's two
#     passes). Discounts the raw value through ONE tunable dial (persistence_weight,
#     0..1): value = raw × lerp(1, persistence, dial). At 0 fragility is ignored; at 1
#     a doomed unit is worth nearly nothing.
# The pass stamps unit.value and state.value_total (own side positive, player side
# NEGATIVE) and is CANON: any eval that needs to know what something is worth reads the
# stamped values, never its own arithmetic.
#
# The stock table (combined through the decision table — see peer_shares/judge_factor):
#   THE JUDGE — KING SAFETY: the win condition's seat. Full authority, no weight dial;
#      objects in proportion to the own king's endangerment and categorically to his
#      death (the veto is this judge's arithmetic, not an engine special case).
#   PEERS, each with a claim on [0,1] that means what it says:
#   1. TOTAL VALUE (1.0, dominant): the stamped value_total, min-max normalized over the
#      pick's cohort (worst 0, best 1). One number for fielding, buffing, healing,
#      hurting the player, and self-preservation.
#   2. MANA OPTIMIZATION (0.6): use your mana — spending counts, waste doesn't. THE
#      fielding pressure: withholding playable units is leaving spendable mana unspent.
#   3. READINESS (0.1): the OTHER resource a play spends — a tap. Keeps "don't tap"
#      a live option against 2's pressure to spend mana on abilities.
#   4. DAMAGE OUTPUT (0.1, the stock quirk): aggression as expression — cohort-relative
#      BEHAVIOR, scored through score_pick.
# PARKED — 0..1 contract offenders, unseated pending inspection (they score in unbounded
# sums or plain counts): PROTECTION EXPOSURE, IDLE HAND, DEATH RISK, EXPECTED HARM.
# BOARD VALUE stays an opt-in quirk (compliant, superseded by TotalValue).
# Threat includes the player's OPEN MANA at 1:1 (MANA_THREAT_RATE), so risk and harm are
# live from turn one — unspent mana is damage the player can still convert.
#
# Survival weights are resolved from unit ROLE tags (design decision 18): the unit says what
# it is (CardData.role), the weight table says what that's worth — stock defaults below,
# overridable per encounter. The scorer itself stays tag-agnostic: criteria receive resolved
# weights and know nothing about the word "fodder". Tags are never load-bearing — an untagged
# unit falls to the "default" entry and is handled correctly.

# The PEER criteria this scorer runs, blended through the decision table (peer_shares
# below); HIGHER IS BETTER. Every peer must score on 0..1 — an eval that cannot is a
# contract offender and gets parked, never seated. New criteria are entries here.
var criteria: Array = []

# The JUDGES: full-authority evals that contribute by objection — a candidate's total is
# the peer verdict × every judge's (1 − objection). Win-condition seats only.
var judges: Array = []

var _shares_cache: Array = []   # lazily computed from the peers' weights, fixed per fight

# The fight's personality as the valuation pass's price list (see run_valuation). Set by
# stock(); null = the global config alone (hand-built scorers in tests).
var pricer: EnemyPersonality = null

# ⚠ EVERY *_CRITERION_WEIGHT CONSTANT BELOW IS NOW A DEFAULT, NOT THE VALUE IN USE. A fight
# is scored through an EnemyPersonality (an authored character in data/enemy_personalities.
# json, Tool ▸ 🧠 Enemy AI), which may state its own weight for any criterion; these consts
# are what it inherits when it doesn't, and they remain the single source of truth for the
# stock character — the reasoning recorded on each one is still the reasoning behind the
# default enemy. Change a const to move every personality that hasn't opinionated away from
# it; author a personality to make ONE enemy different.

# Stock survival-weight table, keyed by role tag ("captain" = any is_king unit; per-card-id
# overrides also allowed). The values encode the default protect ordering: the Captain far
# above everything, support/burst worth shielding, fodder cheap, untagged mid-low.
const STOCK_SURVIVAL_WEIGHTS := {
	"captain": 1.75,
	"support": 0.5,
	"burst": 0.4,
	"dps": 0.3,
	"tank": 0.15,
	"fodder": 0.05,
	"default": 0.1,
}
# Fodder/default sit LOW deliberately: a screen is only worth standing in the open if the
# body is cheaper than the exposure it absorbs — priced any higher, screening scores as a
# net loss and the engine hides everyone in the back.
#
# ⚠ EVERY CONSTANT IN THIS FILE IS PROVISIONAL UNTIL PLAYTESTED. Values come from staged
# sweeps inside tests/test_enemy_engine.gd; the regression tests pin them, but that is
# self-consistency, not validation — never cite the suite as evidence a value is right.
#
# Captain 1.75 makes damage-sharing threat-dependent: moderate threat and the king moves
# up to absorb, heavy threat and it commits to the back column. Below ~1.5 the king
# loiters mid-column while a fodder takes the safe back seat; 2.5 never takes a hit.
# Rough character range: {"captain": 1.0} ≈ reckless sponge, 2.5 ≈ coward.

# How loud bare exposure is next to death risk. Small on purpose: it exists to keep the
# formation instinct alive on quiet boards, not to compete with actual mortal danger.
const EXPOSURE_CRITERION_WEIGHT := 0.15

# How loud the SEATING ORDER is (the Formation criterion — the 0..1-legal re-expression of
# the instinct parked ProtectionExposure carried). Low by design: it is a geometric PRIOR,
# not a reading of the fight, and the damage model outranks it wherever the damage model
# can see anything at all. At 0.1 it claims ~5% of the decision — decisive only where the
# real criteria are indifferent (the case it was built for was a 0.0001 gap), never enough
# to outvote one that is not. Toward 0.3 for a character that fusses over its formation; at
# 1.0 it would trade real value for tidiness.
const FORMATION_CRITERION_WEIGHT := 0.1

# Two prices — or two seats — closer than this are the SAME: the pair drops out of the
# formation measure instead of being decided by float noise (an enemy deck is mostly
# duplicates, and mirrored seats read identical exposure).
const FORMATION_EPSILON := 0.0001

# PARKED (opt-in quirk default; death risk's reference weight 1.0 lives in
# EnemyPersonality.stock_weights). Expected HARM: a unit being worn down matters even when
# it will not die, weighted by the same survival table. Half the death criterion because
# harm is the sub-lethal half of the same concern: losing the unit outright must always
# read worse than any amount of surviving damage.
const HARM_CRITERION_WEIGHT := 0.5

# Open player mana counts as threat, 1:1: mana the player has not yet spent is damage they
# can still convert this round — a fresh unit, a spell. Folded into threat_mass, so it
# reaches both death likelihood and expected harm through the one incoming() measurement.
const MANA_THREAT_RATE := 1.0

# How loud TOTAL VALUE is — the valuation system's one criterion, and the reference scale
# every other weight is read against. Min-max normalized over the pick's cohort, so its
# FULL swing is its weight: the best-valued option earns exactly this much over the worst.
# Dominant on purpose — the valuation pass already folds every value concern (a dying unit
# is a value drop, a hurt player unit is a value gain), so this dial is "how much the
# character cares about the state of the world", which is most of what a character is.
const TOTAL_VALUE_CRITERION_WEIGHT := 1.0

# (King safety carries no weight constant: it is the JUDGE — full authority, fixed. Its
# contribution is controlled by its scoring rule; see the KingSafety class.)

# PARKED (opt-in quirk default, superseded by TotalValue). Board value: the arbitration
# dial between growing the battlefield (fielding, buffing, hurting the player) and
# preserving what stands, in the real currency — a unit is worth its stats + abilities +
# effects (BoardValueConfig), not its mana cost. Min-max normalized within the pick, so
# its FULL swing is its weight: raising it amplifies even trivial value gaps into
# full-weight differences.
#   0.1  → rescues a dying ally over buffing an attacker
#   0.2+ → buffs and lets it die (board value genuinely outweighs safety)
const BOARD_VALUE_CRITERION_WEIGHT := 0.1

# How loud aggression is — the "maximize damage output" BEHAVIOR. Behaviors land on 0..1
# by construction (expression relative to this pick's best option), so the weight is
# directly "how much of a certainly-dying weight-1.0 unit full aggression is worth".
# Nonzero in stock ON PURPOSE: the default character must already reach for damage buffs
# without per-encounter authoring. 0.1 because at 0.25 aggression starts outbidding live
# triage (a support buffing while its 1 HP dps dies); raise per-encounter for genuinely
# bloodthirsty Captains.
const DAMAGE_CRITERION_WEIGHT := 0.1

# How loud "use your mana" is. A GOAL on 0..1 whose per-pick pressure is the FULL swing —
# any waste-free spend scores 1 against declining's 0 — so the weight is exactly "what one
# clean use of mana is worth". 0.6 outbids a placed body's own risk share while staying
# under the weight of genuinely precious lives, so a play that throws away something
# valuable can still be declined — must-improve restraint survives.
const MANA_CRITERION_WEIGHT := 0.6

# How loud keeping units READY is — the counterweight to the mana criterion. Mana pressure
# alone would tap every unit that holds an affordable ability, because a tap is invisible
# to it: only the mana leaves the pool. But a tap spends the unit's whole turn, so this
# prices that second resource in the same currency, making NOT tapping a genuine option.
# Quiet (0.1) on purpose: the valuation's tap-aware attack stock already bills a tapped
# unit's spent swing itself, so a louder readiness double-charges the same sword. What it
# still prices is what the valuation cannot see — the OTHER tap-abilities a tap closes;
# for encounters heavy with such abilities, dial it up on that fight's personality.
const READINESS_CRITERION_WEIGHT := 0.1

# What ONE withheld playable unit costs — the harsh dial. Deliberately blunt, and
# deliberately NOT an inference from the mana pool: it reads the withheld cards directly —
# if a body could stand on the board and doesn't, that is the charge, whatever the pool
# looks like.
#
# Read it against the survival table: at 1.0 one idle body costs as much as a certainly
# dying weight-1.0 unit — more than any non-captain entry and more than mana's whole swing
# (0.6) — so with a body in hand, a turn that spends nothing has to be worth more than a
# certain death to be chosen. It never argues against another PAID play, though: see the
# waiver in idle_hand(). Together the two make the statement precise — spend your mana
# while you are holding a body, and how you spend it is the other criteria's business.
#   0.0  → off; mana pressure alone decides
#   0.5  → strong preference; a valuable free move can still win a pick
#   1.0  → current: while a body is in hand, do something with the mana
const IDLE_HAND_CRITERION_WEIGHT := 1.0




# ── the decision table (the judge/peer blend) ──────────────────────────────────────────
#
# How eval voices combine into one decision (user-designed 2026-07-31, replacing the raw
# weighted sum). Two kinds of seat:
#
#   · PEERS hold a fixed claim on the decision: their weight, on [0,1], meaning exactly
#     what it says — 0.4 is "claim 40% of what's available". Together a table of peers
#     claims 1 − ∏(1−w) of the decision (hungers dilute each other; company at the table
#     shrinks every plate), split among them in proportion to their weights. A peer's
#     share can never exceed its stated weight, equal weights always eat equally, and
#     order never matters. The unclaimed remainder is indifference — it belongs to no
#     one and falls through to the tie-break.
#   · JUDGES hold full authority and contribute by OBJECTION, not preference: a judge's
#     score is how strongly it objects to a candidate (0 = content, 1 = categorical NO),
#     and what it seizes it strikes out — a candidate's total is the peer verdict shrunk
#     by every judge's objection. Full objection zeroes the candidate outright: the veto
#     is this arithmetic, not a special case. Judgeship is reserved for win conditions.
#
# Weights above 1 or below 0 are contract violations (there is no "overyes"); they are
# clamped defensively but a personality should never author them.

# One share per peer weight, same order: the group's combined claim, split proportionally.
static func peer_shares(weights: Array) -> Array:
	var sum := 0.0
	var open := 1.0   # the fraction of the decision no one has claimed yet
	for w: Variant in weights:
		var wf := clampf(float(w), 0.0, 1.0)
		sum += wf
		open *= 1.0 - wf
	var out: Array = []
	if sum <= 0.0:
		for _w: Variant in weights:
			out.append(0.0)
		return out
	var claimed := 1.0 - open
	for w: Variant in weights:
		out.append(claimed * clampf(float(w), 0.0, 1.0) / sum)
	return out


# What survives the judges: the product of (1 − objection) over every judge. 1 = no
# objections, 0 = at least one categorical NO.
static func judge_factor(objections: Array) -> float:
	var f := 1.0
	for o: Variant in objections:
		f *= 1.0 - clampf(float(o), 0.0, 1.0)
	return f


# The scorer for one fight. The PERSONALITY says how loud each criterion is (EnemyPersonality
# — an authored character, or the stock one when none is named); `weight_overrides` layers an
# encounter's own role→weight entries on top of the personality's survival table ("in THIS
# fight, fodders are precious") — see EncounterData.survival_weights.
#
# Every criterion is built the same way whether the personality calls it a core trait or a
# quirk: the split is an authoring distinction (EnemyPersonality), not a mechanical one. The
# ONE mechanical consequence is presence — a quirk the personality does not carry is never
# constructed, so it contributes nothing rather than contributing zero (identical arithmetic,
# but the criterion dumps stay honest about who is in the room).
static func stock(weight_overrides: Dictionary = {}, personality: EnemyPersonality = null) -> BoardScoring:
	var who := personality if personality != null else EnemyPersonality.stock()
	var weights := merged_survival_weights(who, weight_overrides)
	var s := BoardScoring.new()
	s.pricer = who
	for entry: Dictionary in EnemyPersonality.TRAITS:
		var trait_id := String(entry["id"])
		if bool(entry.get("parked", false)):
			continue   # contract offenders never get a seat (see EnemyPersonality.TRAITS)
		if not bool(entry["core"]) and not who.has_quirk(trait_id):
			continue
		if bool(entry.get("judge", false)):
			var j := _judge_for(trait_id, who)
			if j != null:
				s.judges.append(j)
			continue
		var c := _criterion_for(trait_id, weights, who)
		if c == null:
			continue
		c.weight = clampf(who.weight_for(trait_id), 0.0, 1.0)
		s.criteria.append(c)
	return s


# Criterion id → a fresh instance. The one place the scorer's vocabulary is enumerated: a new
# criterion is a case here plus an entry in EnemyPersonality.TRAITS. The parked offenders keep
# their arms so hand-built scorers (tests, probes) can still seat them knowingly.
static func _criterion_for(trait_id: String, weights: Dictionary, who: EnemyPersonality) -> Criterion:
	match trait_id:
		"total_value":   return TotalValue.new(who)
		"formation":     return Formation.new(who)
		"death_risk":    return DeathRisk.new(weights)
		"harm":          return ExpectedHarm.new(weights)
		"protection":    return ProtectionExposure.new(weights)
		"board_value":   return BoardValue.new(who)
		"mana":          return ManaOptimization.new()
		"readiness":     return Readiness.new(who)
		"idle_hand":     return IdleHand.new()
		"damage_output": return DamageOutput.new()
	push_error("BoardScoring: no criterion for trait '%s'" % trait_id)
	return null


static func _judge_for(trait_id: String, who: EnemyPersonality) -> Judge:
	match trait_id:
		"king_safety": return KingSafety.new(who)
	push_error("BoardScoring: no judge for trait '%s'" % trait_id)
	return null


# The two-layer survival table: the personality's standing protect ordering over the stock
# table, with the encounter's own entries amending it per fight. No SEATED criterion
# consumes it while the survival-weight evals are parked (0..1 offenders); the merge is
# kept — and pinned — whole for their return.
static func merged_survival_weights(who: EnemyPersonality, overrides: Dictionary) -> Dictionary:
	var weights := STOCK_SURVIVAL_WEIGHTS.duplicate()
	for key: String in who.survival_weights:
		weights[key] = float(who.survival_weights[key])
	for key: String in overrides:
		weights[key] = float(overrides[key])
	return weights


# Scores one state alone: the peers' verdicts blended by their table shares, shrunk by
# every judge's objection. BEHAVIOR criteria are silent here (their base score() is 0):
# expression is relative to a pick's alternatives, which a lone state does not have — a
# decision's cohort goes through score_pick instead.
func score(state: BoardState) -> float:
	_value(state)
	var shares := _shares()
	var total := 0.0
	for i in criteria.size():
		total += float(shares[i]) * (criteria[i] as Criterion).score(state)
	return _survives(state) * total


# The peers' table shares, computed once — the weights are fixed for the fight.
func _shares() -> Array:
	if _shares_cache.size() != criteria.size():
		var ws: Array = []
		for c: Criterion in criteria:
			ws.append(c.weight)
		_shares_cache = BoardScoring.peer_shares(ws)
	return _shares_cache


# What the judges leave of this state's total, 0..1 (see judge_factor).
func _survives(state: BoardState) -> float:
	if judges.is_empty():
		return 1.0
	var objections: Array = []
	for j: Judge in judges:
		objections.append(j.objection(state))
	return BoardScoring.judge_factor(objections)


# TRUE when a judge objects categorically — this state is not an option at all, whatever
# its virtues. The engine drops such candidates before the cohort forms, so a forbidden
# outcome never anchors a behavior's normalization either.
func vetoes(state: BoardState) -> bool:
	for j: Judge in judges:
		if j.categorical(state):
			return true
	return false


# THE VALUATION PASS RUNS BEFORE THE EVALS: every state entering
# the scorer gets its units priced first, so every criterion reads the same canon values.
# Idempotent per state — a state carried between picks keeps its stamp (nothing mutates a
# scored state), and every mutation path produces a fresh unvalued state (BoardState.copy /
# CandidateApply build them valued = false).
func _value(state: BoardState) -> void:
	if not state.valued or state.valued_by != pricer:
		BoardScoring.run_valuation(state, pricer)


# The behavior-criteria contract (EVAL_CRITERIA_BRIEF.md taxonomy): scores a whole pick's
# cohort at once. GOALS score each state independently, exactly like score(). BEHAVIORS
# measure every state raw, then normalize by the cohort's best measure — the strongest
# expression available this pick scores 1.0 whatever its absolute size (ratified: when a
# 1-damage flick is the best option, taking it IS maximizing damage). The caller passes
# the do-nothing baseline as the FIRST entry, so "act" and "decline" are compared in the
# same currency. Returns one total per entry, same order.
func score_pick(states: Array) -> Array:
	var totals: Array = []
	for t: Dictionary in pick_terms(states):
		totals.append(float(t["total"]))
	return totals


# The same decision, with every term KEPT instead of summed — what the combat log's
# reasoning dump prints (CombatLog). One implementation feeds both, so an explanation can
# never drift from the score it claims to explain: score_pick is this, folded.
#
# Per state: { "total": float, "survives": float,
#              "peers": [{ id, weight, share, score, contribution }],
#              "judges": [{ id, objection }] }
func pick_terms(states: Array) -> Array:
	var out: Array = []
	for s: BoardState in states:
		_value(s)   # the whole pass per option, before any eval runs — see _value
		out.append({"total": 0.0, "survives": 1.0, "peers": [], "judges": []})
	var shares := _shares()
	for i_c in criteria.size():
		var c := criteria[i_c] as Criterion
		var share := float(shares[i_c])
		# GOALS score each state alone; BEHAVIORS measure raw, then normalize over the
		# cohort's best (see the contract above) — the one difference between the branches.
		var scores: Array = []
		var b := c as Behavior
		if b == null:
			for s: BoardState in states:
				scores.append(c.score(s))
		else:
			var raws: Array = []
			for s: BoardState in states:
				raws.append(b.measure(s))
			scores = b.normalized(raws)
		for i in states.size():
			var term := share * float(scores[i])
			var rec: Dictionary = out[i]
			rec["total"] = float(rec["total"]) + term
			(rec["peers"] as Array).append({"id": c.id, "weight": c.weight, "share": share,
					"score": float(scores[i]), "contribution": term})
	# The judges speak last, per candidate: what they seize, they strike out.
	for i in states.size():
		var rec: Dictionary = out[i]
		var objections: Array = []
		for j: Judge in judges:
			var o := j.objection(states[i])
			objections.append(o)
			(rec["judges"] as Array).append({"id": j.id, "objection": o})
		var survives := BoardScoring.judge_factor(objections) if not judges.is_empty() else 1.0
		rec["survives"] = survives
		rec["total"] = float(rec["total"]) * survives
	return out


# The one place a unit's protection weight is resolved: per-card-id entry first, then the
# implicit "captain" tag for kings, then the unit's role tag, then "default". Keys all live
# in the same table, so rebalancing ANY of this is a data change.
static func weight_for(u: BoardState.UnitState, weights: Dictionary) -> float:
	if weights.has(u.card_id):
		return float(weights[u.card_id])
	if u.is_king and weights.has("captain"):
		return float(weights["captain"])
	if not u.role.is_empty() and weights.has(u.role):
		return float(weights[u.role])
	return float(weights.get("default", 0.0))


class Criterion:
	extends RefCounted
	var id: String = ""
	var weight: float = 1.0
	# Higher is better. Override.
	func score(_state: BoardState) -> float:
		return 0.0


# Σ survival_weight × urgency, negated — the soft-combination criterion. Urgency is the
# unit's likelihood of dying where it stands (see urgency() below), so a much-lower-health
# cheap unit can outweigh marginal protection of a healthy expensive one, with no ordering
# gate and no special cases. A unit that dies under EVERY candidate contributes a constant
# term and cancels out of the ranking — triage for free.
class DeathRisk:
	extends Criterion

	var survival_weights: Dictionary = {}

	func _init(weights: Dictionary) -> void:
		id = "death_risk"
		survival_weights = weights

	func score(state: BoardState) -> float:
		var risk := 0.0
		for u: BoardState.UnitState in state.units(1):
			var w := BoardScoring.weight_for(u, survival_weights)
			if w != 0.0:
				risk += w * BoardScoring.urgency(state, u)
		# A unit this candidate KILLED carries its full weight — urgency 1.0 is "certainly
		# dies", and a corpse is that outcome already realised. Without this the risk term
		# of anything the simulation destroys disappears from the sum, and wiping out your
		# own most valuable unit becomes the highest-scoring play on the board. Own side
		# only — a dead PLAYER unit is already rewarded, through the threat mass it stops
		# contributing.
		for dead: BoardState.UnitState in state.graveyard:
			if dead.owner == 1:
				risk += BoardScoring.weight_for(dead, survival_weights)
		return -risk


# Σ survival_weight × harm, negated — the sub-lethal companion to DeathRisk: how worn down
# each unit is expected to end up, regardless of whether it dies. Same walk, same weights;
# harm() instead of urgency() — the fraction of the unit's HEALTH the incoming share eats
# after the shield soaks its part (shield damage regenerates, health damage lasts). No
# graveyard term: a corpse is DeathRisk's charge, and charging it here too would bill the
# same loss twice.
class ExpectedHarm:
	extends Criterion

	var survival_weights: Dictionary = {}

	func _init(weights: Dictionary) -> void:
		id = "harm"
		survival_weights = weights

	func score(state: BoardState) -> float:
		var hurt := 0.0
		for u: BoardState.UnitState in state.units(1):
			var w := BoardScoring.weight_for(u, survival_weights)
			if w != 0.0:
				hurt += w * BoardScoring.harm(state, u)
		return -hurt


# Σ survival_weight × exposure, negated — the deliverable-1 criterion, now sharing the same
# weight table. Runs at a small criterion weight underneath death risk (see stock()).
class ProtectionExposure:
	extends Criterion

	var survival_weights: Dictionary = {}

	func _init(weights: Dictionary) -> void:
		id = "protection"
		survival_weights = weights

	func score(state: BoardState) -> float:
		var exposed := 0.0
		for u: BoardState.UnitState in state.units(1):
			var w := BoardScoring.weight_for(u, survival_weights)
			if w != 0.0:
				exposed += w * BoardScoring.exposure(state, u.row, u.col)
		return -exposed


# VALUE ORDER vs SEAT SAFETY: does the army's worth order match its seats' exposure
# order (formation_order carries the whole argument)? This is the 0..1-legal expression
# of the instinct ProtectionExposure holds in an unbounded sum — which is why it is a
# new criterion rather than that one unparked.
#
# A Criterion, not a Behavior, deliberately: the measure is already absolute on 0..1, and
# min-max normalizing it over the cohort would inflate a flat board's rounding noise into a
# full-weight preference — the exact pathology it exists to cure.
class Formation:
	extends Criterion

	# The fight's personality — the price list the seating is judged against. A character
	# that VALUES units differently therefore SEATS them differently, off the one table;
	# there is no second ordering to author.
	var pricer: EnemyPersonality = null

	func _init(p_pricer: EnemyPersonality = null) -> void:
		id = "formation"
		pricer = p_pricer

	func score(state: BoardState) -> float:
		return BoardScoring.formation_order(state, 1, pricer)


# The net worth of the battlefield (PARKED quirk): every unit priced by its full kit —
# stats at authored exchange rates, abilities and effect categories at authored
# equivalences (BoardValueConfig) — own side positive, player side negative. Fielding,
# buffing, healing AND hurting the player all grow it, so it prices the whole "make the
# battlefield mine" instinct in one currency. Min-max normalized over the pick's cohort:
# worst option 0, best 1, everything else its fraction of that span.
class BoardValue:
	extends Behavior

	# The fight's personality, which carries this eval's parameters (its price list). Set by
	# stock(); null = the global price list alone.
	var pricer: EnemyPersonality = null

	func _init(p_pricer: EnemyPersonality = null) -> void:
		id = "board_value"
		pricer = p_pricer

	func measure(state: BoardState) -> float:
		return BoardScoring.board_value(state, pricer)

	# Signed measures need the min-max anchoring: ratio-to-max is meaningless when the
	# whole cohort can sit below zero (a rich player board). A flat cohort maps to
	# all-zero — nothing to prefer, the criterion goes silent.
	func normalized(raws: Array) -> Array:
		return Behavior.minmax(raws)


# A JUDGE seat at the decision table: full authority, no weight, contributes by
# OBJECTION — 0 = content, 1 = categorical NO. A judge's objection multiplies a
# candidate's whole total away (score/score_pick), and a categorical objection removes
# the candidate from the pick entirely (vetoes / enemy_engine._pick_best). Reserved for
# win conditions; a judge's contribution is controlled by its scoring rule, never a dial.
class Judge:
	extends RefCounted

	var id: String = ""

	# How strongly this judge objects to the state, 0..1. Override.
	func objection(_state: BoardState) -> float:
		return 0.0

	# TRUE when the objection is categorical — the state is not an option at all. Kept
	# separate from objection() so the engine can veto without pricing the state first.
	func categorical(_state: BoardState) -> bool:
		return false


# The win condition's judge: objects in proportion to the own king's endangerment
# (1 − persistence, read off the valuation stamp — never its own arithmetic), and
# categorically to the king's death. Deliberately the simplest seat in the scorer: no
# tags, no tables, no cohort machinery.
#
# The scoring rule (where this judge's character lives, per the decision-table design):
#   · dead king → objection 1, categorical — the veto, by arithmetic;
#   · never-staged king (hand-built boards) → 0: no win condition to protect, silent —
#     without the distinction every kingless fixture carries a constant discount;
#   · living king → THE PANIC WINDOW over its endangerment (expected fraction of its
#     pool lost this turn, off the valuation stamp): below PANIC_FLOOR the judge is
#     silent — the king's fat pool is a fine screen and damage-sharing negotiates
#     freely (the tank era); past PANIC_CEIL objection is near-total (GRADED_MAX) —
#     protection overrides everything short of the veto (the critical era); between
#     them it ramps. This is the tank-early → protect-late transition as a stated
#     rule: "the king tolerates risking a third of its life; by half, nothing else
#     matters." Danger short of death is never categorical (GRADED_MAX < 1), so a
#     cornered king still prefers the least-bad line instead of freezing.
# ⚠ PROVISIONAL like every constant: floor/ceiling are speakable numbers awaiting the
# playtest; a cowardly or reckless personality would author these, not a weight.
class KingSafety:
	extends Judge

	# The panic window: expected pool-loss fraction where objection starts, and where
	# it saturates.
	const PANIC_FLOOR := 0.3
	const PANIC_CEIL := 0.5
	# The ceiling on objection to a LIVING king's danger. The gap to 1 is what keeps a
	# cornered king choosing among bad options rather than vetoing them all.
	const GRADED_MAX := 0.95

	# The fight's personality — needed only for the lazy valuation fallback below, so a
	# judge constructed alone (tests, dumps) reads the same canon stamp.
	var pricer: EnemyPersonality = null

	func _init(p_pricer: EnemyPersonality = null) -> void:
		id = "king_safety"
		pricer = p_pricer

	func objection(state: BoardState) -> float:
		var king := state.captain(1)
		if king == null:
			return 1.0 if categorical(state) else 0.0
		if not state.valued or state.valued_by != pricer:
			BoardScoring.run_valuation(state, pricer)
		# Past the death line the objection keeps a GRADIENT (the unclamped loss ratio):
		# 1 − objection = (1 − GRADED_MAX) ÷ ratio, so a 1.05×-lethal seat strictly
		# outranks a 1.9×-lethal one and a doomed king still crawls toward the least-bad
		# seat instead of freezing (the T3 freeze, 2026-08-06: every candidate objected
		# 0.95 flat, all moves tied decline, the king sat on burning ground). Asymptotic
		# to 1, never reaching it — danger short of actual death stays non-categorical.
		var ratio := king.loss_ratio
		if ratio > 1.0:
			return 1.0 - (1.0 - GRADED_MAX) / ratio
		return GRADED_MAX * clampf((ratio - PANIC_FLOOR) / (PANIC_CEIL - PANIC_FLOOR),
				0.0, 1.0)

	func categorical(state: BoardState) -> bool:
		if state.captain(1) != null:
			return false
		for dead: BoardState.UnitState in state.graveyard:
			if dead.owner == 1 and dead.is_king:
				return true
		return false


# THE VALUATION SYSTEM'S ONE CRITERION: the stamped value_total — every unit on both
# sides priced by the valuation pass (raw worth × persistence discount, see
# run_valuation), own side positive, player side negative. Min-max normalized over the
# pick's cohort: the best total value this pick offers scores 1, the worst 0. One number
# carries it all: a dying own unit is my own total dropping, damage to the player is
# their negative contribution shrinking, a kill is it vanishing, fielding is growth.
class TotalValue:
	extends Behavior

	# The fight's personality — the valuation pass's price list (raw rates, enhancers,
	# and the persistence dial). Null = the global config alone.
	var pricer: EnemyPersonality = null

	func _init(p_pricer: EnemyPersonality = null) -> void:
		id = "total_value"
		pricer = p_pricer

	func measure(state: BoardState) -> float:
		# The pass normally ran before any eval (BoardScoring._value); this lazy fallback
		# covers a criterion constructed alone in a hand-built scorer.
		if not state.valued or state.valued_by != pricer:
			BoardScoring.run_valuation(state, pricer)
		return state.value_total

	# Signed measure — same min-max anchoring as BoardValue, same reasoning.
	func normalized(raws: Array) -> Array:
		return Behavior.minmax(raws)


# Use your mana. Scores THE CHOICE, not the turn's running total: spending nothing scores
# 0, and any spend that leaves the remainder fully usable scores 1 — spending all your
# mana and keeping a usable reserve are EQUALLY fine, only WASTE is punished. A GOAL on
# 0..1 with no cohort machinery (see mana_optimization).
#
# Two properties this shape buys. (1) Fielding pressure: every successive placement
# decision beats declining on its own, because declining spends nothing. (2) Greedy combo
# blindness cured: with 5 mana and options 2/3/4, playing the 4 strands 1 while playing
# the 3 keeps the 2 usable. Waste is judged ONLY when mana is the binding constraint —
# see mana_optimization.
class ManaOptimization:
	extends Criterion

	func _init() -> void:
		id = "mana"

	func score(state: BoardState) -> float:
		return BoardScoring.mana_optimization(state)


# How much of the army's ACTIVITY is still available, 0..1 — the tap counterweight. A tap
# is a second currency the mana criterion cannot see: it spends the unit's attack for the
# round and closes every other ability it holds. Scoring the STATE (fraction of activity
# potential still unspent) is enough to price the CHOICE, because the must-improve gate
# compares each candidate against the do-nothing baseline — the drop between them IS what
# this tap costs. No cohort machinery, no prev/next plumbing.
class Readiness:
	extends Criterion

	# Taps are priced in the same currency board value uses, so this criterion reads the same
	# per-fight price list (see BoardValue.pricer).
	var pricer: EnemyPersonality = null

	func _init(p_pricer: EnemyPersonality = null) -> void:
		id = "readiness"
		pricer = p_pricer

	func score(state: BoardState) -> float:
		return BoardScoring.readiness(state, pricer)


# Every unit the CPU could field right now and isn't, charged one full weight each,
# negated. A GOAL measured on the resulting state, and the bluntest criterion in the
# scorer on purpose: it never reasons about mana, it reads the withheld cards. Placing a
# unit erases its entry, so the charge falls by exactly one weight per body fielded —
# every successive placement improves the score by the same full amount, no normalization
# to dilute it and nothing about the pool for it to be confused by.
class IdleHand:
	extends Criterion

	func _init() -> void:
		id = "idle_hand"

	func score(state: BoardState) -> float:
		return -BoardScoring.idle_hand(state)


# A BEHAVIOR criterion (EVAL_CRITERIA_BRIEF.md taxonomy): measures how fully an action
# expresses a disposition, not how good a state is — actor, not optimizer. Raw measures
# are normalized by the pick's cohort max inside score_pick; a behavior never scores a
# lone state (base score() stays 0), because expression only exists relative to what was
# available.
class Behavior:
	extends Criterion

	# The raw, un-normalized reading of one resulting state. Override.
	func measure(_state: BoardState) -> float:
		return 0.0

	# Maps the cohort's raw measures onto 0..1. Default: ratio-to-max — each option as a
	# fraction of the pick's fullest expression (assumes non-negative measures). Override
	# for other anchorings (the signed min-max below). A cohort with no expression
	# anywhere maps to all-zero: the criterion goes silent instead of dividing by zero.
	func normalized(raws: Array) -> Array:
		var peak := 0.0
		for r in raws:
			peak = maxf(peak, float(r))
		var out: Array = []
		for r in raws:
			out.append(0.0 if peak <= 0.0 else float(r) / peak)
		return out

	# The signed anchoring (TotalValue, BoardValue): worst option 0, best 1, the rest
	# their fraction of the span. A flat cohort goes silent — nothing to prefer.
	static func minmax(raws: Array) -> Array:
		var lo := INF
		var hi := -INF
		for r in raws:
			lo = minf(lo, float(r))
			hi = maxf(hi, float(r))
		var span := hi - lo
		var out: Array = []
		for r in raws:
			out.append(0.0 if span <= 0.0 else (float(r) - lo) / span)
		return out


# Aggression as expression: the candidate's resulting durability-weighted outgoing damage
# mass, normalized by the pick's best. 1.0 always means "the most aggressive expression
# available right now" — never a global ideal. Buffs, placements and attack-raising
# abilities all move it; damage SPELLS are the value evals' business (they hurt what is
# there; this grows the threat the CPU projects) — division of labor, no double counting.
class DamageOutput:
	extends Behavior

	func _init() -> void:
		id = "damage_output"

	func measure(state: BoardState) -> float:
		return BoardScoring.outgoing_mass(state)


# ── The measurement vocabulary ─────────────────────────────────────────────────────────
#
# Named, pure functions over a BoardState. Criteria CONSUME these; they never compute
# damage themselves — so any future sophistication in potential-damage estimation (top-4
# lane cap, per-lane threat pairing, status-based known damage, ranged reach) is an edit
# inside one function here, invisible to criteria, enumeration and selection. Do not
# inline these formulas into a criterion.

# ── exposure (v2 — RELATIVE depth, user-designed 2026-07-31; replaces the absolute base) ──
#
# "How likely is something standing at this slot to be attacked" (design 17b), from
# geometry + own-side occupancy only — deliberately blind to the player's units and their
# targeting policies (the geometry-only setting is a design decision, not an omission:
# leapers are SUPPOSED to get through).
#
# THE v2 RULING: depth without a screen is not safety. The v1 base read the COLUMN INDEX
# ((COLS−c)/COLS), so a lone unit in the back column stamped 0.25 "safe" while the
# waterfall — correctly — poured the entire incoming mass onto it (observed: the naked
# captain at r2c3, exp 0.250, LANDED 98%). The frontmost occupied position IS the front
# line wherever it stands; safety is MANUFACTURED by bodies in front, never found in
# coordinates. So:
#   · base falls with RELATIVE depth: the count of distinct own-occupied columns strictly
#     nearer the front than this slot. Zero bodies in front = front line = 1.0, wherever
#     the slot is; each occupied column between you and the enemy steps it down a tier.
#   · a body strictly in FRONT (lower col) screens, LANE-BLIND — nearest-targeting is
#     resolved by column depth FIRST (the attack-preference rule: depth strictly
#     dominates; lane offset only orders within a column — the rule this model assumes
#     even while the targeting layer is demolished), so an off-lane screen in a
#     nearer column intercepts exactly as absolutely as a same-lane one. The v1 same/off
#     lane split (1.0/0.5) modelled nothing in the rules and is retired (ruled
#     2026-07-31); the two kinds remain distinguished in the breakdown for the debug
#     surfaces only.
#   · a body in the SAME column splits the column's attention a little — this one IS in
#     the rules: within a same-depth tie the facing lane is eaten first.
# All constants are tuning surface; the Combat Gym is the judge.

const COVER_SAME_LANE := 1.0     # screener in front, same row
const COVER_OFF_LANE := 1.0      # screener in front, other row — same credit: depth dominates lane
const COVER_COLUMN_MATE := 0.25  # company in the same column


static func exposure(state: BoardState, r: int, c: int) -> float:
	return exposure_of(state, 1, r, c)


# The same geometry for EITHER side (each grid's col 0 is its own front line, mirrored):
# cover comes from the side's OWN units only, exactly as the enemy-side original did. The
# valuation pass needs it because persistence is measured for player units too.
static func exposure_of(state: BoardState, side: int, r: int, c: int) -> float:
	return float(exposure_breakdown(state, side, r, c)["exposure"])


# THE exposure model, spelled out — the single definition both the number and every debug
# read of it come from. Returns the arithmetic, not just its answer:
#   { "base": the depth term, "cover": the summed denominator credit, "exposure": the result,
#     "who": [{ "id", "w", "kind" }] — every unit that contributed, and under which rule }
# The debug surfaces (DamageShareOverlay, the combat log's slot table) render THIS; they do
# not re-derive it. Revising the model above therefore means editing one function.
static func exposure_breakdown(state: BoardState, side: int, r: int, c: int) -> Dictionary:
	# Relative depth (v2): how many distinct own-occupied columns stand strictly between
	# this slot and the enemy. The occupant itself can never be among them (its col is not
	# < c), so the same formula serves occupied and empty slots alike.
	var nearer_cols: Dictionary = {}
	for u: BoardState.UnitState in state.units(side):
		if u.col < c:
			nearer_cols[u.col] = true
	var base := float(BoardData.COLS - nearer_cols.size()) / float(BoardData.COLS)
	var cover := 0.0
	var who: Array = []
	for u: BoardState.UnitState in state.units(side):
		if u.row == r and u.col == c:
			continue   # the occupant itself is not its own cover
		var w := 0.0
		var kind := ""
		if u.col < c:
			w = COVER_SAME_LANE if u.row == r else COVER_OFF_LANE
			kind = "screen" if u.row == r else "screen-offlane"
		elif u.col == c:
			w = COVER_COLUMN_MATE
			kind = "column-mate"
		else:
			continue
		cover += w
		who.append({"id": u.card_id, "w": w, "kind": kind, "row": u.row, "col": u.col})
	return {"base": base, "cover": cover, "exposure": base / (1.0 + cover), "who": who}


# ── formation (VALUE ORDER vs SEAT SAFETY — the user's spec, nothing added) ──
#
# "Higher value units deserve the best seats, better covered slots" (the user's original
# sentence, 2026-07-31, restored verbatim after three of my re-expressions each flattened
# it — the graded chain, the binary protection tiers — and each flattening produced a
# live misplay; the ruling that closed it: unrequested additions are removed, not
# defended). "How covered is a seat" is NOT this eval's to define: the game already
# computes it — exposure v2, the number every log's board read prints. This eval only
# checks that the army's VALUE order matches that SAFETY order.
#
# THE MEASURE. Over every pair of own units: the pair is CONCORDANT when the more
# valuable one (raw, pre-persistence worth) sits at strictly lower exposure. Score = the
# concordant fraction of the COMPARABLE pairs; equal worth or equal exposure (within
# FORMATION_EPSILON) is no comparison; no comparable pairs → silent 1.0. A misordered
# pair counts against proportionally — never a cliff, so a tank fronting the army loses
# only its own pairs ("suboptimal setups still count", ruled 2026-07-31).
#
# WHY IT EXISTS. The quota split leaks through screens on purpose, but it still zeroes
# every body past the blow-count cutoff — beyond the N most exposed seats, persistence
# (and through it total_value) and delivery (and through it damage_output) go identically
# flat, and seating falls to the tie-break. Leapers are the standing reason to care: some
# damage reaches past every screen, and this eval is the hedge, priced as a PRIOR — it
# never models who leaps or where.
#
# KNOWN SILENCE, on the record: units sharing a column read identical exposure, so
# intra-stack pairs drop out. A stack is still judged through its pairs with every unit
# OUTSIDE it (on real boards the captain is always there), but a board that is ONE stack
# and nothing else carries no comparable pairs at all and scores silent.
static func formation_order(state: BoardState, side: int, pricer: EnemyPersonality = null) -> float:
	# The pass normally ran before any eval (_value); this lazy fallback covers a criterion
	# constructed alone in a hand-built scorer, exactly as TotalValue's does.
	if not state.valued or state.valued_by != pricer:
		run_valuation(state, pricer)
	var us: Array = state.units(side)
	if us.size() < 2:
		return 1.0   # nothing to order — silent, not zero
	var expo: Array = []
	for u: BoardState.UnitState in us:
		expo.append(exposure_of(state, side, u.row, u.col))
	var concordant := 0.0
	var comparable := 0.0
	for i in us.size():
		for j in range(i + 1, us.size()):
			var a: BoardState.UnitState = us[i]
			var b: BoardState.UnitState = us[j]
			var dv := a.raw_value - b.raw_value
			var de := float(expo[i]) - float(expo[j])
			if absf(dv) < FORMATION_EPSILON or absf(de) < FORMATION_EPSILON:
				continue   # same worth, or same seat: no opinion
			comparable += 1.0
			if (dv > 0.0) == (de < 0.0):
				concordant += 1.0   # the dearer unit sits safer
	if comparable <= 0.0:
		return 1.0
	return concordant / comparable


# ── the eval channels' consumption (STATUS_EVAL_BRIEF.md) ─────────────────────────────
# The authored annotation fold (EvalChannels, stamped at capture) enters the engine at
# exactly three sites: unit_threat_out below (threat — damage out), exposed_incoming
# (exposure — damage in), and run_valuation's raw pricing (value). Each reading combines
# the unit's OWN fold with its SEAT's (BoardState.ground, read at the unit's current
# coordinates — so a move candidate re-prices by geometry alone), muls after all adds
# around the native base: (base + adds) × muls. Null folds are neutral, and clamping at
# zero keeps a hostile annotation from turning a quantity into its opposite.

# Damage out per round — the unit's native attack mass through its threat channel.
# (Blind: threat_mul 0.5 halves whatever the unit's mass happens to be.)
static func unit_threat_out(state: BoardState, u: BoardState.UnitState) -> float:
	var base := float(u.attack * u.strikes)
	var m := u.eval_mods
	var g := state.seat_mods(u.owner, u.row, u.col)
	if m == null and g == null:
		return base
	var add := (m.threat_add if m != null else 0.0) + (g.threat_add if g != null else 0.0)
	var mul := (m.threat_mul if m != null else 1.0) * (g.threat_mul if g != null else 1.0)
	return maxf(0.0, (base + add) * mul)


# Damage in per round: the waterfall's pour IS the native base of the incoming quantity;
# standing exposure (burning, its seat's fire) adds on top, and exposure muls wrap the
# whole thing (a "halve all incoming" ward halves the pour too).
static func exposed_incoming(state: BoardState, u: BoardState.UnitState,
		landed: float) -> float:
	var m := u.eval_mods
	var g := state.seat_mods(u.owner, u.row, u.col)
	if m == null and g == null:
		return landed
	var add := (m.exposure_add if m != null else 0.0) + (g.exposure_add if g != null else 0.0)
	var mul := (m.exposure_mul if m != null else 1.0) * (g.exposure_mul if g != null else 1.0)
	return maxf(0.0, (landed + add) * mul)


# The value channel around the raw pricing (run_valuation's stage 1). Kept non-negative:
# "worse than absent" is not a worth the persistence math can carry.
static func annotated_raw_value(state: BoardState, u: BoardState.UnitState,
		pricer: EnemyPersonality) -> float:
	var raw := raw_unit_value(u, pricer)
	var m := u.eval_mods
	var g := state.seat_mods(u.owner, u.row, u.col)
	if m == null and g == null:
		return raw
	var add := (m.value_add if m != null else 0.0) + (g.value_add if g != null else 0.0)
	var mul := (m.value_mul if m != null else 1.0) * (g.value_mul if g != null else 1.0)
	return maxf(0.0, (raw + add) * mul)


# Total damage the player can put out per round: Σ attack × strikes over fielded units,
# PLUS their open mana at MANA_THREAT_RATE — unspent mana is damage not yet given a body.
# Visible quantities only — reading the enemy's fielded army and mana pool is not
# predicting targeting. Consequence: with mana in the pot, threat is nonzero even against
# an empty player board, so death risk and harm speak from turn one instead of leaving
# formation entirely to the exposure criterion.
static func threat_mass(state: BoardState) -> float:
	return threat_against(state, 1)


# The damage bearing down on `side` per round — the other side's fielded attack mass, plus
# open mana ONLY when the player is the aggressor. The asymmetry is deliberate: the CPU's
# own unspent mana must not read as threat against player units during planning, or every
# candidate that SPENDS mana would raise the player's persistence (their worth rebounds)
# and the scorer would learn to hoard — the exact perversity the mana criterion fights.
static func threat_against(state: BoardState, side: int) -> float:
	var total := float(state.player_mana) * MANA_THREAT_RATE if side == 1 else 0.0
	for u: BoardState.UnitState in state.units(1 - side):
		total += unit_threat_out(state, u)
	return total


# ── the damage quota (user-designed 2026-08-06; replaces the sequential pour) ─────────
#
# ALL threat is MELEE-TARGETING pressure — open mana included: mana prices the unit about
# to be played, not a spell, and spells reaching the back line are out of planning's
# control, so the geometry does not price them (the melee doctrine). The model's one job
# is LANE BREAKTHROUGH: how likely the incoming damage is to reach past the screens. Who
# swings at whom is unknowable at plan time (targeting policies, dodges, mid-round
# deaths), so the model keeps only the knowable parts:
#   · the side's total incoming mass,
#   · roughly how many BLOWS it arrives in (blow_count — fielded strikes plus the
#     triangular pretend-units open mana could still field),
#   · and each body's exposure — the geometry number that already encodes how much of
#     the incoming pressure survives the bodies in front (exposure v2).
#
# Distribution is a FRONT-FIRST BLAST (user-corrected 2026-08-06 — the interim
# exposure-proportional split leaked a dummy-sized share onto a fully screened captain;
# "five more-exposed bodies and five blows: the sixth body takes zero"): the mass is cut
# into `blows` equal quanta, and each quantum in turn lands on the most exposed body
# still STANDING — a tie splits the quantum evenly (equal-depth bodies are equally
# targetable in the rules, so neither is a screen for the other). What lands on a body
# is capped by its remaining pool; the overkill past the pool and the dodged part are
# WASTED, never redistributed. A body is a screen until its pool is spent, then the
# remaining blows walk deeper — so breakthrough is what the model measures: depth = how
# many blows must be consumed before one reaches you. Bodies the blows never reach draw
# exactly zero.
#
# Still never "X will attack Y" (17b): one aggregate mass, anonymous equal quanta, no
# pairing.
#   naive=true — the seeding pass: raw stat mass, no delivery/crit/dodge. Cuts the
#   delivery recursion exactly as before (delivery reads naive urgencies).
#   trace — an optional out-parameter for the debug inspector (DamageShareOverlay): the
#   blast written down term by term, so the UI SHOWS this function's own arithmetic
#   instead of re-deriving a second opinion of it. Ask for it by passing {"units": []};
#   omitted, it costs one has() check.
#     { "mass", "thrown_at", "blows", "quantum" (mass ÷ blows),
#       "units": [{ "unit", "exposure", "eligible" (drew any blow), "pool", "dodge",
#       "aimed", "landed" }] — exposure-descending }
static func incoming_allocation(state: BoardState, side: int, naive: bool,
		trace: Dictionary = {}) -> Dictionary:
	var entries: Array = []
	for u: BoardState.UnitState in state.units(side):
		entries.append({"u": u, "e": exposure_of(state, side, u.row, u.col)})
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["e"]) > float(b["e"]))
	var mass := threat_against(state, side) if naive \
			else expected_threat_against(state, side)
	var thrown_at := attack_speed_ref(state, 1 - side)
	var blows := blow_count(state, side)
	var quantum := mass / float(blows) if blows > 0 else 0.0
	var aimed: Dictionary = {}
	var landed: Dictionary = {}
	var dodge: Dictionary = {}
	var pool_left: Dictionary = {}
	for ent: Dictionary in entries:
		var u: BoardState.UnitState = ent["u"]
		aimed[u] = 0.0
		landed[u] = 0.0
		dodge[u] = 0.0 if naive else minf(dodge_expect(u, thrown_at), 0.95)
		pool_left[u] = float(u.health + u.shield)
	# The blast: each quantum walks the exposure order and lands on the front-most
	# STANDING tie group. A dodger soaks the aim without spending its pool (thrown-and-
	# lost), so it keeps screening — attention is what a screen absorbs.
	if quantum > 0.0:
		var last_group: Array = []
		for q in blows:
			var group: Array = []
			var top := -1.0
			for ent: Dictionary in entries:
				if float(pool_left[ent["u"]]) <= 0.0001:
					continue
				if top < 0.0:
					top = float(ent["e"])
					group.append(ent["u"])
				elif absf(float(ent["e"]) - top) < 0.0001:
					group.append(ent["u"])
				else:
					break
			if group.is_empty():
				# Every body is spent. Nothing more LANDS — but the leftover blows do not
				# vanish from the pressure story: they aim at whoever fell last (the
				# deepest tier), so `aimed` keeps recording how overkilled this side is.
				# loss_ratio reads aimed — capping it here would blind the judge and the
				# surrender verdict to everything past "exactly dead" (the T5 freeze:
				# 28 mass onto a 3-pool captain read ratio 1.0).
				if not last_group.is_empty():
					var excess := quantum * float(blows - q) / float(last_group.size())
					for u: BoardState.UnitState in last_group:
						aimed[u] = float(aimed[u]) + excess
				break
			last_group = group
			var share := quantum / float(group.size())
			for u: BoardState.UnitState in group:
				aimed[u] = float(aimed[u]) + share
				var add := minf(share * (1.0 - float(dodge[u])), float(pool_left[u]))
				landed[u] = float(landed[u]) + add
				pool_left[u] = float(pool_left[u]) - add
	# Opt-in by key, not by emptiness: the default argument is itself an empty dictionary,
	# so a caller asks for the trace by handing one that already carries "units".
	if trace.has("units"):
		trace["mass"] = mass
		trace["thrown_at"] = thrown_at
		trace["blows"] = blows
		trace["quantum"] = quantum
		trace["units"] = []
		for ent: Dictionary in entries:
			var u: BoardState.UnitState = ent["u"]
			(trace["units"] as Array).append({"unit": u, "exposure": float(ent["e"]),
					"eligible": float(aimed[u]) > 0.0, "pool": float(u.health + u.shield),
					"dodge": float(dodge[u]), "aimed": float(aimed[u]),
					"landed": float(landed[u])})
	return landed


# How many BLOWS the mass bearing down on `side` arrives in: one per strike of every
# opposing fielded unit, plus the pretend-units the player's open mana could still field
# (side 1 only — mirroring threat_against's mana asymmetry). Pretend units cost 1, 2, 3, …
# in sequence: keep fielding while affordable; a remainder that cannot afford the next
# cost folds into the last pretend unit instead of becoming one (user-designed
# 2026-08-06 — 3 mana is 2 units because 1+2, 6 mana is 3 because 1+2+3).
static func blow_count(state: BoardState, side: int) -> int:
	var n := 0
	for u: BoardState.UnitState in state.units(1 - side):
		n += maxi(1, u.strikes)
	if side == 1:
		n += mana_blows(state.player_mana)
	return n


# The triangular pretend-unit count for open mana (see blow_count).
static func mana_blows(mana: int) -> int:
	var n := 0
	var cost := 1
	var left := mana
	while left >= cost:
		left -= cost
		n += 1
		cost += 1
	return n


# Expected damage landing on this unit per round, under the NAIVE quota (raw stat
# mass — the public seeding vocabulary; the valuation's stamp uses the refined split
# inside run_valuation). Side-aware: a player unit's incoming is the CPU's mass split
# through the player's own formation.
static func incoming(state: BoardState, unit: BoardState.UnitState) -> float:
	return exposed_incoming(state, unit,
			float(incoming_allocation(state, unit.owner, true).get(unit, 0.0)))


# The unit's likelihood of dying where it stands, 0..1: expected incoming damage against
# effective remaining life (health + shield). Linear, clamped — past "certainly dead" more
# overkill adds nothing.
static func urgency(state: BoardState, unit: BoardState.UnitState) -> float:
	var life := unit.health + unit.shield
	if life <= 0:
		return 1.0
	return clampf(incoming(state, unit) / float(life), 0.0, 1.0)


# The fraction of this unit's HEALTH its incoming share is expected to eat, 0..1. The
# shield soaks first (shield loss regenerates each round; health loss lasts — and for the
# king it persists across fights), so only what gets THROUGH counts as harm. Proportional
# rather than absolute damage points on purpose: it lands on the same 0..1 scale as
# urgency, so the death and harm criteria stay commensurable, and 9 damage wounds a 15 HP
# unit far more than a 40 HP one. Distinct from urgency, which reads incoming against
# REMAINING life to ask "does it die" — this reads against MAX health to ask "how much of
# the unit is being consumed".
static func harm(state: BoardState, unit: BoardState.UnitState) -> float:
	if unit.max_health <= 0:
		return 0.0
	var through := maxf(0.0, incoming(state, unit) - float(unit.shield))
	return clampf(through / float(unit.max_health), 0.0, 1.0)


# ── outgoing damage mass (the aggression measurement) ──────────────────────────────────
#
# The CPU-side mirror of threat_mass, durability-weighted: attack stats are the ONLY way
# attack damage is visible to a static scorer (sims resolve the candidate, never the strike
# phase), and a stat is only worth what its body will live to convert — +10 attack on a
# unit that dies before swinging is nearly worthless. All the aggression math lives in
# these three functions; refine here, invisibly to the criterion.

# Σ attack × strikes × delivery × crit expectation over the CPU's fielded units. The crit
# factor keeps the aggression measure honest with the fight's real rules: a fast
# attacker's output genuinely runs ~10–15% hotter. Target dodge is deliberately NOT
# folded in here — it is a property of the defender the cohort normalization would mostly
# wash out, and the criterion measures MY expression, not their evasion.
static func outgoing_mass(state: BoardState) -> float:
	var t_ref := target_speed_ref(state, 0)
	var total := 0.0
	for u: BoardState.UnitState in state.units(1):
		total += float(u.attack * u.strikes) * delivery(state, u) * crit_expect(u, t_ref)
	return total


# A spent tap ≡ a spent attack (tap-abilities contract): a tapped unit swings nothing this
# round, so its stat is nearly worthless to THIS turn's output — capped hard rather than
# zeroed, because the stat itself survives into future turns (a buff on a tapped body is
# wasted this round, not forever). This is what prices the act of tapping: an ability whose
# cast taps its holder pays the holder's own capped output inside the candidate's score,
# so "is this worth my tap" is part of every ability's evaluation.
const TAP_DELIVERY_FACTOR := 0.1


# How much of this unit's attack stat it will live to convert, 0..1. Combat is
# speed-ordered, so the share of player threat SLOWER than the unit cannot pre-empt its
# first strike — that share of the round is insured; the rest hangs on survival
# (persistence = 1 − urgency, which already folds health, shield, cover and the actual
# threat facing the unit). A tapped unit is hard-capped: its swing this round is already
# spent (see TAP_DELIVERY_FACTOR).
static func delivery(state: BoardState, unit: BoardState.UnitState) -> float:
	var first := first_strike_share(state, unit)
	var persistence := 1.0 - urgency(state, unit)
	var base := first + (1.0 - first) * persistence
	if unit.exhausted:
		return base * TAP_DELIVERY_FACTOR
	return base


# The fraction of the OPPOSING side's fielded attack mass strictly slower than this unit —
# a static stat comparison, never "X will attack Y". Open mana is excluded on purpose: it
# has no speed stat, and its pressure already reaches persistence through urgency. No
# fielded attack at all means nothing can pre-empt anything — fully insured. Side-aware:
# delivery is measured for player units too, so the comparison reads whichever army
# opposes the unit.
static func first_strike_share(state: BoardState, unit: BoardState.UnitState) -> float:
	var total := 0.0
	var slower := 0.0
	for u: BoardState.UnitState in state.units(1 - unit.owner):
		var mass := float(u.attack * u.strikes)
		total += mass
		if u.speed < unit.speed:
			slower += mass
	if total <= 0.0:
		return 1.0
	return slower / total


# ── dodge / crit expectation ───────────────────────────────────────────────────────────
#
# The Resolver's dodge and crit rules folded into the scorer's damage model as EXPECTED
# VALUE — closed-form arithmetic over the same data-driven tuning the fight resolves with
# (combat_tuning.json via Resolver.dodge_tuning / crit_tuning), no rolls. This is not a
# new value channel: it is a CORRECTION to incoming() — a speed-5 unit in a slot does not
# actually absorb what a speed-1 unit there would, and the model should not believe it
# does. Flows into persistence (and everything downstream) by construction.
#
# Not 1:1 with the Resolver, in exactly two ways, both deliberate:
#   · the PAIRWISE speed-edge terms (dodge: target − attacker; crit: attacker − target)
#     are measured against ONE aggregate reference speed per side, because the no-pairing
#     doctrine (design 17b) forbids attacker↔target matching. The references are chosen
#     by whose damage they stand for: a side's damage is thrown at its attack-mass-
#     weighted mean speed, and lands on targets around its exposure-weighted mean speed
#     (the same shares incoming() apportions by).
#   · the interception pass (relics rewriting a dodge/crit query per-strike) is invisible
#     to the static model; the flat per-unit bonuses (dodge_bonus etc.) ARE captured.
# The determinism switches are honored: with a mechanic disabled (the regression
# harness's default), its expectation factor is exactly neutral — the scorer never
# believes in a rule the fight will not roll.

# The speed a side's damage is thrown at: attack-mass-weighted mean speed of its fielded
# units (a 0-attack body's speed says nothing about the damage). 0 when the side projects
# no mass — there is then no unit-thrown damage for a dodge edge to measure against.
static func attack_speed_ref(state: BoardState, side: int) -> float:
	var mass := 0.0
	var acc := 0.0
	for u: BoardState.UnitState in state.units(side):
		var m := float(u.attack * u.strikes)
		mass += m
		acc += m * float(u.speed)
	return acc / mass if mass > 0.0 else 0.0


# The speed a side's damage tends to LAND on: exposure-weighted mean speed of the side's
# fielded units — weighted by the same geometry incoming() apportions damage with, so the
# crit edge is judged against who actually absorbs the hits.
static func target_speed_ref(state: BoardState, side: int) -> float:
	var total := 0.0
	var acc := 0.0
	for u: BoardState.UnitState in state.units(side):
		var e := exposure_of(state, side, u.row, u.col)
		total += e
		acc += e * float(u.speed)
	return acc / total if total > 0.0 else 0.0


# This unit's chance (0..1) to dodge a strike thrown at `attacker_speed` —
# Resolver.dodge_chance's formula on snapshot data: buildings never dodge; fixed +
# per-speed + one-sided speed-edge + the unit's own dodge_bonus; capped at max_pct.
static func dodge_expect(u: BoardState.UnitState, attacker_speed: float) -> float:
	if not Resolver.dodge_enabled or u.is_building:
		return 0.0
	var cfg := Resolver.dodge_tuning()
	var spd := float(u.speed)
	var pct := float(cfg["fixed_pct"]) + float(cfg["per_speed_pct"]) * spd
	var edge := spd - attacker_speed
	if edge > 0.0:
		pct += float(cfg["per_speed_diff_pct"]) * edge
	pct += float(u.dodge_bonus)
	return clampf(minf(pct, float(cfg["max_pct"])), 0.0, 100.0) / 100.0


# The expected-damage multiplier this unit's crits add against targets around
# `target_speed`: 1 + chance × (multiplier − 1). Mirrors Resolver.crit_chance /
# crit_multiplier on snapshot data (fixed + per-speed + one-sided edge + the unit's own
# bonuses, both capped). Never below 1 — a crit only ever adds.
static func crit_expect(u: BoardState.UnitState, target_speed: float) -> float:
	if not Resolver.crit_enabled:
		return 1.0
	var cfg := Resolver.crit_tuning()
	var spd := float(u.speed)
	var pct := float(cfg["fixed_pct"]) + float(cfg["per_speed_pct"]) * spd
	var edge := spd - target_speed
	if edge > 0.0:
		pct += float(cfg["per_speed_diff_pct"]) * edge
	pct += float(u.crit_chance_bonus)
	var chance := clampf(minf(pct, float(cfg["max_pct"])), 0.0, 100.0) / 100.0
	var mult := clampf(float(cfg["multiplier"]) + float(u.crit_multiplier_bonus) / 100.0,
			1.0, float(cfg["multiplier_max"]))
	return 1.0 + chance * (mult - 1.0)


# The damage `side` should EXPECT to absorb this round — the valuation pass's refined
# threat (pass 2 only; threat_against stays the naive form): each opposing attacker's
# mass is discounted by what it will live to throw (delivery — damage a dead unit never
# lands isn't damage) and raised by its expected crits. Player open mana rides on top for
# the CPU side exactly as in threat_against, undiscounted by delivery (it has no body to
# kill before it swings) — under the melee doctrine it then splits and dodges through the
# quota like every other part of the mass (incoming_allocation).
# Delivery reads pass-1 urgencies (naive quota), so this never recurses.
static func expected_threat_against(state: BoardState, side: int) -> float:
	var t_ref := target_speed_ref(state, side)
	var total := float(state.player_mana) * MANA_THREAT_RATE if side == 1 else 0.0
	for u: BoardState.UnitState in state.units(1 - side):
		total += unit_threat_out(state, u) * delivery(state, u) * crit_expect(u, t_ref)
	return total


# ── board value (the parked board-value quirk's currency) ──────────────────────────────
#
# What one unit is worth in the eval's common currency: stats at the authored exchange
# rates plus fixed equivalences for its abilities and effect categories — ALL numbers
# tool-authorable through BoardValueConfig (data/board_value.json). Cost says what a unit
# COSTS; this says what it IS. All future shaping (diminishing returns, per-role
# multipliers) happens inside these two functions, invisible to the criterion.
# `pricer` is the fight's PERSONALITY, which carries its own partial price list layered
# over the global one. Null means the global config alone — what a lone measurement
# outside a fight reads.
static func unit_value(u: BoardState.UnitState, pricer: EnemyPersonality = null) -> float:
	var v := float(u.attack * u.strikes) * _stat_rate(pricer, "attack")
	v += float(u.health) * _stat_rate(pricer, "health")
	v += float(u.max_health - u.health) * _stat_rate(pricer, "missing_health")
	v += float(u.shield) * _stat_rate(pricer, "shield")
	v += float(u.speed) * _stat_rate(pricer, "speed")
	for id: String in u.ability_ids:
		v += _ability_value(pricer, id)
	return v


# The two price lookups, in one place: a personality prices it if there is one, otherwise the
# global config does. Every value measurement goes through these — never BoardValueConfig
# directly, or a per-encounter price list would be silently ignored on that line.
static func _stat_rate(pricer: EnemyPersonality, key: String) -> float:
	return pricer.stat_rate(key) if pricer != null else BoardValueConfig.stat_rate(key)


static func _ability_value(pricer: EnemyPersonality, id: String) -> float:
	return pricer.ability_value(id) if pricer != null else BoardValueConfig.ability_value(id)


# The net battlefield: own units add, player units subtract. Signed on purpose — a rich
# player board IS a poor position, and killing or wounding player units raises the total
# exactly like fielding raises it.
static func board_value(state: BoardState, pricer: EnemyPersonality = null) -> float:
	var total := 0.0
	for u: BoardState.UnitState in state.units(1):
		total += unit_value(u, pricer)
	for u: BoardState.UnitState in state.units(0):
		total -= unit_value(u, pricer)
	return total


# ── the valuation pass (canon for every value eval) ────────────────────────────────────
#
# Runs ONCE per state, before any eval (BoardScoring._value): prices every unit on BOTH
# sides in two stages and stamps the results onto the state. Any eval that needs to know
# what something is worth reads the stamped values — never its own arithmetic.
#
#   1. RAW VALUE — what the unit DOES, current health irrelevant: stats at the authored
#      exchange rates (attack × strikes full; MAX health and shield at MINIMAL rates —
#      the pool is the carrier, priced by persistence, not the payload; speed half), its
#      abilities and effect categories, and arbitrary per-card enhancers (unit_values,
#      keyed by card id). ROLE TAGS are deliberately not consulted (parked — roles unfold
#      from stats; HVT protection is a future eval). All rates live in BoardValueConfig /
#      data/board_value.json and a personality may re-price any of them per fight.
#   2. PERSISTENCE — how likely the unit is to survive the turn: current health + shield
#      against its expected incoming share under the refined damage model (attacker
#      delivery, crit expectation, defender dodge — see run_valuation). The discount is
#      dialed by ONE tunable, persistence_weight (0..1):
#          value = raw × lerp(1, persistence, dial)
#      0 = fragility is ignored (a dying queen is still a queen); 1 = full discount (a
#      doomed unit is worth nearly nothing). THE dial for how much low health / expected
#      damage lowers unit valuation — tool-authorable, per-personality overridable.

# What the unit IS, before asking whether it survives. Deliberately blind to current
# health — the wound is persistence's business, not worth's. Raw value prices the
# PAYLOAD, not the carrier: health/shield rates are minimal (their real worth — absorbing
# damage — is persistence's job, and pricing the pool here too would double-count it into
# every other stat), and ROLE TAGS are not consulted at all (roles unfold naturally from
# stats: a tank reads as a big cheap absorber because that is what its sheet says;
# protecting high-value targets is a future eval's own concern).
static func raw_unit_value(u: BoardState.UnitState, pricer: EnemyPersonality = null) -> float:
	var atk := float(u.attack * u.strikes) * _stat_rate(pricer, "attack")
	# A spent tap is a spent swing HERE TOO: the valuation is a this-turn instrument, and
	# this turn a tapped unit's attack delivers almost nothing — same hard cap delivery
	# uses, one constant. A tap-blind attack stock ties fresh and tapped buff targets and
	# lets buff targeting fall to target safety (often the sheltered tapped body). Next
	# turn's re-valuation restores the untapped worth — the discount is the round, not the
	# sword.
	if u.exhausted:
		atk *= TAP_DELIVERY_FACTOR
	var v := atk
	v += float(u.max_health) * _stat_rate(pricer, "health")
	v += float(u.shield) * _stat_rate(pricer, "shield")
	v += float(u.speed) * _stat_rate(pricer, "speed")
	for id: String in u.ability_ids:
		v += _ability_value(pricer, id)
	v += _unit_bonus(pricer, u.card_id)
	return v


# How likely the unit is to still be standing after the turn, 0..1 — urgency mirrored
# (current health + shield vs expected incoming). This is the pass's FIRST reading only
# (raw threat, no expectation model); the persistence the stamp carries is the refined
# second pass inside run_valuation. Kept public as the naive vocabulary — the parked
# quirks and delivery() read the same raw urgency underneath.
static func persistence(state: BoardState, u: BoardState.UnitState) -> float:
	return 1.0 - urgency(state, u)


# The whole pass: every unit on both sides gets raw → persistence → value, and the state
# gets the signed total (own side positive, player side negative — a rich player board IS
# a poor position). Stamps `valued` so the pass runs once per state; every mutation path
# hands back an unvalued state (BoardState.copy / CandidateApply._capture_back).
#
# TWO PASSES (the expected-damage model). Raw threat pretends every attacker lands
# everything: a unit that dies before it swings still projects its full mass, so the CPU
# would be paid for damage that can never happen and cower from corpses. Instead:
#   PASS 1 (implicit): delivery() reads naive-quota urgencies — how likely each
#     ATTACKER is to live to throw its damage. Seeding the refinement with the naive
#     reading is what cuts the recursion (my delivery depends on your threat, which
#     would depend on my delivery, …) — one refinement step, no fixpoint.
#   PASS 2: each side's incoming is the REFINED quota (incoming_allocation with the
#     delivery-discounted, crit-raised mass, dodge folded per body) — then urgency,
#     persistence and value follow as before. Since the melee doctrine every part of the
#     mass, mana included, splits and dodges the same way.
static func run_valuation(state: BoardState, pricer: EnemyPersonality = null) -> void:
	var dial := _persistence_factor(pricer)
	var total := 0.0
	for side in 2:
		var trace: Dictionary = {"units": []}
		var landed := incoming_allocation(state, side, false, trace)
		# The blast caps LANDED at each pool, so the lethality RATIO must read AIMED —
		# the dodge-discounted pressure a seat draws, uncapped by what the body could
		# absorb. Landed says what is lost (persistence); aimed says how far past dead
		# the seat is (loss_ratio — the judge's and the surrender verdict's number).
		var pressure: Dictionary = {}
		for rec: Dictionary in (trace["units"] as Array):
			pressure[rec["unit"]] = float(rec["aimed"]) * (1.0 - float(rec["dodge"]))
		for u: BoardState.UnitState in state.units(side):
			u.raw_value = annotated_raw_value(state, u, pricer)
			var inc := exposed_incoming(state, u, float(landed.get(u, 0.0)))
			var life := u.health + u.shield
			var urg := 1.0 if life <= 0 else clampf(inc / float(life), 0.0, 1.0)
			u.loss_ratio = INF if life <= 0 else \
					exposed_incoming(state, u, float(pressure.get(u, 0.0))) / float(life)
			u.persistence = 1.0 - urg
			u.value = u.raw_value * lerpf(1.0, u.persistence, dial)
			total += u.value if side == 1 else -u.value
	state.value_total = total
	state.valued = true
	state.valued_by = pricer


# The valuation pass's price lookups — same personality-over-global layering as
# _stat_rate / _ability_value. (Role tags are parked out of the valuation;
# BoardValueConfig.role_value survives as the parked mechanism's accessor.)
static func _persistence_factor(pricer: EnemyPersonality) -> float:
	return pricer.persistence_factor() if pricer != null else BoardValueConfig.persistence_weight()


static func _unit_bonus(pricer: EnemyPersonality, card_id: String) -> float:
	return pricer.unit_bonus(card_id) if pricer != null else BoardValueConfig.unit_bonus(card_id)


# ── readiness (the tap counterweight) ─────────────────────────────────────────────────

# Everything a unit could do this round if left alone, in board-value currency: its swing
# plus every ability a tap would close. Non-tap abilities are excluded (they keep working
# once the unit is exhausted, so a tap does not spend them); passives too — they run
# regardless. Rates come from BoardValueConfig, so this stays tool-authored like every
# other number in the value currency.
static func activity_potential(u: BoardState.UnitState, pricer: EnemyPersonality = null) -> float:
	var p := float(u.attack * u.strikes) * _stat_rate(pricer, "attack")
	for id: String in u.ability_ids:
		var ab := AbilityData.get_ability(id)
		if ab != null and ab.tap:
			p += _ability_value(pricer, id)
	return p


# The best single tap-ability the unit holds — what one tap can actually buy.
static func best_tap_ability(u: BoardState.UnitState, pricer: EnemyPersonality = null) -> float:
	var best := 0.0
	for id: String in u.ability_ids:
		var ab := AbilityData.get_ability(id)
		if ab != null and ab.tap:
			best = maxf(best, _ability_value(pricer, id))
	return best


# What a spent tap COST this unit: its attack for the round plus every OTHER ability it
# holds — never the ability the tap bought, which was used, not lost (the user's exact
# model). A tap can only ever buy one ability, so crediting the unit's best one is the
# faithful reading: a one-ability unit that taps forfeits only its swing, while silencing
# a deep toolkit costs the whole rest of it. Untapped units forfeit nothing.
static func tap_forfeit(u: BoardState.UnitState, pricer: EnemyPersonality = null) -> float:
	if not u.exhausted:
		return 0.0
	return maxf(0.0, activity_potential(u, pricer) - best_tap_ability(u, pricer))


# How much of the CPU side's activity survives, 0..1 (1 = nothing forfeited). Proportional
# on purpose: tapping your only unit spends all of your turn's agency, tapping one of
# eight spends an eighth — a tap should cost in proportion to how much of the army it
# silences. A side with nothing to activate reads 1 (nothing to lose).
static func readiness(state: BoardState, pricer: EnemyPersonality = null) -> float:
	var total := 0.0
	var forfeited := 0.0
	for u: BoardState.UnitState in state.units(1):
		total += activity_potential(u, pricer)
		forfeited += tap_forfeit(u, pricer)
	if total <= 0.0:
		return 1.0
	return 1.0 - forfeited / total


# ── idle hand (the "never withhold a unit" criterion) ──────────────────────────────────

# How many placeable units the CPU is holding that it COULD put on the board right now —
# the count, not a fraction: withholding two bodies is twice the offence, and the whole
# point of this criterion is that the charge never gets diluted (a plain sum over
# withheld cards, exactly as DeathRisk is a plain sum over endangered units).
#
# "Could play" is read narrowly and only from what the state actually knows:
#   · the card is a placeable unit — spells and kings never enter hand_unit_costs;
#   · the CPU could afford it out of the pool THIS PICK STARTED WITH (hand_budget_before,
#     never the mana left — read against the mana left, any spend drains the pool, makes
#     the held body unaffordable and the charge disappear, excusing the withholding);
#   · there is somewhere to put it — a full board is not withholding.
# THE WAIVER: a choice that SPENDS MANA is never charged. Without it the criterion
# punishes ability use — a heal costs a tap and a mana but leaves the hand untouched, so
# it would carry the full charge and lose every argument to fielding a body. What is
# forbidden is IDLENESS while holding a playable unit, not preferring one paid play over
# another: the charge falls only on choices that spend nothing — declining, and free
# repositioning.
#
# The fielding pressure survives the waiver because the greedy loop asks once per action:
# a turn that spends its mana on a heal comes straight back to a pick where the body is
# still in hand, and there the placement is competing against declining, which IS charged.
# So the unit still goes down — just not necessarily before the heal.
#
# Nothing here judges whether the play is GOOD; that is what the other criteria are for.
static func idle_hand(state: BoardState) -> float:
	if state.mana_spent_step > 0:
		return 0.0
	if state.hand_unit_costs.is_empty() or state.empty_slots(1).is_empty():
		return 0.0
	var idle := 0.0
	for c: Variant in state.hand_unit_costs:
		if int(c) <= state.hand_budget_before:
			idle += 1.0
	return idle


# ── mana optimization (the "use your mana" criterion) ──────────────────────────────────

# How well THIS CHOICE uses the mana pool, 0..1.
# THE INVARIANT (pinned by tests — see the enemy-engine suite, "THE INVARIANT"):
# SPENDING MANA ALWAYS SCORES STRICTLY ABOVE SPENDING NONE. A tie is a failure, because
# the engine requires strict improvement — equal-to-declining means the unit is never
# played, which is the withholding bug in every one of its disguises. The ratio below
# guarantees it structurally: a spending choice's numerator is at least its own cost, so
# its score can never reach zero, while declining is exactly zero.
#
#   · a choice that spends nothing → 0 (declining expresses nothing — this is what every
#     successive placement decision beats, which is the whole fielding pressure);
#   · otherwise → what this choice's LINE will consume (its own cost plus the most any
#     continuation can still spend) ÷ the most ANY line could have consumed from the
#     position this pick started in.
#
# That denominator is the load-bearing part: waste is only waste when a better line
# EXISTED. Never judge leftover mana in absolute terms — a real hand holds cards the CPU
# cannot yet afford, and with one of those lingering the leftover always looks stranded,
# so the last affordable play scores no better than declining and the unit stays in hand.
# Measured counterfactually, that leftover was never spendable by anyone, so playing the
# last affordable card is an optimal line and scores 1.
#
# The anchors, all falling out of the one ratio with no special cases:
#   · spend the whole pool                        → 1
#   · spend some, remainder still fully usable    → 1 (equal — only waste is punished)
#   · mana beyond what all options could cost     → 1 (abundance, not waste)
#   · squander a big spend on a small one         → low (5 mana, options 1 and 5: taking
#     the 1 consumes 1 of a possible 5 → 0.2)
#   · greedy combo blindness                      → cured (5 mana, options 2/3/4: the 4
#     strands 1 → 0.8, while the 3 or the 2 keep a perfect line → 1)
# Reads the engine-stamped mana story; a state scored outside a planning turn (total 0)
# is a constant, invisible to any ranking.
static func mana_optimization(state: BoardState) -> float:
	if state.enemy_mana_total <= 0 or state.mana_spent_step <= 0:
		return 0.0
	var capacity := state.mana_capacity_before
	if capacity <= 0:
		return 1.0   # nothing was ever spendable — any spend is an optimal line
	var achieved := state.mana_spent_step + spend_capacity(state)
	return clampf(float(achieved) / float(capacity), 0.0, 1.0)


# The most mana some subset of the still-playable options can consume from this state —
# the "best remaining line" figure both sides of the ratio above are built from.
static func spend_capacity(state: BoardState) -> int:
	if state.enemy_mana_left <= 0:
		return 0
	return largest_fit(option_costs(state), state.enemy_mana_left)


# The mana costs of everything the CPU still HAS to play from this state — hand cards
# plus untapped units' ability costs. LOOSE by design: any legal play counts, with no
# judgment of whether it is worth making; escalate only if it misbehaves. Not filtered by
# affordability — largest_fit skips whatever does not fit, and mana_optimization's
# counterfactual ratio already handles a card the CPU cannot yet pay for.
static func option_costs(state: BoardState) -> Array:
	var costs: Array = []
	for c: Variant in state.hand_costs:
		if int(c) > 0:
			costs.append(int(c))
	for u: BoardState.UnitState in state.units(1):
		for ab_id: String in u.ability_ids:
			var ab := AbilityData.get_ability(ab_id)
			if ab == null or ab.mana <= 0:
				continue
			if not ab.ready(u.exhausted):
				continue
			costs.append(ab.mana)
	return costs


# The largest total ≤ capacity that some subset of these costs adds up to — subset-sum
# over tiny integers as a bitset walk.
static func largest_fit(costs: Array, capacity: int) -> int:
	if capacity <= 0:
		return 0
	var reachable: Array = []
	reachable.resize(capacity + 1)
	reachable.fill(false)
	reachable[0] = true
	var best := 0
	for cost: Variant in costs:
		var ci := int(cost)
		for m in range(capacity, ci - 1, -1):
			if bool(reachable[m - ci]) and not bool(reachable[m]):
				reachable[m] = true
				if m > best:
					best = m
	return best
