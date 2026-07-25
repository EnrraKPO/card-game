class_name FitGrid
extends Control

# A container that sizes a fixed set of card-shaped children to fit its own rectangle exactly —
# as large as possible while ALL of them stay visible, with no scrolling. It picks the column
# count that maximises card size under both the width and height constraint, then lays the cards
# out centered. Recomputes on resize. The guarantee: there is never both clipped/scrolled content
# AND unused space. Children are expected to be uniform CardUI-shaped Controls; their size and
# custom_minimum_size are driven here, so don't set them outside.

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


func _ready() -> void:
	resized.connect(_relayout)


# Replace the displayed set with `cards` (uniform card-shaped Controls) and refit.
func set_cards(cards: Array) -> void:
	for old: Node in get_children():
		remove_child(old)
		old.queue_free()
	for card: Node in cards:
		add_child(card)
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


func _relayout() -> void:
	var kids := get_children()
	var n := kids.size()
	if n == 0 or size.x <= 0.0 or size.y <= 0.0:
		return
	if uniform_gap:
		_relayout_uniform(kids, n)
		return

	var layout := compute_layout(n, size.x, size.y, max_card_width, separation, min_card_width)
	var cw: float = layout["cw"]
	var ch: float = layout["ch"]
	var col_count: int = layout["cols"]
	var row_count: int = layout["rows"]
	var block_h: float = layout["block_h"]

	# Publish the real needed height while the floor forces an overflow (an enclosing
	# ScrollContainer takes it from there); zero otherwise. Guarded against relayout feedback.
	var want_min_y: float = block_h if (min_card_width > 0.0 and block_h > size.y + 0.5) else 0.0
	if absf(custom_minimum_size.y - want_min_y) > 0.5:
		custom_minimum_size.y = want_min_y

	# Centre the whole block vertically; each row is centred horizontally (the last may be partial).
	var oy := maxf(0.0, (size.y - block_h) * 0.5)
	for i in n:
		var card := kids[i] as Control
		if card == null:
			continue
		var r := floori(float(i) / float(col_count))
		var c := i - r * col_count
		var in_row := col_count if r < row_count - 1 else n - col_count * (row_count - 1)
		var row_w := float(in_row) * cw + float(in_row - 1) * separation
		var ox := maxf(0.0, (size.x - row_w) * 0.5)
		card.custom_minimum_size = Vector2(cw, ch)
		card.size = Vector2(cw, ch)
		card.position = Vector2(ox + float(c) * (cw + separation), oy + float(r) * (ch + separation))


# Uniform-gap layout (see `uniform_gap`): the between-card gap equals the border gap within each
# axis. `separation` is the MINIMUM gap; cards grow as large as they can while every gap stays at
# or above it, then the leftover in each axis is split evenly across that axis's gaps (borders
# included), so a full row's card sits exactly one gap in from the edge. A partial last row is
# centred but keeps the same between-card gap.
func _relayout_uniform(kids: Array, n: int) -> void:
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
	if absf(custom_minimum_size.y - want_min_y) > 0.5:
		custom_minimum_size.y = want_min_y

	for i in n:
		var card := kids[i] as Control
		if card == null:
			continue
		var r := floori(float(i) / float(col_count))
		var c := i - r * col_count
		var in_row := col_count if r < row_count - 1 else n - col_count * (row_count - 1)
		# Full rows resolve to a border of exactly gap_x; a partial last row centres its cards
		# (wider side margins) but keeps gap_x between them.
		var row_w := float(in_row) * cw + float(in_row - 1) * gap_x
		var ox := (W - row_w) * 0.5
		card.custom_minimum_size = Vector2(cw, ch)
		card.size = Vector2(cw, ch)
		card.position = Vector2(ox + float(c) * (cw + gap_x), gap_y + float(r) * (ch + gap_y))
