class_name Locomotion
extends RefCounted

## Thumbstick locomotion for the toss test (Fix Pass 2), ordered by
## Chris from the field: "before I kill myself, I need thumbstick
## movement. I can't be walking around the room." The stationary
## assumption failed in his real play space - he walks virtually to
## the stand, up the court to inspect a landing, and between ends.
##
## Pure math, no state, no scene access, so the logic suites
## exercise exactly what the headset runs.
##
## Fix Pass 6 restored the STANDARD twin-stick scheme, Chris's
## field order after he loaded Ancient Dungeon VR to check what
## his hands know: "When you see me move, that's all left stick.
## Turning is right stick. That's the standard in most games. And
## then the two are blended by player to get where you're going."
## (FP2 shipped this assignment; FP4 swapped the sticks; FP5 put
## the smooth turn on the left. This pass puts the assignment
## back, keeping FP4's walk sign and FP5's smooth turn.)
##
## Walk: LEFT stick, head-relative on the flat, direct (no accel
## lag, no head-bob), ~2 m/s at full deflection past a radial
## deadzone. The Y sign is FP4's field-corrected one - see
## walk_displacement; it travelled with the walk math, unchanged.
## Turn: RIGHT stick X, SMOOTH turning about the CAMERA's XZ
## position at a rate proportional to deflection, up to
## TURN_SPEED at full push (Fix Pass 5: the Fix Pass 2-4 snap
## steps were replaced at Chris's field order - he felt the steps,
## not smooth turning; there is no snap mode anymore).
## Right stick Y is deliberately unused. The two sticks are read
## and applied independently in the same frame, so the player
## blends them into a curved path.

const WALK_SPEED: float = 2.0
const DEADZONE: float = 0.15
const TURN_SPEED: float = 100.0 # degrees per second at full deflection
const PLAY_CENTER := Vector3(0.0, 0.0, -6.096) # court centre (midpoint of the 40 ft)
const PLAY_RADIUS: float = 25.0


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


## Smooth-turn rate for one frame of right-stick X input; returns
## the degrees to rotate THIS frame. Deflection past the deadzone
## is rescaled exactly like walking, so a touch of stick turns
## slowly and precisely and a full push turns at TURN_SPEED.
## Positive X (push right) turns right, which is a negative Godot
## yaw - the sign sense the old snap had. Feed it every frame and
## apply the result about the camera with rotate_about(); the
## heading then moves in small continuous increments, never a step.
static func turn_angle(stick_x: float, delta: float) -> float:
	var mag: float = absf(stick_x)
	if mag < DEADZONE or delta <= 0.0:
		return 0.0
	var scaled: float = (minf(mag, 1.0) - DEADZONE) / (1.0 - DEADZONE)
	return -signf(stick_x) * scaled * TURN_SPEED * delta
