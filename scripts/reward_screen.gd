extends Control

# Opt-in elemental-card offers: { "id": String, "btn": CheckButton, "ui": CardUI }. The matching
# element card for each essence reward is offered with an Accept/Reject toggle (Accept by default);
# accepted ones are added to the deck on finish (see _finish).
var _element_toggles: Array = []

# Interior padding for _module_panel(). Shared so the side column's precomputed card-sizing math
# (which needs to know its true available height up front, unlike the grid columns which just
# react live to whatever rect they're given) can account for the panel eating into it.
const MODULE_PAD := 20.0


func get_chrome() -> Dictionary:
	return {"title": Loc.t("reward.title"), "exit": _skip, "show_footer": true}


func _ready() -> void:
	Sfx.music("music_rewards")
	UIScale.layout_changed.connect(func() -> void: get_tree().reload_current_scene(), CONNECT_ONE_SHOT)

	# Shell mounts this screen as a child of `_lower_area` and only reparents it into the real,
	# margined `wrap` container a moment later (see shell.gd:_rebuild_lower) — so `self`'s rect
	# isn't meaningful until that reparent has actually happened. One frame is enough for it to
	# settle (confirmed: self.size matches wrap's inset rect exactly after this).
	await get_tree().process_frame
	Vfx.play("reward_open_rays", self)   # the chest-lid moment (entry carries the open sound)

	var compact := UIScale.is_compact()

	# Standalone mode: a reward not tied to a combat win (e.g. the charm choice after clearing a
	# stage). The offers come from GameData.pending_reward_offers, there's no gold/exp/material
	# summary and no bonus-card side column — just the pick. See GameData.pending_reward_*.
	var standalone := not GameData.pending_reward_offers.is_empty()

	# The authoritative "how tall can our content actually be" figure. Deliberately NOT derived
	# from body/content_row's own reported size: those are real Containers, and CardUI defaults to
	# reporting its native 260x340 as its own minimum size before anything explicitly resizes it —
	# that default propagates upward through side_col/content_row and forces body (a Container) to
	# grow past what its anchors actually want, well before our own sizing code gets a chance to
	# shrink it back down. `wrap` (the MarginContainer Shell provides) is sized top-down from the
	# viewport/header/footer and is completely unaffected by anything inside it, so it's the one
	# reliable source for "how much room do we really have."
	var wrap := get_parent()
	var avail_h: float = get_viewport_rect().size.y
	if wrap is MarginContainer:
		avail_h = wrap.size.y - wrap.get_theme_constant("margin_top") - wrap.get_theme_constant("margin_bottom")

	var body := VBoxContainer.new()
	body.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	body.clip_contents = true   # anti-bleed safety net: never draw past our own row into the footer
	body.add_theme_constant_override("separation", 14 if compact else 10)
	add_child(body)

	# Title + stat pips share ONE row instead of two stacked rows — collapsing them reclaims a
	# whole row's worth of vertical space for the modules below to actually grow into. Two lines
	# of text-only content taking two full-width rows was exactly the kind of space that should
	# have gone to something that can grow, not to a heading that doesn't need its own row.
	var header_row := HBoxContainer.new()
	header_row.add_theme_constant_override("separation", 28 if compact else 20)
	body.add_child(header_row)

	var title := Label.new()
	if standalone:
		title.text = GameData.pending_reward_title if not GameData.pending_reward_title.is_empty() else Loc.t("reward.choose_default")
	else:
		title.text = Loc.t("reward.victory")
	title.add_theme_font_size_override("font_size", 40 if compact else 32)
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	header_row.add_child(title)

	# Gold/exp/material pips: a wrapping row of chunky stat pills, filling whatever width the
	# title doesn't need. Deliberately NOT ScreenUI.stat() — that's the header's tiny nav-chip
	# scale (font 15/22), the floor for a corner readout, not the target for a body element on a
	# screen that's supposed to read big; _reward_stat() below is the same tag+value chip look at
	# roughly double the scale, sized for this screen instead of the header.
	var summary_strip := HFlowContainer.new()
	summary_strip.add_theme_constant_override("h_separation", 20 if compact else 16)
	summary_strip.add_theme_constant_override("v_separation", 12)
	summary_strip.size_flags_horizontal = SIZE_EXPAND_FILL
	header_row.add_child(summary_strip)

	# The gold/exp/material summary and the bonus-card side column only make sense for a combat win;
	# a standalone reward (e.g. the post-stage charm) has none of these — just the pick.
	var granted_cards: Array[String] = []
	if not standalone and GameData.current_encounter != null:
		# Authored roll + tool-driven per-type default — the same totals apply_encounter_rewards
		# banked at combat end, so the pills always match what the run actually received.
		var gold_gained: int = GameData.reward_gold(GameData.current_encounter)
		summary_strip.add_child(_reward_stat(Loc.t("screen_ui.gold"), "+%d" % gold_gained, Color("9c7a10"), compact))

		var mineral_gained: int = GameData.reward_mineral(GameData.current_encounter)
		if mineral_gained > 0:
			summary_strip.add_child(_reward_stat(Loc.t("reward.stat_mineral"), "+%d" % mineral_gained,
					Materials.color(Materials.MAGIC_MINERAL), compact))

		# Experience was banked at combat end (GameData.apply_encounter_rewards) — show it for feedback.
		var exp_gained: int = GameData.current_encounter.exp_reward
		if exp_gained > 0:
			summary_strip.add_child(_reward_stat(Loc.t("reward.stat_exp"), "+%d" % exp_gained, Color("1f5c8a"), compact))

		# Crafting resources earned this fight (already banked). Each elemental essence reward also
		# grants the matching element CARD to the deck — collected here and shown as actual cards below
		# (rather than as "+1 X card" text), so the player sees exactly what entered their deck.
		var mats: Dictionary = GameData.current_encounter.material_rewards
		for id: String in mats:
			var amt := int(mats[id])
			if amt <= 0:
				continue
			summary_strip.add_child(_reward_stat(Materials.display_name(id), "+%d" % amt, Materials.color(id), compact))
			if id in Materials.ELEMENTS:
				granted_cards.append(id)

	# Built here but added below as part of reward_col (paired with reward_grid, not body directly)
	# so it's centered over the reward grid's own column, not the full screen width — it was
	# visually off-center whenever the bonus-card side column was present.
	var choose_lbl := Label.new()
	choose_lbl.text = Loc.t("reward.pick_one")
	choose_lbl.add_theme_font_size_override("font_size", 40 if compact else 30)
	choose_lbl.add_theme_color_override("font_color", Color("5a4a38"))
	choose_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	# Measuring an orphan Label's minimum size (choose_lbl isn't parented anywhere yet — it's only
	# added to reward_col much later) returns a stale, too-small figure (confirmed: ~33px instead
	# of the ~65px it actually renders at) — the same class of "measured before the tree settles"
	# issue as CardUI's native-size default earlier in this file. Attaching it to `body` briefly and
	# letting a frame pass gives an accurate reading before it's moved into reward_col for real.
	body.add_child(choose_lbl)
	await get_tree().process_frame
	var choose_lbl_h := choose_lbl.get_combined_minimum_size().y
	body.remove_child(choose_lbl)

	# content_row: the bonus-card side column (if any) and the main reward grid never compete for
	# space. Neither panel expands to claim leftover space — both are sized to hug their own real
	# content (see below), so content_row centers the pair as a block; whatever's left over sits
	# OUTSIDE both borders as ordinary screen margin, instead of being trapped inside a panel that
	# implies it's all meaningful.
	var content_row := HBoxContainer.new()
	content_row.size_flags_vertical = SIZE_EXPAND_FILL
	var content_row_sep := 20.0 if compact else 14.0
	content_row.add_theme_constant_override("separation", content_row_sep)
	content_row.alignment = BoxContainer.ALIGNMENT_CENTER
	body.add_child(content_row)

	# skip_btn is built after content_row (below) but its height is a fixed constant either way.
	# content_row_true_h is content_row's real total height, computed from `avail_h` and the other
	# children's own (reliable — plain Labels/HFlowContainer, not subject to CardUI's
	# oversized-default problem) minimum sizes — never from content_row's own reported size, which
	# is what the side column is about to influence (reading it back would reintroduce the same
	# circularity we hit with the skip button earlier).
	#
	# Both side_panel and reward_panel get this SAME full height (both are EXPAND_FILL vertical, so
	# they always match) — but they do NOT get the same amount of USABLE height for their cards:
	# reward_panel reserves real space inside itself for choose_lbl and skip_btn; side_panel has no
	# equivalent overhead. Budgeting the side column as if it also lost that space (an earlier
	# "cancellation" trick, intended to keep both card rows the same height) just shrank the bonus
	# card and left the difference sitting empty at the bottom of its panel — exactly the dead zone
	# from the screenshot. Each column now gets its OWN real budget instead.
	var skip_btn_h := 140.0 if compact else 120.0
	var body_sep := 14.0 if compact else 10.0
	var content_row_true_h := avail_h - header_row.get_combined_minimum_size().y - body_sep

	var side_panel_w := 0.0
	if not granted_cards.is_empty():
		side_panel_w = _build_element_offers(content_row, granted_cards, compact, content_row_true_h - MODULE_PAD * 2.0)

	# Offers are unified Grants (cards from the reward pool, plus an optional relic), rendered and
	# applied generically through the ItemKind layer — see Grant / ItemKinds. The whole offer is
	# clickable (no separate button) to keep picking friction-free. Built here (before reward_panel)
	# so its count is known up front for the width computation below.
	var offers: Array = []
	if standalone:
		offers = GameData.pending_reward_offers.duplicate()
	elif GameData.current_encounter != null:
		if not GameData.current_encounter.reward_offers.is_empty():
			# An encounter with an explicit offer list (elites: relic/charm choice) uses it verbatim.
			offers = GameData.current_encounter.reward_offers.duplicate()
		else:
			for id: String in GameData.current_encounter.reward_pool:
				offers.append(Grant.make("card", id))
			if not GameData.current_encounter.relic_offer.is_empty():
				offers.append(Grant.make("relic", GameData.current_encounter.relic_offer))

	# The reward picks are the main event: a FitGrid (the shared "N card-shaped controls, sized to
	# fill available space, no scrolling" component also used by the shop/deck/event screens).
	# max_card_width is raised well past FitGrid's shop/deck-grid default (260, tuned for grids of
	# many cards) — here there are only ever 2-4 picks and they ARE the screen, so the real ceiling
	# should be whatever the available rect allows, not an arbitrary "don't balloon" guard meant
	# for a different kind of screen.
	#
	# reward_panel is sized to hug the grid's ACTUAL computed block width (via FitGrid's own sizing
	# math, reused here), not "100% of whatever's left in content_row" — with few/height-bound
	# cards, that used to leave a big empty strip inside the panel's border alongside the cards.
	# Computed via FitGrid.compute_layout BEFORE building the grid, so the panel and the grid agree
	# on the same number from the same math — no guessing, no chasing FitGrid's live size after
	# the fact.
	var avail_w: float = get_viewport_rect().size.x
	if wrap is MarginContainer:
		avail_w = wrap.size.x - wrap.get_theme_constant("margin_left") - wrap.get_theme_constant("margin_right")
	var reward_avail_w := avail_w - (side_panel_w + content_row_sep if side_panel_w > 0.0 else 0.0) - MODULE_PAD * 2.0
	var grid_sep := 24.0 if compact else 16.0
	var reward_col_sep := 14.0 if compact else 10.0
	# The height actually available to the GRID itself is content_row's real height minus
	# reward_panel's own top/bottom padding, its two internal separators (above/below the grid,
	# next to choose_lbl and skip_btn), AND choose_lbl/skip_btn's own heights — everything reward_col
	# actually contains besides the grid.
	var reward_grid_h := (content_row_true_h - choose_lbl_h - skip_btn_h
			- MODULE_PAD * 2.0 - reward_col_sep * 2.0)
	var layout := FitGrid.compute_layout(offers.size(), reward_avail_w, reward_grid_h, 900.0, grid_sep)

	var reward_panel := _module_panel()
	reward_panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	reward_panel.custom_minimum_size.x = float(layout["block_w"]) + MODULE_PAD * 2.0
	content_row.add_child(reward_panel)
	var reward_col := VBoxContainer.new()
	reward_col.add_theme_constant_override("separation", reward_col_sep)
	reward_panel.add_child(reward_col)
	reward_col.add_child(choose_lbl)

	var reward_grid := FitGrid.new()
	reward_grid.max_card_width = 900.0
	reward_grid.separation = grid_sep
	reward_grid.size_flags_horizontal = SIZE_EXPAND_FILL
	reward_grid.size_flags_vertical = SIZE_EXPAND_FILL
	reward_col.add_child(reward_grid)

	var offer_controls: Array = []
	for grant: Grant in offers:
		offer_controls.append(_make_offer(grant, compact))
	reward_grid.set_cards(offer_controls)

	var skip_btn := ScreenUI.action_button(Loc.t("reward.skip"), _skip,
		Vector2(440, 140) if compact else Vector2(380, 120), 40 if compact else 30,
		ScreenUI.CHROME_NEUTRAL)
	skip_btn.size_flags_horizontal = SIZE_SHRINK_CENTER
	reward_col.add_child(skip_btn)

	if OS.get_environment("REWARD_DEBUG") != "":
		(func() -> void:
			for i in 5:
				await get_tree().process_frame
			print("DEBUG avail_h=", avail_h, " body.size=", body.size, " content_row.size=", content_row.size,
				" content_row.position=", content_row.position, " content_row bottom=",
				content_row.position.y + content_row.size.y)
			print("DEBUG wrap.size=", wrap.size, " wrap margin_bottom=", wrap.get_theme_constant("margin_bottom"),
				" self.size=", size, " self.global_position=", global_position)
			print("DEBUG viewport=", get_viewport_rect())
		).call()


