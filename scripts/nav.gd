extends Node

# Autoload (`Nav`). One place that owns "going back". The active screen registers its exit via
# set_back() in _ready (or clear_back() for forward/terminal screens). We route both the OS go-back
# gesture (Android hardware back / browser back) and ui_cancel (Esc) to that handler — and, crucially,
# always consume NOTIFICATION_WM_GO_BACK_REQUEST so the gesture never falls through to the default
# "quit the app". With no handler registered the gesture is simply inert.

var _back: Callable = Callable()
var shell: Node = null


# Registers the persistent Shell (see scripts/shell.gd) so goto() has somewhere to mount content.
func register_shell(s: Node) -> void:
	shell = s


# THE navigation entry point — mounts `scene_path` into the Shell's body instead of replacing the
# whole scene tree, so the Shell's header/footer chrome persists across navigation. Replaces the
# old get_tree().change_scene_to_file(...) calls everywhere.
func goto(scene_path: String) -> void:
	shell.mount(scene_path)


# The active screen's exit. Returning to a parent should re-set this; forward/terminal screens
# clear_back() so the gesture does nothing.
func set_back(action: Callable) -> void:
	_back = action


func clear_back() -> void:
	_back = Callable()


# Invokes the current back handler if one is registered and still valid. Returns whether it fired.
func go_back() -> bool:
	# is_valid() is false once the registering screen frees, so a stale handler is safely ignored.
	if _back.is_valid():
		_back.call()
		return true
	return false


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		go_back()   # consume regardless; no handler => no-op (never quits)


func _unhandled_input(event: InputEvent) -> void:
	# Reached only when no focused Control consumed it (so open modal dialogs keep their own Esc).
	if event.is_action_pressed("ui_cancel") and go_back():
		get_viewport().set_input_as_handled()
