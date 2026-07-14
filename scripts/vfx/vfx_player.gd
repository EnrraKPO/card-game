class_name VFXPlayer
extends Node

var _root:           Node
var _get_card_ui:    Callable  # func(CardInstance) -> CardUI
# The relic-chip cue for relic-owned interceptions — func(relic_id: String). Injected by
# combat (the tray lives in its chrome); invalid = no chip on screen, cue skipped.
var relic_glint:     Callable


func setup(root: Node, get_card_ui: Callable) -> void:
	_root        = root
	_get_card_ui = get_card_ui
	for id: String in EFFECT_SCRIPTS:
		Vfx.register_custom(id, _run_designed.bind(EFFECT_SCRIPTS[id]))


# Fire-and-forget: call without await.  Blocking: await the call.
# The look is addressed BY LIBRARY ID (the combat_* entries, renderer "custom") and dispatched
# by the Vfx service back into the designed class registered above — combat keeps choreography
# and drawing, the library keeps the one address space every VFX resolves through.
# ELEMENT RESOLUTION happens here first: when the event carries a composition, the library
# answers with the element-variant look if one is live (projectile_/impact_<sorted comp>),
# else the designed base class plays.
func play(event: VFXEvent) -> void:
	if event.type == VFXEvent.Type.PROJECTILE:
		var vid := Vfx.resolve("projectile", event.composition)
		if not vid.is_empty():
			# Variant flight: the library's travel look flies + bursts in the element's skin.
			await Vfx.play(vid, event.target, {"source": event.source})
			# The designed projectile does its impact bookkeeping on arrival (damage number +
			# HP snap); a variant's arrival is now — same bookkeeping, same designed number read.
			if event.show_impact:
				await play(VFXEvent.health_damage(event.target, event.amount))
				if is_instance_valid(event.target):
					event.target.refresh()
			return
	elif event.type == VFXEvent.Type.HEALTH_DAMAGE:
		var iid := Vfx.resolve("impact", event.composition)
		if not iid.is_empty():
			Vfx.play(iid, event.target)   # the elemental burst under the designed number read
		# The King wounded is the run's own life bleeding — a heavier, screen-worthy cue rides
		# on top of the normal damage read.
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
	# A designed projectile resolves its impact internally (no HEALTH_DAMAGE event follows),
	# so the King cue fires here on arrival.
	if event.type == VFXEvent.Type.PROJECTILE and event.show_impact and _is_king(event.target):
		Vfx.play("king_hit_flash", event.target)


# Plays an EffectSystem result array (await it). Three layers read as cause → effect: (1) the SOURCE
# card glints once (its ability fired); (2) every affected card gets a tinted TARGET reticle that
# leads its hit; (3) the effect's own VFX lands. Layers 2 + 3 fire for ALL targets AT ONCE, so a
# multi-target effect (e.g. a death that damages a whole row) reads as one simultaneous burst rather
# than a one-card-at-a-time walk — the reticles still call out exactly who is hit and how. When the
# source unit is on the board, health damage flies in as a projectile from it (the impact snaps HP +
# shows the number on arrival); otherwise damage resolves on the target in place.
# CALLERS MUST AWAIT THIS before cleanup_effect_deaths(), or a killed target is freed mid-sequence.
const SOURCE_HOLD := 0.22   # beat after the caster glints, before its effects start landing
const MARK_LEAD   := 0.24   # the reticle reads as "look at THIS card" before its badge cue fires
const STEP_HOLD   := 0.30   # beat after the burst resolves, before returning
const CHIP_LEAD   := 0.34   # beat after a relic chip glints, before the rewritten effect lands

