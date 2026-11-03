class_name AIPitcher
extends Node3D

## The AI opponent (Backyard Game v1): a low-poly club player
## built from primitives - legs, torso, head, cap, one swinging
## arm - plus the release model it throws with.
##
## The release is CONSTRUCTED, not estimated (the brief allows
## this): a ballistic "good flip" is computed from the release
## point to the target stake, then sampled with human error.
## The shoe then flies the PRODUCTION physics - stake sweep
## guard, clay, settle and scoring are the real path; no outcome
## is faked. The sampler's spread constants below were tuned
## against tests/ai_measure.gd run over the real scene (see the
## delivery report for the measured ringer line).
##
## Swing animation is cosmetic: the arm carries the shoe through
## a windup / swing / follow-through, and at the release angle
## the caller's on_release fires and physics takes the shoe.

const GRAV: float = 9.8
const FLIGHT_T: float = 1.40 # planned seconds, release to stake plane
const ARRIVE_H: float = 0.22 # planned height crossing the stake plane
# Arrival phase, found by grid search over the production
# physics at live pacing (Fix Pass 11 retune, 2026-11-03):
# the shoe must arrive LOW (crossing at 0.22 m, well under
# the stake top) at the end of a slow 1.40 s flip, so it
# drops OVER the stake and the solver arrests it in the
# opening. Perfect throws ring across a ~45-82 deg phase
# corridor at this profile; 59 sits in it with the sampled
# spread centred.
const PHASE_DEG: float = 59.0

# --- Error model (measured with tests/ai_measure.gd) ---
# Retuned 2026-11-03 (Fix Pass 11). The v1 line quoted here
# before (24.1% ringers) was measured under a sped-up clock
# (Engine.time_scale 3), which stretches the physics step
# 3x - at that step size the solver drops the shoe onto the
# stake and the capture is nearly free. At live pacing the
# v1 profile actually rang ~3.5%: its high, fast arrival
# flies over the stake and clangs off. The constants above
# and the spread below were re-derived at time_scale 1:
# a lower, slower base the stake can arrest, and a tighter
# spread, because the ringer window (31 mm half-width, a
# ~40 deg phase corridor) is narrower than the old jitter.
# Final line, 220 simulated throws through the production
# flight path at live pacing (2026-11-03): 23.2% ringers,
# 80.9% of shoes inside 6 in, mean landing 3.7 in, self-play
# 0.96 points per side per inning - a club player, back in
# the 20-30% band.
# Fix Pass 13 re-measure (2026-11-03): the box moved behind
# the foul line, level with the player, 3.6 m across (see
# box_root) - 220 throws at live pacing, NO spread change:
# 23.6% ringers, 83.2% inside 6 in, mean landing 3.8 in,
# self-play 1.06 points per side per inning. The line holds
# from the new box.
const ERR_SPEED_FRAC: float = 0.008 # fraction of release speed
const ERR_AZIMUTH_DEG: float = 0.24 # horizontal direction, degrees
const ERR_VY: float = 0.025 # added vertical velocity, m/s
const ERR_POS_X: float = 0.013 # release point lateral jitter, m
const ERR_POS_Y: float = 0.010 # release point height jitter, m
const ERR_SPIN_FRAC: float = 0.016 # flip rate jitter, fraction

const ARM_LEN: float = 0.62
# Fix Pass 11: the throwing arm is the LANE-side arm. The AI
# now stands across the pit from the player (see
# release_base_pos), so the shoulder local x flips sign vs v1:
# +0.30 puts the shoulder toward the lane from either side.
const SHOULDER_LOCAL := Vector3(0.30, 1.45, 0.0)
const A_RELEASE: float = 1.15 # arm angle (rad) at the release instant
const THROW_DUR: float = 1.9 # seconds for a full swing at speed 1

var speed_scale: float = 1.0 # tests raise this; feel is judged live

var _arm_pivot: Node3D
var _body_root: Node3D
var _throwing: bool = false
var _anim_t: float = 0.0
var _shoe: Shoe = null
var _release: Dictionary = {}
var _on_release: Callable
var _on_done: Callable
var _released: bool = false
var _idle_t: float = 0.0


## Where the AI stands when it pitches from an end (Fix Pass
## 13, Chris's layout call: SAME END, OPPOSITE SIDES, real
## singles): his box sits BEHIND the foul line at the player's
## own stance depth - the same 0.55 m behind the line the game
## seats the player at (main's _move_player_to_end) - on the
## side of the court opposite the player's rack, with 3.6 m of
## lateral separation from the stance centre (pit width plus
## both boxes). FP11 put him across the pit but UP BESIDE it -
## rooted level with the pit clay, his release a step in FRONT
## of the line - and he still read as standing on the player's
## side of the game ("both players are still on same side").
## The box root is the anchor now; the release point is
## DERIVED from it (the hand tip at the release arm angle), so
## the character can never drift away from his box again.
## end_sign: +1 = home end (throws toward -z), -1 = far end.
const BOX_SIDE_X: float = 3.6
const BOX_DEPTH: float = 0.55


