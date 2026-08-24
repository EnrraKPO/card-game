class_name StatusPip
extends Panel

# A status badge shown on a card or a slot's ground row — the scene status_pip.tscn (size,
# fonts, corners, borders are all authored there; edit the scene to restyle/resize). The
# script only binds the per-status DISPLAY FACTS handed to it as a StatusPipView — the pip
# never reads the game world (docs/planning/RULINGS.html R4); whoever composes the view
# answers every question that needs game knowledge. It's a Panel subclass so it can glint
# as the status's container cue (see glint) and show the status's own rich hover tooltip.

var view: StatusPipView = null

# ── Ground-tab mode (a slot's ground status — see SlotUI) ───────────────────────────────────
# A ground status rides the TOP BORDER of its slot with the occupant card drawn OVER it, so the
# square card badge is the wrong shape: most of it would be swallowed. In tab mode the badge is
# reshaped WIDE AND SHORT, and the icon is lifted to OVERFLOW above the tab's own top edge — the
# overflowing icon lands in the row gutter, where no card can reach it, and is what stays legible
# when the tab body is covered. The pip's RECT still spans the whole extent (icon + tab) so the
# hover tooltip answers over the icon too; the tab's fill moves to a child panel (_tab_bg) that
# occupies only the lower band.
# The icon is sized to the budget it must survive in, not to the tab: only what clears the slot
# border stays visible under a card, and an icon read from its top SLIVER alone is unreadable.
# ⚠ THE TRADE THAT GOVERNS THIS NUMBER: the strip that survives an occupant is EXACTLY
# SlotUI.GROUND_ROW_RISE tall, whatever the icon's size — so growing the icon only adds pixels
# BELOW the card, and shrinks the fraction of the glyph a covered tab can show. At 19 against a
# rise of 12, about two thirds clears, which still names the status at a glance. Anything much
# larger is bought entirely from the covered case and paid for on every occupied slot.
const TAB_ICON := 19.0
const TAB_ICON_OVERFLOW := 7.0   # how far the icon rises above the tab body's top edge
# The band is JUST tall enough to hold the icon's dip plus a hair of padding below it — total
# pip = 21px, band 14. It used to run 12px past the icon's bottom, which read as a pointless
# apron hanging into the slot (user call, 2026-08-03).
const TAB_H := 14.0           # the tab body's own height
# ⚠ FALLBACKS ONLY. The real width is computed by the slot and pushed through set_tab_width: it is
# a share of the SLOT's width (SlotUI.GROUND_TAB_WIDTH_FRAC), because "how wide should this read"
# is a question about the space the row has, which the pip cannot see. These two values are what a
# tab wears for the frame between as_ground_tab() and the slot's first layout pass.
const TAB_W := 46.0           # with a count to show; TAB_W_BARE otherwise
const TAB_W_BARE := 26.0
# The icon sits against the tab's RIGHT edge, a hair in from it — the row is right-aligned too, so
# icon and row share one edge and a pile reads as a stack building from the right rather than a
# centred cluster whose contents drift as the count changes.
const TAB_ICON_PAD := 3.0
# While a tab pip flashes it must outrank everything else in its canvas layer — including a
# picked card, which lifts ITSELF to HighlightFx.Z_LIFT, and a z lift outranks tree order.
const GLINT_Z := HighlightFx.Z_LIFT + 10
var _tab := false
var _tab_bg: Panel = null
var _tab_w := 0.0


# Binds a status view onto the scene's nodes (called right after instantiate, before it enters
# the tree — so it uses direct child access, not @onready, and the local-to-scene stylebox
# override).
func setup(v: StatusPipView) -> void:
	view = v
	UIScale.tip(self, v.display_name)

	# Per-status colour onto the badge fill (the stylebox is local-to-scene, so this is per-instance).
	var sb := get_theme_stylebox("panel") as StyleBoxFlat
	if sb != null:
		sb.bg_color = v.color

	# Prefer the status's art; fall back to its coloured glyph.
	var icon := $Icon as TextureRect
	var glyph := $Glyph as Label
	if v.icon != null:
		icon.texture = v.icon
		icon.visible = true
		glyph.visible = false
	else:
		glyph.text = v.glyph
		glyph.visible = true
		icon.visible = false

	# Headline count (bottom-right) — the view already decided what number headlines.
	var count_lbl := $Count as Label
	count_lbl.text = str(v.count)
	count_lbl.visible = v.count > 1

	# Stack tag (top-left) — again the view's call, not a game-rule read.
	var stacks_lbl := $Stacks as Label
	stacks_lbl.text = "x%d" % v.stacks
	stacks_lbl.visible = v.show_stacks


