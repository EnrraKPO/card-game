class_name CandidateApply
extends RefCounted

# The apply seam: simulate one candidate on a COPY of the board state and return what the
# board becomes (design decision 17 — evaluate the resulting STATE, never classify the
# action). The caller's state is never touched.
#
# Spell and ability candidates route through SimEffects — today a guarded interpreter
# over the real Effect data, later the extracted rules layer (design Part 5, step 0);
# the swap happens inside SimEffects, not here. Do not add effect logic anywhere else.


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
		"cast":
			var spell: CardInstance = cand["inst"]
			SimEffects.apply_cast(next, spell.data.effects, 1, null, _find(next, cand))
		"ability":
			var ab: AbilityData = cand["ability"]
			var holder := next.find(cand["inst"])
			if holder == null:
				push_error("CandidateApply: ability holder not on the simulated board")
				return next
			if ab.tap:
				holder.exhausted = true   # the sim spends the tap, closing repeat windows
			SimEffects.apply_cast(next, ab.effects, 1, holder, _find(next, cand))
		_:
			push_error("CandidateApply: unknown candidate kind '%s'" % String(cand["kind"]))
	return next


# The candidate's manual target, re-found inside the simulated copy (identity token →
# this copy's UnitState). Null for area/self casts.
static func _find(next: BoardState, cand: Dictionary) -> BoardState.UnitState:
	var token: CardInstance = cand.get("target", null)
	return next.find(token) if token != null else null
