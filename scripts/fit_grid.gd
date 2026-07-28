class_name FitGrid
extends Control

# A container that sizes a fixed set of card-shaped children to fit its own rectangle exactly —
# as large as possible while ALL of them stay visible, with no scrolling. It picks the column
# count that maximises card size under both the width and height constraint, then lays the cards
# out centered. Recomputes on resize. The guarantee: there is never both clipped/scrolled content
# AND unused space. Children are expected to be uniform CardUI-shaped Controls; their size and
# custom_minimum_size are driven here, so don't set them outside.
#
# set_cards is DIFF-AWARE: cards already in the grid are kept (same node), missing ones freed,
# new ones added — so with `animate` on, a membership change plays as motion (survivors glide,
# far movers crossfade, newcomers fade in) instead of a snap. Callers that rebuild every node
# each call simply get the classic all-new snap, so existing screens are unaffected.

const RATIO := 340.0 / 260.0   # CardUI height / width (CardUI.NATIVE_SIZE)

# Cards never upscale past their native width (keeps art crisp and stops a tiny deck from
# ballooning into a few giant cards). Some whitespace is fine — clipping content is not.
@export var max_card_width := 260.0
@export var separation := 10.0
# 0 = cards shrink as far as the fit demands (the guarantee above). >0 = a hard floor: cards
# never go narrower (e.g. a touch-target minimum); the block may then overflow the available
# height, and the grid publishes the height it really needs via custom_minimum_size — host it
# in a ScrollContainer and fit-all degrades to scrolling ONLY once the floor is hit.
@export var min_card_width := 0.0
# Default OFF = the classic behaviour: fixed `separation` between cards, the block centred so the
# border margins are just the leftover (symmetric per axis, but NOT equal to the between-card
# gap). ON = the gap between cards EQUALS the gap to the borders, within each axis (left border
# == horizontal card gap == right border; top == vertical == bottom) by spreading the slack
# across every gap including the borders. Here `separation` is the MINIMUM gap — cards are sized
# as large as possible while every gap stays >= it, so raising `separation` adds breathing room
# everywhere at once. The two axes' gaps can still differ (a fixed card aspect can't fill an
# arbitrary rect evenly in both), but each axis reads as one consistent rhythm.
@export var uniform_gap := false
# OFF (default) = every relayout snaps, exactly the classic behaviour. ON = a set_cards reflow
# ANIMATES: surviving cards glide to their new rect (position + size), a card whose travel would
# exceed FAR_CARDS card-widths CROSSFADES instead (dissolves in place, reappears fading in at its
# slot — a row-wrap must not fly across the whole table), and newly added cards fade in at their
# slot. Container resizes ALWAYS snap — tweening under a live window drag reads as lag, not
# polish. While a reflow is in flight is_settling() is true and `settled` fires once the grid is
# quiet; hosts should gate card interaction on it (mid-glide rects are presentation, not truth).
@export var animate := false

signal settled   # the animated reflow finished (or was cut short) — the grid is quiet again

# Glide duration; a crossfade splits it half dissolve / half reappear. Shared verbatim by the
# forge's fly-home (ForgeFuseAnim) so the table's reflow and the forged card's flight move as ONE
# choreographed motion — same length, same curve, stopping on the same frame. Deliberately
# GENTLE: sine ease-in-out (see the glide tween) at an unhurried pace — the reorganization is
# housekeeping, it must never lunge at the player.
const ANIM_T := 0.4
const FAR_CARDS := 2.6  # travel beyond this many card-widths = crossfade, never a cross-table flight

var _anim_tweens: Array[Tween] = []
var _pending := 0            # live reflow tweens; 0 = settled
# child -> Rect2: where each child is headed under the current layout (== its actual rect once
# settled). Kept so a host can aim an external animation at a card's FINAL home while the glide
# is still in flight — see target_global_rect.
var _targets: Dictionary = {}
# Children currently mid-fade (entrance/crossfade) — ONLY these get their alpha restored when a
# reflow is cut short. Blanket-resetting every child's alpha would stomp host-owned modulate
# states (e.g. the Forge hides a dragged card's grid original via modulate.a).
var _fading: Dictionary = {}


