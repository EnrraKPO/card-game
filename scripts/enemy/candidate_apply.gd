class_name CandidateApply
extends RefCounted

# The apply seam: simulate one candidate on a COPY of the board state and return what the
# board becomes (design decision 17 — evaluate the resulting STATE, never classify the
# action). The caller's state is never touched.
#
# Day one only placement exists. When spell/effect candidates arrive, THIS is the seam
# that calls the extracted rules layer so triggered effects fire in the simulation —
# do not add effect logic anywhere else (design Part 5, step 0).


static func apply(state: BoardState, cand: Dictionary) -> BoardState:
	var next := state.copy()
	match String(cand["kind"]):
		"place":
			var inst: CardInstance = cand["inst"]
			var u := BoardState.UnitState.from_instance(inst)
			u.owner = 1   # hand cards haven't been assigned a side yet
			next.place(u, int(cand["row"]), int(cand["col"]))
		"move":
			var from_r := int(cand["from_row"])
			var from_c := int(cand["from_col"])
			var mover: BoardState.UnitState = next.unit_at(1, from_r, from_c)
			next.grid_of(1)[from_r][from_c] = null
			next.place(mover, int(cand["row"]), int(cand["col"]))
		_:
			push_error("CandidateApply: unknown candidate kind '%s'" % String(cand["kind"]))
	return next
