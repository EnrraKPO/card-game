class_name VFXPlayer
extends Node

# The combat VFX dispatcher, salvaged from the pre-swap tree: every designed combat look
# (the combat_* entries in data/vfx/vfx.json, renderer "custom") maps to one effect class,
# registered with the Vfx service at setup and addressed by library id — combat keeps
# choreography and drawing, the library keeps the one address space every VFX resolves
# through. THIS SLICE IS THE PLAYER ALONE: the old record-consuming walks (play_results /
# play_interceptions, built over the demolished resolution records) did not come over —
# under the core, cues arrive one at a time through the presentation outlet's stream and
# the presenter builds one VFXEvent per cue (docs/planning/RULINGS.html R13).

var _root: Node


func setup(root: Node) -> void:
	_root = root
	for id: String in EFFECT_SCRIPTS:
		Vfx.register_custom(id, _run_designed.bind(EFFECT_SCRIPTS[id]))


# Fire-and-forget: call without await.  Blocking: await the call.
# ELEMENT RESOLUTION happens here first: when the event carries a composition, the library
# answers with the element-variant look if one is live (projectile_/impact_<sorted comp>),
# else the designed base class plays.
func play(event: VFXEvent) -> void:
	if event.target == null or not is_instance_valid(event.target):
		return
	if event.type == VFXEvent.Type.PROJECTILE:
		var vid := Vfx.resolve("projectile", event.composition)
		if not vid.is_empty():
			await Vfx.play(vid, event.target, {"source": event.source})
			if event.show_impact:
				await play(VFXEvent.health_damage(event.target, event.amount))
				if is_instance_valid(event.target):
					event.target.refresh()
			return
	elif event.type == VFXEvent.Type.HEALTH_DAMAGE:
		var iid := Vfx.resolve("impact", event.composition)
		if not iid.is_empty():
			Vfx.play(iid, event.target)   # the elemental burst under the designed number read
		# The King wounded is the run's own life bleeding — a heavier, screen-worthy cue
		# rides on top of the normal damage read.
		if _is_king(event.target):
			Vfx.play("king_hit_flash", event.target)
	elif event.type == VFXEvent.Type.DEATH:
		# A death may earn a variant dressing (king/tribe/large). It plays OVER the designed
		# fade, which always runs — the card leaving its slot is non-negotiable.
		var did := _death_variant(event.target)
		if not did.is_empty():
			Vfx.play(did, event.target)
	var id := _library_id(event)
	if id.is_empty():
		return
	await Vfx.play(id, event.target, {"event": event})
	if event.type == VFXEvent.Type.PROJECTILE and event.show_impact and _is_king(event.target):
		Vfx.play("king_hit_flash", event.target)


func _is_king(ui: CardUI) -> bool:
	return ui != null and is_instance_valid(ui) and ui.card_data != null \
			and ui.card_data.is_king


# The death dressing a unit earns: the King's shatter, its tribe's signature, or the heavy
# version for expensive units. "" = just the designed fade. Gated on Vfx.live so muted
# placeholders fall back silently.
const LARGE_DEATH_COST := 5

func _death_variant(ui: CardUI) -> String:
	if ui == null or not is_instance_valid(ui) or ui.card_data == null:
		return ""
	var data := ui.card_data
	if data.is_king and Vfx.live("death_king"):
		return "death_king"
	if not data.tribe.is_empty() and Vfx.live("death_" + data.tribe):
		return "death_" + data.tribe
	if data.cost >= LARGE_DEATH_COST and Vfx.live("death_large"):
		return "death_large"
	return ""


# The reticle/category tint for a happening, by the same (attribute, sign) logic that
# routes the effect VFX — one classification, reused.
static func result_color(attr: String, delta: int) -> Color:
	match attr:
		"health": return Color(0.3, 1.0, 0.4) if delta > 0 else Color(1.0, 0.3, 0.3)
		"shield": return Color(0.5, 0.85, 1.0)
		_:        return Color(1.0, 0.85, 0.2) if delta > 0 else Color(0.78, 0.42, 1.0)


# ── The designed looks, as library custom renderers ───────────────────────────
# Each combat_* entry in data/vfx/vfx.json (renderer "custom") maps to one designed effect
# class. Supporting a new VFX type = a new effect file + a row here + a library entry.

var EFFECT_SCRIPTS := {
	"combat_health_damage":   VFXEffectHealthDamage,
	"combat_shield_hit":      VFXEffectShieldHit,
	"combat_heal":            VFXEffectHeal,
	"combat_buff":            VFXEffectBuff,
	"combat_debuff":          VFXEffectDebuff,
	"combat_death":           VFXEffectDeath,
	"combat_card_placed":     VFXEffectCardPlaced,
	"combat_shield_restored": VFXEffectShieldRestored,
	"combat_projectile_orb":  VFXEffectProjectile,
	"combat_projectile_bolt": VFXEffectProjectile,
	"combat_source_glint":    VFXEffectSourceGlint,
	"combat_target_mark":     VFXEffectTargetMark,
	"combat_miss":            VFXEffectMiss,
	# (combat_dodge / combat_crit renderers were nuked with those rules pre-swap; the core
	# re-grew dodge and crit — their cues fall back to combat_miss / the damage read until
	# looks are authored. Journaled.)
}


# The library id a VFXEvent plays as.
func _library_id(event: VFXEvent) -> String:
	match event.type:
		VFXEvent.Type.HEALTH_DAMAGE:   return "combat_health_damage"
		VFXEvent.Type.SHIELD_HIT:      return "combat_shield_hit"
		VFXEvent.Type.HEAL:            return "combat_heal"
		VFXEvent.Type.BUFF:            return "combat_buff"
		VFXEvent.Type.DEBUFF:          return "combat_debuff"
		VFXEvent.Type.DEATH:           return "combat_death"
		VFXEvent.Type.CARD_PLACED:     return "combat_card_placed"
		VFXEvent.Type.SHIELD_RESTORED: return "combat_shield_restored"
		VFXEvent.Type.PROJECTILE:
			if event.proj_style == VFXEvent.Projectile.BOLT:
				return "combat_projectile_bolt"
			return "combat_projectile_orb"
		VFXEvent.Type.SOURCE_TRIGGER:  return "combat_source_glint"
		VFXEvent.Type.TARGET_MARK:     return "combat_target_mark"
		VFXEvent.Type.MISS:            return "combat_miss"
		VFXEvent.Type.DODGE:           return "combat_miss"
		VFXEvent.Type.CRIT:            return "combat_health_damage"
		_:
			push_warning("VFXPlayer: no library id for event type %d" % event.type)
			return ""


# The custom-renderer callable behind every combat entry: instantiate the designed class
# and run it against the VFXEvent carried in opts. Returns at the look's HANDOFF (see
# Vfx's "Sequencing" section) — the class declares its own span, the dial decides how much
# of it counts as its moment, and the tail plays on under the next beat. A class that
# leaves span at 0 is ATOMIC and awaited to its last frame.
func _run_designed(_vd: VFXData, _target: Control, opts: Dictionary, effect_script: GDScript) -> void:
	var event: VFXEvent = opts.get("event")
	if event == null:
		return
	var effect: VFXEffect = effect_script.new()
	effect.setup(event, _root)
	add_child(effect)
	if effect.span <= 0.0:
		await effect.play()
		return
	effect.play()
	await get_tree().create_timer(Vfx.handoff(effect.span, _vd)).timeout
