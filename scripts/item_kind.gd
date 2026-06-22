class_name ItemKind
extends RefCounted

# Base for an acquirable item TYPE in the unified offer/grant layer. Each kind knows how to sample
# offers, render an offer widget, price itself, gate granting, and apply a grant to the run.
# Registered by string key in ItemKinds and consumed generically by shop_screen, reward_screen and
# relic_event_screen through Grant — so adding a new item type is ONE registration, not bespoke
# offer/buy code per surface. Subclasses: ItemKindCard / ItemKindCharm / ItemKindRelic.

# N offerable item ids for a shop/reward, sampled with `rng` (subclasses may ignore it and use the
# global RNG). Default: nothing to offer.
func offer_pool(_count: int, _rng: RandomNumberGenerator) -> Array[String]:
	return []


# The visual widget shown for one offered id (a CardUI, or a coloured chip — see make_chip).
func make_offer_ui(_id: String) -> Control:
	return Control.new()


func display_name(id: String) -> String:
	return id.capitalize()


func tooltip(id: String) -> String:
	return display_name(id)


func color(_id: String) -> Color:
	return Color.WHITE


# Gold cost when offered in a shop (0 = free / not priced).
func default_price(_id: String) -> int:
	return 0


# Whether granting this id is currently allowed (capacity, uniqueness, …). Default: always.
func can_grant(_id: String) -> bool:
	return true


# Apply the grant to the run/profile and persist. Override per kind.
func grant(_id: String, _count: int) -> void:
	pass


# ── Shared UI ──────────────────────────────────────────────────────────────────────────

# A 64×64 coloured chip with a glyph and tooltip — the shared look for charm/relic offers and the
# relic tray (lifted from shop_screen's charm-chip styling).
static func make_chip(letter: String, col: Color, tip: String) -> Control:
	var chip := Panel.new()
	chip.custom_minimum_size = Vector2(64, 64)
	chip.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	chip.tooltip_text = tip
	var style := StyleBoxFlat.new()
	style.bg_color = col
	style.set_corner_radius_all(14)
	style.set_border_width_all(3)
	style.border_color = Color(0.04, 0.04, 0.06, 0.9)
	chip.add_theme_stylebox_override("panel", style)
	var glyph := Label.new()
	glyph.text = letter
	glyph.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	glyph.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	glyph.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	glyph.add_theme_font_size_override("font_size", 26)
	chip.add_child(glyph)
	return chip
