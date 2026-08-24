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
	# The upgradable stats are the same words as the rules-text glossary — reuse those keys so
	# a stat name reads identically (and localizes) everywhere. See [[localization]] term.*.
	if attr in UPGRADABLE:
		return Loc.t("term." + attr)
	return attr.capitalize()


# The card's current definition as a fresh, safe-to-mutate dict.
func _current_def() -> Dictionary:
	if not override.is_empty():
		return override.duplicate(true)
	var base := CardData.get_card(id)
	return base.to_dict() if base != null else {"id": id}


# Permanently changes one numeric field, materialising the override on first edit.
# Storage-level writer. Its one caller was the nuked single writer, so nothing reaches it
# today (see event_screen.gd's inert training).
func bump(field: String, amount: int = 1) -> void:
	var def := _current_def()
	def[field] = int(def.get(field, 0)) + amount
	override = def


# ── Charm capacity ────────────────────────────────────────────────────────────────
# A card bears ONE CHARM PER COMPONENT. A plain Pawn is one component and holds one charm; a
# forged two-piece card holds two, and the widest compositions the forge allows (two elements
# plus two pieces) hold four. So enchanting capacity is earned the same way everything else on a
# card is — by merging — and the charm rail can't be dumped onto whichever card was picked first.
#
# The rule lives here rather than in CharmData.can_attach_to because capacity is a fact about the
# BEARER's current load, not about the charm: can_attach_to answers "is this charm legal on this
# kind of card" from CardData alone, and has no idea what is already attached.
func card_data() -> CardData:
	if not override.is_empty():
		return CardData.build_from_dict(override)
	return CardData.get_card(id)


# The rule itself takes the card's definition rather than reading it back, so a caller that
# ALREADY holds the CardData (the forge asks this of every deck entry on every hover) doesn't
# rebuild an overridden card's definition from its dict just to count its components.
static func charm_capacity_of(data: CardData) -> int:
	return data.component_count() if data != null else 0


static func charm_room_of(data: CardData, current: Array) -> int:
	return maxi(0, charm_capacity_of(data) - current.size())


static func can_bear_charm_on(data: CardData, current: Array, charm_id: String) -> bool:
	return charm_id not in current and charm_room_of(data, current) > 0


func charm_capacity() -> int:
	return charm_capacity_of(card_data())


func charm_room() -> int:
	return charm_room_of(card_data(), charms)


func can_bear_charm(charm_id: String) -> bool:
	return can_bear_charm_on(card_data(), charms, charm_id)


# Attaches a charm (once — no duplicate of the same charm, and never past capacity). Returns
# whether it went on, so a caller that skipped the check still can't silently overfill a card.
func add_charm(charm_id: String) -> bool:
	if not can_bear_charm(charm_id):
		return false
	charms.append(charm_id)
	return true


# Merges a charm's definition-patch (stat bumps) into a def dict. (The effects half of the
# patch burned in the effect-cleanse: charm effects re-author in the new schema, and the
# rebuilt charm patch carries new-language payloads or none.)
func _apply_charm(def: Dictionary, charm_id: String) -> void:
	var charm := CharmData.get_charm(charm_id)
	if charm == null:
		return
	for attr in charm.stats:
		def[attr] = int(def.get(attr, 0)) + int(charm.stats[attr])


# The card this deck entry stands for, override and charms folded in — the one product
# every screen renders (the live-fight construction goes through the new core's envelope).
func effective_data() -> CardData:
	# Fast path: a plain card with no override and no charms uses the registered base.
	if override.is_empty() and charms.is_empty():
		return CardData.get_card(id)
	var def := _current_def()
	for charm_id: String in charms:
		_apply_charm(def, charm_id)
	var data := CardData.build_from_dict(def)
	if data == null:
		return null
	# Restore the snapshot's text into the override: for an authored card Loc still wins by
	# id, but a runtime-derived composite carries its only copy of the name/desc here.
	data.display_name = str(def.get("display_name", ""))
	data.description  = str(def.get("description", ""))
	return data


func to_dict() -> Dictionary:
	return {"id": id, "override": override, "charms": charms}


# A fully independent copy — used to snapshot an owned deck into a run so the run's
# per-card edits (bump / add_charm) never write back to the saved deck. The override and
# charms containers are deep-duplicated, not shared.
func clone() -> DeckCard:
	var dc := DeckCard.make(id)
	dc.override = override.duplicate(true)
	dc.charms = charms.duplicate()
	return dc


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
