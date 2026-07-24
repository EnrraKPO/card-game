class_name CardTooltip
extends RefCounted

# THE shared rich card hover panel: an enlarged CardUI preview beside a detail column (name,
# generated-token note, description, abilities, attached charms). CardUI._make_custom_tooltip
# returns this in-game, and any other screen (the Forge, collection, decks…) can call build() to
# get the exact same hover, so card info reads identically everywhere. Pure read of the
# CardInstance — every call builds fresh nodes, so the returned Control is owned by whoever
# shows it.
#
# SIZING RULE: every autowrap label gets custom_minimum_size.x pinned to its actual column
# width. Without it, Godot computes an autowrap label's minimum HEIGHT as if the label were
# squeezed to its narrowest possible width (roughly the longest word), so nested containers
# reserve room for a dozen phantom lines and the tooltip balloons with empty space far past
# its real content ("tooltip_large" bug). Pinned width ⇒ min height == rendered height ⇒ the
# panel is exactly as big as its content.

const PREVIEW_SIZE := Vector2(260, 340)   # size of the enlarged card rendered inside the tooltip
# Small ability-widget views in the detail column (260:340 aspect, same as everywhere).
const ABILITY_WIDGET_SIZE := Vector2(96, 126)
# The detail column's fixed width; all autowrap labels pin against it (see SIZING RULE).
const COLUMN_WIDTH := 240.0
# The optional stat-guide column (inspector only, see build's with_stat_guide): its fixed width
# (same SIZING RULE) plus the size of the real stat badge shown at the start of each row.
const GUIDE_WIDTH := 300.0
const GUIDE_ICON := 44.0
const GUIDE_ROW_SEP := 10.0   # gap between a badge and its note, and between rows
const GUIDE_PAD := 9.0        # content margin inside each note container
const GUIDE_BORDER := 3.0     # the note container's thick coloured outline
# Health/Shield/Attack notes are pinned to this height so the four badges end up EVENLY spaced;
# Speed alone is free to grow taller (it carries the crit/dodge formula). Tuned to fit the
# tallest of the three short notes in both shipped languages (see the render checks).
const GUIDE_NOTE_MIN_H := 96.0

# Badge-number palette, matching the card face: cream on most stats, blue on Shield (CardUI).
const STAT_NUM_COLOR := Color(0.97, 0.95, 0.86)
const SHIELD_NUM_COLOR := Color(0.58, 0.86, 1.0)
# Each stat's representative colour — the note's outline + its title read in it.
const NOTE_BG := Color(0.13, 0.14, 0.18, 0.96)
const HEALTH_COLOR := Color(0.90, 0.32, 0.34)   # red
const SHIELD_COLOR := Color(0.52, 0.80, 1.0)    # light blue
const ATTACK_COLOR := Color(0.96, 0.82, 0.32)   # yellow
const SPEED_COLOR := Color(0.46, 0.86, 0.52)    # green

# Dark panel (stands out against the light board theme) — text palette is light-on-dark.
const BG_COLOR := Color(0.09, 0.095, 0.13, 0.97)
const BORDER_COLOR := Color(0.45, 0.47, 0.6, 0.9)
const TEXT_MAIN := Color(0.93, 0.9, 0.82)     # description / ability text
const TEXT_TITLE := Color(0.97, 0.96, 0.92)   # the card name
const TEXT_SECTION := Color(0.72, 0.7, 0.62)  # "Abilities"/"Charms"/"Statuses" headers
const TEXT_NOTE := Color(0.55, 0.85, 0.95)    # the generated-token note
const TEXT_HINT := Color(0.95, 0.82, 0.35)    # yellow "expand" footnote on the hover tooltip


