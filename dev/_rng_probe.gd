extends Node
# Throwaway probe for CombatRng's two guarantees:
#   1. a seed reproduces its stream exactly;
#   2. a HYPOTHETICAL scope (the enemy engine simulating casts on world copies) cannot
#      disturb the live streams — the property that lets a logged fight survive edits to
#      how the CPU thinks.
#   godot --headless --path . res://dev/_rng_probe.tscn


func _ready() -> void:
	# 1. Same seed, same sequence.
	CombatRng.begin(4242)
	var a: Array = []
	for _i in 8:
		a.append(CombatRng.roll(&"rules"))
	CombatRng.begin(4242)
	var b: Array = []
	for _i in 8:
		b.append(CombatRng.roll(&"rules"))
	print("REPRODUCIBLE: ", a == b)

	# 2. The live sequence with planning noise interleaved must equal the one without.
	CombatRng.begin(4242)
	var c: Array = []
	for i in 8:
		# Between every live roll, "plan": a scope that rolls the same stream hard.
		CombatRng.enter_hypothetical()
		for _j in 25:
			CombatRng.roll(&"rules")
		CombatRng.exit_hypothetical()
		c.append(CombatRng.roll(&"rules"))
	print("HYPOTHETICALS ISOLATED: ", a == c)

	# 3. The streams are independent: burning the ai stream must not move rules.
	CombatRng.begin(4242)
	var d: Array = []
	for i in 8:
		for _j in 13:
			CombatRng.roll_int(0, 99, &"ai")
		d.append(CombatRng.roll(&"rules"))
	print("STREAMS INDEPENDENT: ", a == d)

	# 4. Outside a fight everything falls back to the global generator (no crash, no seed).
	CombatRng.end()
	CombatRng.roll(&"rules")
	print("FALLBACK OK: active=", CombatRng.active())
	get_tree().quit()
