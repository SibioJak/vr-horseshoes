class_name Shoe
extends RigidBody3D

## The horseshoe: a RigidBody3D built from three box parts (toe bridge
## + two shanks) plus heel calks, with one collision box per main part.
## Local frame: origin at shoe centre, shoe lying flat in XZ, toe
## (closed end) toward -Z, open end / heels toward +Z, +Y up.
##
## Grab zones live here, once, as data: the runtime proximity test,
## the part highlight, the hold transforms and the permanent zone
## audit in the test suite all read the same definitions.

const LENGTH: float = 0.1937 # 7 5/8 in
const WIDTH: float = 0.1842 # 7 1/4 in
const OPENING: float = 0.0889 # 3 1/2 in
const BAR: float = 0.0270 # bar thickness (toe/shank width)
const HEIGHT: float = 0.0210 # bar height
const MASS_KG: float = 1.13 # 2.5 lb

# Ringer inner window (stake centre, shoe-local): opening minus the
# 1 in stake, toe inner edge to just past the heel tips.
const RINGER_INNER_HALF: float = 0.0310
const RINGER_Z_MIN: float = -0.0580
const RINGER_Z_MAX: float = 0.1060

var parts: Dictionary = {} # zone name -> MeshInstance3D
var zone_markers: Dictionary = {} # zone name -> MeshInstance3D (proof/debug)
var _base_mats: Dictionary = {}
var _hi_mats: Dictionary = {}
var _calk_instances: Array = []
var tint := Color(0.36, 0.38, 0.42) # shoe paint (default: bare steel)
var _part_boxes: Array = [] # {pos, size} per collision part, shoe-local

# --- Stake sweep guard (Fix Pass 9) ---
# The stake is 25 mm wide; a fast shoe steps ~15 cm per physics
# step and Godot's shape-cast CCD demonstrably does NOT sweep a
# flat dead-centre shoe against it (the technique audit's traces:
# shots arriving in the upper stake band tunnelled clean through
# at centre heights 0.21-0.34, even with FP8's +3 mm core, a
# +10 mm core, a box core, or 120 Hz physics). So the shoe sweeps
# ITSELF: each step, its collision parts are swept against the
# stake cylinder across the step's motion. If a part's swept
# path touches the cylinder, the verdict waits: if the solver
# registers a stake contact, the guard stands down for the
# flight (a legitimate clang or ringer wrap is never touched);
# if the touch completes with no solver stake contact, the shoe
# ghosted - it is restored to the last clean substep pose with
# its velocity reflected, once per flight. (No centre-crossing
# condition: an opening-first shoe slides the stake into its U
# channel untouched while the centre crosses, and the bridge
# touch a step later is the one that tunnels.) Wired by main at
# spawn (guard_* below); reset at every throw release.
var guard_axis_a: Vector3 = Vector3.ZERO # stake collision axis, bottom centre (world)
var guard_axis_b: Vector3 = Vector3.ZERO # stake collision axis, top centre (world)
var guard_radius: float = 0.0
var guard_body: PhysicsBody3D = null
var guard_enabled: bool = false
var stake_guard_saves: int = 0
var _guard_armed: bool = false
var _guard_saved_this_flight: bool = false
var _guard_pending: Dictionary = {}

const GUARD_MIN_SPEED: float = 3.0 # ghosting needs speed; slow contacts are the solver's
const GUARD_SUBSTEPS: int = 8
const GUARD_AXIS_SAMPLES: int = 32


static func zones() -> Dictionary:
	return {
		"toe": {
			"center": Vector3(0.0, 0.0, -0.0834),
			"extents": Vector3(0.120, 0.034, 0.030),
			"hold": "flip",
			"slide_axis": Vector3(1.0, 0.0, 0.0),
			"slide_max": 0.022,
		},
		"shank_left": {
			"center": Vector3(-0.0786, 0.0, 0.0068),
			"extents": Vector3(0.030, 0.034, 0.120),
			"hold": "turn",
			"slide_axis": Vector3(0.0, 0.0, 1.0),
			"slide_max": 0.045,
		},
		"shank_right": {
			"center": Vector3(0.0786, 0.0, 0.0068),
			"extents": Vector3(0.030, 0.034, 0.120),
			"hold": "turn",
			"slide_axis": Vector3(0.0, 0.0, 1.0),
			"slide_max": 0.045,
		},
	}