func _ready() -> void:
	resized.connect(_relayout)


func is_settling() -> bool:
	return _pending > 0


# The GLOBAL rect `child` is headed to under the current layout — equal to its actual rect once
# the grid has settled. This is the authoritative "where does this card live" answer while a
# glide is in flight (the child's live rect is presentation, not truth).
func target_global_rect(child: Control) -> Rect2:
	var r: Rect2 = _targets.get(child, child.get_rect())
	return Rect2(get_global_transform() * r.position, r.size)


# Replace the displayed set with `cards` (uniform card-shaped Controls), diff-aware (see header),
# and refit — animated when `animate` is on and the grid already had content (the first
# population just appears; there is nothing on screen for it to transition from).
func set_cards(cards: Array) -> void:
	var prior := get_child_count() > 0
	var keep: Dictionary = {}
	for card: Node in cards:
		keep[card] = true
	for old: Node in get_children():
		if not keep.has(old):
			remove_child(old)
			old.queue_free()
	var fresh: Dictionary = {}
	for i in cards.size():
		var card: Node = cards[i]
		if card.get_parent() != self:
			fresh[card] = true
			add_child(card)
		move_child(card, i)
	if animate and prior:
		_animate_layout(fresh)
	else:
		_relayout()


# Pure sizing math, with no dependency on a live FitGrid instance — so a caller can learn the real
# block size N cards would use within a given budget BEFORE building the grid (or without building
# one at all), e.g. to size an enclosing panel to hug that real content width/height instead of
# guessing or just claiming 100% of whatever space happens to be available.
static func compute_layout(n: int, avail_w: float, avail_h: float, max_w: float, sep: float,
		min_w := 0.0) -> Dictionary:
	if n <= 0 or avail_w <= 0.0 or avail_h <= 0.0:
		return {"cw": 0.0, "ch": 0.0, "cols": 0, "rows": 0, "block_w": 0.0, "block_h": 0.0}
	var best_w := 0.0
	var best_cols := 1
	for cols in range(1, n + 1):
		var rows := ceili(float(n) / float(cols))
		var w_by_width := (avail_w - float(cols - 1) * sep) / float(cols)
		var w_by_height := ((avail_h - float(rows - 1) * sep) / float(rows)) / RATIO
		var w := minf(w_by_width, w_by_height)
		if w > best_w:
			best_w = w
			best_cols = cols
	var cw := minf(best_w, max_w)
	# Floor engaged: hold the cards at min_w and take as many columns as the WIDTH allows —
	# the block grows taller than avail_h, which the caller scrolls (see min_card_width).
	if min_w > 0.0 and cw < min_w:
		cw = min_w
		best_cols = maxi(floori((avail_w + sep) / (min_w + sep)), 1)
	var ch := cw * RATIO
	var col_count := best_cols
	var row_count := ceili(float(n) / float(col_count))
	var block_w := float(col_count) * cw + float(col_count - 1) * sep
	var block_h := float(row_count) * ch + float(row_count - 1) * sep
	return {"cw": cw, "ch": ch, "cols": col_count, "rows": row_count, "block_w": block_w, "block_h": block_h}


# ── Layout targets ──────────────────────────────────────────────────────────────
# Both fit modes reduced to one shape: the target Rect2 for every child (in child order) plus the
# min-height to publish while the touch floor forces an overflow. Pure w.r.t. the children — the
# snap path assigns these rects directly, the animated path tweens toward them.

