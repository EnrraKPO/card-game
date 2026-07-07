class_name EffectTracker
extends RefCounted

# The lifetime authority of a STANDING ("while"-trigger) effect — the track record the
# unified effect model hangs cessation on (see EFFECT_SYSTEM_DESIGN.md §2.3):
#
#     valid()     — queried on EVERY read; monotonic (once false, false forever).
#     intensity() — current magnitude multiplier (a status's stacks); 1 otherwise.
#
# The tracker KIND is authored ON THE EFFECT ({"tracker": {"kind": ...}}); the binding to a
# concrete host object happens here, at bind(), and is resolved entirely inside the tracker —
# the effect never knows what it is bound to, and the host never knows it is being tracked.
# There is deliberately NO per-container-type behavior anywhere outside this file's duck-typed
# probes: a new host works with the existing kinds the moment it exposes the probed surface.
#
# Pull vs push: valid() is the CORRECTNESS mechanism (an un-cleaned-up dead tracker's effects
# are already inert); prompt removal of the host (StatusEngine.advance dropping an expired
# status) is hygiene only. Nothing depends on cleanup running before the next read.
#
# Kinds (inner classes — same single-file rule as TriggerResolver: bind() may run during
# other classes' static-init, and separate files hit the load order):
#   • ContainerTracker ("container") — valid while the bound host still exists (duck probe:
#                 an `exists()` method; hosts without one are permanent for as long as they
#                 are enumerated).
#   • StacksTracker ("stacks")       — valid while the host's stack count is > 0; intensity
#                 = that count. How per-stack scaling is AUTHORED — never evaluator logic
#                 keyed on the container being a status.


func valid() -> bool:
	return true


func intensity() -> int:
	return 1


# The one factory: authored spec + the host object the effect went live in.
static func bind(spec: Dictionary, host: Object) -> EffectTracker:
	match str(spec.get("kind", "container")):
		"stacks":
			return StacksTracker.new(host)
		_:
			return ContainerTracker.new(host)


# Host references are WEAK: the host owns its trackers (StatusInstance._trackers), so a
# strong back-reference would be a RefCounted cycle (leak). A freed host reads as gone —
# which is also the correct validity answer.
class ContainerTracker extends EffectTracker:
	var _host_ref: WeakRef

	func _init(host: Object) -> void:
		_host_ref = weakref(host)

	func valid() -> bool:
		var host: Object = _host_ref.get_ref()
		if host == null:
			return false
		if host.has_method("exists"):
			return bool(host.call("exists"))
		return true


class StacksTracker extends EffectTracker:
	var _host_ref: WeakRef

	func _init(host: Object) -> void:
		_host_ref = weakref(host)

	func valid() -> bool:
		var host: Object = _host_ref.get_ref()
		if host == null:
			return false
		if host.has_method("exists") and not bool(host.call("exists")):
			return false
		return intensity() > 0

	func intensity() -> int:
		var host: Object = _host_ref.get_ref()
		if host == null or host.get("stacks") == null:
			return 0
		return int(host.get("stacks"))