# A visually distinct module surface — same look as the header/footer bars (ScreenUI.SURFACE_COLOR
# / SURFACE_BORDER), reused here instead of inventing a new style, so each content_row module
# (bonus-card column, reward-pick column) reads as a clearly bounded piece of the screen rather
# than floating text/cards with only whitespace implying where one module ends and another begins.
func _module_panel() -> PanelContainer:
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = ScreenUI.SURFACE_COLOR
	sb.border_color = ScreenUI.SURFACE_BORDER
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(14)
	sb.set_content_margin_all(MODULE_PAD)
	panel.add_theme_stylebox_override("panel", sb)
	panel.size_flags_horizontal = SIZE_EXPAND_FILL
	panel.size_flags_vertical = SIZE_EXPAND_FILL
	return panel


# A tag+value chip at body-content scale, not header scale — same visual language as
# ScreenUI.stat()/header_chip() (reused here), but that helper's font sizes (15/22) are tuned for
# a corner readout, not a screen whose whole job is to read big.
func _reward_stat(tag: String, value: String, value_color: Color, compact: bool) -> Control:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 12)
	h.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var t := Label.new()
	t.text = tag
	t.add_theme_font_size_override("font_size", 30 if compact else 22)
	t.add_theme_color_override("font_color", Color("6b5636"))
	h.add_child(t)
	var v := Label.new()
	v.text = value
	v.add_theme_font_size_override("font_size", 40 if compact else 30)
	v.add_theme_color_override("font_color", value_color)
	h.add_child(v)
	return ScreenUI.header_chip(h)


