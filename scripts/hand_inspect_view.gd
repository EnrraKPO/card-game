class_name HandInspectView
extends RefCounted

# The plain facts the hand's inspect sidebar and ability tray render for ONE unit
# (docs/planning/RULINGS.html R4/R8): the unit's face and text, and one entry per ability —
# its display card (authoring data, like any CardData a widget renders) and its text column.
# Composed by the view model; the bar renders what it is handed and never asks who holds
# what. `enemy` drives the view-only dim — an opponent's roster is information, not a menu.

# The identity token the inspected unit answers to (Selection names it; an Abilities-list
# entry press selects through it). Opaque: compared and handed to the authority, never read.
var subject: Variant = null
var title: String = ""
var description: String = ""
var card: CardData = null                     # the sidebar's preview face
var enemy: bool = false
var ability_names: Array[StringName] = []     # the ask names, parallel to the entries below
var ability_cards: Array[CardData] = []       # each ability's display card (may hold nulls)
var ability_texts: Array[String] = []         # each ability's name+description column text
