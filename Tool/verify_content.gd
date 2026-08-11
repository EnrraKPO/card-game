# Headless check that Tool-installed content is actually loaded by the game's
# data registries. Run from the repo root:
#   Godot_v4.6.3-stable_win64_console.exe --headless --path . res://Tool/verify_content.tscn
extends Node

func _ready() -> void:
	var failed := 0

	var card := CardData.get_card("frost_adept")
	failed += _check("card frost_adept loads", card != null)
	if card:
		failed += _check("card is ranged water pawn",
			card.ranged and card.elements == Array(["water"], TYPE_STRING, "", null))
		# (the on-attack chilled effect check died with the effect layer 2026-08-11 —
		# CardData no longer carries effects; the new schema brings its own check)
		failed += _check("card art wired (may be placeholder until the editor imports the png)",
			card.art_path != "")

	var status := StatusData.get_status("chilled")
	failed += _check("status chilled loads", status != null)

	var relic := RelicData.get_relic("winter_sigil")
	failed += _check("relic winter_sigil loads", relic != null)

	var ability := AbilityData.get_ability("frost_nova")
	failed += _check("ability frost_nova loads", ability != null)

	var charm := CharmData.get_charm("frostbrand")
	failed += _check("charm frostbrand loads", charm != null)

	var tree := UpgradeTree.get_tree_def("winterlore")
	failed += _check("upgrade tree winterlore loads", tree != null)
	if tree:
		failed += _check("winterlore has 2 nodes", tree.nodes.size() == 2)

	var enc_found := false
	for t in EncounterTemplateData._all:
		if t.id == "frozen_patrol":
			enc_found = true
	failed += _check("encounter frozen_patrol loads", enc_found)

	print("RESULT: " + ("ALL OK" if failed == 0 else str(failed) + " FAILED"))
	get_tree().quit(0 if failed == 0 else 1)


func _check(name: String, ok: bool) -> int:
	print(("  ok  " if ok else "FAIL  ") + name)
	return 0 if ok else 1