# The element card(s) earned this fight, each offered with an Accept/Reject toggle (Accept by
# default). Accepted cards are added to the deck on finish; the essence itself is always kept.
# This is the "side column" next to the main reward grid in content_row — it does NOT compete with
# the grid for space (no stretch_ratio).
#
# Cards sit SIDE BY SIDE (not stacked) so each one gets content_row's FULL height — same as the
# main grid's cards. Stacking would cut every card's height in half or worse just because there
# happen to be 2 of them, which is exactly the kind of item-count-driven shrinkage the fill-space
# standard rules out; height here is deliberately count-independent, same as FitGrid's own cards.
# pref_card_w is generous (rarely the binding constraint) since height is the real limiter now.
#
# Card size is computed ONCE and applied at creation, before the CardUI ever enters the tree with
# its native, unsized 260x340 default — that default, if ever exposed to a live Container even
# transiently, propagates upward (side_col and content_row are real Containers) and forces body to
# grow past what its anchors want, which is what caused the skip button to end up positioned off
# the bottom of the screen. Sizing at creation means that never happens.
func _build_element_offers(content_row: HBoxContainer, ids: Array[String], compact: bool,
		content_row_h: float) -> float:
	var valid_ids: Array[String] = []
	for id: String in ids:
		if CardData.get_card(id) != null:
			valid_ids.append(id)
	var n := valid_ids.size()
	if n == 0:
		return 0.0

	# The Accept/Reject toggle is a real interactable, so its tap target floor is fixed (matches the
	# project's button-sizing standard, ScreenUI.action_button's default min_size.y) rather than
	# shrinking along with the card.
	var toggle_h := 96.0 if compact else 64.0
	var slot_sep := 8.0
	var col_sep := 12.0 if compact else 8.0
	var desc_font := 26 if compact else 19

	# Wrapped in the same module panel look as reward_col (see _module_panel) so the bonus-card
	# offer reads as its own distinct piece of the screen, not just some cards floating next to
	# the real pick.
	var side_panel := _module_panel()
	side_panel.size_flags_horizontal = SIZE_SHRINK_CENTER   # content-width, not stretched
	content_row.add_child(side_panel)
	var side_col := VBoxContainer.new()
	side_col.alignment = BoxContainer.ALIGNMENT_CENTER
	side_col.add_theme_constant_override("separation", col_sep)
	side_panel.add_child(side_col)

	var recv_lbl := Label.new()
	recv_lbl.text = Loc.t("reward.bonus_card")
	recv_lbl.add_theme_font_size_override("font_size", 36 if compact else 26)
	recv_lbl.add_theme_color_override("font_color", Color("5a4a38"))
	recv_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	side_col.add_child(recv_lbl)

	# CenterContainer keeps the row (and so each slot) from being stretched out to match "Bonus
	# card:"'s width whenever that label is wider than the 2 slots + separation actually need.
	var row_center := CenterContainer.new()
	side_col.add_child(row_center)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", col_sep)
	row_center.add_child(row)

	# desc_h is a deliberate fixed reservation (not measured from wrapped text) for the same reason
	# recv_lbl above skips autowrap: a wrap-driven height would depend on the width we're about to
	# derive from that same height, which doesn't converge in one pass.
	var desc_h := 96.0 if compact else 74.0
	var label_h := recv_lbl.get_combined_minimum_size().y
	var overhead := label_h + col_sep + toggle_h + slot_sep + desc_h + slot_sep
	# No width cap: the card grows to whatever height content_row_h actually allows. There used to
	# be a pref_card_w ceiling here on the theory that a "secondary" bonus card should read smaller
	# than the hero pick — but that ceiling was what left a dead gap under the Accept button
	# whenever there weren't enough cards to reach it. The card's own overhead (label/toggle/desc)
	# already makes it read smaller than the main grid without an artificial cap on top.
	var card_h := maxf(60.0, content_row_h - overhead)
	var card_w := card_h / FitGrid.RATIO

	for id: String in valid_ids:
		var data := CardData.get_card(id)
		var slot := VBoxContainer.new()
		slot.add_theme_constant_override("separation", slot_sep)
		slot.alignment = BoxContainer.ALIGNMENT_CENTER

		var ui := CardUI.create(CardInstance.from_data(data))
		ui.draggable = false
		ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
		ui.custom_minimum_size = Vector2(card_w, card_h)
		ui.size = Vector2(card_w, card_h)
		# The Accept/Reject toggle's own text content ("Accept" at a big legible font) can need a
		# wider natural minimum than card_w — and it should be allowed that width rather than being
		# squeezed, per the project's tap-target standard. But slot (a VBoxContainer) then reports
		# ITS OWN minimum width as the widest child, i.e. the toggle's, and ui/desc_lbl default to
		# stretching to match that (cross-axis FILL) — which for ui, since CardUI scales uniformly
		# from width, makes the card render TALLER than its card_h box, bleeding into the description
		# below. SHRINK_CENTER here keeps ui/desc_lbl at exactly their intended card_w regardless of
		# how wide the toggle needs to be, centered within the (possibly wider) slot.
		ui.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		slot.add_child(ui)

		var desc_lbl := Label.new()
		desc_lbl.text = TextIcons.plain(data.description)
		desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		desc_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		desc_lbl.add_theme_font_size_override("font_size", desc_font)
		desc_lbl.add_theme_color_override("font_color", Color("4a3d2e"))
		desc_lbl.clip_text = true
		desc_lbl.custom_minimum_size = Vector2(card_w, desc_h)
		desc_lbl.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		slot.add_child(desc_lbl)

		var toggle := CheckButton.new()
		toggle.button_pressed = true   # Accept by default
		toggle.text = Loc.t("reward.accept")
		toggle.add_theme_font_size_override("font_size", 30 if compact else 22)
		toggle.custom_minimum_size = Vector2(card_w, toggle_h)
		toggle.toggled.connect(func(on: bool) -> void:
			toggle.text = Loc.t("reward.accept") if on else Loc.t("reward.reject")
			ui.modulate = Color(1, 1, 1, 1) if on else Color(1, 1, 1, 0.35)
		)
		slot.add_child(toggle)
		# The project theme (assets/ui/theme.tres) only overrides CheckButton's font_color — no
		# stylebox of its own for any state. Its "normal" look happens to read fine, but "hover"
		# renders with no background panel at all (confirmed via screenshot: the box disappears and
		# the text/switch just float with no grouping), rather than falling back to Button's hover
		# style the way normal apparently does. Pulling Button's hover stylebox explicitly and
		# applying it here fixes this one toggle without touching the shared theme (which also
		# affects collection_screen.gd's CheckButtons).
		var btn_hover := toggle.get_theme_stylebox("hover", "Button")
		if btn_hover != null:
			toggle.add_theme_stylebox_override("hover", btn_hover)
		row.add_child(slot)

		_element_toggles.append({"id": id, "btn": toggle, "ui": ui})

	return float(n) * card_w + float(n - 1) * col_sep + MODULE_PAD * 2.0


