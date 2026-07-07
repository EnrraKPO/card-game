class_name ModifierSet
extends RefCounted

# The aggregate of every active Effect for the current run — the run-wide counterpart to a
# CardInstance's `modifiers` dict. Built by collecting effects from any source (owned profile
# upgrades now; relics, hero/King effects later). It only AGGREGATES and routes by kind:
# global MODIFIERs feed the resolver (GameData.value); card MODIFIERs feed read-time
# CardInstance resolution; TRIGGERED/CUSTOM feed run-level combat dispatch. A fresh, empty
# set is a valid no-op.

var _mods: Array = []   # Array[Effect]


# Gathers the effects contributed by a profile's OWNED upgrade nodes across all trees.
static func from_profile(profile: ProfileData) -> ModifierSet:
	var s := ModifierSet.new()
	if profile == null:
		return s
	for tree: UpgradeTree in UpgradeTree.all():
		for node: UpgradeNode in tree.nodes:
			if profile.owns_upgrade(node.id):
				s._mods.append_array(node.effects)
	return s


# The full active set for a live run: the profile's owned upgrades PLUS the run's relics. Both
# sources contribute plain Effects, so they aggregate into the one set with no special-casing.
static func for_run(profile: ProfileData, run: RunData) -> ModifierSet:
	var s := from_profile(profile)
	if run != null:
		for relic_id: String in run.relics:
			var relic := RelicData.get_relic(relic_id)
			if relic != null:
				s._mods.append_array(relic.effects)
	return s


func add(e: Effect) -> void:
	_mods.append(e)


# Summed delta of all GLOBAL MODIFIER effects for a key. The resolver (GameData.value_f) adds
# this to the registry default.
func total_add(key: String) -> float:
	var sum := 0.0
	for e: Effect in _mods:
		if e.kind == Effect.Kind.MODIFIER and e.scope == Effect.Scope.GLOBAL and e.key == key:
			sum += e.amount
	return sum


# The run set's STANDING effects — enumerated by LiveEffects (the one read-time evaluator)
# alongside every other container's. This class only aggregates; it no longer evaluates.
func standing() -> Array:
	var out: Array = []
	for e: Effect in _mods:
		if e.is_standing():
			out.append(e)
	return out


# Active TRIGGERED/CUSTOM effects listening to an event — the run-level dispatch list
# (see EffectSystem.trigger_global; the full activation gate runs there via the resolver).
func triggered(event_id: StringName) -> Array:
	var out: Array = []
	for e: Effect in _mods:
		if (e.kind == Effect.Kind.TRIGGERED or e.kind == Effect.Kind.CUSTOM) \
				and e.trigger_resolver().listens(event_id):
			out.append(e)
	return out
