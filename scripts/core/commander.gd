class_name Commander
extends RefCounted

# A command span's servant (Combat Frame §5). Within its span, a commander fires the ask
# events the card system defines — play, use_ability, Move's ask among the latter — at
# will, each ask resolving in full before the next; the span ends when the commander
# returns. The player's span is served by the interaction layer behind this surface; the
# enemy's by the enemy commander. This base yields at once — the empty span.


func command(_world: World) -> void:
	@warning_ignore("redundant_await")
	await null