static func box_root(end_sign: int, line_z: float) -> Vector3:
	var travel: float = -float(end_sign)
	return Vector3(-BOX_SIDE_X * float(end_sign), 0.0,
		line_z - travel * BOX_DEPTH)


## The swing's release point: the hand tip at the release arm
## angle A_RELEASE, derived from the box root - shoulder
## toward the lane at shoulder height, arm reaching
## forward-down at that angle. At the release instant the
## animated hand tip and this point coincide (the same
## guarantee FP11's solve-the-root-from-the-release gave,
## run the other way).
static func release_base_pos(end_sign: int, line_z: float) -> Vector3:
	var root: Vector3 = box_root(end_sign, line_z)
	var travel: float = -float(end_sign)
	return Vector3(
		root.x + SHOULDER_LOCAL.x * float(end_sign),
		SHOULDER_LOCAL.y - ARM_LEN * cos(A_RELEASE),
		root.z + travel * ARM_LEN * sin(A_RELEASE))


## The un-sampled "good flip": ballistic velocity that crosses
## the target stake's plane at ARRIVE_H after FLIGHT_T, with one
## full end-over-end revolution in the same time (the audit's
## proven flip profile: opening toward the target at release,
## spin about the flip axis of the travel frame).
##
## Fix Pass 11 retune: the frame is built ONCE for straight -Z
## travel (v1's home-end construction) and then yawed onto the
## ACTUAL travel direction. v1 applied that frame unyawed,
## which was exact while the release sat near the lane
## centreline; from across the pit the travel runs ~13 deg
## diagonal, so the flip plane and the opening's facing are
## yawed onto the travel vector with it. For a straight throw
## the yaw is 0 (home) or PI (far, which is exactly how v1's
## two cases were related). The profile constants themselves
## (FLIGHT_T / ARRIVE_H / PHASE_DEG) are the retune described
## at the error model above - the yaw alone did not restore
## the arrival (the unyawed AND yawed v1 profiles both rang
## 0/60 perfect throws at live pacing); the low, slow,
## drop-on profile is what the stake can catch.
static func base_release(from_pos: Vector3, target_stake: Vector3) -> Dictionary:
	var vel := Vector3(
		(target_stake.x - from_pos.x) / FLIGHT_T,
		(ARRIVE_H - from_pos.y + 0.5 * GRAV * FLIGHT_T * FLIGHT_T) / FLIGHT_T,
		(target_stake.z - from_pos.z) / FLIGHT_T)
	var flat := Vector3(target_stake.x - from_pos.x, 0.0, target_stake.z - from_pos.z)
	var yaw_basis := Basis(Vector3.UP, atan2(-flat.x, -flat.z))
	var basis: Basis = yaw_basis * Basis(Vector3(1.0, 0.0, 0.0), deg_to_rad(PHASE_DEG)) \
		* Basis(Vector3.UP, PI)
	var rate: float = TAU / FLIGHT_T
	var ang: Vector3 = yaw_basis * Vector3(rate, 0.0, 0.0)
	return {"pos": from_pos, "basis": basis, "vel": vel, "ang": ang}


## One sampled AI release: the good flip plus club-player error.
static func sample_release(rng: RandomNumberGenerator, from_pos: Vector3,
		target_stake: Vector3) -> Dictionary:
	var rel: Dictionary = base_release(from_pos, target_stake)
	var pos: Vector3 = rel["pos"]
	pos.x += rng.randfn(0.0, ERR_POS_X)
	pos.y += rng.randfn(0.0, ERR_POS_Y)
	var vel: Vector3 = rel["vel"]
	var speed: float = vel.length()
	var dir: Vector3 = vel / speed
	# Azimuth error rotates the (flat) direction of travel.
	var az: float = deg_to_rad(rng.randfn(0.0, ERR_AZIMUTH_DEG))
	var flat := Vector2(dir.x, dir.z).rotated(az)
	dir.x = flat.x
	dir.z = flat.y
	dir = dir.normalized()
	vel = dir * (speed * (1.0 + rng.randfn(0.0, ERR_SPEED_FRAC)))
	vel.y += rng.randfn(0.0, ERR_VY)
	rel["pos"] = pos
	rel["vel"] = vel
	var ang: Vector3 = rel["ang"]
	rel["ang"] = ang * (1.0 + rng.randfn(0.0, ERR_SPIN_FRAC))
	return rel


func _mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	return m


