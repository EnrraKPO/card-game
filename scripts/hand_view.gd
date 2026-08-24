class_name HandView
extends RefCounted

# The fan's own facts (docs/planning/RULINGS.html R8): the ordered items the bar presents.
# Fan-level states (which item is lifted, inspected, being dragged) join here as their
# micro-atoms land — the bar renders this view and nothing else.

var items: Array[HandItemView] = []