func play_results(results: Array, source_inst: CardInstance = null,
		cue_status_id: String = "", show_cue: bool = true) -> void:
	var source_ui: CardUI = null
	if source_inst != null and source_inst.row >= 0:
		source_ui = _get_card_ui.call(source_inst) as CardUI
	# The source's composition rides every hit of this resolution, so damage can play its
	# element-variant look — known here even when the source has no on-board UI.
	var comp: Array = []
	if source_inst != null and source_inst.data != null:
		comp = source_inst.data.elements

	# Layer 1 — the CONTAINER cue: glint the container whose effects are about to land, once, and only
	# when the effects actually move a stat (a no-op resolution shouldn't flare). An empty cue id glints
	# the source card itself (the card container); a status id glints that status's pip. `show_cue` off
	# skips it entirely (e.g. run-level effects with no on-board container).
	if show_cue and source_ui != null and is_instance_valid(source_ui) and not results.is_empty():
		if cue_status_id.is_empty():
			await play(VFXEvent.source_trigger(source_ui))
		else:
			var pip := source_ui.find_status_pip(cue_status_id)
			if pip != null:
				pip.flash_proc()
				_status_tick_sfx(cue_status_id)
		await _hold(SOURCE_HOLD)

	# Launch each affected card's reticle + hit as its own sub-sequence and let them run together.
	# `remaining` is a mutable box (Array so the concurrent calls share one counter); each sub-
	# sequence ticks it down when its hit lands, and we drain the box before returning so callers
	# still see every hit resolved before they sweep deaths.
	var remaining := [0]
	for r: Dictionary in results:
		if r.is_empty():
			continue
		# Whatever intercepted this result's mutation inside the Resolver cues FIRST — the
		# rewriter (relic chip / status pip) reads as the cause of the adjusted number.
		if r.has("interceptions"):
			await play_interceptions(r.get("interceptions"))
		# A status application has no stat delta — it's its own cue: mark the target, then pop the
		# pip that was added/stacked. Handled up front, sequentially, so it reads before stat hits.
		if r.has("status_applied"):
			await _play_status_applied(r.get("target"), str(r.get("status_applied", "")))
			continue
		# A side-targeted result (draw/mana — target is a CombatSide, not a card) has no board
		# surface here: its presentation IS the hand/gauge reacting to the side's signals.
		var inst := r.get("target") as CardInstance
		if inst == null or inst.row < 0:
			continue
		var card_ui: CardUI = _get_card_ui.call(inst) as CardUI
		if card_ui == null:
			continue
		var attr:  String = r.get("attribute", "")
		var delta: int    = r.get("delta", 0)
		if delta == 0:
			continue
		remaining[0] += 1
		_play_target(card_ui, attr, delta, source_ui, comp, remaining)

	if remaining[0] == 0:
		return
	while remaining[0] > 0:
		await get_tree().process_frame
	await _hold(STEP_HOLD)


# Plays the cue for each interception record (Outcome.interceptions, or a result dict's
# "interceptions" key), in firing order — pure playback; resolution already happened. A
# status-owned record flashes that status's pip on its holder; a card-owned one glints the
# holder's card; a relic-owned one glints its tray chip via the injected relic_glint.
# Upgrades (and un-owned run records) have no combat chip — no cue surface.
func play_interceptions(records: Array) -> void:
	for rec: Dictionary in records:
		var kind := str(rec.get("owner_kind", ""))
		if kind == "relic":
			if relic_glint.is_valid():
				relic_glint.call(str(rec.get("owner_id", "")))
				await _hold(CHIP_LEAD)
			continue
		if kind != "status" and kind != "card":
			continue
		var holder: CardInstance = rec.get("holder")
		if holder == null or holder.row < 0:
			continue
		var ui := _get_card_ui.call(holder) as CardUI
		if ui == null or not is_instance_valid(ui):
			continue
		if kind == "status":
			var pip := ui.find_status_pip(str(rec.get("owner_id", "")))
			if pip != null:
				pip.flash_proc()
		else:
			await play(VFXEvent.source_trigger(ui))
		await _hold(SOURCE_HOLD)


# A status landing on a card: a benefit-tinted reticle on the card, then refresh so the new/updated
# pip exists, then pop that pip so the gained stack reads. No stat number — the pip carries the count.
func _play_status_applied(inst: CardInstance, status_id: String) -> void:
	if inst == null or inst.row < 0:
		return
	var card_ui: CardUI = _get_card_ui.call(inst) as CardUI
	if card_ui == null or not is_instance_valid(card_ui):
		return
	var sd := StatusData.get_status(status_id)
	var beneficial := sd == null or sd.beneficial
	var tint := Color(0.55, 0.95, 0.6) if beneficial else Color(0.95, 0.55, 0.55)
	Sfx.play("status_apply_buff" if beneficial else "status_apply_debuff")
	await play(VFXEvent.target_mark(card_ui, tint))
	card_ui.refresh()
	await get_tree().process_frame   # let the freshly built pip lay out before it can pivot/pop
	var pip := card_ui.find_status_pip(status_id)
	if pip != null:
		pip.flash_applied()
	await _hold(MARK_LEAD)


