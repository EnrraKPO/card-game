class_name DamageShareOverlay
extends PanelContainer

# THE debug read of the damage waterfall: what every slot on both boards is expected to
# absorb this turn, and the arithmetic that got there (BoardScoring.incoming_allocation —
# EVAL_CRITERIA_BRIEF.md, "the damage waterfall"). Opened from combat's debug row.
#
# EVERY SLOT, not every unit. The waterfall allocates damage to BODIES — absorption needs a
# pool — but the terms that decide the pour are geometric and defined for a bare
# coordinate, so an empty slot is not a blank row here:
#   · exposure — column depth divided by the cover the side's own units give it. Computed
#     for any (row, col), occupied or not; this is what the engine already reads when it
#     prices a placement into an empty slot.
#   · tier — where that exposure puts the slot in the front-first pour order.
#   · arriving — the mass still unabsorbed when the pour reaches that tier: what a body
#     standing here would be walking into.
# An occupied slot adds the terms that need a pool: cap (pool inflated by dodge — a dodger
# soaks attention beyond its life), aimed, landed, and the valuation stamp the whole thing
# feeds (urgency → persistence → value).
#
# The numbers are READ, never re-derived: the panel asks incoming_allocation for its own
# trace, so it can only ever show what the engine actually computed.

const CELL_MIN := Vector2(148.0, 118.0)

var _state: BoardState
var _pricer: EnemyPersonality


# ── The same read, as text (for CombatLog) ─────────────────────────────────────────────
#
# The panel is live and gone the moment the board moves; a discussion about why a slot
# scored what it scored needs the snapshot to still exist afterwards. This writes the
# IDENTICAL numbers — same trace, same helpers, same exposure_breakdown — into log lines.
# One computation, two presentations: if the panel and the log ever disagree, that is a bug
# in this file, not a difference of opinion.
#
# `state` must already have been through BoardScoring.run_valuation (the caller does it, so
# a caller who has just valued the board is not made to pay for it twice).
static func report_lines(state: BoardState, caption: String = "") -> Array:
	var lines: Array = []
	if not caption.is_empty():
		lines.append(caption)
	for side in [1, 0]:
		var trace: Dictionary = {"tiers": []}
		var landed := BoardScoring.incoming_allocation(state, side, false, trace)
		var mass := float(trace.get("mass", 0.0))
		var absorbed := 0.0
		for u: Variant in landed.values():
			absorbed += float(u)
		lines.append("%s — incoming mass %.2f · absorbed %.2f · dodged/unspent %.2f · speed ref %.2f"
				% ["CPU board" if side == 1 else "Player board", mass, absorbed,
				maxf(0.0, mass - absorbed), float(trace.get("thrown_at", 0.0))])
		for r in BoardData.ROWS:
			for c in BoardData.COLS:
				lines.append("  " + _slot_line(state, side, r, c, trace, landed, mass))
	return lines


# One slot as a single grep-able line. Empty slots are printed too — their geometry is what
# the engine reads when it prices a placement INTO them, so a table that skipped them would
# hide the terms behind half the decisions.
static func _slot_line(state: BoardState, side: int, r: int, c: int, trace: Dictionary,
		landed: Dictionary, mass: float) -> String:
	var b := BoardScoring.exposure_breakdown(state, side, r, c)
	var exposure := float(b["exposure"])
	var unit := _unit_at(state, side, r, c)
	var s := "r%dc%d %-16s base %.3f  cover %.2f  exp %.3f (tier %d)  arriving %.2f" \
			% [r, c, unit.card_id if unit != null else "—empty—", float(b["base"]),
			float(b["cover"]), exposure, _tier_of(state, side, exposure),
			_arriving_at(trace, exposure)]
	if unit != null:
		var rec := _record_for(trace, unit)
		var got := float(landed.get(unit, 0.0))
		s += "  | pool %d+%d  dodge %.0f%%  cap %.2f  aimed %.2f  LANDED %.2f (%.0f%%)" \
				% [unit.health, unit.shield, float(rec.get("dodge", 0.0)) * 100.0,
				float(rec.get("cap", 0.0)), float(rec.get("aimed", 0.0)), got,
				100.0 * got / mass if mass > 0.0 else 0.0]
		s += "  urgency %.2f  persist %.2f  value %.2f (raw %.2f)" \
				% [BoardScoring.urgency(state, unit), unit.persistence, unit.value,
				unit.raw_value]
	s += _who_text(b)
	return s


# Builds and parents the panel. `pricer` is the fight's personality (null = stock), so the
# value stamps shown are the ones THIS opponent computes, not a generic pricing.
static func open(host: Control, player_grid: Array, enemy_grid: Array, player_mana: int,
		pricer: EnemyPersonality = null) -> DamageShareOverlay:
	var o := DamageShareOverlay.new()
	o._pricer = pricer
	o._state = BoardState.capture(player_grid, enemy_grid, player_mana)
	# The same valuation pass every criterion runs on, so persistence/value below are the
	# stamps the engine itself would read this instant.
	BoardScoring.run_valuation(o._state, pricer)
	# ON ITS OWN CANVAS LAYER, high: slot cues and card views ride overlay layers of their
	# own, and a plain child of the combat screen renders UNDER them — the first shot of this
	# panel had the board's slot frames drawn straight through the readout.
	var layer := CanvasLayer.new()
	layer.layer = 220
	host.add_child(layer)
	layer.add_child(o)
	o.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	o._build()
	return o