static func zone_aabb(zone: String) -> AABB:
	var z: Dictionary = zones()[zone]
	var c: Vector3 = z["center"]
	var e: Vector3 = z["extents"]
	return AABB(c - e * 0.5, e)


## The defined hold for a zone: shoe transform relative to the hand
## (shoe_global = hand_global * this). The anchor is the zone centre,
## so the grabbed part of the shoe sits in the fingers.
static func hold_transform(zone: String, hand: String) -> Transform3D:
	var z: Dictionary = zones()[zone]
	var center: Vector3 = z["center"]
	var basis: Basis
	if String(z["hold"]) == "flip":
		# Toe in the fingers, shoe flat, open end forward (hand -Z):
		# rotate PI about Y so shoe +Z (open) points along hand -Z.
		basis = Basis.from_euler(Vector3(0.0, PI, 0.0))
	else:
		# Shank in the fingers, shoe flat, opening to the side away
		# from the palm: right hand -> opening to the left (the
		# right-handed 1 1/4 turn setup), left hand mirrored.
		var yaw: float = -PI * 0.5 if hand == "R" else PI * 0.5
		basis = Basis.from_euler(Vector3(0.0, yaw, 0.0))
	var origin: Vector3 = basis * (-center) + Vector3(0.0, -0.018, 0.0)
	return Transform3D(basis, origin)


func _ready() -> void:
	mass = MASS_KG
	# Zero damping, EXPLICITLY (Fix Pass 9, technique envelope
	# audit). Godot's physics space default damp is 0.1 for both
	# linear and angular, and this shoe never opted out - so every
	# throw silently bled ~10% of its velocity and ~10% of its
	# spin per second of flight. The audit's trace: a scripted
	# 5.24 rad/s flip arrived at 4.66 rad/s, and the shoe touched
	# down ~1 m short of its own ballistic line. Real air drag on
	# a 1.13 kg shoe at ~10 m/s is roughly 25x smaller than that.
	# A pitched shoe is ballistic with a preserved spin - the spin
	# IS the technique (a 1-1/4 turn must still be a 1-1/4 turn
	# when it reaches the stake) - so both damps are pinned to
	# zero in REPLACE mode, immune to the space default.
	linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	linear_damp = 0.0
	angular_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	angular_damp = 0.0
	var phys := PhysicsMaterial.new()
	phys.friction = 0.9
	phys.bounce = 0.12
	physics_material_override = phys
	contact_monitor = true
	max_contacts_reported = 6
	# Continuous CD. In Godot 4.7 this property is a BOOL (the old
	# CCDMode enum is gone): on = shape-cast CCD. It sweeps the
	# shoe's LINEAR motion only - it cannot sweep the tumble -
	# which is why the stake also carries a collision core 3 mm
	# fat (Fix Pass 8). The smoke suite asserts this stays on.
	continuous_cd = true
	_build_part("toe", Vector3(WIDTH, HEIGHT, BAR), Vector3(0.0, 0.0, -LENGTH * 0.5 + BAR * 0.5), 0.0)
	_build_part("shank_left", Vector3(BAR, HEIGHT, LENGTH - BAR), Vector3(-WIDTH * 0.5 + BAR * 0.5, 0.0, BAR * 0.5), 0.0)
	_build_part("shank_right", Vector3(BAR, HEIGHT, LENGTH - BAR), Vector3(WIDTH * 0.5 - BAR * 0.5, 0.0, BAR * 0.5), 0.0)
	# Heel calks: small angled blocks at the open tips (not grab zones).
	_build_calk(Vector3(-WIDTH * 0.5 + BAR * 0.5, 0.002, LENGTH * 0.5 - 0.012), -0.35)
	_build_calk(Vector3(WIDTH * 0.5 - BAR * 0.5, 0.002, LENGTH * 0.5 - 0.012), 0.35)
	_build_markers()


func _steel_mat(hi: bool) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	if hi:
		m.albedo_color = Color(1.0, 0.62, 0.15)
		m.emission_enabled = true
		m.emission = Color(1.0, 0.5, 0.1)
		m.emission_energy_multiplier = 1.6
	else:
		m.albedo_color = tint
		m.metallic = 0.85
		m.roughness = 0.42
	return m