# `scale` sizes the whole panel up proportionally — preview, column width, fonts, pads. Fonts
# scale through their point size (not a canvas transform), so text stays crisp at any factor.
# 1.0 = the hover tooltip; CardInspector passes the factor that fills the screen (see there).
#
# `with_stat_guide` prepends a stat-glossary column (Health/Shield/Attack/Speed, each with its
# real badge icon + a plain-language rule, plus a live crit/dodge formula footnote). It's the
# deep-dive the full-screen CardInspector opts into; the compact hover tooltip leaves it off.
# Shown only for units — spells carry none of these stats (see has_stat_guide). The column is
# headed by a "Show Stat Descriptions" toggle; `descriptions_shown` false collapses it to just
# that toggle (CardInspector owns the toggle state and rebuilds on change).
static func build(inst: CardInstance, show_cost := true, scale := 1.0,
		with_stat_guide := false, descriptions_shown := true) -> Control:
	if inst == null:
		return null
	var s := scale

	var panel := PanelContainer.new()
	var style  := StyleBoxFlat.new()
	style.bg_color = BG_COLOR
	style.set_border_width_all(1)
	style.border_color = BORDER_COLOR
	style.set_corner_radius_all(6)
	style.set_content_margin_all(12.0 * s)
	panel.add_theme_stylebox_override("panel", style)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", int(8.0 * s))
	panel.add_child(root)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", int(14.0 * s))
	root.add_child(hbox)

	# Enlarged visual of the card itself (art + frame + badges). SHRINK_CENTER (not the default FILL)
	# keeps the card at PREVIEW_SIZE instead of stretching vertically when the detail column is
	# taller, which would blow up the COVERED art far past its window.
	var preview := CardUI.create(inst, show_cost)
	preview.custom_minimum_size = PREVIEW_SIZE * s
	preview.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_child(preview)

	hbox.add_child(build_details(inst, s))

	# The stat glossary, prepended as the leftmost column so it reads before the card itself. The
	# same explanations also ride the card's OWN stat badges as hover tooltips (see set_stat_tooltips).
	if with_stat_guide and has_stat_guide(inst):
		var guide := build_stat_guide(inst, s, descriptions_shown)
		hbox.add_child(guide)
		hbox.move_child(guide, 0)
		if preview.has_method("set_stat_tooltips"):
			preview.set_stat_tooltips(stat_tips(inst))

	# Hover-tooltip footnote pointing to the full-screen inspector. Only on the compact hover panel
	# (not the guide variant, which already IS the expanded view).
	if not with_stat_guide:
		var hint := Label.new()
		hint.text = Loc.t("card_tooltip.expand_hint")
		hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		hint.add_theme_font_size_override("font_size", int(19.0 * s))
		hint.add_theme_color_override("font_color", TEXT_HINT)
		root.add_child(hint)

	return panel


# The card's detail column (name, generated-token note, description, targeting/building rules,
# abilities, charms, statuses) — the right-hand half of the hover panel, reused verbatim by the
# CardInspector. Vertically SHRINK_CENTER so it sits centred beside a taller card.
static func build_details(inst: CardInstance, s := 1.0) -> VBoxContainer:
	var col_w := COLUMN_WIDTH * s
	var vbox := VBoxContainer.new()
	vbox.custom_minimum_size.x = col_w
	vbox.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	vbox.add_theme_constant_override("separation", int(6.0 * s))

	var name_lbl := Label.new()
	name_lbl.text = inst.data.display_name
	name_lbl.add_theme_font_size_override("font_size", int(22.0 * s))
	name_lbl.add_theme_color_override("font_color", TEXT_TITLE)
	vbox.add_child(name_lbl)

	vbox.add_child(HSeparator.new())

	# Generated tokens explain their hidden cost: playing one taps the rook.
	if inst.source_building != null:
		var note := Label.new()
		# No leading icon glyph here — the default font (Baloo2-ExtraBold) is missing several
		# symbol glyphs (⚒, ✓, ●, the old ✕), which render broken on web/mobile builds where
		# there's no system-font fallback; see ScreenUI.CLOSE_GLYPH for the same issue.
		note.text = Loc.t("card_tooltip.generated", {"name": inst.source_building.data.display_name})
		vbox.add_child(_wrap_label(note, col_w, int(15.0 * s), TEXT_NOTE))

	var desc := inst.data.description
	if not desc.is_empty():
		vbox.add_child(_rich_label(desc, col_w, int(18.0 * s), TEXT_MAIN))

	# Auto-attack targeting policy, appended after the authored text as its own line (units only;
	# spells return "" — see CardData.targeting_line). Colour-dimmed to read as a system rule.
	var targeting := inst.data.targeting_line()
	if not targeting.is_empty():
		vbox.add_child(_rich_label(targeting, col_w, int(15.0 * s), TEXT_SECTION))

	# Rooted-building note, appended after the authored/targeting text as its own line (buildings
	# only; non-buildings return "" — see CardData.building_line). Colour-dimmed as a system rule.
	var building := inst.data.building_line()
	if not building.is_empty():
		vbox.add_child(_rich_label(building, col_w, int(15.0 * s), TEXT_SECTION))

	# Activated abilities: a SMALL ability-widget view per ability beside its description —
	# the same visual the tray uses, so "this is an ability" reads identically everywhere.
	# Info-only here (mouse-ignored, not draggable); activation stays in the tray.
	var abilities: Array = inst.ability_list()
	if not abilities.is_empty():
		vbox.add_child(HSeparator.new())
		vbox.add_child(_section_title(Loc.t("card_tooltip.section_abilities"), s))
		for ab: AbilityData in abilities:
			vbox.add_child(_ability_row(inst, ab, s))

	# Charm detail: one line per attached charm, colour-matched to its on-card pip.
	if not inst.charms.is_empty():
		vbox.add_child(HSeparator.new())
		vbox.add_child(_section_title(Loc.t("card_tooltip.section_charms"), s))
		for charm_id: String in inst.charms:
			var charm := CharmData.get_charm(charm_id)
			if charm == null:
				continue
			var ch_line := "%s  %s — %s" % [charm.letter, charm.display_name, charm.description]
			vbox.add_child(_rich_label(ch_line, col_w, int(15.0 * s), charm.color.lightened(0.35)))

	# Active statuses: one line each (glyph, name, count, description), colour-matched to its pip.
	if not inst.statuses.is_empty():
		vbox.add_child(HSeparator.new())
		vbox.add_child(_section_title(Loc.t("card_tooltip.section_statuses"), s))
		for si: StatusInstance in inst.statuses:
			var sd: StatusData = si.data
			var cnt := si.count()
			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", int(6.0 * s))
			var icon := sd.icon_rect(22.0 * s)
			if icon != null:
				row.add_child(icon)
			var line := "%s%s" % [sd.display_name, (" %d" % cnt) if cnt > 0 else ""]
			if not sd.description.is_empty():
				line += " — %s" % sd.description
			# The pip + the row's separation, so pip + text fill the column.
			row.add_child(_rich_label(line, col_w - 28.0 * s, int(15.0 * s),
				sd.color.lightened(0.35)))
			vbox.add_child(row)

	return vbox


