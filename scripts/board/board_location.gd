class_name BoardLocation
extends RefCounted

# ONE address on the board, as ONE value (LOCATION_MANAGER_DESIGN.md §4.1). Never loose
# components: handing back a separate row and column is how the material-delivery conflation
# defect got written — someone held a row and a column, needed a side, and took one from the
# ALLEGIANCE channel. A bundled value makes that class of mistake hard to write.
#
# `side` is SPATIAL — which half of the board this cell lives on. It is NOT allegiance.
# A unit's allegiance stays on the unit (CardInstance.owner); where it stands is here.
#
# IMMUTABLE and INTERNED. There are ROWS × COLS × 2 = 24 real addresses in the game, so every
# one of them is a single shared object minted once by `at()`. Two consequences worth having:
# identity comparison IS value comparison (`loc_a == loc_b` means "the same cell"), and a
# location can be a Dictionary key directly. The fields are exposed read-only — a location is
# a value, and a value that can be edited in place is a coordinate store in disguise.
#
# VALIDITY IS ANSWERED HERE, ONCE. `at()` returns null for an address that is not a real cell,
# which replaces the four hand-rolled bounds guards the survey found (§3). "Not on the board"
# stops being a sentinel coordinate and becomes the absence of a location.

const SIDES := 2

var _side: int = -1
var _row: int = -1
var _col: int = -1

var side: int:
	get: return _side
var row: int:
	get: return _row
var col: int:
	get: return _col

# The intern table: Vector3i(side, row, col) -> BoardLocation. Populated on demand and never
# cleared — it holds 24 pure values with no world state in them, so sharing them between the
# live world and a simulation's copy is safe by construction (unlike anything that knows what
# is docked, which is why the MANAGER lives inside the world and this does not).
static var _interned: Dictionary = {}


# True when (side, row, col) names a cell that exists. The one definition of "real address".
static func is_real(p_side: int, p_row: int, p_col: int) -> bool:
	return p_side >= 0 and p_side < SIDES \
			and p_row >= 0 and p_row < BoardData.ROWS \
			and p_col >= 0 and p_col < BoardData.COLS


# THE mint. Null = that is not a cell — an answer, not an error (the caller decides whether an
# off-board address was a bug or a legal edge; see §2.9).
static func at(p_side: int, p_row: int, p_col: int) -> BoardLocation:
	if not is_real(p_side, p_row, p_col):
		return null
	var k := Vector3i(p_side, p_row, p_col)
	var found: BoardLocation = _interned.get(k)
	if found != null:
		return found
	var loc := BoardLocation.new()
	loc._side = p_side
	loc._row = p_row
	loc._col = p_col
	_interned[k] = loc
	return loc


# Every real address, in fixed reading order (side, then row, then column). Fixed because
# simulations re-run and must reproduce results exactly (§4.2).
static func all() -> Array:
	var out: Array = []
	for s in SIDES:
		for r in BoardData.ROWS:
			for c in BoardData.COLS:
				out.append(at(s, r, c))
	return out


# The sort key for deterministic ordering, and the Vector3i form the ground layer was already
# keyed by before this existed.
func key() -> Vector3i:
	return Vector3i(_side, _row, _col)


# True when `other` names the same cell. Identity would do (interning guarantees it); this
# exists so call sites can say what they mean and stay null-safe.
func same_as(other: BoardLocation) -> bool:
	return other != null and other._side == _side and other._row == _row and other._col == _col


func _to_string() -> String:
	return "(%s r%d c%d)" % ["player" if _side == 0 else "enemy", _row, _col]
