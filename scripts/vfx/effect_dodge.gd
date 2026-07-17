class_name VFXEffectDodge
extends VFXEffect

# Played when a unit DODGES an attack (the speed-driven avoid in Resolver._apply_damage). The
# target darts aside and snaps back — an active evade, sold by motion — while an agile cyan
# "Dodge!" label pops off it. Distinct from VFXEffectMiss: a miss is the ATTACKER whiffing
# (a grey absence-of-damage), a dodge is the TARGET's own nimbleness reading as a deliberate slip.

const DODGE_COLOR := Color(0.55, 0.92, 1.0)   # agile cyan — reads as speed, not the grey of a whiff
const DASH_PX     := 26.0                     # how far the card slips aside
const DASH_OUT    := 0.09                     # quick flick out…
const DASH_BACK   := 0.16                     # …and a slightly softer settle home


func play() -> void:
	var card := _event.target
	if card == null or not is_instance_valid(card):
		queue_free(); return
	_sidestep(card)
	# Glint the SPEED badge — a dodge is the unit's Speed at work, so the stat that caused it
	# flares with the same pop + brightness the relic chips use when they fire.
	if card.has_method("flash_stat_proc"):
		card.flash_stat_proc("speed")
	_float_label("Dodge!", DODGE_COLOR, "")
	queue_free()


# A lateral flick away from the strike and back to origin. Bound to the card (via its own tween)
# so it self-cancels if the card is freed mid-dodge; returns to `origin` so it never desyncs the
# board layout. Player units (owner 0) sit on the left and slip left; enemy units slip right —
# away from where the attacker lunges in from.
func _sidestep(card: Control) -> void:
	var origin := card.position
	var dir := -1.0 if _owner_of(card) == 0 else 1.0
	var away := origin + Vector2(dir * DASH_PX, -DASH_PX * 0.35)
	var tw := card.create_tween()
	tw.tween_property(card, "position", away, DASH_OUT).set_ease(Tween.EASE_OUT)
	tw.tween_property(card, "position", origin, DASH_BACK).set_ease(Tween.EASE_OUT)


# The owning side of the board card, read off its CardInstance; defaults to player (0) so a
# card without one still slips a sensible way.
func _owner_of(card: Control) -> int:
	var ui := card as CardUI
	if ui != null and ui.card_instance != null:
		return ui.card_instance.owner
	return 0