# Whether the stat-guide column applies to this card: units carry Health/Shield/Attack/Speed,
# spells carry none of them, so the glossary would be meaningless there.
static func has_stat_guide(inst: CardInstance) -> bool:
	return inst != null and not inst.is_spell


# The Health/Shield/Attack/Speed glossary column: each row is the card's real stat badge (reused
# from CardUI, so the icon matches the number on the card exactly) beside a plain-language rule,
# with a live crit/dodge formula note under Speed. Each badge also carries the same text as a
# hover tooltip (UIScale.tip, so touch — where the inspector opens by long-press — stays clean).
static func build_stat_guide(inst: CardInstance, s := 1.0, descriptions_shown := true) -> Control:
	var vbox := VBoxContainer.new()
	vbox.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	vbox.add_theme_constant_override("separation", int(GUIDE_ROW_SEP * s))

	# The toggle heads the column (replacing a plain "Stats" title). CardInspector finds this
	# CheckButton, wires its `toggled`, and rebuilds — so the builder stays state-free.
	var toggle := CheckButton.new()
	toggle.text = Loc.t("statguide.toggle")
	toggle.button_pressed = descriptions_shown
	toggle.add_theme_font_size_override("font_size", int(15.0 * s))
	toggle.add_theme_color_override("font_color", TEXT_SECTION)
	vbox.add_child(toggle)

	# Collapsed: the toggle alone (no wide empty column — the panel shrinks to two columns).
	if not descriptions_shown:
		return vbox

	vbox.custom_minimum_size.x = GUIDE_WIDTH * s
	vbox.add_child(HSeparator.new())

	# The three short notes share one pinned height (GUIDE_NOTE_MIN_H) so the four badges come out
	# evenly spaced; Speed's note is free to grow (its description runs a line longer).
	vbox.add_child(_stat_row(CardUI.BADGE_HEALTH, inst.current_health, STAT_NUM_COLOR,
		HEALTH_COLOR, "health", s, true))
	vbox.add_child(_stat_row(CardUI.BADGE_SHIELD, inst.current_shield, SHIELD_NUM_COLOR,
		SHIELD_COLOR, "shield", s, true))
	vbox.add_child(_stat_row(CardUI.BADGE_ATTACK, int(inst.get_attribute("attack")), STAT_NUM_COLOR,
		ATTACK_COLOR, "attack", s, true))
	vbox.add_child(_stat_row(CardUI.BADGE_SPEED, int(inst.get_attribute("speed")), STAT_NUM_COLOR,
		SPEED_COLOR, "speed", s, false))

	# The crit/dodge maths reads as a FOOTNOTE under the whole column — dim, its own rule, sitting
	# outside the Speed container it elaborates on.
	vbox.add_child(HSeparator.new())
	vbox.add_child(_rich_label(_crit_dodge_note(inst), GUIDE_WIDTH * s, int(13.0 * s), TEXT_SECTION))
	return vbox