## Pair colours (Backyard Game v1): a side's shoes are painted -
## the player's pair yellow, the AI's blue, per Chris's photo
## feed. Recolours every part + calk in the pair colour (painted
## metal: a little less metallic than bare steel); the orange
## grab highlight is untouched and wins while shown.
func apply_tint(c: Color) -> void:
	tint = c
	for zone: String in parts.keys():
		var mi: MeshInstance3D = parts[zone]
		var was_hi: bool = mi.material_override == _hi_mats[zone]
		var m := StandardMaterial3D.new()
		m.albedo_color = c
		m.metallic = 0.55
		m.roughness = 0.50
		_base_mats[zone] = m
		if not was_hi:
			mi.material_override = m
	for calk: Variant in _calk_instances:
		(calk as MeshInstance3D).material_override = _steel_mat(false)


func _build_part(zone: String, size: Vector3, pos: Vector3, _unused: float) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.position = pos
	add_child(mi)
	parts[zone] = mi
	_base_mats[zone] = _steel_mat(false)
	_hi_mats[zone] = _steel_mat(true)
	mi.material_override = _base_mats[zone]
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = size
	cs.shape = bs
	cs.position = pos
	add_child(cs)
	_part_boxes.append({"pos": pos, "size": size})


func _build_calk(pos: Vector3, yaw: float) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(BAR, HEIGHT * 1.25, 0.030)
	mi.mesh = bm
	mi.position = pos
	mi.rotation.y = yaw
	mi.material_override = _steel_mat(false)
	add_child(mi)
	_calk_instances.append(mi)


func _build_markers() -> void:
	var zs: Dictionary = zones()
	for zone: String in zs.keys():
		var z: Dictionary = zs[zone]
		var c: Vector3 = z["center"]
		var mi := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = 0.011
		sm.height = 0.022
		mi.mesh = sm
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.albedo_color = Color(1.0, 0.85, 0.2, 0.55)
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mi.material_override = m
		mi.position = c + Vector3(0.0, 0.026, 0.0)
		mi.visible = false
		add_child(mi)
		zone_markers[zone] = mi


func set_highlight(zone: String, on: bool) -> void:
	if zone == "":
		return
	var mi: MeshInstance3D = parts[zone]
	mi.material_override = _hi_mats[zone] if on else _base_mats[zone]


func clear_highlights() -> void:
	for zone: String in parts.keys():
		set_highlight(zone, false)


func set_markers_visible(on: bool) -> void:
	for zone: String in zone_markers.keys():
		var mi: MeshInstance3D = zone_markers[zone]
		mi.visible = on


## World-space centre of a grab zone.
func zone_world_center(zone: String) -> Vector3:
	var z: Dictionary = zones()[zone]
	var c: Vector3 = z["center"]
	return global_transform * c


# --- Stake sweep guard implementation (see the guard_* block) ---

func reset_stake_guard() -> void:
	_guard_armed = guard_enabled
	_guard_saved_this_flight = false
	_guard_pending.clear()


func _axis_closest(p: Vector3) -> Vector3:
	var ab: Vector3 = guard_axis_b - guard_axis_a
	var t: float = clampf((p - guard_axis_a).dot(ab) / ab.length_squared(), 0.0, 1.0)
	return guard_axis_a + ab * t


## Do any collision parts intersect the stake cylinder at this
## pose? Tested as axis samples against each part box expanded
## by the cylinder radius (a sphere-swept axis - conservative at
## the corners, which is the safe direction for a guard).
func _parts_hit_axis(pose: Transform3D) -> Dictionary:
	var inv_basis: Basis = pose.basis.transposed()
	for raw: Variant in _part_boxes:
		var part: Dictionary = raw
		var half: Vector3 = (part["size"] as Vector3) * 0.5
		var centre: Vector3 = pose.origin + pose.basis * (part["pos"] as Vector3)
		for s: int in GUARD_AXIS_SAMPLES + 1:
			var axis_pt: Vector3 = guard_axis_a.lerp(
				guard_axis_b, float(s) / float(GUARD_AXIS_SAMPLES))
			var local: Vector3 = inv_basis * (axis_pt - centre)
			if absf(local.x) <= half.x + guard_radius \
					and absf(local.y) <= half.y + guard_radius \
					and absf(local.z) <= half.z + guard_radius:
				return {"part_centre": centre, "axis_point": axis_pt}
	return {}


