class_name VFXEvent
extends RefCounted

enum Type {
	HEALTH_DAMAGE,
	SHIELD_HIT,
	HEAL,
	BUFF,
	DEBUFF,
	DEATH,
	CARD_PLACED,
	SHIELD_RESTORED,
	COMBINE,
	PROJECTILE,
	SOURCE_TRIGGER,   # the card whose ability fired flares (causality cue)
	TARGET_MARK,      # a card singled out by an effect gets a tinted reticle
	MISS,             # an attack negated (e.g. by Blind): a "Miss" label instead of a damage number
}

# SOURCE_TRIGGER look. Generic for now; the field is here so source glints can later branch by
# the firing trigger (a battlecry shouldn't look like a deathrattle). Add values, don't replumb.
enum TriggerVariant { GENERIC }

# Projectile look: a round magic ORB (triggered/spell damage) vs a sharp BOLT streak that
# orients along its flight path (ranged unit auto-attacks). Same system, distinct visuals.
enum Projectile { ORB, BOLT }

var type:      Type
var target:    CardUI
var source:    CardUI = null    # PROJECTILE: where the shot flies FROM (target is where it lands)
var attribute: String = ""
var amount:    int    = 0
var color:     Color  = Color.WHITE
var proj_style:  Projectile = Projectile.ORB
var variant:     TriggerVariant = TriggerVariant.GENERIC   # SOURCE_TRIGGER look selector
# PROJECTILE: when true the bolt resolves its own impact (flash + "-N HP" + HP snap) on arrival;
# when false it only travels + bursts and the caller applies/labels the damage (auto-attacks,
# which split shield vs health themselves).
var show_impact: bool = true


static func health_damage(card: CardUI, dmg: int) -> VFXEvent:
	var e := VFXEvent.new()
	e.type = Type.HEALTH_DAMAGE; e.target = card; e.amount = dmg
	return e


static func shield_hit(card: CardUI, absorbed: int) -> VFXEvent:
	var e := VFXEvent.new()
	e.type = Type.SHIELD_HIT; e.target = card; e.amount = absorbed
	return e


static func heal(card: CardUI, amount: int) -> VFXEvent:
	var e := VFXEvent.new()
	e.type = Type.HEAL; e.target = card; e.amount = amount
	return e


static func buff(card: CardUI, attr: String, amount: int) -> VFXEvent:
	var e := VFXEvent.new()
	e.type = Type.BUFF; e.target = card; e.attribute = attr; e.amount = amount
	return e


static func debuff(card: CardUI, attr: String, amount: int) -> VFXEvent:
	var e := VFXEvent.new()
	e.type = Type.DEBUFF; e.target = card; e.attribute = attr; e.amount = amount
	return e


static func death(card: CardUI) -> VFXEvent:
	var e := VFXEvent.new()
	e.type = Type.DEATH; e.target = card
	return e


# A negated attack: a "Miss" label floats off the would-be victim, in place of a damage number.
static func miss(card: CardUI) -> VFXEvent:
	var e := VFXEvent.new()
	e.type = Type.MISS; e.target = card
	return e


static func card_placed(card: CardUI) -> VFXEvent:
	var e := VFXEvent.new()
	e.type = Type.CARD_PLACED; e.target = card
	return e


static func shield_restored(card: CardUI, amount: int) -> VFXEvent:
	var e := VFXEvent.new()
	e.type = Type.SHIELD_RESTORED; e.target = card; e.amount = amount
	return e


# The triggering card flares to show ITS ability is what fired (played once per resolution, before
# the effect lands on its targets). `variant` is reserved for per-trigger looks (battlecry vs
# deathrattle); only GENERIC exists today.
static func source_trigger(card: CardUI, variant: TriggerVariant = TriggerVariant.GENERIC) -> VFXEvent:
	var e := VFXEvent.new()
	e.type = Type.SOURCE_TRIGGER; e.target = card; e.variant = variant
	return e


# A reticle that snaps onto a card singled out by an effect — the "this one is being affected"
# cue, tinted (`color`) by what's happening to it so it reads at a glance alongside the source glint.
static func target_mark(card: CardUI, color: Color) -> VFXEvent:
	var e := VFXEvent.new()
	e.type = Type.TARGET_MARK; e.target = card; e.color = color
	return e


# A shot that flies from `source` to `target`. For effect damage (default ORB, show_impact),
# the impact flash + "-N HP" happen on landing. For ranged auto-attacks pass style=BOLT and
# show_impact=false so the caller resolves the (shield-split) damage itself.
static func projectile(source: CardUI, target: CardUI, dmg: int,
		color: Color = Color(1.0, 0.5, 0.15),
		style: Projectile = Projectile.ORB, p_show_impact: bool = true) -> VFXEvent:
	var e := VFXEvent.new()
	e.type = Type.PROJECTILE; e.source = source; e.target = target; e.amount = dmg; e.color = color
	e.proj_style = style; e.show_impact = p_show_impact
	return e