# Reshapes this pip into the ground TAB (see the block at the top). Call after setup() AND after
# the pip is in the tree — it reads the count visibility setup() decided, and lays the count
# out from its own text metrics, which are unresolvable outside a tree.
# `solo` = this tab is ONE unit of a duplicate-display status (StatusPipView.duplicates):
# the row shows one tab per stack, so a number on each would be nonsense — icon only.
# NO GLYPH in tab mode: the text fallback doesn't render reliably on web, and a border-riding
# tab has no room to misrender in. A status without art shows the coloured band alone (visibly
# missing = an authoring nudge), never a glyph. Card pips keep the glyph path untouched.
func as_ground_tab(solo: bool = false) -> void:
	_tab = true
	var glyph := $Glyph as Label
	var count_lbl := $Count as Label
	var stacks_lbl := $Stacks as Label

	glyph.visible = false
	# The stack tag has nowhere to live on a 20px band — the headline count carries the number.
	stacks_lbl.visible = false
	if solo:
		count_lbl.visible = false
	count_lbl.add_theme_font_size_override("font_size", 15)
	count_lbl.add_theme_constant_override("outline_size", 3)

	# The tab's fill moves onto a child band; the pip itself goes transparent so its rect can
	# span the icon's overflow (for hover) without painting a box around it.
	_tab_bg = Panel.new()
	_tab_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tab_bg.add_theme_stylebox_override("panel", _tab_style())
	add_child(_tab_bg)
	move_child(_tab_bg, 0)   # under the icon/labels it backs
	add_theme_stylebox_override("panel", StyleBoxEmpty.new())

	set_tab_width(TAB_W if count_lbl.visible else TAB_W_BARE)


# Sizes the tab to `w` and lays its parts out to it. Split from as_ground_tab so the slot's
# ground row can SHRINK tabs when a stack of duplicates outgrows the slot (SlotUI._layout_ground).
# Only the BAND narrows — the icon keeps its size and simply overhangs a narrower band, so a
# heavy pile reads as tabs crowding and overlapping each other (intended; no stack cap).
func set_tab_width(w: float) -> void:
	if not _tab:
		return
	_tab_w = w
	custom_minimum_size = Vector2(w, TAB_ICON_OVERFLOW + TAB_H)
	size = custom_minimum_size
	_tab_bg.position = Vector2(0.0, TAB_ICON_OVERFLOW)
	_tab_bg.size = Vector2(w, TAB_H)

	var icon := $Icon as TextureRect
	var count_lbl := $Count as Label
	icon.set_anchors_preset(Control.PRESET_TOP_LEFT, true)
	icon.grow_horizontal = Control.GROW_DIRECTION_END
	icon.grow_vertical = Control.GROW_DIRECTION_END
	icon.size = Vector2(TAB_ICON, TAB_ICON)
	# Right-aligned, and when the band is squeezed narrower than the icon the overhang goes LEFT —
	# the right edges of every tab in a compressed pile still line up, so a crowd reads as a stack
	# rather than as a smear.
	var icon_x := w - TAB_ICON - TAB_ICON_PAD
	icon.position = Vector2(icon_x, 0.0)
	if count_lbl.visible:
		# Icon right, count to its LEFT — both in the icon's row, breaking out above the band, so
		# both facts a ground status carries clear the slot border together and survive the card.
		# A count down in the band would be stranded under the occupant.
		_centre_label(count_lbl, Rect2(TAB_ICON_PAD, 0.0,
				maxf(icon_x - TAB_ICON_PAD * 2.0, 1.0), TAB_ICON))


# Centres a label ON a box instead of forcing the box ONTO it. A Label refuses to be smaller than
# its own text, so assigning a box smaller than the text silently inflates the rect — and with the
# scene's grow-both directions that inflation is what pushed the glyph's ink down past the slot
# border, where the card ate it. Centring keeps the INK where the box says, whatever the metrics.
func _centre_label(lbl: Label, box: Rect2) -> void:
	lbl.set_anchors_preset(Control.PRESET_TOP_LEFT, true)
	lbl.grow_horizontal = Control.GROW_DIRECTION_END
	lbl.grow_vertical = Control.GROW_DIRECTION_END
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	var m := lbl.get_combined_minimum_size()
	lbl.size = m
	lbl.position = box.position + (box.size - m) * 0.5


# The tab band's own fill: the BRIGHTEST of the ground layer's three shades (GroundPalette) —
# a tab is the only ground surface drawn on top of another one, sharing the top gutter with the
# slot's frame, and two parts of one system in one flat colour read as a single smeared shape.
# Corners uniformly rounded but DELIBERATELY sharper than the slot's own radius (5) — a small
# marker wearing a big radius on a 13px band read as a blob; near-sharp reads as a tag pinned to
# the border (user call).
func _tab_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = GroundPalette.tab(view.color) if view != null else Color.WHITE
	# The outline is the status's OWN colour in shadow (GroundPalette.tab_border), never the card
	# badge's near-black — the tab has to cut cleanly out of the frame it rides on, in its own
	# colour's terms. Shade separation alone left the two fused (user's call, both directions
	# tried).
	sb.border_color = GroundPalette.tab_border(view.color) if view != null \
			else Color(0.2, 0.2, 0.2)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(2)
	sb.anti_aliasing = true
	return sb


# Status pips carry TWO distinct, reusable cues — the same vocabulary for every status, so "fired"
# and "gained" always read the same way no matter which status it is:
#   • flash_proc    — the status's triggered effect just FIRED: a sharp WHITE discharge + scale
#                     punch.
#   • flash_applied — the status was just APPLIED/stacked onto the card: a softer bloom in the
#                     status's OWN colour + a gentle pop.
# Both bail if the pip isn't laid out yet (can't pivot from a zero rect).

