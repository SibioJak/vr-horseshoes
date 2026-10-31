class_name Locomotion
extends RefCounted

## Thumbstick locomotion for the toss test (Fix Pass 2), ordered by
## Chris from the field: "before I kill myself, I need thumbstick
## movement. I can't be walking around the room." The stationary
## assumption failed in his real play space - he walks virtually to
## the stand, up the court to inspect a landing, and between ends.
##
## Pure math + one bit of snap-turn state, no scene access, so the
## logic suites exercise exactly what the headset runs.
##
## Walk: RIGHT stick (moved from the left in Fix Pass 4, Chris's
## field order - his rig, his layout), head-relative on the flat,
## direct (no accel lag, no head-bob), ~2 m/s at full deflection
## past a radial deadzone.
## Turn: LEFT stick X, 30-degree snap steps about the CAMERA's XZ
## position, edge-armed so a held stick fires exactly once per push.
## Left stick Y is deliberately unused.

const WALK_SPEED: float = 2.0
const DEADZONE: float = 0.15
const SNAP_DEGREES: float = 30.0
const SNAP_ON: float = 0.7
const SNAP_OFF: float = 0.3
const PLAY_CENTER := Vector3(0.0, 0.0, -6.096) # court centre (midpoint of the 40 ft)
const PLAY_RADIUS: float = 25.0

var _snap_armed: bool = true


## World-space displacement for one frame of walk-stick input.
## head_basis is the camera's global basis; only its flat forward /
## right matter. Stick Y convention, FIELD-CORRECTED (Fix Pass 4,
## 2026-10-31): Fix Pass 2 assumed the paper Godot/OpenXR convention
## (forward push reads y = -1). On Chris's actual Quest 3 / Virtual
## Desktop rig his forward push reads y = +1 through the "primary"
## action, so the pass-2 build walked him BACKWARD when he pushed
## forward. Forward input is therefore +stick.y here. Do NOT "fix"
## this back from spec memory - the field report on the target rig
## outranks the paper convention.
## Magnitude past the deadzone is rescaled so full deflection is full
## speed and a gentle push is a gentle walk; an over-long diagonal is
## clamped to unit length first so diagonals are not faster.
static func walk_displacement(stick: Vector2, head_basis: Basis, delta: float) -> Vector3:
	var s: Vector2 = stick
	if s.length() > 1.0:
		s = s.normalized()
	var mag: float = s.length()
	if mag < DEADZONE:
		return Vector3.ZERO
	var scaled: float = (mag - DEADZONE) / (1.0 - DEADZONE)
	var dir2: Vector2 = s / mag
	var fwd: Vector3 = -head_basis.z
	fwd.y = 0.0
	var right: Vector3 = head_basis.x
	right.y = 0.0
	if fwd.length() < 0.001 or right.length() < 0.001:
		return Vector3.ZERO
	fwd = fwd.normalized()
	right = right.normalized()
	var dir: Vector3 = right * dir2.x + fwd * dir2.y
	if dir.length() < 0.001:
		return Vector3.ZERO
	return dir.normalized() * (scaled * WALK_SPEED * delta)


## Keep the origin inside a sane disc around the court (XZ only -
## the origin's height never changes) so the player cannot wander
## off into the void and get lost.
static func clamp_origin(pos: Vector3) -> Vector3:
	var out: Vector3 = pos
	var off := Vector2(out.x - PLAY_CENTER.x, out.z - PLAY_CENTER.z)
	if off.length() > PLAY_RADIUS:
		off = off.normalized() * PLAY_RADIUS
		out.x = PLAY_CENTER.x + off.x
		out.z = PLAY_CENTER.z + off.y
	return out


## Rotate a transform about a world pivot (the camera's position)
## around the vertical axis. The pivot's world image is invariant -
## turning in place never translates the player.
static func rotate_about(tf: Transform3D, pivot_world: Vector3, angle_rad: float) -> Transform3D:
	var r := Basis(Vector3.UP, angle_rad)
	var new_origin: Vector3 = pivot_world + r * (tf.origin - pivot_world)
	return Transform3D(r * tf.basis, new_origin)


## Snap-turn edge logic. Feed the left stick's X every frame;
## returns the degrees to rotate THIS frame (0, +30, or -30).
## Positive X (push right) turns right, which is a negative Godot
## yaw. One turn per push past SNAP_ON; re-arms below SNAP_OFF.
func snap_turn_update(stick_x: float) -> float:
	if not _snap_armed:
		if absf(stick_x) < SNAP_OFF:
			_snap_armed = true
		return 0.0
	if stick_x > SNAP_ON:
		_snap_armed = false
		return -SNAP_DEGREES
	if stick_x < -SNAP_ON:
		_snap_armed = false
		return SNAP_DEGREES
	return 0.0