# Frees the layer this panel was mounted on, not just the panel.
func dismiss() -> void:
	var layer := get_parent()
	if layer is CanvasLayer:
		layer.queue_free()
	else:
		queue_free()


func _build() -> void:
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.04, 0.04, 0.07, 1.0)   # opaque: this is a readout, not a veil
	bg.content_margin_left = 16.0
	bg.content_margin_right = 16.0
	bg.content_margin_top = 12.0
	bg.content_margin_bottom = 12.0
	add_theme_stylebox_override("panel", bg)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	add_child(col)

	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 12)
	col.add_child(top)
	var title := Label.new()
	title.text = "Damage share — every slot's read of the waterfall"
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0))
	title.size_flags_horizontal = SIZE_EXPAND_FILL
	top.add_child(title)
	var close := ScreenUI.close_button(dismiss, true)
	top.add_child(close)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = SIZE_EXPAND_FILL
	col.add_child(scroll)
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 14)
	body.size_flags_horizontal = SIZE_EXPAND_FILL
	scroll.add_child(body)

	# The CPU's own board first — it is the side whose decisions the log is usually chasing.
	_build_side(body, 1, "CPU board (the enemy's own slots)")
	_build_side(body, 0, "Player board")


# One side: the header of totals, then its slots laid out as the board is.
func _build_side(host: VBoxContainer, side: int, caption: String) -> void:
	var trace: Dictionary = {"tiers": []}
	var landed := BoardScoring.incoming_allocation(_state, side, false, trace)
	var mass := float(trace.get("mass", 0.0))

	var head := Label.new()
	head.text = caption
	head.add_theme_font_size_override("font_size", 19)
	head.add_theme_color_override("font_color", Color(1.0, 0.84, 0.52))
	host.add_child(head)

	var sub := Label.new()
	sub.add_theme_font_size_override("font_size", 16)
	sub.add_theme_color_override("font_color", Color(0.88, 0.91, 0.98))
	# The mass is what the OTHER side is expected to deliver — delivery-discounted and
	# crit-raised (expected_threat_against), plus the player's open mana when the player is
	# the aggressor. Absorbed vs wasted is the dodge story: a dodged part is thrown and
	# lands on no one.
	var absorbed := 0.0
	for u: Variant in landed.values():
		absorbed += float(u)
	sub.text = "incoming mass %.2f   ·   absorbed %.2f   ·   dodged/unspent %.2f   ·   attacker speed ref %.2f" \
			% [mass, absorbed, maxf(0.0, mass - absorbed), float(trace.get("thrown_at", 0.0))]
	host.add_child(sub)

	var grid := GridContainer.new()
	grid.columns = BoardData.COLS
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 6)
	host.add_child(grid)
	for r in BoardData.ROWS:
		for c in BoardData.COLS:
			grid.add_child(_cell(side, r, c, trace, landed, mass))


# One slot's full read. Occupied slots carry every term; empty ones carry the geometric
# ones and say plainly that there is nothing here to absorb.
func _cell(side: int, r: int, c: int, trace: Dictionary, landed: Dictionary,
		mass: float) -> Control:
	var exposure := BoardScoring.exposure_of(_state, side, r, c)
	var unit := _unit_at(_state, side, r, c)

	var panel := PanelContainer.new()
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.10, 0.11, 0.16, 1.0) if unit == null else Color(0.13, 0.16, 0.24, 1.0)
	box.border_color = Color(0.30, 0.34, 0.46)
	box.set_border_width_all(1)
	box.set_content_margin_all(7.0)
	panel.add_theme_stylebox_override("panel", box)
	panel.custom_minimum_size = CELL_MIN
	panel.size_flags_horizontal = SIZE_EXPAND_FILL

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 1)
	panel.add_child(v)

	var name_lbl := Label.new()
	name_lbl.add_theme_font_size_override("font_size", 16)
	name_lbl.text = "r%dc%d  %s" % [r, c, unit.card_id if unit != null else "— empty —"]
	var tint := Color(0.70, 0.74, 0.86)
	if unit != null:
		tint = Color(1.0, 0.86, 0.45) if unit.is_king else Color(1.0, 1.0, 1.0)
	name_lbl.add_theme_color_override("font_color", tint)
	v.add_child(name_lbl)

	# Exposure DECOMPOSED — the whole point of the panel is showing the arithmetic, and
	# "0.333" alone says nothing about which body is doing the screening. Defined for empty
	# slots exactly as for occupied ones, which is also what keeps an empty cell worth its
	# space on screen.
	var cover := BoardScoring.exposure_breakdown(_state, side, r, c)
	var tier := _tier_of(_state, side, exposure)
	_row(v, "base", "%.3f   (depth: col %d of %d)" % [float(cover["base"]), c, BoardData.COLS])
	_row(v, "cover", "%.2f%s" % [float(cover["cover"]), _who_text(cover)])
	_row(v, "exposure", "%.3f   (tier %d)" % [exposure, tier])
	# What is still in the air when the pour reaches this depth — the number that makes an
	# empty slot's danger legible before anything stands in it.
	_row(v, "arriving", "%.2f" % _arriving_at(trace, exposure))

	if unit == null:
		var none := Label.new()
		none.add_theme_font_size_override("font_size", 14)
		none.add_theme_color_override("font_color", Color(0.70, 0.74, 0.86))
		none.text = "no body — absorbs nothing"
		v.add_child(none)
		return panel

	var rec := _record_for(trace, unit)
	var got := float(landed.get(unit, 0.0))
	_row(v, "pool", "%d hp + %d shield" % [unit.health, unit.shield])
	_row(v, "dodge", "%.0f%%   cap %.2f" % [float(rec.get("dodge", 0.0)) * 100.0,
			float(rec.get("cap", 0.0))])
	_row(v, "aimed", "%.2f" % float(rec.get("aimed", 0.0)))
	_row(v, "LANDED", "%.2f   (%.0f%% of mass)" % [got,
			100.0 * got / mass if mass > 0.0 else 0.0], true)
	_row(v, "urgency", "%.2f" % BoardScoring.urgency(_state, unit))
	_row(v, "persist", "%.2f" % unit.persistence)
	_row(v, "value", "%.2f   (raw %.2f)" % [unit.value, unit.raw_value])
	return panel


