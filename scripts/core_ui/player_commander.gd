class_name PlayerCommander
extends Commander

# The player's command span (Combat Frame §5), served by the fight screen: the hand and
# board fire the asks — play, use_ability, Move's ask among the latter — each resolving
# in full before the next; the span ends when the player ends the turn.

var _screen: FightScreen = null


func _init(screen: FightScreen) -> void:
	_screen = screen


func command(world: World) -> void:
	_screen.begin_player_span()
	while true:
		var ask: Event = await _screen.next_command()
		if ask == null:
			break
		await world.cascade.fire(ask)
		_screen.refresh()
	_screen.end_player_span()
