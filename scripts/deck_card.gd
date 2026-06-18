class_name DeckCard
extends RefCounted

# One persistent card in the player's run deck. While unmodified it just references a
# base card id (lean; inherits any rebalance of the base). The moment something changes
# it (e.g. a "?" event), we snapshot the full card definition into `override` and from
# then on the deck card IS that overridden definition — so ANY authorable aspect can be
# changed (stats, description, effects, composition), not a fixed set of stat deltas.
# An override is the same dict schema CardData.build_from_dict / to_dict round-trips, so
# it serialises cleanly and rebuilds through the one card constructor.

# Stats the "?" event offers to raise. (The override model can change any field; this is
# only which ones that particular site exposes.)
const UPGRADABLE := ["attack", "health", "speed", "shield"]

var id: String
var override: Dictionary = {}   # empty = use the registered base card; else a full def
var charms: Array = []           # Array[String]: charm ids enchanting this specific card


static func make(card_id: String) -> DeckCard:
	var dc := DeckCard.new()
	dc.id = card_id
	return dc


static func attr_label(attr: String) -> String:
	match attr:
		"attack": return "Attack"
		"health": return "Health"
		"speed":  return "Speed"
		"shield": return "Shield"
	return attr.capitalize()


# The card's current definition as a fresh, safe-to-mutate dict.
func _current_def() -> Dictionary:
	if not override.is_empty():
		return override.duplicate(true)
	var base := CardData.get_card(id)
	return base.to_dict() if base != null else {"id": id}


# Permanently changes one numeric field, materialising the override on first edit.
func bump(field: String, amount: int = 1) -> void:
	var def := _current_def()
	def[field] = int(def.get(field, 0)) + amount
	override = def


# Attaches a charm (once — no duplicate of the same charm).
func add_charm(charm_id: String) -> void:
	if charm_id not in charms:
		charms.append(charm_id)


# Merges a charm's definition-patch (stat bumps + extra effects) into a def dict, so the
# charm's effects fire through the normal per-card trigger system once built.
func _apply_charm(def: Dictionary, charm_id: String) -> void:
	var charm := CharmData.get_charm(charm_id)
	if charm == null:
		return
	for attr in charm.stats:
		def[attr] = int(def.get(attr, 0)) + int(charm.stats[attr])
	if not charm.effects.is_empty():
		var fx: Array = (def.get("effects", []) as Array).duplicate()
		fx.append_array(charm.effects)
		def["effects"] = fx


func make_instance() -> CardInstance:
	var inst: CardInstance
	# Fast path: a plain card with no override and no charms uses the registered base.
	if override.is_empty() and charms.is_empty():
		var base := CardData.get_card(id)
		if base == null:
			return null
		inst = CardInstance.from_data(base)
	else:
		var def := _current_def()
		for charm_id: String in charms:
			_apply_charm(def, charm_id)
		var data := CardData.build_from_dict(def)
		if data == null:
			return null
		inst = CardInstance.from_data(data)
	inst.charms = charms.duplicate()   # display only; mechanics are baked into the data above
	return inst


func to_dict() -> Dictionary:
	return {"id": id, "override": override, "charms": charms}


# Accepts the new {id, override, charms} form, legacy {id, mods} (attr→delta), and bare strings.
static func from_variant(v: Variant) -> DeckCard:
	if v is DeckCard:
		return v
	if v is String:
		return make(v)
	if v is Dictionary:
		var dc := make(v.get("id", ""))
		dc.override = v.get("override", {})
		dc.charms = v.get("charms", [])
		if dc.override.is_empty() and v.has("mods"):
			dc._migrate_legacy_mods(v.get("mods", {}))
		return dc
	return make("")


func _migrate_legacy_mods(mods: Dictionary) -> void:
	if mods.is_empty():
		return
	var def := _current_def()
	for attr in mods:
		def[attr] = int(def.get(attr, 0)) + int(mods[attr])
	override = def