func _target_layout(n: int) -> Dictionary:
	if uniform_gap:
		return _target_layout_uniform(n)

	var layout := compute_layout(n, size.x, size.y, max_card_width, separation, min_card_width)
	var cw: float = layout["cw"]
	var ch: float = layout["ch"]
	var col_count: int = layout["cols"]
	var row_count: int = layout["rows"]
	var block_h: float = layout["block_h"]

	var want_min_y: float = block_h if (min_card_width > 0.0 and block_h > size.y + 0.5) else 0.0

	# Centre the whole block vertically; each row is centred horizontally (the last may be partial).
	var rects: Array = []
	var oy := maxf(0.0, (size.y - block_h) * 0.5)
	for i in n:
		var r := floori(float(i) / float(col_count))
		var c := i - r * col_count
		var in_row := col_count if r < row_count - 1 else n - col_count * (row_count - 1)
		var row_w := float(in_row) * cw + float(in_row - 1) * separation
		var ox := maxf(0.0, (size.x - row_w) * 0.5)
		rects.append(Rect2(Vector2(ox + float(c) * (cw + separation), oy + float(r) * (ch + separation)),
				Vector2(cw, ch)))
	return {"rects": rects, "min_y": want_min_y}


# Uniform-gap layout (see `uniform_gap`): the between-card gap equals the border gap within each
# axis. `separation` is the MINIMUM gap; cards grow as large as they can while every gap stays at
# or above it, then the leftover in each axis is split evenly across that axis's gaps (borders
# included), so a full row's card sits exactly one gap in from the edge. A partial last row is
# centred but keeps the same between-card gap.
func _target_layout_uniform(n: int) -> Dictionary:
	var W := size.x
	var H := size.y
	var g := separation
	# Pick the column count giving the LARGEST cards while both axes' gaps can stay >= g.
	var best_cw := 0.0
	var best_cols := 1
	for cols in range(1, n + 1):
		var rows := ceili(float(n) / float(cols))
		var cw_w := (W - float(cols + 1) * g) / float(cols)
		var cw_h := (H - float(rows + 1) * g) / (float(rows) * RATIO)
		var cw := minf(minf(cw_w, cw_h), max_card_width)
		if cw > best_cw:
			best_cw = cw
			best_cols = cols
	var col_count := best_cols
	var cw: float = best_cw
	# Touch floor: hold size and take as many columns as the width allows (keeping >= g gaps);
	# the block then overflows the height and an enclosing ScrollContainer scrolls it.
	var overflow := false
	if min_card_width > 0.0 and cw < min_card_width:
		cw = min_card_width
		col_count = maxi(floori((W - g) / (cw + g)), 1)
		overflow = true
	var row_count := ceili(float(n) / float(col_count))
	var ch := cw * RATIO
	# Even split of each axis's slack across its gaps (n cards → n+1 gaps counting both borders).
	var gap_x := (W - float(col_count) * cw) / float(col_count + 1)
	var gap_y := g if overflow else (H - float(row_count) * ch) / float(row_count + 1)

	var block_h := float(row_count) * ch + float(row_count + 1) * gap_y
	var want_min_y: float = block_h if (overflow and block_h > H + 0.5) else 0.0

	var rects: Array = []
	for i in n:
		var r := floori(float(i) / float(col_count))
		var c := i - r * col_count
		var in_row := col_count if r < row_count - 1 else n - col_count * (row_count - 1)
		# Full rows resolve to a border of exactly gap_x; a partial last row centres its cards
		# (wider side margins) but keeps gap_x between them.
		var row_w := float(in_row) * cw + float(in_row - 1) * gap_x
		var ox := (W - row_w) * 0.5
		rects.append(Rect2(Vector2(ox + float(c) * (cw + gap_x), gap_y + float(r) * (ch + gap_y)),
				Vector2(cw, ch)))
	return {"rects": rects, "min_y": want_min_y}


# Publish the real needed height while the floor forces an overflow (an enclosing
# ScrollContainer takes it from there); zero otherwise. Guarded against relayout feedback.
func _publish_min_y(want_min_y: float) -> void:
	if absf(custom_minimum_size.y - want_min_y) > 0.5:
		custom_minimum_size.y = want_min_y


# ── Applying the layout ─────────────────────────────────────────────────────────