func flash_proc() -> void:
	if size == Vector2.ZERO:
		return
	pivot_offset = _flash_pivot()
	_begin_lift()
	_white_flash()
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(self, "scale", Vector2(1.55, 1.55), 0.14).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)
	tw.chain().tween_property(self, "scale", Vector2.ONE, 0.22).set_ease(Tween.EASE_OUT)
	tw.chain().tween_callback(_end_lift)


func flash_applied() -> void:
	if size == Vector2.ZERO:
		return
	pivot_offset = _flash_pivot()
	_begin_lift()
	_color_ring(view.color if view != null else Color.WHITE)
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(self, "scale", Vector2(1.28, 1.28), 0.12).set_ease(Tween.EASE_OUT)
	tw.chain().tween_property(self, "scale", Vector2.ONE, 0.20).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_SINE)
	tw.chain().tween_callback(_end_lift)


# A tab pip is half-tucked behind a card and grows UP into the row gutter — anchoring the punch
# at its bottom edge keeps the growth out of the card it's riding. A card badge grows from its
# centre as it always has.
func _flash_pivot() -> Vector2:
	return Vector2(size.x * 0.5, size.y) if _tab else size * 0.5


# The glint is the moment a ground tab is allowed to OUTRANK the card covering it — a temporary
# z lift, restored when the flash ends. Card badges have nothing to climb over and stay put.
func _begin_lift() -> void:
	if _tab:
		z_index = GLINT_Z


func _end_lift() -> void:
	if _tab:
		z_index = 0


# A bright white sheen blooming over the pip and fading — the unmistakable "this fired" discharge,
# above the row's clip so it can't be hidden.
func _white_flash() -> void:
	var flash := Panel.new()
	flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	flash.z_index = 50
	flash.size = size
	flash.pivot_offset = _flash_pivot()
	var fs: StyleBoxFlat = _tab_style() if _tab else StyleBoxFlat.new()
	fs.bg_color = Color(1, 1, 1, 0.9)
	if not _tab:
		fs.set_corner_radius_all(8)
	flash.add_theme_stylebox_override("panel", fs)
	add_child(flash)
	var ft := create_tween()
	ft.set_parallel(true)
	ft.tween_property(flash, "scale", Vector2(1.7, 1.7), 0.34).set_ease(Tween.EASE_OUT)
	ft.tween_property(flash, "modulate:a", 0.0, 0.34).set_ease(Tween.EASE_OUT)
	ft.chain().tween_callback(flash.queue_free)


# A hollow ring in `col` ringing outward from the pip and fading — the "gained" bloom, tinted by
# the status so an application reads as arrival, not discharge.
func _color_ring(col: Color) -> void:
	var ring := Panel.new()
	ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ring.z_index = 50
	ring.size = size
	ring.pivot_offset = _flash_pivot()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(col, 0.0)
	sb.border_color = Color(col, 0.85)
	sb.set_border_width_all(3)
	sb.set_corner_radius_all(4 if _tab else 10)
	sb.anti_aliasing = true
	ring.add_theme_stylebox_override("panel", sb)
	add_child(ring)
	var t := create_tween()
	t.set_parallel(true)
	t.tween_property(ring, "scale", Vector2(1.95, 1.95), 0.38).set_ease(Tween.EASE_OUT)
	t.tween_property(ring, "modulate:a", 0.0, 0.38)
	t.chain().tween_callback(ring.queue_free)


func _make_custom_tooltip(_for_text: String) -> Object:
	if view == null or UIScale.is_touch():
		return null
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(ScreenUI.SURFACE_DEEP, 0.97)
	style.set_border_width_all(1)
	style.border_color = view.color
	style.set_corner_radius_all(6)
	style.set_content_margin_all(10)
	panel.add_theme_stylebox_override("panel", style)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	panel.add_child(vbox)

	var title_row := HBoxContainer.new()
	title_row.add_theme_constant_override("separation", 6)
	if view.icon != null:
		var icon := TextureRect.new()
		icon.texture = view.icon
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.custom_minimum_size = Vector2(24.0, 24.0)
		title_row.add_child(icon)
	var title := Label.new()
	title.text = "%s%s" % [view.display_name, (" %d" % view.count) if view.count > 1 else ""]
	title.add_theme_font_size_override("font_size", 16)
	title.add_theme_color_override("font_color", view.color.darkened(0.35))   # light panel
	title_row.add_child(title)
	vbox.add_child(title_row)

	if not view.description.is_empty():
		var desc := Label.new()
		desc.text = TextIcons.plain(view.description)
		desc.autowrap_mode = TextServer.AUTOWRAP_WORD
		desc.custom_minimum_size.x = 240.0
		desc.add_theme_font_size_override("font_size", 14)
		desc.add_theme_color_override("font_color", Color("3a2f22"))   # dark text — panel is light
		vbox.add_child(desc)
	return panel
