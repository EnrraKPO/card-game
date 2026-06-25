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


func _relayout() -> void:
	var kids := get_children()
	var n := kids.size()
	if n == 0 or size.x <= 0.0 or size.y <= 0.0:
		return

	# Largest card width that still fits all n cards in our rect — try every column count and keep
	# the best, bounded by whichever of width/height runs out first.
	var best_w := 0.0
	var best_cols := 1
	for cols in range(1, n + 1):
		var rows := ceili(float(n) / float(cols))
		var w_by_width := (size.x - float(cols - 1) * separation) / float(cols)
		var w_by_height := ((size.y - float(rows - 1) * separation) / float(rows)) / RATIO
		var w := minf(w_by_width, w_by_height)
		if w > best_w:
			best_w = w
			best_cols = cols

	var cw := minf(best_w, max_card_width)
	var ch := cw * RATIO
	var col_count := best_cols
	var row_count := ceili(float(n) / float(col_count))

	# Centre the whole block vertically; each row is centred horizontally (the last may be partial).
	var block_h := float(row_count) * ch + float(row_count - 1) * separation
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
