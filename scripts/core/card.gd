class_name Card
extends GameEntity

# A Card (Core System Design §1, §5): the base of the two kinds, Unit and Spell. Its
# machinery: the play effect and the payability query. Its stat: `cost`, seeded from
# the authored form at construction and mutable through the write road like any stat —
# discounts and surcharges are ordinary stat mutations.
#
# The play effect, composed here: trigger — event `play`, source the played card (the
# route-source + is_holder entry binds it); conditions affordability and holder-in-hand,
# both baked. Targeting: authored, or the type fact where none is authored — Card
# defaults to automatic targeting of the Game; Unit overrides to a manual pick of a
# Slot; a declined pick ends the play unpaid. Payload: the pay mutator — unique, runs
# once before the walk, recipient the holder's side — then the card's substantive
# mutators, routed through the effect's target resolver. The payment produces
# `play_engaged`.
#
# The play effect carries the implied fielded condition REMOVED: its duty is asked of a
# card in hand (B28).

var play_effect: Effect = null

# Composition (A7's envelope birth fact; T1): the card's elements, stamped at build
# from the envelope and never rewritten — an immutable birth fact at this scope.
var elements: Array[StringName] = []

# One play effect per TYPE, not per card: the machinery is stateless and shared across
# card copies and simulated worlds (Mutation §4's lifecycle) — built once per concrete
# class (the targeting default is the type fact that differs).
static var _play_templates: Dictionary = {}


func _init(p_allegiance: Side = null) -> void:
	super._init(p_allegiance)
	var key: Script = get_script()
	if not Card._play_templates.has(key):
		Card._play_templates[key] = _build_play_effect()
	play_effect = Card._play_templates[key]
	effects.append(play_effect)


func _build_play_effect() -> Effect:
	return compose_play_effect(null, [] as Array[Mutator])


# The play effect whole (Core §5): the fixed trigger, the authored targeting or
# the type fact where null, and the payload — pay, then the type's baked substantive
# mutators (a unit's placement, Core §6), then the authored substantive mutators.
func compose_play_effect(targeting: TargetResolver, substantive: Array[Mutator],
		windup: StringName = &"", contact: StringName = &"") -> Effect:
	var trigger := Trigger.new()
	trigger.event = &"play"
	trigger.entity_entries.append(Ability.source_is_holder())
	var holder_entry := Trigger.EntityEntry.new()
	holder_entry.route = &"holder"
	holder_entry.conditions.append(BakedConditions.Affordability.new(-1, 0))
	holder_entry.conditions.append(BakedConditions.InHand.new())
	trigger.entity_entries.append(holder_entry)
	var payload: Array[Mutator] = []
	payload.append(PayMutator.new(-1, 0))
	payload.append_array(_baked_substantive())
	payload.append_array(substantive)
	var effect := Effect.new(trigger,
			targeting if targeting != null else _default_play_targeting(), payload)
	effect.windup_presentation = windup
	effect.contact_presentation = contact
	effect.fielded_condition_removed = true
	return effect


# Replaces the type-default play effect with a composed one (the envelope's authored
# play, Core §5) — the one seat that swaps it.
func adopt_play_effect(effect: Effect) -> void:
	effects.erase(play_effect)
	play_effect = effect
	effects.append(effect)


# The type's baked substantive mutators (Core §6): none on the base; Unit bakes its
# placement into the play.
func _baked_substantive() -> Array[Mutator]:
	return []


# The type fact (Core §5): a Card targets the Game automatically; Unit overrides.
func _default_play_targeting() -> TargetResolver:
	return TargetResolver.game_default()


# The payability query (Core §1): may this card's play be afforded right now — the
# baked conditions' read, for the previews and the greyout.
func payable() -> bool:
	return BakedConditions.affordable(self, -1, 0) \
			and housing != null and housing.name == &"hand"


func _declared_mutable_stats() -> Array[StringName]:
	var out: Array[StringName] = super._declared_mutable_stats()
	out.append(&"cost")
	return out
