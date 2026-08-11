class_name CharmData
extends RefCounted

# A charm is a persistent enchantment attached to a specific deck card — a Wildfrost-style
# charm (the per-card reward axis; the run-global axis, relics, is separate/TODO).
# Mechanically it's a small definition-patch of stat bumps merged into the card's definition
# when its CardInstance is built (see DeckCard.make_instance). The effects half of the patch
# burned in the effect-cleanse — charm effect payloads re-author in the new schema.
# Data-driven from data/charms/*.json.

var id: String
# Localized text (Loc `charm.<id>.name`/`.desc`), not read from the data file. See CardData.
var _name_override := ""
var display_name: String:
	get:
		var s := Loc.opt("charm.%s.name" % id)
		return s if s != "" else _name_override
	set(value):
		_name_override = value
var _desc_override := ""
var description: String:
	get:
		var s := Loc.opt("charm.%s.desc" % id)
		return s if s != "" else _desc_override
	set(value):
		_desc_override = value
var color: Color = Color(0.72, 0.72, 0.8)   # charm pip colour on the card
var letter: String = "✦"                     # short glyph shown on the pip
var icon: Texture2D = null                    # optional illustration; when present it replaces the
											   # coloured letter chip everywhere the charm is shown
var stats: Dictionary = {}    # attribute -> int delta (attack/health/speed/shield/cost)
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
		if not bool(d.get("enabled", true)):
			continue
		var c := CharmData.new()
		c.id           = d.get("id", "")
		# display_name/description resolve through Loc by id (see the property getters).
		c.color        = Color.html(str(d.get("color", "b8b8c8")))
		c.letter       = d.get("letter", "✦")
		# Art is by-convention (assets/charms/<id>.png), same pattern relic_data uses for relic art —
		# no path in the JSON. Absent art is fine: the letter+colour chip is the fallback everywhere.
		var art_path := "res://assets/charms/%s.png" % c.id
		if ResourceLoader.exists(art_path):
			c.icon = load(art_path)
		c.stats        = d.get("stats", {})
		c.targets      = d.get("targets", "unit")
		if not c.id.is_empty():
			_all[c.id] = c


static func get_charm(p_id: String) -> CharmData:
	return _all.get(p_id, null)


# ── The charm's face ──────────────────────────────────────────────────────────────
# ONE builder for every surface that shows a charm — the pip on a card, the chip on the forge's
# charm rail, an item chip in a shop or reward. `icon` has always been documented as replacing the
# coloured letter chip "everywhere the charm is shown", but each surface hand-rolled its own
# coloured-circle-plus-letter and never asked for the art, so all seven charms shipped their
# painted asset and none of them ever appeared. Building the face here is what makes the field's
# promise true by construction: a new surface gets the art for free, and a charm with no art (a
# newly authored one, before its asset exists) still falls back to the letter chip.
#
# `px` sizes the badge; `count` > 1 stamps a ×N corner, for the surfaces that stack charms.
func badge(px: float, count: int = 1) -> Control:
	var chip: Panel = TextIcons.TipPanel.new()   # tooltip renders keyword icons
	chip.custom_minimum_size = Vector2(px, px)
	chip.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	chip.size_flags_vertical   = Control.SIZE_SHRINK_CENTER
	chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# The CONTAINER is always drawn — the charm's colour behind a dark rim — exactly as a status pip
	# and a composition chip are. On a card the badge sits over painted art, and a bare cut-out
	# icon had nothing to separate it from whatever was behind it; the disc gives it a consistent
	# silhouette, a readable backdrop, and makes a charm read as the same KIND of thing as the
	# status and component badges it shares the card with.
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_corner_radius_all(int(px * 0.5))   # circular — reads apart from the square piece chips
	style.set_border_width_all(maxi(2, int(px * 0.09)))
	style.border_color = Color(0.04, 0.04, 0.06, 0.9)
	chip.add_theme_stylebox_override("panel", style)
	if icon != null:
		# Inset so the disc reads as a rim around the art, never a hairline behind it (the same
		# 3-in-36 proportion the composition chips use).
		var inset := maxf(2.0, px * 0.083)
		var tex := TextureRect.new()
		tex.texture = icon
		tex.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		tex.offset_left   = inset
		tex.offset_top    = inset
		tex.offset_right  = -inset
		tex.offset_bottom = -inset
		tex.expand_mode  = TextureRect.EXPAND_IGNORE_SIZE
		tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
		chip.add_child(tex)
	else:
		chip.add_child(_centred_label(letter, maxi(int(px * 0.55), 14)))
	if count > 1:
		# Over the art, the count needs its own dark backing to stay legible on any painting.
		var tag := _centred_label("×%d" % count, maxi(int(px * 0.3), 13))
		tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		tag.vertical_alignment   = VERTICAL_ALIGNMENT_BOTTOM
		chip.add_child(tag)
	return chip


# A bare art rect for INLINE use — beside a line of text in a tooltip, where the badge's chip
# framing would be too heavy. Null when the charm has no art, so callers can skip the slot
# entirely (same contract as StatusData.icon_rect, which the tooltip already follows).
func icon_rect(px: float) -> TextureRect:
	if icon == null:
		return null
	var r := TextureRect.new()
	r.texture = icon
	r.custom_minimum_size = Vector2(px, px)
	r.expand_mode  = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	r.size_flags_vertical = Control.SIZE_SHRINK_BEGIN   # top-align with the label's first line
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r


func _centred_label(text: String, font_px: int) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", font_px)
	lbl.add_theme_color_override("font_color", Color(0.98, 0.98, 1.0))
	lbl.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.85))
	lbl.add_theme_constant_override("outline_size", 4)
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return lbl


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
