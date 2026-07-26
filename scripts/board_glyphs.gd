class_name BoardGlyphs
extends RefCounted

# The board-slot state icons (see SlotUI). Ships as SVG placeholder art with a PNG-override hook:
# drop a <id>.png next to the <id>.svg in assets/board/ and the game uses the PNG instead — the
# exact convention AttentionBadge uses for its marks (AttentionBadge._art_for). One resolver, cached.

const DIR := "res://assets/board/"

# Preloaded SVG fallbacks — the shipped placeholders. A same-named .png (see _resolve) wins.
const _SVG := {
	"open":       preload("res://assets/board/slot_open.svg"),
	"move_ring":  preload("res://assets/board/slot_move_ring.svg"),
	"move_arrow": preload("res://assets/board/slot_move_arrow.svg"),
	"target_ok":  preload("res://assets/board/slot_target_ok.svg"),
	"target_bad": preload("res://assets/board/slot_target_bad.svg"),
	"attack":     preload("res://assets/board/slot_attack.svg"),
}

static var _cache: Dictionary = {}


# The texture for a glyph id ("open" / "move_ring" / "move_arrow" / "target_ok" / "target_bad"),
# preferring a hand-authored PNG override over the shipped SVG. Resolved once per id, then cached.
static func tex(id: String) -> Texture2D:
	if _cache.has(id):
		return _cache[id]
	var result: Texture2D = _resolve(id)
	_cache[id] = result
	return result


static func _resolve(id: String) -> Texture2D:
	var png_path := DIR + "slot_" + id + ".png"
	if ResourceLoader.exists(png_path):
		var png := load(png_path)
		if png is Texture2D:
			return png as Texture2D
	return _SVG.get(id) as Texture2D
