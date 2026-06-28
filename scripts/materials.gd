class_name Materials
extends RefCounted

# Display + lookup helpers for profile crafting resources (the meta economy). Lightweight
# seed of a future MaterialData registry — for now names derive from the element cards and
# colours live here. Materials are an id→count bag on ProfileData, in three categories:
#   • essence — element ids ("fire".."light"); raw drops, refined in the Lab.
#   • stone   — "<element>_stone"; essence refined one tier up (see Lab.refine).
#   • piece   — "<chesspiece>_piece" (pawn..king); chess-piece tokens spent on king-alchemy
#               (the King Forge consumes "king_piece") and future piece crafting.

const ELEMENTS := ["fire", "water", "air", "earth", "darkness", "light"]
const PIECES := ["pawn", "knight", "bishop", "rook", "queen", "king"]

const STONE_SUFFIX := "_stone"
const PIECE_SUFFIX := "_piece"

# Illustrated art for tokens. Piece/stone filenames match the id ("king_piece.png",
# "fire_stone.png"); essence ids are the bare element, so their art is "<element>_essence.png".
const PIECE_ART_DIR := "res://assets/ui/pieces/"
const STONE_ART_DIR := "res://assets/ui/stones/"
const ESSENCE_ART_DIR := "res://assets/ui/essences/"

const ELEMENT_COLOR := {
	"fire":     Color(0.90, 0.35, 0.20),
	"water":    Color(0.30, 0.55, 0.95),
	"air":      Color(0.70, 0.85, 0.95),
	"earth":    Color(0.55, 0.75, 0.35),
	"darkness": Color(0.60, 0.40, 0.80),
	"light":    Color(0.95, 0.90, 0.50),
}

# Chess pieces aren't elemental — a metallic palette, brightening toward the King (the prize).
const PIECE_COLOR := {
	"pawn":   Color(0.72, 0.74, 0.80),
	"knight": Color(0.55, 0.70, 0.85),
	"bishop": Color(0.75, 0.60, 0.88),
	"rook":   Color(0.80, 0.62, 0.45),
	"queen":  Color(0.88, 0.70, 0.40),
	"king":   Color(0.95, 0.82, 0.35),
}


# ── id helpers ─────────────────────────────────────────────────────────────────────────

static func is_stone(id: String) -> bool:
	return id.ends_with(STONE_SUFFIX)


static func is_piece(id: String) -> bool:
	return id.ends_with(PIECE_SUFFIX)


# The element an essence/stone belongs to ("fire_stone" -> "fire"; "fire" -> "fire").
static func element_of(id: String) -> String:
	return id.trim_suffix(STONE_SUFFIX)


# The chess piece a piece-token belongs to ("king_piece" -> "king").
static func piece_of(id: String) -> String:
	return id.trim_suffix(PIECE_SUFFIX)


# The stone id for an element ("fire" -> "fire_stone").
static func stone_id(element: String) -> String:
	return element + STONE_SUFFIX


# The piece-token id for a chess piece ("king" -> "king_piece").
static func piece_id(piece: String) -> String:
	return piece + PIECE_SUFFIX


# Category of a material id: "piece", "stone", or "essence".
static func category(id: String) -> String:
	if is_piece(id):
		return "piece"
	if is_stone(id):
		return "stone"
	return "essence"


# ── display ────────────────────────────────────────────────────────────────────────────

# Full label, e.g. "Fire Essence" / "Fire Stone" / "King Piece" — hub, reward, Lab screens.
static func display_name(id: String) -> String:
	if is_piece(id):
		return "%s Piece" % piece_of(id).capitalize()
	if is_stone(id):
		return "%s Stone" % short_name(element_of(id))
	var card := CardData.get_card(id)
	if card != null and not card.elements.is_empty():
		return "%s Essence" % card.display_name
	return id.capitalize()


# Short label, e.g. "Fire" — used in compact map-node previews.
static func short_name(id: String) -> String:
	if is_piece(id):
		return "%s Piece" % piece_of(id).capitalize()
	if is_stone(id):
		return "%s Stone" % short_name(element_of(id))
	var card := CardData.get_card(id)
	return card.display_name if card != null else id.capitalize()


static func color(id: String) -> Color:
	if is_piece(id):
		return PIECE_COLOR.get(piece_of(id), Color(0.85, 0.78, 0.50))
	return ELEMENT_COLOR.get(element_of(id), Color.WHITE)


# The discreet backing tint for a material's token/slot: elemental colour for essences and
# stones, gold for the King (the prize), and a neutral grey for the other chess pieces so
# their illustrated art reads on its own rather than under a coloured wash.
static func frame_tint(id: String) -> Color:
	if is_piece(id) and piece_of(id) != "king":
		return Color(0.78, 0.80, 0.85)
	return color(id)


# Illustrated art for a material id, or null if it has none yet. Pieces, stones and elemental
# essences are all illustrated now.
static func texture(id: String) -> Texture2D:
	var path := ""
	if is_piece(id):
		path = PIECE_ART_DIR + id + ".png"
	elif is_stone(id):
		path = STONE_ART_DIR + id + ".png"
	elif id in ELEMENTS:
		path = ESSENCE_ART_DIR + id + "_essence.png"
	else:
		return null
	if not ResourceLoader.exists(path):
		return null
	return load(path) as Texture2D


# Compact "+2 Fire" summary of a rewards dict (id→count) for map previews.
static func summary(rewards: Dictionary) -> String:
	var parts: Array = []
	for id: String in rewards:
		parts.append("+%d %s" % [int(rewards[id]), short_name(id)])
	return ", ".join(parts)