# A pickable offer. Cards render as the card art plus its rules text below (click anywhere to
# pick); relics render as a card-sized info panel, also click-to-pick. A relic at the capacity cap
# is shown disabled. Sizing is left to the caller's FitGrid, which drives size/position directly.
func _make_offer(grant: Grant, compact: bool) -> Control:
	match grant.kind:
		"card":  return _make_card_offer(grant)
		"charm": return _make_charm_offer(grant)
		_:       return _make_relic_offer(grant)


# Wraps the card art with its description below, within whatever cell FitGrid assigns. Deliberately
# a plain Control, not a VBoxContainer: a real Container here would report a minimum size from its
# children (CardUI's own unsized native 260x340 default among them) that could exceed the cell
# FitGrid explicitly assigns via `card.size =`, overriding it — the same propagation bug fixed in
# the side column, just one level over. A plain Control never reports a size beyond what's set here,
# so it can only ever be exactly the cell FitGrid gives it. Position/size applied on `resized`,
# mirroring how the relic panel below already live-scales its own content from its assigned box.
func _make_card_offer(grant: Grant) -> Control:
	var data := CardData.get_card(grant.id)
	var wrap := Control.new()

	var ui := grant.make_ui()
	ui.mouse_filter = Control.MOUSE_FILTER_STOP   # the offer card captures clicks to pick
	if ui is CardUI:
		(ui as CardUI).draggable = false
		(ui as CardUI).pressed.connect(func() -> void: _pick(grant, ui))
	wrap.add_child(ui)

	var desc_text: String = data.description if data != null else ""
	var desc_lbl := TextIcons.rich_label(desc_text, 16, ScreenUI.TEXT_COLOR, true)
	wrap.add_child(desc_lbl)

	# The card shrinks a deliberate fixed fraction of its cell's height to leave room for the
	# description below, rather than the text overlapping the art or getting clipped.
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
		TextIcons.set_text(desc_lbl, desc_text, true)   # re-derive icon sizes from the new font
	)
	return wrap


