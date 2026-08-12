class_name TriggeredEffect
extends RefCounted

# The action structure that REACTS (TARGETING_DESIGN.md §1-2, signed
# ATTACK_SYSTEM_DESIGN.html): *when [trigger], deliver [payloads] to [targets]*. One
# TriggerResolver (the anchor — dispatch asks it "do you fire?"), at most one
# TargetResolver (one resolution shared by every payload — sharing the outcome's
# IDENTITY is what makes "deal 3 to a random enemy and stun IT" expressible; null =
# targetless, the payloads name their own recipients), and N Payloads.
#
# Stateless and immutable after parse — one instance serves every fielded copy of its
# container; all runtime facts arrive through the ActionExecutor's Feed.
#
# Authoring (the native dictionary form):
#   { "id": "<name>",                       # named-effect id ("" for inline effects)
#     "trigger": { ...TriggerResolver... },
#     "targets": { ...TargetResolver... },  # absent = targetless
#     "payloads": [ { ...Payload... }, ... ] }

var id: String = ""                     # the named-effect id; "" for an inline effect
var trigger: TriggerResolver = null
var targets: TargetResolver = null      # null = targetless
var payloads: Array = []                # Array[Payload]
# CONDITIONALLY SANCTIONED (signature note, 2026-08-12 — revisited when any other effect
# needs a follow-up): how many times one firing unfolds (resolve-then-deliver), as an
# evaluable value (null = once). Each repeat RE-RESOLVES, which is what preserves the
# playtested flurry rule — a slain victim doesn't soak the follow-ups. nearest_attack
# authors {"kind": "holder_stat", "stat": "strikes"}; the read floors at 1.
var repeats: Mutator = null


# The firing's repeat count, derived fresh at dispatch (floors at 1 — a debuffed stat
# never cancels the act outright).
func repeat_count(feed: Feed) -> int:
	if repeats == null:
		return 1
	return maxi(1, int(repeats.derive(feed)))


# The one authored form. A malformed member poisons the whole effect — refused loudly,
# never half-loaded.
static func parse(effect_value: Variant) -> TriggeredEffect:
	if not (effect_value is Dictionary):
		push_error("TriggeredEffect: '%s' is not the native effect form — refusing" % str(effect_value))
		return null
	var d := effect_value as Dictionary
	var e := TriggeredEffect.new()
	e.id = str(d.get("id", ""))
	e.trigger = TriggerResolver.parse(d.get("trigger"))
	if e.trigger == null:
		return null
	if d.has("targets"):
		e.targets = TargetResolver.parse(d.get("targets"))
		if e.targets == null:
			return null
	for p_data: Variant in (d.get("payloads", []) as Array):
		var p := Payload.parse(p_data)
		if p == null:
			return null
		e.payloads.append(p)
	if d.has("repeats"):
		e.repeats = Mutator.parse(d.get("repeats"))
		if e.repeats == null:
			return null
	return e


func to_dict() -> Dictionary:
	var d := {"trigger": trigger.to_dict()}
	if not id.is_empty():
		d["id"] = id
	if targets != null:
		d["targets"] = targets.to_dict()
	if not payloads.is_empty():
		var pl: Array = []
		for p: Payload in payloads:
			pl.append(p.to_dict())
		d["payloads"] = pl
	if repeats != null:
		d["repeats"] = repeats.to_dict()
	return d