# One affected card's slice of a (possibly multi-target) resolution, run concurrently with its
# siblings: the tinted reticle leads (so the eye arrives first), then the effect's own VFX lands.
# Ticks `remaining` down on completion so play_results knows when the whole burst has resolved.
func _play_target(card_ui: CardUI, attr: String, delta: int, source_ui: CardUI,
		comp: Array, remaining: Array) -> void:
	# Layer 2 — target reticle leads the hit, tinted by what's happening to this card.
	await play(VFXEvent.target_mark(card_ui, _result_color(attr, delta)))
	await _hold(MARK_LEAD)
	# Layer 3 — the effect's own VFX. A projectile defers the HP snap to its own impact, so
	# don't double-refresh here. Damage carries the source's composition so the library can
	# answer with the element-variant look (see play()).
	var deferred := false
	match attr:
		"health":
			if delta < 0:
				if source_ui != null and is_instance_valid(source_ui) and source_ui != card_ui:
					var shot := VFXEvent.projectile(source_ui, card_ui, -delta)
					shot.composition = comp
					await play(shot)
					deferred = true
				else:
					var hit := VFXEvent.health_damage(card_ui, -delta)
					hit.composition = comp
					await play(hit)
			else:
				await play(VFXEvent.heal(card_ui, delta))
		"shield":
			if delta < 0: await play(VFXEvent.shield_hit(card_ui, -delta))
			else:         await play(VFXEvent.shield_restored(card_ui, delta))
		_:
			if delta > 0: await play(VFXEvent.buff(card_ui, attr, delta))
			else:         await play(VFXEvent.debuff(card_ui, attr, -delta))
	# The instance was already mutated by the effect; snap the card's printed stats so the
	# change is visible immediately, not only at the next board-wide refresh (end of turn).
	if not deferred and is_instance_valid(card_ui):
		card_ui.refresh()
	remaining[0] -= 1


func _hold(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _is_king(ui: CardUI) -> bool:
	return ui != null and is_instance_valid(ui) and ui.card_instance != null \
			and ui.card_instance.data != null and ui.card_instance.data.is_king


# The death dressing a unit earns: the King's shatter, its tribe's signature, or the heavy
# version for expensive units. "" = just the designed fade. Gated on Vfx.live so muted
# placeholders fall back silently.
const LARGE_DEATH_COST := 5

func _death_variant(ui: CardUI) -> String:
	if ui == null or not is_instance_valid(ui) or ui.card_instance == null:
		return ""
	var data := ui.card_instance.data
	if data == null:
		return ""
	if data.is_king and Vfx.live("death_king"):
		return "death_king"
	if not data.tribe.is_empty() and Vfx.live("death_" + data.tribe):
		return "death_" + data.tribe
	if data.cost >= LARGE_DEATH_COST and Vfx.live("death_large"):
		return "death_large"
	return ""


# A status proc's sound, when the library defines one for it (damage_poison_tick, …).
func _status_tick_sfx(status_id: String) -> void:
	var tick := "damage_%s_tick" % status_id
	if SoundData.get_sound(tick) != null:
		Sfx.play(tick)


# The reticle/category tint for a result, by the same (attribute, sign) logic that routes the
# effect VFX below — one classification, reused. Extend both together when adding a category.
func _result_color(attr: String, delta: int) -> Color:
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
}


# The library id a VFXEvent plays as. The two projectile looks share one class; the event's
# style picks the entry.
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
		_:
			push_warning("VFXPlayer: no library id for event type %d" % event.type)
			return ""


# The custom-renderer callable behind every combat entry: instantiate the designed class and
# run it against the VFXEvent carried in opts, drawing into the combat tree exactly as before.
func _run_designed(_vd: VFXData, _target: Control, opts: Dictionary, effect_script: GDScript) -> void:
	var event: VFXEvent = opts.get("event")
	if event == null:
		return
	var effect: VFXEffect = effect_script.new()
	effect.setup(event, _root)
	add_child(effect)
	await effect.play()
