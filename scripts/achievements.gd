class_name Achievements

# A deliberately small, not-yet-user-facing achievement layer. An achievement is a one-time
# milestone: the first time the player meets it, it pays out a reward and (if it celebrates)
# queues a hub celebration, then never fires again — recorded on ProfileData.unlocked_achievements,
# which persists per profile. Today there is exactly one: finishing your first match grants a King
# Piece and celebrates with a Lab nudge. The registry (DEFS) and the generic paths are real, so a
# future milestone is a DEFS entry plus a record_* call at the moment it happens.
#
# TWO-STEP by design. Unlocks happen mid-run (in combat), but the celebration is a blocking modal
# that would fight the run flow there — and its "visit the Lab" call-to-action only makes sense at
# the meta hub, where the Lab lives. So record_* grants + records + QUEUES a celebration; the hub
# (game_world) drains the queue on load and calls celebrate() to show the modal.
#
# Rewards are a small spec (only `king_pieces` is wired). The payout routes through
# GameData.grant_materials, which persists the profile — unlock, reward, and queued celebration
# are all saved together.

const FIRST_MATCH := "first_match"

const DEFS := {
	FIRST_MATCH: {
		"title": "First Steps",
		"body": "You finished your first match and earned a King Piece — the key to forging new Kings.",
		"king_pieces": 1,
		"celebrate": true,   # queue a hub celebration modal on unlock
		"lab_cta": true,     # that modal offers a jump straight to the Lab
	},
}


# Call the moment the player finishes a real (non-practice) match, win OR loss. Grants and records
# the first-match milestone once, and queues its celebration for the next hub visit. No UI here —
# the reward lands quietly; the fanfare is the hub's job (see celebrate()).
static func record_match_completed() -> void:
	_award(FIRST_MATCH)


# Grants a milestone the first time it's met: records the unlock, pays its reward, and queues its
# celebration. A no-op if there's no profile, the id is unknown, or the player already holds it.
static func _award(id: String) -> void:
	var profile: ProfileData = GameData.current_profile
	if profile == null or profile.has_achievement(id):
		return
	var def: Dictionary = DEFS.get(id, {})
	if def.is_empty():
		return
	profile.unlock_achievement(id)
	if def.get("celebrate", false):
		profile.queue_celebration(id)

	var pieces := int(def.get("king_pieces", 0))
	if pieces > 0:
		GameData.grant_materials({Materials.piece_id("king"): pieces})   # adds + saves the profile
	else:
		GameData.save_profile()   # still persist the unlock + any queued celebration


# Shows a milestone's celebration modal over `host` (called by the hub as it drains the queue).
# No-op for an unknown id. The `lab_cta` milestones offer a button that jumps to the Lab.
static func celebrate(id: String, host: Node) -> void:
	var def: Dictionary = DEFS.get(id, {})
	if def.is_empty():
		return
	var icon: Texture2D = null
	if int(def.get("king_pieces", 0)) > 0:
		icon = Materials.texture(Materials.piece_id("king"))
	MilestoneCelebration.open(host, def.get("title", "Achievement"), def.get("body", ""),
		icon, bool(def.get("lab_cta", false)))
