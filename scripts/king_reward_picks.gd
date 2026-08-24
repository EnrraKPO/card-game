extends Control

# The base King deck's run-start ritual: three sequential picks, each a choice among three random
# single-element cards, added to the run deck before the map. Reached from deck_select_screen when
# the chosen deck is the pristine starter (OwnedDeck.is_base_template); it owns the embark →
# map handoff that _play would otherwise do. The King deck is colorless, so this is where a run
# gains its elemental flavor. See [[abilities]]/reward_screen for the card-offer visual pattern.

const PICKS := 3
const CHOICES := 3   # single-element cards offered per pick (distinct-of-6; repeats across picks OK)
const MAP_SCENE := "res://scenes/map.tscn"

var _compact := false
var _round := 0            # 0-based index of the pick in progress
var _busy := false         # gate re-entrancy during the pick burst / round swap
var _chosen: Array = []    # element ids picked so far (for the progress pips)

var _title: Label
var _progress: Label
var _pips: HBoxContainer
var _grid: FitGrid


func get_chrome() -> Dictionary:
	# A mid-embark ritual — the run already exists, so there's no bailing back to the hub: title
	# only, no exit/close, inert OS-back.
	return {"title": Loc.t("king_picks.title"), "fields": [], "back": Callable(), "inset": true}


func _ready() -> void:
	# Reached without an active run (e.g. a stale direct load) — nothing to add cards to.
	if GameData.current_run == null:
		Nav.goto.call_deferred(MAP_SCENE)
		return
	_compact = UIScale.is_compact()

	var body := VBoxContainer.new()
	body.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	body.add_theme_constant_override("separation", 18 if _compact else 12)
	add_child(body)

	# ── Header: instruction + progress pips ─────────────────────────────────────────
	_title = Label.new()
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.add_theme_font_size_override("font_size", 44 if _compact else 34)
	_title.add_theme_color_override("font_color", ScreenUI.TEXT_COLOR)
	body.add_child(_title)

	var prow := HBoxContainer.new()
	prow.alignment = BoxContainer.ALIGNMENT_CENTER
	prow.add_theme_constant_override("separation", 18)
	body.add_child(prow)

	_progress = Label.new()
	_progress.add_theme_font_size_override("font_size", 28 if _compact else 22)
	_progress.add_theme_color_override("font_color", Color(0.78, 0.8, 0.9))
	_progress.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	prow.add_child(_progress)

	_pips = HBoxContainer.new()
	_pips.add_theme_constant_override("separation", 10)
	prow.add_child(_pips)

	# ── The three element cards fill the rest of the screen ─────────────────────────
	# Only three cards, so FitGrid's default 260px native cap would strand most of the screen
	# empty — let them grow large (they're the whole point of this screen) so the trio fills it.
	_grid = FitGrid.new()
	_grid.max_card_width = 520.0
	_grid.separation = 40.0
	_grid.size_flags_horizontal = SIZE_EXPAND_FILL
	_grid.size_flags_vertical = SIZE_EXPAND_FILL
	body.add_child(_grid)

	_start_round()


# Lays out a fresh pick: three distinct random single-element cards, header + pips updated.
func _start_round() -> void:
	_busy = false
	_title.text = Loc.t("king_picks.prompt")
	_progress.text = Loc.t("king_picks.progress", {"n": _round + 1, "total": PICKS})
	_rebuild_pips()

	var pool: Array = Materials.ELEMENTS.duplicate()
	pool.shuffle()
	var tiles: Array[Control] = []
	for i in CHOICES:
		tiles.append(_make_card_tile(str(pool[i])))
	_grid.set_cards(tiles)


# A card-shaped, clickable tile: the element card art with its description below, live-sized to
# whatever cell FitGrid assigns. Mirrors reward_screen._make_card_offer (a plain Control wrap so the
# CardUI's native 260x340 min size can't propagate up and override the assigned cell).
func _make_card_tile(elem_id: String) -> Control:
	var data := CardData.get_card(elem_id)
	var wrap := Control.new()

	var ui := CardUI.create(data)
	ui.mouse_filter = Control.MOUSE_FILTER_STOP
	ui.pressed.connect(func() -> void: _pick(elem_id, ui))
	wrap.add_child(ui)

	var desc_text: String = data.description if data != null else ""
	var desc_lbl := TextIcons.rich_label(desc_text, 16, ScreenUI.TEXT_COLOR, true)
	wrap.add_child(desc_lbl)

	const DESC_FRACTION := 0.2
	const GAP := 8.0
	wrap.resized.connect(func() -> void:
		var cw := wrap.size.x
		var ch := wrap.size.y
		if cw <= 0.0 or ch <= 0.0:
			return
		var desc_h := ch * DESC_FRACTION
		var card_h := ch - desc_h - GAP
		var card_w := minf(cw, card_h / FitGrid.RATIO)
		card_h = card_w * FitGrid.RATIO
		ui.position = Vector2((cw - card_w) * 0.5, 0.0)
		ui.size = Vector2(card_w, card_h)
		desc_lbl.position = Vector2(0.0, card_h + GAP)
		desc_lbl.size = Vector2(cw, desc_h)
		desc_lbl.add_theme_font_size_override("normal_font_size", clampi(roundi(cw / 15.0), 12, 22))
		TextIcons.set_text(desc_lbl, desc_text, true)
	)
	return wrap


# Commits a pick: adds the card to the run deck, celebrates it, then advances to the next round or
# finishes into the map.
func _pick(elem_id: String, card: CardUI) -> void:
	if _busy:
		return
	_busy = true
	GameData.current_run.deck.append(DeckCard.make(elem_id))
	_chosen.append(elem_id)
	Selection.select(card)
	await Vfx.play("reward_card_burst", card)

	_round += 1
	if _round >= PICKS:
		_finish()
	else:
		_start_round()


func _finish() -> void:
	GameData.save_run()
	# The adventure's first step (moved here from deck_select for the base deck): gates bloom over
	# the whole screen, held so the map navigation doesn't cut it.
	await Vfx.play("embark_gates_bloom", self)
	Nav.goto(MAP_SCENE)


# Three dots tracking progress: filled (King-piece gold) for picks made, dim for those to come.
func _rebuild_pips() -> void:
	for c in _pips.get_children():
		c.queue_free()
	var done := Color(0.9, 0.72, 0.24)
	var todo := Color(0.32, 0.34, 0.42)
	for i in PICKS:
		var pip := Panel.new()
		var d := 26.0 if _compact else 20.0
		pip.custom_minimum_size = Vector2(d, d)
		pip.size_flags_vertical = SIZE_SHRINK_CENTER   # stay round, don't stretch to the row height
		var style := StyleBoxFlat.new()
		style.bg_color = done if i < _chosen.size() else todo
		style.set_corner_radius_all(int(d))
		pip.add_theme_stylebox_override("panel", style)
		_pips.add_child(pip)