func _make_relic_offer(grant: Grant) -> Control:
	var relic := RelicData.get_relic(grant.id)
	var accent := relic.color if relic != null else Color(0.80, 0.74, 0.45)
	return _make_info_offer(grant, Loc.t("reward.tag_relic"), accent,
		relic.icon if relic != null else null,
		relic.letter if relic != null else "✦",
		grant.display_name(),
		relic.description if relic != null else "",
		grant.can_apply(),
		Loc.t("reward.inventory_full"))


# Charm offers are rendered like relics — a card-sized info panel, click to pick — from
# CharmData (icon art when authored, glyph + colour otherwise) and always pickable (charms
# have no capacity cap).
func _make_charm_offer(grant: Grant) -> Control:
	var charm := CharmData.get_charm(grant.id)
	var accent := charm.color if charm != null else Color(0.72, 0.72, 0.80)
	return _make_info_offer(grant, Loc.t("reward.tag_charm"), accent, charm.icon if charm != null else null,
		charm.letter if charm != null else "✦",
		charm.display_name if charm != null else grant.display_name(),
		charm.description if charm != null else "",
		true, "")


# The shared "info panel" offer used by relics and charms: an accent-bordered, card-sized button
# with a glyph/icon, a kind tag, name, description, and (optionally) an unavailable note. Scales its
# own content live from the box FitGrid assigns it. `full_text` shows (and disables the pick) when
# not pickable — an empty string means "always available".
func _make_info_offer(grant: Grant, tag: String, accent: Color, icon: Texture2D, glyph: String,
		name_text: String, desc_text: String, pickable: bool, full_text: String) -> Control:
	var btn: Button = TextIcons.TipButton.new()   # tooltip renders keyword icons
	UIScale.tip(btn, grant.tooltip())
	btn.disabled = not pickable
	var style := StyleBoxFlat.new()
	style.bg_color = ScreenUI.SURFACE_DEEP
	style.set_corner_radius_all(10)
	style.set_border_width_all(3)
	style.border_color = accent
	btn.add_theme_stylebox_override("normal", style)
	btn.add_theme_stylebox_override("disabled", style)
	var hover := style.duplicate() as StyleBoxFlat
	hover.bg_color = ScreenUI.SURFACE_DEEP.lightened(0.08)
	btn.add_theme_stylebox_override("hover", hover)
	btn.add_theme_stylebox_override("pressed", hover)

	var v := VBoxContainer.new()
	v.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	v.clip_contents = true   # safety net only — the live scaling below is what actually keeps fit
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	btn.add_child(v)

	var icon_box: TextureRect = null
	var glyph_lbl: Label = null
	if icon != null:
		icon_box = _offer_icon(icon, 104)
		v.add_child(icon_box)
	else:
		glyph_lbl = _offer_label(glyph, 44, accent.darkened(0.3))
		v.add_child(glyph_lbl)
	var tag_lbl := _offer_label(tag, 16, Color("5a4a38"))
	v.add_child(tag_lbl)
	var name_lbl := _offer_label(name_text, 20, ScreenUI.TEXT_COLOR)
	name_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(name_lbl)
	var desc := TextIcons.rich_label(desc_text, 16, Color("4a3d2e"), true)
	v.add_child(desc)
	var full_lbl: Label = null
	if not pickable and not full_text.is_empty():
		full_lbl = _offer_label(full_text, 16, Color("8a2020"))
		v.add_child(full_lbl)

	# A relic offer is hand-built (not a CardUI, which scales its whole canvas as one unit), so it
	# has to scale its own content live from the box FitGrid actually assigns it — font sizes and
	# spacing derived from the live width, exactly like CardUI derives its Canvas scale from size.x.
	# This is what keeps text from either overflowing a small box or reading tiny in a big one.
	const REF_W := 260.0
	btn.resized.connect(func() -> void:
		var w := maxf(btn.size.x, 1.0)
		var scale := w / REF_W
		if icon_box != null:
			icon_box.custom_minimum_size = Vector2.ONE * (w * 0.42)
		if glyph_lbl != null:
			glyph_lbl.add_theme_font_size_override("font_size", clampi(roundi(44 * scale), 28, 72))
		tag_lbl.add_theme_font_size_override("font_size", clampi(roundi(16 * scale), 12, 26))
		name_lbl.add_theme_font_size_override("font_size", clampi(roundi(20 * scale), 14, 32))
		name_lbl.custom_minimum_size.x = w - 18
		desc.add_theme_font_size_override("normal_font_size", clampi(roundi(16 * scale), 12, 24))
		desc.custom_minimum_size.x = w - 18
		TextIcons.set_text(desc, desc_text, true)   # re-derive icon sizes from the new font
		if full_lbl != null:
			full_lbl.add_theme_font_size_override("font_size", clampi(roundi(16 * scale), 12, 24))
		v.add_theme_constant_override("separation", clampi(roundi(8 * scale), 4, 14))
	)

	if pickable:
		btn.pressed.connect(func() -> void: _pick(grant, btn))
	return btn


