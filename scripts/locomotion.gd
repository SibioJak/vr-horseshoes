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


## Fix Pass 30: THE LINE BARRIER's math. Chris's law, the pass
## condition: "looking straight down from your throwing spot,
## the line stays under your toes." The barrier judges the
## HEAD'S GROUND POSITION (the camera's world XZ), never the
## origin: FP20 clamped the ORIGIN at a plane 0.40 m past the
## line, and a head leaning ahead of its origin crossed freely
## - origin obedient at the plane, head stooped to look down,
## and the head's ground point sat ~0.70 m past the line
## (Chris, 2026-11-08, headset screenshot looking straight
## down: "line is behind me"). A physical room-scale step
## leaked the same way: it moves the head, not the origin,
## and the old clamp never saw it.
##
## Given the origin and head world positions, return the
## origin shifted back along +Z by exactly the head's excess
## past (line_z - epsilon) - the head ends ON the limit, the
## origin retreats as the player leans or steps, and sliding
## along the line (X) is untouched. A head already at or
## behind the limit leaves the origin exactly as it was.
static func line_barrier_origin(origin_pos: Vector3, head_pos: Vector3, line_z: float, epsilon: float) -> Vector3:
	var out: Vector3 = origin_pos
	var limit: float = line_z - epsilon
	if head_pos.z < limit:
		out.z += limit - head_pos.z
	return out


## Rotate a transform about a world pivot (the camera's position)
## around the vertical axis. The pivot's world image is invariant -
## turning in place never translates the player.
##
## Fix Pass 15: the result's basis is built as a pure yaw
## (yaw_of(tf.basis) + angle), NOT composed as Ry(angle) * tf.basis.
## For a level input the two are identical, but the composed form
## PRESERVES any pitch/roll that ever entered the basis - this
## form sheds it. Every origin reorientation in the game walks
## through a yaw-only construction like this one (see
## seat_transform); pitch and roll can never be written into
## the origin, only read out of the head.
static func rotate_about(tf: Transform3D, pivot_world: Vector3, angle_rad: float) -> Transform3D:
	var r := Basis(Vector3.UP, angle_rad)
	var new_origin: Vector3 = pivot_world + r * (tf.origin - pivot_world)
	return Transform3D(Basis(Vector3.UP, yaw_of(tf.basis) + angle_rad), new_origin)


## Heading of a basis in radians: where its -Z points, projected
## on the ground plane. yaw_of(Basis(Vector3.UP, a)) == a, and a
## pitched/rolled basis still yields its heading - this is how a
## yaw is EXTRACTED from a head pose without importing its tilt.
static func yaw_of(b: Basis) -> float:
	return atan2(b.z.x, b.z.z)


## The yaw-only basis with the same heading as b: pitch and roll
## identically zero, by construction.
static func level_basis(b: Basis) -> Basis:
	return Basis(Vector3.UP, yaw_of(b))


## tf with its basis levelled - position and heading kept, any
## pitch/roll stripped. The self-healing guard's repair tool.
static func level_transform(tf: Transform3D) -> Transform3D:
	return Transform3D(level_basis(tf.basis), tf.origin)


## How far a basis sits from level, in degrees. Computed from
## the Y axis alone: for the yaw/tilt decomposition of any
## rotation, the image of world-up has y-component cos(tilt),
## so a pure yaw reads EXACTLY 0 (its Y column is (0, 1, 0)
## bit-for-bit). Do NOT measure this with
## Quaternion.angle_to: on float32 quaternions its small-angle
## floor is ~0.04 deg - a level Basis(UP, 0.7) "measures"
## 0.0396 deg through it, which once had the level guard
## "repairing" a level rig every physics frame forever.
static func tilt_deg(b: Basis) -> float:
	return rad_to_deg(acos(clampf(b.y.y, -1.0, 1.0)))


## THE seat (Fix Pass 15): the origin transform that lands the
## camera at want_pos facing want_yaw with a LEVEL origin, no
## matter how the head is held at the seating instant. Only the
## head's HEADING is taken from its pose (yaw_of); its pitch and
## roll are never read. Replaces the old seat,
## want_cam * cam.transform.inverse(), whose inverse carried
## the head's full rotation into the origin basis: seat while
## looking down ~10 deg at the pit and the origin kept that
## pitch forever after - the whole world slanted the moment
## the player straightened up (Chris, 2026-11-03: "the entire
## view of the game world slants downward like 10 degrees,
## total vertigo inducer", in both game sessions - every B-tap
## swap was a roll of that dice).
static func seat_transform(cam_local: Transform3D, want_pos: Vector3, want_yaw: float) -> Transform3D:
	var b := Basis(Vector3.UP, want_yaw - yaw_of(cam_local.basis))
	return Transform3D(b, want_pos - b * cam_local.origin)


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
