class_name TriggeredEffect
extends RefCounted

# The action structure that REACTS (TARGETING_DESIGN.md §1-2): *when [trigger], to
# [targets]* — and, once a sanctioned form exists again, what happens to them. One
# TriggerResolver (the anchor — dispatch asks it "do you fire?") and at most one
# LegacyTargetResolver (null = targetless).
#
# ⚠ THE CONSEQUENCE HALF IS GONE (2026-08-14 ruling): Payload and Mutator were
# vaporized as cursed, and the effect no longer carries anything that happens. An
# effect currently says only WHEN and to WHOM. Nothing replaces them until a form is
# pitched and signed.
#
# Stateless and immutable after parse — one instance serves every fielded copy of its
# container; runtime facts arrive from the machinery that runs it at the moment it runs.
#
# Authoring (the native dictionary form):
#   { "id": "<name>",                       # named-effect id ("" for inline effects)
#     "trigger": { ...TriggerResolver... },
#     "targets": { ...LegacyTargetResolver... },  # absent = targetless
#     "windup_presentation": "<name>",      # optional appointment (absent = default)
#     "contact_presentation": "<name>" }    # optional appointment (absent = default)

var id: String = ""                     # the named-effect id; "" for an inline effect
var trigger: TriggerResolver = null
var targets: LegacyTargetResolver = null      # null = targetless
# The two appointed presentation names (signed EFFECT_PRESENTATION_DESIGN.html §3/§8):
# each is a plain name into data/presentations.json — a word, not a structure — so
# naming them reveals nothing of the effect's insides. "" = unappointed; the defaults
# of §4 fill the slot at resolution (see the two _id() methods below).
var windup_presentation: String = ""
var contact_presentation: String = ""


# The effect speaking outward (§8): each resolved presentation name — appointed, or
# default — through one method apiece. No caller ever reaches in. The windup's default
# is the shared glint; the contact falls to the effect's own name when the library
# defines one, else to the default landing (§4 as amended a2).
func windup_presentation_id() -> String:
	return windup_presentation if not windup_presentation.is_empty() else "glint"


func contact_presentation_id() -> String:
	if not contact_presentation.is_empty():
		return contact_presentation
	if not id.is_empty() and PresentationLibrary.has_contact(id):
		return id
	return "default_landing"


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
		e.targets = LegacyTargetResolver.parse(d.get("targets"))
		if e.targets == null:
			return null
	if d.has("repeats"):
		push_error("TriggeredEffect: 'repeats' is deleted (nuked 2026-08-12) — refusing")
		return null
	# An appointment must name a defined presentation — a stranger poisons the effect,
	# the same loud refusal as every other malformed member.
	e.windup_presentation = str(d.get("windup_presentation", ""))
	if not e.windup_presentation.is_empty() and not PresentationLibrary.has_windup(e.windup_presentation):
		push_error("TriggeredEffect: appointed windup '%s' is not in data/presentations.json — refusing"
				% e.windup_presentation)
		return null
	e.contact_presentation = str(d.get("contact_presentation", ""))
	if not e.contact_presentation.is_empty() and not PresentationLibrary.has_contact(e.contact_presentation):
		push_error("TriggeredEffect: appointed contact '%s' is not in data/presentations.json — refusing"
				% e.contact_presentation)
		return null
	return e


func to_dict() -> Dictionary:
	var d := {"trigger": trigger.to_dict()}
	if not id.is_empty():
		d["id"] = id
	if targets != null:
		d["targets"] = targets.to_dict()
	if not windup_presentation.is_empty():
		d["windup_presentation"] = windup_presentation
	if not contact_presentation.is_empty():
		d["contact_presentation"] = contact_presentation
	return d
