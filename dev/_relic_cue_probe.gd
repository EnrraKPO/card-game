extends Node
# Diagnostic: runs the STUB fight's world (no screen) with a recording outlet and prints
# every windup/cue beat involving the relic, statuses, and poison — separating "the
# engine never cues" from "the screen never dresses". Commanders are the pass-only base:
# the two kings trade blows, so the player king's strike is the relic's occasion.
# "D:/Godot/Godot_v4.6.3-stable_win64_console.exe" --headless --path . res://dev/_relic_cue_probe.tscn


class RecordingOutlet extends PresentationOutlet:
	var lines: Array[String] = []

	func cue(visual: StringName, recipient: GameEntity, magnitude: float,
			variant: StringName = &"") -> void:
		lines.append("cue %s -> %s mag %.0f %s" % [visual, recipient.id, magnitude, variant])

	func windup(visual: StringName, source: GameEntity, recipients: Array[GameEntity]) -> void:
		lines.append("windup '%s' from %s at %d recipients" % [visual, source.id,
				recipients.size()])


func _ready() -> void:
	var fight: Dictionary = FightScreen.real_fight()
	ContentLibrary.clear()
	for envelope: Variant in (fight.content as Dictionary).cards:
		ContentLibrary.register_card(envelope)
	for envelope: Variant in (fight.content as Dictionary).get("statuses", []):
		ContentLibrary.register_status(envelope)
	for envelope: Variant in (fight.content as Dictionary).get("relics", []):
		ContentLibrary.register_relic(envelope)
	var world := World.new(int(fight.seed))
	var outlet := RecordingOutlet.new()
	world.outlet = outlet
	if not Genesis.setup(world, fight.player, fight.enemy):
		print("GENESIS REFUSED")
		get_tree().quit()
		return
	var rounds := 0
	while rounds < 3 and world.clock.outcome == &"":
		await world.clock.run_round()
		rounds += 1
	print("=== beats of interest (%d outlet lines total) ===" % outlet.lines.size())
	for line: String in outlet.lines:
		if line.contains("windup") or line.contains("status") or line.contains("poison") \
				or line.contains("contagion"):
			print(line)
	var found := false
	for entity: GameEntity in world.all_entities():
		if entity is Status and (entity as Status).status_id == &"poison":
			found = true
			print("POISON on-world: housed in '%s' of %s, stacks %.0f" % [
					entity.housing.name if entity.housing != null else &"nowhere",
					entity.housing.owner.id if entity.housing != null else "?",
					entity.get_stat(&"stacks")])
	if not found:
		print("NO poison statuses exist on the world after %d rounds" % rounds)
	get_tree().quit()
