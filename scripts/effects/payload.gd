class_name Payload
extends RefCounted

# The small dumb "what happens" species of an action (TARGETING_DESIGN.md §2, signed
# ATTACK_SYSTEM_DESIGN.html): a payload carries delivery rules only. It does not point
# (the target resolver's job), does not decide when (the trigger's job), and proposes
# every state change to the Arbitrator — never writes one itself.
#
# DELIVERY CONDITIONS (§4.3): each payload gates itself against what was resolved. Kind
# fitness ("I apply to units") is simply a payload's first delivery condition; a payload
# not applying to a recipient is SELECTION, not failure — a mixed-kind resolution feeds
# each payload its own slice. No connivance between payload and resolver, ever.
#
# Species are inner classes of this file (the one-file load-order rule); the roster grows
# with signed initiatives only. Authoring: { "kind": "<species>", ...params }.


# Does this payload apply to this delivery? The base gate is kind fitness; species narrow
# it further as their rules demand.
func applies(_feed: Feed) -> bool:
	return false


# Deliver to the feed's recipient: derive values via the payload's mutators and propose
# StatMutations to the Arbitrator. Nothing comes back (the outcome is ruled out of
# existence — signed EFFECT_PRESENTATION_DESIGN.html amendment 2): each mutation
# announces its presentation and fires its events at its own commit.
func deliver(_feed: Feed) -> void:
	pass


# Native (dictionary) authored form.
func to_dict() -> Dictionary:
	return {}


# The one authored form. Unknown kinds are refused loudly — no permissive default.
static func parse(payload_value: Variant) -> Payload:
	if not (payload_value is Dictionary):
		push_error("Payload: '%s' is not the native payload form — refusing" % str(payload_value))
		return null
	var d := payload_value as Dictionary
	match str(d.get("kind", "")):
		"attack":
			return Attack.parse_attack(d)
	push_error("Payload: unknown payload kind '%s' — refusing (no permissive default)" % str(d.get("kind", "")))
	return null


# ── Species ──────────────────────────────────────────────────────────────────────────

class Attack extends Payload:
	# THE STRIKE (§2: attack is a payload kind, not a ruleset). Owns the attack's delivery
	# rules the way the status payload owns stacking; nothing above it knows attacks are
	# special. The strike mechanics themselves — dodge before interception, the shield
	# split, crit after interception — are the Arbitrator's application knowledge: this
	# payload builds the attack-channel damage proposal and submits it. The amount is a
	# Mutator ("my attack stat" by default — authored explicitly in the named effects).
	var amount: Mutator = null

	static func parse_attack(d: Dictionary) -> Attack:
		var p := Attack.new()
		p.amount = Mutator.parse(d.get("amount"))
		if p.amount == null:
			push_error("Payload.Attack: unparseable amount '%s' — refusing" % str(d.get("amount")))
			return null
		return p

	# A strike lands on a living unit; anything else in the resolution is not this
	# payload's slice.
	func applies(feed: Feed) -> bool:
		var unit := feed.recipient as CardInstance
		return unit != null and unit.is_alive()

	func deliver(feed: Feed) -> void:
		var unit := feed.recipient as CardInstance
		var dmg: int = amount.derive(feed)
		Arbitrator.submit(StatMutation.damage(unit, dmg, feed.holder))

	func to_dict() -> Dictionary:
		return {"kind": "attack", "amount": amount.to_dict()}
