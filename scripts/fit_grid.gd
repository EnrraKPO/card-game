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
static func compute_layout(n: int, avail_w: float, avail_h: float, max_w: float, sep: float) -> Dictionary:
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

	var layout := compute_layout(n, size.x, size.y, max_card_width, separation)
	var cw: float = layout["cw"]
	var ch: float = layout["ch"]
	var col_count: int = layout["cols"]
	var row_count: int = layout["rows"]
	var block_h: float = layout["block_h"]

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