# The relic illustration, sized to a fixed square, taking the place of the big glyph label at the
# top of a relic offer. Fit-centred (art carries its own frame + transparency).
func _offer_icon(icon: Texture2D, box: int) -> TextureRect:
	var tex := TextureRect.new()
	tex.texture = icon
	tex.custom_minimum_size = Vector2(box, box)
	tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tex.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return tex


func _offer_label(text: String, font_size: int, col: Color) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", font_size)
	lbl.add_theme_color_override("font_color", col)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return lbl


var _picked := false

func _pick(grant: Grant, source: Control = null) -> void:
	if _picked:   # the claim celebration is awaited — don't let a second click double-grant
		return
	_picked = true
	# The claim celebrates on the offer itself (each entry carries its taken-sound), held so
	# the navigation right after doesn't cut it mid-burst.
	if source != null and is_instance_valid(source):
		match grant.kind:
			"relic": await Vfx.play("reward_relic_halo", source)
			"charm": await Vfx.play("charm_attach_glint", source)
			_:       await Vfx.play("reward_card_burst", source)
	else:
		Sfx.play("reward_card_taken")
	grant.apply()
	_finish()


func _skip() -> void:
	_finish()


func _finish() -> void:
	# A standalone reward (e.g. the post-stage charm) isn't a combat win — no bonus cards, no
	# encounter to clear. Consume the pending request; advance the stage first if it asked to.
	if not GameData.pending_reward_offers.is_empty():
		var advance := GameData.pending_reward_advance_stage
		GameData.pending_reward_offers = []
		GameData.pending_reward_title = ""
		GameData.pending_reward_advance_stage = false
		if advance:
			GameData.advance_stage()   # generates the next stage's map + saves
		else:
			GameData.save_run()
		Nav.goto("res://scenes/map.tscn")
		return

	# Gold + materials were applied at combat end (GameData.apply_encounter_rewards); here we add
	# any ACCEPTED bonus elemental cards plus whatever pick reward was already applied, then leave.
	if GameData.current_run != null:
		for entry: Dictionary in _element_toggles:
			var btn: CheckButton = entry["btn"]
			if btn.button_pressed:
				GameData.current_run.deck.append(DeckCard.make(str(entry["id"])))
	GameData.save_run()
	GameData.current_encounter = null
	Nav.goto("res://scenes/map.tscn")
