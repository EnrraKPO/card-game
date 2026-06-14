extends Control


func _ready() -> void:
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var label := Label.new()
	label.add_theme_font_size_override("font_size", 48)
	label.text = "Hello %s!" % GameData.username
	center.add_child(label)