func _box(parent: Node, pos: Vector3, size: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.position = pos
	mi.material_override = mat
	parent.add_child(mi)
	return mi


func _ready() -> void:
	_body_root = Node3D.new()
	add_child(_body_root)
	var denim := _mat(Color(0.20, 0.26, 0.44))
	var shirt := _mat(Color(0.16, 0.38, 0.72)) # opponent blue
	var skin := _mat(Color(0.82, 0.62, 0.47))
	var cap_mat := _mat(Color(0.75, 0.16, 0.14))
	_box(_body_root, Vector3(-0.11, 0.42, 0.0), Vector3(0.15, 0.84, 0.17), denim)
	_box(_body_root, Vector3(0.11, 0.42, 0.0), Vector3(0.15, 0.84, 0.17), denim)
	_box(_body_root, Vector3(0.0, 1.12, 0.0), Vector3(0.46, 0.58, 0.24), shirt)
	var head := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.115
	sm.height = 0.23
	sm.radial_segments = 16
	sm.rings = 8
	head.mesh = sm
	head.material_override = skin
	head.position = Vector3(0.0, 1.56, 0.0)
	_body_root.add_child(head)
	var cap := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.12
	cm.bottom_radius = 0.125
	cm.height = 0.07
	cap.mesh = cm
	cap.material_override = cap_mat
	cap.position = Vector3(0.0, 1.645, 0.0)
	_body_root.add_child(cap)
	_box(_body_root, Vector3(0.0, 1.615, -0.14), Vector3(0.20, 0.025, 0.13), cap_mat)
	# Rest arm (far side from the lane): hangs still.
	_box(_body_root, Vector3(-0.31, 1.06, 0.0), Vector3(0.11, 0.58, 0.12), shirt)
	# Throwing arm: pivot at the lane-side shoulder.
	_arm_pivot = Node3D.new()
	_arm_pivot.position = SHOULDER_LOCAL
	_body_root.add_child(_arm_pivot)
	_box(_arm_pivot, Vector3(0.0, -ARM_LEN * 0.5, 0.0), Vector3(0.11, ARM_LEN, 0.12), shirt)
	var hand := MeshInstance3D.new()
	var hm := SphereMesh.new()
	hm.radius = 0.05
	hm.height = 0.10
	hand.mesh = hm
	hand.material_override = skin
	hand.position = Vector3(0.0, -ARM_LEN, 0.0)
	_arm_pivot.add_child(hand)


## Stand in the end's box (Fix Pass 13: behind the foul line,
## level with the player's stance depth, opposite side of the
## court) facing the target stake down-lane.
func place_at(end_sign: int, line_z: float) -> void:
	var travel: float = -float(end_sign)
	position = box_root(end_sign, line_z)
	rotation = Vector3(0.0, 0.0 if travel < 0.0 else PI, 0.0)


func hand_tip_transform() -> Transform3D:
	var tip_local := Transform3D(Basis.IDENTITY, Vector3(0.0, -ARM_LEN, 0.0))
	return _arm_pivot.global_transform * tip_local


func is_throwing() -> bool:
	return _throwing


## Arm angle (rad about the shoulder X) for animation time t in
## [0, THROW_DUR]. Windup slow, swing fast, follow-through settles.
func _arm_angle(t: float) -> float:
	var w_end: float = THROW_DUR * 0.52
	var s_end: float = THROW_DUR * 0.76
	if t < w_end:
		var f: float = t / w_end
		return lerpf(0.12, -1.85, f * f * (3.0 - 2.0 * f))
	if t < s_end:
		var f2: float = (t - w_end) / (s_end - w_end)
		return lerpf(-1.85, 1.30, f2 * f2)
	var f3: float = (t - s_end) / (THROW_DUR - s_end)
	return lerpf(1.30, 0.85, f3 * f3 * (3.0 - 2.0 * f3))


## Play one swing with the given shoe and sampled release. The
## shoe rides the hand (frozen) until the release angle, where
## on_release fires (the caller unfreezes it with the release);
## on_done fires when the animation completes.
func play_throw(shoe_node: Shoe, release: Dictionary,
		on_release: Callable, on_done: Callable) -> void:
	_shoe = shoe_node
	_release = release
	_on_release = on_release
	_on_done = on_done
	_anim_t = 0.0
	_released = false
	_throwing = true


func _process(delta: float) -> void:
	_idle_t += delta
	if not _throwing:
		# Idle: a barely-there sway so the character reads alive.
		if _arm_pivot != null:
			_arm_pivot.rotation.x = 0.12 + 0.03 * sin(_idle_t * 1.4)
			_body_root.position.y = 0.008 * sin(_idle_t * 2.2)
		return
	_anim_t += delta * speed_scale
	var ang: float = _arm_angle(minf(_anim_t, THROW_DUR))
	_arm_pivot.rotation.x = ang
	if _shoe != null and not _released:
		var rel_basis: Basis = _release["basis"]
		var local_spin := Basis(Vector3.RIGHT, ang - A_RELEASE)
		var shoe_basis: Basis = global_transform.basis * local_spin * rel_basis
		_shoe.global_transform = Transform3D(shoe_basis, hand_tip_transform().origin)
	if not _released and ang >= A_RELEASE and _anim_t > THROW_DUR * 0.52:
		_released = true
		var cb: Callable = _on_release
		_shoe = null
		cb.call()
	if _anim_t >= THROW_DUR:
		_throwing = false
		_shoe = null
		var done: Callable = _on_done
		done.call()