# One glossary row: the stat badge (its real icon with this card's current value on it) beside a
# thick-outlined note in the stat's own colour — a coloured title (the stat name) over the rule.
# Badge and note are both TOP-aligned so the badge sits level with the title. `fixed_h` pins the
# note to GUIDE_NOTE_MIN_H (the three short stats) for even badge spacing; Speed passes false so
# its longer description can grow the box.
static func _stat_row(icon_tex: Texture2D, value: int, num_color: Color, stat_color: Color,
		stat_key: String, s := 1.0, fixed_h := false) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", int(GUIDE_ROW_SEP * s))
	row.add_child(_stat_badge(icon_tex, value, num_color, s))

	var container := PanelContainer.new()
	container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	container.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	var style := StyleBoxFlat.new()
	style.bg_color = NOTE_BG
	style.set_border_width_all(int(GUIDE_BORDER * s))
	style.border_color = stat_color
	style.set_corner_radius_all(int(6.0 * s))
	style.set_content_margin_all(GUIDE_PAD * s)
	container.add_theme_stylebox_override("panel", style)
	if fixed_h:
		container.custom_minimum_size.y = GUIDE_NOTE_MIN_H * s
	row.add_child(container)

	var inner := VBoxContainer.new()
	inner.add_theme_constant_override("separation", int(3.0 * s))
	container.add_child(inner)

	# Column width, less the badge, the row gap, and the note's own borders + padding (SIZING RULE).
	var text_w := GUIDE_WIDTH * s - (GUIDE_ICON + GUIDE_ROW_SEP) * s \
			- 2.0 * (GUIDE_PAD + GUIDE_BORDER) * s

	var title := Label.new()
	title.text = Loc.t("term." + stat_key)
	title.add_theme_font_size_override("font_size", int(17.0 * s))
	title.add_theme_color_override("font_color", stat_color)
	inner.add_child(title)

	var desc := _wrap_label(Label.new(), text_w, int(14.0 * s), TEXT_MAIN)
	desc.text = Loc.t("statguide." + stat_key)
	inner.add_child(desc)
	return row


# The card's own explanations, keyed by stat, for the card-badge hover tooltips — each a
# {title, color, body}: the stat's name in its glossary colour over the plain-language rule (with
# the live formula appended to Speed's body). Consumed by CardUI.set_stat_tooltips (StatBadgeTip).
static func stat_tips(inst: CardInstance) -> Dictionary:
	var colors := {
		"health": HEALTH_COLOR, "shield": SHIELD_COLOR,
		"attack": ATTACK_COLOR, "speed": SPEED_COLOR,
	}
	var tips := {}
	for k: String in ["health", "shield", "attack", "speed"]:
		var body := Loc.t("statguide." + k)
		if k == "speed":
			body += "\n\n" + _crit_dodge_note(inst)
		tips[k] = {"title": Loc.t("term." + k), "color": colors[k], "body": body}
	return tips


# The stat badge shown in a glossary row: the card's real badge texture with this card's current
# value drawn centred on it, styled like the card face (cream/blue number, dark outline). Purely
# decorative here — the hover tooltips live on the CARD's badges, so this ignores the mouse.
# Top-aligned in its row.
static func _stat_badge(tex: Texture2D, value: int, num_color: Color, s := 1.0) -> Control:
	var box := Control.new()
	box.custom_minimum_size = Vector2(GUIDE_ICON, GUIDE_ICON) * s
	box.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var icon := TextureRect.new()
	icon.texture = tex
	icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(icon)

	var lbl := Label.new()
	lbl.text = str(value)
	lbl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", int(20.0 * s))
	lbl.add_theme_color_override("font_color", num_color)
	lbl.add_theme_color_override("font_outline_color", Color(0.02, 0.02, 0.04, 1.0))
	lbl.add_theme_constant_override("outline_size", int(5.0 * s))
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(lbl)
	return box