# The snap path: every child straight to its target rect. Also the resize handler — a reflow in
# flight when the container resizes is cut short (see _cut_short) and the grid lands instantly.
func _relayout() -> void:
	var kids := get_children()
	var n := kids.size()
	if n == 0 or size.x <= 0.0 or size.y <= 0.0:
		return
	_cut_short()
	var lay := _target_layout(n)
	_publish_min_y(float(lay["min_y"]))
	var rects: Array = lay["rects"]
	_targets.clear()
	for i in n:
		var card := kids[i] as Control
		if card == null:
			continue
		var rect: Rect2 = rects[i]
		_targets[card] = rect
		card.custom_minimum_size = rect.size
		card.size = rect.size
		card.position = rect.position


# The animated path (set_cards with `animate` on): survivors glide, far movers crossfade,
# `fresh` children (just added) fade in at their slot. Fades touch ONLY modulate:a and entrances
# don't scale — a host may own the child's scale (e.g. the Highlight's grow) and its colour.
# A reflow arriving mid-reflow retargets: old tweens are cut and new ones start from wherever
# the cards visually are — never queued, never jumped-to-end.
func _animate_layout(fresh: Dictionary) -> void:
	var kids := get_children()
	var n := kids.size()
	if n == 0 or size.x <= 0.0 or size.y <= 0.0:
		return
	_cut_short()
	var lay := _target_layout(n)
	_publish_min_y(float(lay["min_y"]))
	var rects: Array = lay["rects"]
	_targets.clear()
	for i in n:
		var card := kids[i] as Control
		if card == null:
			continue
		var rect: Rect2 = rects[i]
		_targets[card] = rect
		card.custom_minimum_size = rect.size
		if fresh.has(card):
			# Entrance: appear at the slot, fading in. No motion — it came from nowhere, so any
			# travel would invent an origin.
			card.size = rect.size
			card.position = rect.position
			card.modulate.a = 0.0
			_fading[card] = true
			var tw := create_tween()
			tw.tween_property(card, "modulate:a", 1.0, ANIM_T).set_trans(Tween.TRANS_SINE)
			_track(tw)
		elif card.position.distance_to(rect.position) > FAR_CARDS * rect.size.x:
			# Far mover (typically a row-wrap: far-left, one row up → far-right): dissolve in
			# place and reappear fading in at the slot, instead of a flight across the table.
			_fading[card] = true
			var tw := create_tween()
			tw.tween_property(card, "modulate:a", 0.0, ANIM_T * 0.5).set_trans(Tween.TRANS_SINE)
			tw.tween_callback(func() -> void:
				card.size = rect.size
				card.position = rect.position)
			tw.tween_property(card, "modulate:a", 1.0, ANIM_T * 0.5).set_trans(Tween.TRANS_SINE)
			_track(tw)
		elif card.position.distance_to(rect.position) > 0.5 or \
				(card.size - rect.size).length() > 0.5:
			# The glide: position and size together, sine ease-in-out — starts soft, settles
			# soft. Gentle by design; a fast-launch curve here reads as the table lunging.
			var tw := create_tween()
			tw.set_parallel(true)
			tw.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
			tw.tween_property(card, "position", rect.position, ANIM_T)
			tw.tween_property(card, "size", rect.size, ANIM_T)
			_track(tw)
		else:
			card.size = rect.size
			card.position = rect.position


func _track(tw: Tween) -> void:
	_anim_tweens.append(tw)
	_pending += 1
	tw.finished.connect(func() -> void:
		_pending -= 1
		if _pending == 0:
			_finish_settle())


func _finish_settle() -> void:
	for child: Node in _fading.keys():
		if is_instance_valid(child):
			(child as Control).modulate.a = 1.0
	_fading.clear()
	_anim_tweens.clear()
	settled.emit()


# Cut a reflow short: kill the tweens, restore only OUR fades (see _fading), and — because a
# killed tween never fires `finished` — resolve the settle so a waiter on `settled` isn't left
# hanging. Retargeting calls this immediately before starting the replacement tweens.
func _cut_short() -> void:
	if _pending == 0:
		return
	for tw: Tween in _anim_tweens:
		if tw.is_valid():
			tw.kill()
	_pending = 0
	_finish_settle()
