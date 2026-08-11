class_name CandidateApply
extends RefCounted

# The apply seam: simulate one candidate and return the BoardState the position becomes
# (design decision 17 — evaluate the resulting STATE, never classify the action). The
# caller's state is never touched.
#
# Two tiers since the decoupling refactor (COMBAT_DECOUPLING_REFACTOR.md Step 5):
#   · place / move — pure geometry, applied to a BoardState copy (cheap, no rules; a
#     placement's played effects are deliberately not simulated yet — widening that is a
#     scoring decision, not plumbing).
#   · cast / ability — REMOVED with the effect system (see the real-rules NEED block
#     below); no such candidates are generated while can_simulate_cast refuses everything.
#
# `sim` is the per-turn simulation context the engine threads through:
#   { "world":    CombatWorld — the LIVE world; never mutated, only copied,
#     "accepted": Array — this turn's accepted candidate dicts, in acceptance order }


static func apply(state: BoardState, cand: Dictionary, sim: Dictionary = {}) -> BoardState:
	match String(cand["kind"]):
		"place":
			var placed := state.copy()
			var inst: CardInstance = cand["inst"]
			var u := BoardState.UnitState.from_instance(inst)
			u.owner = 1   # hand cards haven't been assigned a side yet
			placed.place(u, int(cand["row"]), int(cand["col"]))
			return placed
		"move":
			var moved := state.copy()
			var from_r := int(cand["from_row"])
			var from_c := int(cand["from_col"])
			var mover: BoardState.UnitState = moved.unit_at(1, from_r, from_c)
			moved.grid_of(1)[from_r][from_c] = null
			moved.place(mover, int(cand["row"]), int(cand["col"]))
			return moved
		"arrange":
			# Two moves, one destination board — sequenced exactly as enumerated
			# (CandidateMoves._feasible_pair guarantees each step's slot is free).
			var arranged := state.copy()
			for m: Dictionary in (cand["moves"] as Array):
				var fr := int(m["from_row"])
				var fc := int(m["from_col"])
				var mv: BoardState.UnitState = arranged.unit_at(1, fr, fc)
				arranged.grid_of(1)[fr][fc] = null
				arranged.place(mv, int(m["row"]), int(m["col"]))
			return arranged
		"cast", "ability":
			# EFFECT SIMULATION REMOVED (effect-cleanse demolition) — see the NEED block below.
			push_error("CandidateApply: cast/ability candidates cannot exist while the effect "
					+ "system is demolished")
			return state.copy()
	push_error("CandidateApply: unknown candidate kind '%s'" % String(cand["kind"]))
	return state.copy()


# ── The sim-support gate (decision 18 under the real rules) — RAZED with the effect
# layer, 2026-08-11. NEEDS, when the rebuilt structures land:
#   · a simulatability gate — the real rules run in simulation, so the refuse-list holds
#     only the genuinely unknowable-or-unsafe: probabilistic effects (the sim would have
#     to guess the roll) and random discards (a nondeterministic pick). A cast still needs
#     at least one played-effect — a castable no-op isn't a candidate.
#   · needs_manual — whether the cast needs a manually picked target; the candidate
#     generators then enumerate one candidate per possible target ("tested against EVERY
#     possible target", decision 17). Must come from the targeting authority's declared
#     gesture requirement, never from a policy peek.


# ── The real-rules path — EFFECT SIMULATION REMOVED (effect-cleanse demolition) ────────
# The third copy of the ON_PLAY dispatcher lived here (_run_cast) and died with the other
# two (SpellCaster._resolve_on_play, Combat._cast_enemy_spell). The seam's DOCTRINE, which
# the rebuilt path must honor when cast/ability simulation returns:
#   · REAL RULES ON A WORLD COPY: copy the live CombatWorld, replay this turn's accepted
#     candidates onto the copy (place/move/arrange = geometry; casts = the one pipeline),
#     run the candidate through the SAME resolution path the live game uses — never a
#     shadow interpreter — then capture the result into the scorer's read-model.
#   · THE HYPOTHETICAL SCOPE (CombatRng.enter/exit_hypothetical): planning rolls
#     dodge/crit/chance from a throwaway generator, never the fight's own streams, or the
#     combat-log seed stops reproducing the fight the moment the CPU thinks differently.
#   · CAPTURE-BACK FORWARDING (⚠): the read-model is built fresh, not copied, so EVERY
#     engine-stamped BoardState field must be forwarded BY HAND or it silently reads zero
#     on the cast path only (how the idle-hand criterion first went quiet on heals). A new
#     BoardState field goes in three places: BoardState.copy(), the capture-back, and
#     wherever the engine stamps it. Sources map back to live identity tokens; sim-born
#     spawns keep their copies. The ground is re-captured from the world, never forwarded.
#   · Only THIS candidate's deaths join the graveyard delta (replayed corpses already sit
#     in the working state's graveyard).