# This card's live crit/dodge rules, spelled out with its own numbers (Speed drives both) and the
# authored coefficients/caps from combat_tuning.json — so the note stays true if balance is retuned.
# Buildings never dodge (Resolver hard-zeroes it), so their dodge line says exactly that.
static func _crit_dodge_note(inst: CardInstance) -> String:
	var spd := int(inst.get_attribute("speed"))
	var lines: Array[String] = [Loc.t("statguide.at_speed", {"speed": spd})]

	if inst.data != null and inst.data.is_building():
		lines.append(Loc.t("statguide.dodge_building"))
	else:
		var d := Resolver.dodge_tuning()
		lines.append(_rule_line("statguide.dodge_line", int(round(Resolver.dodge_chance(inst) * 100.0)),
			d, "statguide.diff_dodge"))

	var c := Resolver.crit_tuning()
	var crit_line := _rule_line("statguide.crit_line", int(round(Resolver.crit_chance(inst) * 100.0)),
		c, "statguide.diff_crit")
	lines.append(Loc.t("statguide.crit_dmg", {"line": crit_line,
		"mult": _fmt(Resolver.crit_multiplier(inst))}))
	return "\n".join(lines)


# Assembles one "Dodge/Crit N%: base% + per% per Speed[, +diff% …] (max cap%)" rule from a tuning
# dict, dropping the speed-edge clause when that coefficient is zero.
static func _rule_line(key: String, chance: int, cfg: Dictionary, diff_key: String) -> String:
	var params := {
		"chance": chance,
		"base": _fmt(float(cfg.get("fixed_pct", 0))),
		"per": _fmt(float(cfg.get("per_speed_pct", 0))),
		"max": _fmt(float(cfg.get("max_pct", 100))),
	}
	var diff := float(cfg.get("per_speed_diff_pct", 0))
	params["diff"] = "" if diff <= 0.0 else Loc.t(diff_key, {"diff": _fmt(diff)})
	return Loc.t(key, params)


# Trims a tuning number to its shortest exact form (2.5 stays "2.5", 1.0 becomes "1").
static func _fmt(v: float) -> String:
	if is_equal_approx(v, round(v)):
		return str(int(round(v)))
	return String.num(v, 2).trim_suffix("0").trim_suffix(".")


# One ability line: the small widget (built exactly like the tray's tokens, so armed autocast
# brackets/effects read here too) beside the ability's name and description.
static func _ability_row(inst: CardInstance, ab: AbilityData, s := 1.0) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", int(10.0 * s))

	var tok := CardInstance.from_data(ab.display_card())
	tok.owner = inst.owner
	tok.row = -1
	tok.col = -1
	tok.source_building = inst
	tok.ability = ab
	var w := AbilityWidget.create_for(tok)
	w.custom_minimum_size = ABILITY_WIDGET_SIZE * s
	w.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	w.mouse_filter = Control.MOUSE_FILTER_IGNORE
	w.draggable = false
	row.add_child(w)

	var line := ab.display_name
	if not ab.description.is_empty():
		line += " — " + ab.description
	# Widget width + the row's separation leaves this much column for the text.
	var lbl := _rich_label(line, (COLUMN_WIDTH - ABILITY_WIDGET_SIZE.x - 10.0) * s,
		int(15.0 * s), TEXT_MAIN)
	lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(lbl)
	return row


static func _section_title(text: String, s := 1.0) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", int(16.0 * s))
	lbl.add_theme_color_override("font_color", TEXT_SECTION)
	return lbl


# Styles a label as wrapped detail text with its width PINNED (see the SIZING RULE up top —
# unpinned autowrap labels report phantom min heights and balloon the panel).
static func _wrap_label(lbl: Label, width: float, font_size: int, color: Color) -> Label:
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
	lbl.custom_minimum_size.x = width
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.add_theme_font_size_override("font_size", font_size)
	lbl.add_theme_color_override("font_color", color)
	return lbl


# Rules-text counterpart of _wrap_label: a RichTextLabel so element/piece keywords render as
# inline icons (TextIcons). Same SIZING RULE — width pinned so fit_content reports the real
# rendered height instead of phantom lines.
static func _rich_label(text: String, width: float, font_size: int, color: Color) -> RichTextLabel:
	var rtl := TextIcons.rich_label(text, font_size, color)
	rtl.custom_minimum_size.x = width
	rtl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return rtl
