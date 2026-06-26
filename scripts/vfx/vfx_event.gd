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
}

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


static func card_placed(card: CardUI) -> VFXEvent:
	var e := VFXEvent.new()
	e.type = Type.CARD_PLACED; e.target = card
	return e


static func shield_restored(card: CardUI, amount: int) -> VFXEvent:
	var e := VFXEvent.new()
	e.type = Type.SHIELD_RESTORED; e.target = card; e.amount = amount
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