func _row(host: VBoxContainer, label: String, value: String, strong: bool = false) -> void:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 6)
	host.add_child(h)
	var l := Label.new()
	l.text = label
	l.custom_minimum_size.x = 62.0
	l.add_theme_font_size_override("font_size", 14)
	l.add_theme_color_override("font_color", Color(0.72, 0.76, 0.88))
	h.add_child(l)
	var v := Label.new()
	v.text = value
	v.add_theme_font_size_override("font_size", 14)
	v.add_theme_color_override("font_color",
			Color(1.0, 0.72, 0.42) if strong else Color(0.96, 0.97, 1.0))
	h.add_child(v)


# WHO is giving this slot its cover, and under which rule — the contributors of
# BoardScoring.exposure_breakdown rendered for a reader. Named rules, not bare weights: the
# three credits mean different things (a body in front SCREENS; a body at the same depth is
# only a "column-mate", which is attention-splitting, not protection) and a column of
# undifferentiated numbers is exactly what made that distinction invisible.
static func _who_text(breakdown: Dictionary) -> String:
	var who: Array = breakdown["who"]
	if who.is_empty():
		return "   (none)"
	var parts: Array = []
	for e: Dictionary in who:
		parts.append("%s r%dc%d %s %.2f" % [String(e["id"]), int(e["row"]), int(e["col"]),
				String(e["kind"]), float(e["w"])])
	return "   ← " + ", ".join(parts)


static func _unit_at(state: BoardState, side: int, r: int, c: int) -> BoardState.UnitState:
	for u: BoardState.UnitState in state.units(side):
		if u.row == r and u.col == c:
			return u
	return null


# The pour's own record for this unit, straight out of the trace.
static func _record_for(trace: Dictionary, unit: BoardState.UnitState) -> Dictionary:
	for t: Dictionary in (trace["tiers"] as Array):
		for rec: Dictionary in (t["units"] as Array):
			if rec["unit"] == unit:
				return rec
	return {}


# The slot's place in the pour order, 1 = poured into first. Ranked over EVERY slot on the
# side, not just the occupied ones: the trace's own tiers contain bodies only, so ranking
# against them would file every empty slot behind the same body and report a dozen
# different positions as one tier. Equal exposures share a rank — that is the water-filling
# rule, and it is the difference between a screen and a tie.
static func _tier_of(state: BoardState, side: int, exposure: float) -> int:
	var levels: Array = []
	for r in BoardData.ROWS:
		for c in BoardData.COLS:
			var e := BoardScoring.exposure_of(state, side, r, c)
			var seen := false
			for l: Variant in levels:
				if absf(float(l) - e) < 0.0001:
					seen = true
					break
			if not seen:
				levels.append(e)
	levels.sort()
	levels.reverse()
	for i in levels.size():
		if absf(float(levels[i]) - exposure) < 0.0001:
			return i + 1
	return levels.size()


# The mass still unabsorbed when the pour reaches this exposure: everything strictly more
# exposed has already taken its fill. For an occupied slot this is what its own tier was
# handed; for an empty one it is what a body standing here would meet.
static func _arriving_at(trace: Dictionary, exposure: float) -> float:
	var tiers: Array = trace["tiers"]
	for t: Dictionary in tiers:
		if float(t["exposure"]) <= exposure + 0.0001:
			return float(t["arriving"])
	if tiers.is_empty():
		return float(trace.get("mass", 0.0))
	return float((tiers[tiers.size() - 1] as Dictionary)["leaving"])
