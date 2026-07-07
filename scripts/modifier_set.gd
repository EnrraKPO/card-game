class_name ModifierSet
extends RefCounted

# The aggregate of every active Effect for the current run — the run-wide counterpart to a
# CardInstance's `modifiers` dict. Built by collecting effects from any source (owned profile
# upgrades now; relics, hero/King effects later). It only AGGREGATES and routes by kind:
# global MODIFIERs feed the resolver (GameData.value); card MODIFIERs feed read-time
# CardInstance resolution; TRIGGERED/CUSTOM feed run-level combat dispatch. A fresh, empty
# set is a valid no-op.

var _mods: Array = []   # Array[Effect]
# Which container contributed each effect ({"kind": String, "id": String} by Effect) —
# DISPATCH CONTEXT for presentation (glint the right relic chip), recorded here because
# effects are container-blind by design and never carry their origin themselves.
var _owners: Dictionary = {}


# Gathers the effects contributed by a profile's OWNED upgrade nodes across all trees.
static func from_profile(profile: ProfileData) -> ModifierSet:
	var s := ModifierSet.new()
	if profile == null:
		return s
	for tree: UpgradeTree in UpgradeTree.all():
		for node: UpgradeNode in tree.nodes:
			if profile.owns_upgrade(node.id):
				for e: Effect in node.effects:
					s._add_owned(e, "upgrade", node.id)
	return s


# The full active set for a live run: the profile's owned upgrades PLUS the run's relics. Both
# sources contribute plain Effects, so they aggregate into the one set with no special-casing.
static func for_run(profile: ProfileData, run: RunData) -> ModifierSet:
	var s := from_profile(profile)
	if run != null:
		for relic_id: String in run.relics:
			var relic := RelicData.get_relic(relic_id)
			if relic != null:
				for e: Effect in relic.effects:
					s._add_owned(e, "relic", relic_id)
	return s


func add(e: Effect) -> void:
	_add_owned(e, "run", "")


func _add_owned(e: Effect, owner_kind: String, owner_id: String) -> void:
	_mods.append(e)
	_owners[e] = {"kind": owner_kind, "id": owner_id}


# The contributing container of an effect in this set — consumed by the grouped run-level
# dispatch so combat can cue the owner (relic chip) before its effects' VFX.
func owner_of(e: Effect) -> Dictionary:
	return _owners.get(e, {"kind": "run", "id": ""})


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
