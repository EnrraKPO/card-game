class_name AllDecision
extends Decision

# Machinery only, never authored: elects the narrowed field whole. The base rules'
# decision — the untap rule reaches every fielded unit, the ramp and refill and draw
# rules reach both sides (Combat Frame §4); a delivery walks every recipient (B32).
# Deterministic — the election is the field in its narrowed order.


func resolve(_plate: Plate, candidates: Array[GameEntity]) -> Array[GameEntity]:
	return candidates
