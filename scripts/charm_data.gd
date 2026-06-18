class_name CharmData
extends RefCounted

# A charm is a persistent enchantment attached to a specific deck card — a Wildfrost-style
# charm (the per-card reward axis; the run-global axis, relics, is separate/TODO).
# Mechanically it's a small definition-patch: stat bumps + extra effects that get merged
# into the card's definition when its CardInstance is built (see DeckCard.make_instance),
# so charm effects fire through the SAME per-card Effect/trigger system as native effects.
# Data-driven from data/charms/*.json.

var id: String
var display_name: String
var description: String
var color: Color = Color(0.72, 0.72, 0.8)   # charm pip colour on the card
var letter: String = "✦"                     # short glyph shown on the pip
var stats: Dictionary = {}    # attribute -> int delta (attack/health/speed/shield/cost)
var effects: Array = []       # Array[Dictionary], the same effect schema cards use
# Which cards this charm may attach to: "unit" (default — combat charms), "spell"
# (e.g. cost/on_play charms on element cards), or "any". The King is never eligible.
var targets: String = "unit"

static var _all: Dictionary = {}


static func _static_init() -> void:
	var dir := DirAccess.open("res://data/charms/")
	if dir == null:
		return   # charms are optional content; an absent folder is fine
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if fname.ends_with(".json"):
			_load_json("res://data/charms/" + fname)
		fname = dir.get_next()
	dir.list_dir_end()


static func _load_json(path: String) -> void:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return
	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK:
		push_error("CharmData: parse error in %s — %s" % [path, json.get_error_message()])
		return
	var entries: Array = json.data if json.data is Array else [json.data]
	for d: Dictionary in entries:
		var c := CharmData.new()
		c.id           = d.get("id", "")
		c.display_name = d.get("display_name", "")
		c.description  = d.get("description", "")
		c.color        = Color.html(str(d.get("color", "b8b8c8")))
		c.letter       = d.get("letter", "✦")
		c.stats        = d.get("stats", {})
		c.effects      = d.get("effects", [])
		c.targets      = d.get("targets", "unit")
		if not c.id.is_empty():
			_all[c.id] = c


static func get_charm(p_id: String) -> CharmData:
	return _all.get(p_id, null)


# Whether this charm may be attached to the given card. The King is never a valid
# target (deck-side changes can't reach the board King); otherwise it's by `targets`.
func can_attach_to(card: CardData) -> bool:
	if card == null or card.is_king:
		return false
	match targets:
		"any":   return true
		"spell": return card.card_type == CardData.CardType.SPELL
		_:       return card.card_type == CardData.CardType.UNIT


static func all() -> Array:
	return _all.values()