## Sweep one step's motion (from the step's start state). If a
## part's swept path intersects the stake cylinder at any
## substep, returns the pending verdict: the last clean pose
## before the touch plus the touch geometry. There is NO
## centre-crossing condition: an opening-first shoe (the ringer
## entry, and shot A) slides the stake into its U channel with
## no part near the axis while the centre crosses - the bridge
## reaches the stake a step later, and THAT touch is the one
## the solver tunnels through.
func _sweep_step(state: PhysicsDirectBodyState3D) -> Dictionary:
	var dt: float = state.step
	var start_tf: Transform3D = state.transform
	var lv: Vector3 = state.linear_velocity + state.total_gravity * dt * 0.5
	var av: Vector3 = state.angular_velocity
	var q0: Quaternion = start_tf.basis.get_rotation_quaternion()
	var prev_pose: Transform3D = start_tf
	for k: int in range(1, GUARD_SUBSTEPS + 1):
		var f: float = float(k) / float(GUARD_SUBSTEPS)
		var qk: Quaternion = q0
		if av.length() > 0.01:
			qk = Quaternion(av.normalized(), av.length() * dt * f) * q0
		var posek := Transform3D(Basis(qk), start_tf.origin + lv * dt * f)
		var hit: Dictionary = _parts_hit_axis(posek)
		if not hit.is_empty():
			return {"clean_pose": prev_pose, "age": 0,
				"part_centre": hit["part_centre"], "axis_point": hit["axis_point"]}
		prev_pose = posek
	return {}


func _apply_guard_save(state: PhysicsDirectBodyState3D) -> void:
	var clean_pose: Transform3D = _guard_pending["clean_pose"]
	var part_centre: Vector3 = _guard_pending["part_centre"]
	var axis_point: Vector3 = _guard_pending["axis_point"]
	_guard_pending.clear()
	_guard_saved_this_flight = true
	stake_guard_saves += 1
	state.transform = clean_pose
	var n: Vector3 = part_centre - axis_point
	if n.length() < 0.001:
		n = -state.linear_velocity.normalized()
	else:
		n = n.normalized()
	var v: Vector3 = state.linear_velocity
	var vn: float = v.dot(n)
	if vn < 0.0:
		v = v - (1.0 + 0.20) * vn * n
		v *= 0.92
	state.linear_velocity = v
	var av: Vector3 = state.angular_velocity * 0.6
	var kick: Vector3 = n.cross(v)
	if kick.length() > 0.01:
		av += kick.normalized() * minf(3.0, v.length() * 0.30)
	state.angular_velocity = av


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	if not guard_enabled or guard_body == null or _guard_saved_this_flight:
		return
	# Contacts from the step that just finished: a solver stake
	# contact disarms the guard for this approach (clang or wrap
	# - the stake is in the solver's hands, never second-guessed).
	for ci: int in state.get_contact_count():
		if state.get_contact_collider_object(ci) == guard_body:
			_guard_armed = false
			_guard_pending.clear()
			return
	if not _guard_armed:
		return
	# Confirm a pending touch from an earlier step: the swept
	# path touched the cylinder and the solver has had its
	# chance to own it. If the shoe has left the touch again
	# (or two steps pass) with no solver stake contact, the
	# touch was a ghost - answer it. If the shoe left the stake
	# neighbourhood entirely (a bounce the solver DID handle via
	# another body, a deflection), the verdict is moot.
	if not _guard_pending.is_empty():
		var age: int = int(_guard_pending.get("age", 0)) + 1
		_guard_pending["age"] = age
		var centre_now: Vector3 = state.transform.origin
		if centre_now.distance_to(_axis_closest(centre_now)) >= 0.5:
			_guard_pending.clear()
		elif _parts_hit_axis(state.transform).is_empty() or age >= 2:
			_apply_guard_save(state)
			return
		else:
			return # still inside the touch; the solver gets one more step
	# Sweep this step's motion for the next verdict.
	var centre: Vector3 = state.transform.origin
	if centre.distance_to(_axis_closest(centre)) > 1.2:
		return
	if state.linear_velocity.length() < GUARD_MIN_SPEED:
		return
	_guard_pending = _sweep_step(state)
