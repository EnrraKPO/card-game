class_name TestSuiteOverlay
extends Control

# The test suite inspector — opened from the settings overlay's Test Suite button. It runs
# THE REAL RUNNER (tests/_runner.tscn) in a headless subprocess and presents its verdicts:
# per-suite pass/fail counts, every FAIL line, and the total. A subprocess rather than an
# in-process run because the runner's clean environment WIPES the session (fresh profile,
# no run) — inspecting tests must never cost the player their game. Desktop-only: the web
# export has no processes to spawn (the settings overlay hides the entry there).

const PANEL_WIDTH := 1240.0
const PANEL_HEIGHT_FRAC := 0.86

var _layer: CanvasLayer
var _panel: PanelContainer
var _results: VBoxContainer = null
var _run_button: Button = null
var _done_button: Button = null
var _thread: Thread = null

signal closed


static func open(host: Node) -> TestSuiteOverlay:
	if host == null or not host.is_inside_tree():
		return null
	var overlay := TestSuiteOverlay.new()
	var layer := CanvasLayer.new()
	layer.layer = 210   # above the settings overlay that opened it
	overlay._layer = layer
	layer.add_child(overlay)
	host.get_viewport().add_child(layer)
	return overlay


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	var scrim := ColorRect.new()
	scrim.color = Color(0, 0, 0, 0.66)
	scrim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(scrim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	_panel = PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = CardTooltip.BG_COLOR
	style.set_border_width_all(1)
	style.border_color = CardTooltip.BORDER_COLOR
	style.set_corner_radius_all(10)
	style.set_content_margin_all(44)
	_panel.add_theme_stylebox_override("panel", style)
	center.add_child(_panel)

	var inner := VBoxContainer.new()
	inner.custom_minimum_size.x = minf(PANEL_WIDTH, get_viewport_rect().size.x * 0.86)
	inner.add_theme_constant_override("separation", 24)
	_panel.add_child(inner)

	var title := Label.new()
	title.text = Loc.t("settings.tests")
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 52)
	title.add_theme_color_override("font_color", CardTooltip.TEXT_TITLE)
	inner.add_child(title)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.y = get_viewport_rect().size.y * PANEL_HEIGHT_FRAC - 320.0
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	inner.add_child(scroll)
	_results = VBoxContainer.new()
	_results.add_theme_constant_override("separation", 8)
	_results.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_results)
	_line(_suite_roster_note(), CardTooltip.TEXT_MAIN, 24)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 24)
	inner.add_child(buttons)
	_run_button = ScreenUI.action_button(Loc.t("tests.run"), _run, Vector2(0, 96), 34)
	_run_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	buttons.add_child(_run_button)
	_done_button = ScreenUI.action_button(Loc.t("settings.done"), _close, Vector2(0, 96), 34)
	_done_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	buttons.add_child(_done_button)

	Vfx.play("ui_modal_open_bloom", _panel)


# What is about to run, before any run: the roster straight from the runner's own list — the
# single source of truth the headless gate uses.
func _suite_roster_note() -> String:
	var names: Array[String] = []
	for suite_script: GDScript in preload("res://tests/_runner.gd").SUITES:
		var suite: TestCase = suite_script.new()
		names.append(suite.suite_name())
	return "%d suites: %s" % [names.size(), ", ".join(names)]


# ── The run ─────────────────────────────────────────────────────────────────────

func _run() -> void:
	if _thread != null:
		return
	_run_button.disabled = true
	_done_button.disabled = true
	_clear_results()
	_line(Loc.t("tests.running"), CardTooltip.TEXT_MAIN, 26)
	# The blocking OS.execute rides a Thread so the UI stays alive; results re-enter the main
	# thread through call_deferred.
	_thread = Thread.new()
	_thread.start(_execute_runner)


func _execute_runner() -> void:
	var output: Array = []
	var exit_code := OS.execute(OS.get_executable_path(), [
		"--headless",
		"--path", ProjectSettings.globalize_path("res://"),
		"res://tests/_runner.tscn",
	], output, true)
	var text: String = output[0] if not output.is_empty() else ""
	_show_results.call_deferred(exit_code, text)


func _show_results(exit_code: int, text: String) -> void:
	if _thread != null:
		_thread.wait_to_finish()
		_thread = null
	_run_button.disabled = false
	_done_button.disabled = false
	_clear_results()
	var suite := ""
	for raw: String in text.split("\n"):
		var line := raw.strip_edges()
		if line.begins_with("--"):
			suite = line.trim_prefix("--").trim_suffix("--").strip_edges()
		elif line.begins_with("FAIL:"):
			_line("    ✗ " + line.trim_prefix("FAIL:").strip_edges(),
					Color(0.95, 0.45, 0.4), 22)
		elif line.ends_with("failed") and line.contains("passed,") and suite != "":
			var red := not line.contains(" 0 failed")
			_line("%s %s — %s" % ["✗" if red else "✓", suite, line],
					Color(0.95, 0.45, 0.4) if red else Color(0.55, 0.85, 0.5), 24)
			suite = ""
		elif line.begins_with("TOTAL:"):
			var red := not line.contains(" 0 failed")
			_line(line, Color(0.95, 0.45, 0.4) if red else Color(0.55, 0.85, 0.5), 30)
	if _results.get_child_count() == 0:
		# Nothing parseable came back — the subprocess itself failed; show what it said.
		_line(Loc.t("tests.launch_failed") % exit_code, Color(0.95, 0.45, 0.4), 24)
		for raw: String in text.split("\n").slice(0, 30):
			_line(raw, CardTooltip.TEXT_MAIN, 18)


func _clear_results() -> void:
	for child in _results.get_children():
		_results.remove_child(child)
		child.queue_free()


func _line(text: String, color: Color, size_px: int) -> void:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", size_px)
	label.add_theme_color_override("font_color", color)
	_results.add_child(label)


func _close() -> void:
	# Done is disabled while a run is in flight, so a live thread never needs joining here.
	closed.emit()
	_layer.queue_free()
