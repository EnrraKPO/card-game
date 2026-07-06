class_name AbilityWidget
extends CardUI

# The tray widget for an ACTIVATED ABILITY (see AbilityData). Extends CardUI — the ability
# token is still a card-SHAPED view underneath (same drag/press/targeting plumbing, so
# SpellCaster and Hand treat it exactly like a spell card) — but presents with its own
# procedurally-drawn frame so it reads "ability", not "card". Real frame art can replace the
# procedural panels later without touching behavior.
#
# Autocast (the Warcraft idiom): an autocast-capable ability (AbilityData.autocast) shows
# corner brackets — dim while merely capable, bright and pulsing while ARMED. Right-click
# (desktop) or long-press (touch) toggles armed state, stored on the HOLDER unit
# (CardInstance.autocast_ability — a single field, so max 1 armed per unit is structural).
# While armed, dragging the holder onto a valid target fires the ability (see the autocast
# path in CombatBoard/SpellCaster).

signal autocast_toggled(holder: CardInstance)

# Native Canvas units (260x340). Bracket size keeps the corner art's aspect (581:508);
# the art itself lives in CardUI.AUTOCAST_CORNERS (shared with the board echo).
const BRACKET_SIZE := Vector2(64.0, 56.0)
const BRACKET_INSET := 3.0
const BRACKET_DIM_ALPHA := 0.35

# Procedural frame palette — deliberately not the card frames' gold/parchment: a cool dark
# slab with an arcane violet edge, so an ability is instantly tellable from a card.
const FRAME_BG := Color(0.115, 0.10, 0.16)
const FRAME_EDGE := Color(0.66, 0.52, 0.92)

var _bracket_layer: Control = null
var _bracket_tween: Tween = null

static var _widget_scene: PackedScene = null


static func create_for(tok: CardInstance) -> AbilityWidget:
	if _widget_scene == null:
		_widget_scene = load("res://scenes/ability_widget.tscn")
	var ui: AbilityWidget = _widget_scene.instantiate()
	ui.card_instance = tok
	ui._show_cost = true
	return ui


func _ready() -> void:
	super()
	_build_ability_chrome()
	_refresh_brackets()


# The ability this widget presents / the unit holding it (both set by the token's creator).
func _ability() -> AbilityData:
	return card_instance.ability if card_instance != null else null


func _holder() -> CardInstance:
	return card_instance.source_building if card_instance != null else null


func _is_armed() -> bool:
	var ab := _ability()
	var holder := _holder()
	return ab != null and holder != null and holder.autocast_ability == ab.id


# ── Procedural frame + brackets ────────────────────────────────────────────────────

func _build_ability_chrome() -> void:
	# Replace the card-frame art with the widget's own frame: a full-rect background slab
	# behind the art plus an edge ring above it. Border (the type-coded card outline) is
	# retired too — the widget's edge ring is its outline.
	_frame.visible = false
	_border.visible = false

	var bg := Panel.new()
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bg_style := StyleBoxFlat.new()
	bg_style.bg_color = FRAME_BG
	bg_style.set_corner_radius_all(12)
	bg.add_theme_stylebox_override("panel", bg_style)
	_canvas.add_child(bg)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_canvas.move_child(bg, 0)   # behind the art and every badge

	var edge := Panel.new()
	edge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var edge_style := StyleBoxFlat.new()
	edge_style.bg_color = Color.TRANSPARENT
	edge_style.border_color = FRAME_EDGE
	edge_style.set_border_width_all(4)
	edge_style.set_corner_radius_all(12)
	edge.add_theme_stylebox_override("panel", edge_style)
	_canvas.add_child(edge)
	edge.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	# Corner brackets live on one shared layer (built by CardUI.build_bracket_layer, same art
	# as the board echo) so the armed pulse is a single tween on the layer, not four.
	var ab := _ability()
	if ab == null or not ab.autocast:
		return
	_bracket_layer = build_bracket_layer(BRACKET_SIZE, BRACKET_INSET)


# Bracket state: dim while capable-but-off, full-bright with a slow pulse while armed. Tween
# hygiene mirrors _refresh_ability_cue: kill before recreate, so repeated refreshes never
# stack tweens.
func _refresh_brackets() -> void:
	if _bracket_layer == null:
		return
	if _bracket_tween != null:
		_bracket_tween.kill()
		_bracket_tween = null
	if _is_armed():
		_bracket_layer.modulate.a = 1.0
		_bracket_tween = create_tween()
		_bracket_tween.set_loops()
		_bracket_tween.tween_property(_bracket_layer, "modulate:a", 0.65, 0.7).set_ease(Tween.EASE_IN_OUT)
		_bracket_tween.tween_property(_bracket_layer, "modulate:a", 1.0, 0.7).set_ease(Tween.EASE_IN_OUT)
	else:
		_bracket_layer.modulate.a = BRACKET_DIM_ALPHA


func refresh() -> void:
	super()
	_refresh_brackets()   # no-op until _build_ability_chrome has run (layer still null)


# ── Autocast toggle input ──────────────────────────────────────────────────────────

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			_toggle_autocast()
			accept_event()
			return
	super(event)


# Touch path: long-press toggles autocast instead of opening the CardInspector — the widget's
# tooltip already carries the description, and toggling is the gesture that matters here.
# Non-capable abilities keep the inherited inspect behavior.
func _on_long_press() -> void:
	var ab := _ability()
	if ab != null and ab.autocast:
		_did_inspect = true   # swallow the pending release so the hold doesn't also cast
		_toggle_autocast()
		return
	super()


# A dragged tray token ghosts as an ability widget, not a plain card (see DragGhost).
func make_ghost_view() -> CardUI:
	return AbilityWidget.create_for(card_instance)


func _toggle_autocast() -> void:
	var ab := _ability()
	var holder := _holder()
	if ab == null or not ab.autocast or holder == null:
		return
	holder.autocast_ability = "" if holder.autocast_ability == ab.id else ab.id
	_refresh_brackets()
	autocast_toggled.emit(holder)
