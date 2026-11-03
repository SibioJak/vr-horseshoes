extends Node3D

## VR Horseshoes - DE Toss Test.
## One pit, one stake at 40 ft, twenty shoes. Everything here serves
## the toss: zone-snap grab + sticky slide (GrabState/Shoe), windowed
## release sampling (ThrowMath), an honest rigid-body shoe, a JSONL
## recorder, and an in-world board. No scoring, no opponents, no audio.
##
## Rig binding is FIELD-CENSUS settled (VR Baseball Duel, same rig:
## Quest 3 + Virtual Desktop/VDXR + Godot 4.7): hands register as
## plain "left_hand"/"right_hand" with live data on the "default"
## pose. One XRController3D per hand, pose never overridden. Do not
## "fix" these names to /user/hand/... paths - no such trackers exist
## on this rig.

const STAKE_POS := Vector3(0.0, 0.05, -12.192) # pit surface point, 40 ft from the foul line (z=0)
const STAKE_VISUAL_RADIUS: float = 0.0127 # the 1 in steel Chris sees
const STAKE_COLLISION_RADIUS: float = 0.0157 # visual + 3 mm (Fix Pass 8, see _build_world)
const PIT_SIZE := Vector3(0.914, 0.05, 1.829) # 36 in x 72 in
const FOUL_40_Z: float = 0.0
const FOUL_30_Z: float = -3.048 # 30 ft line: 9.144 m from the stake
const FOUL_Z: float = FOUL_40_Z
const STANCE_HALF_WIDTH: float = 0.85
const STANCE_HALF_DEPTH: float = 0.40
const STAND_SIDE_X: float = 0.75
const STAND_BEHIND_M: float = 0.50
const STAND_SHOE_Y: float = 0.785
const CANDIDATE_RADIUS: float = 0.14
const BOARD_POS := Vector3(-2.4, 0.0, -16.2) # Fix Pass 10: beyond the pit, left of the stake
const BOARD_YAW_DEG: float = 10.0 # face turned back at the pitching end
const THROW_MIN_SPEED: float = 0.9
const SAMPLE_KEEP_SEC: float = 0.40
const SETTLE_STILL_SEC: float = 0.25
const RETURN_WAIT_SEC: float = 0.20

var origin: XROrigin3D
var cam: XRCamera3D
var hand_ctrl: Dictionary = {} # "L"/"R" -> XRController3D
var ctrl_rep: Dictionary = {}
var xr_ok: bool = false
var head_tracking_ok: bool = false

var shoe: Shoe
var stake_body_node: StaticBody3D = null
var stake_axis_a: Vector3 = Vector3.ZERO # stake collision axis endpoints (world)
var stake_axis_b: Vector3 = Vector3.ZERO
var stand_tfs: Dictionary = {} # line_ft (30/40) -> pedestal shoe transform
var stand_tf: Transform3D # the pedestal the shoe currently belongs to
var active_stand_line_ft: int = 40
var board_root: Node3D
var board_slab_size := Vector3(3.0, 2.7, 0.05)
var title_label: Label3D
var status_label: Label3D
var controls_label: Label3D
var scenery_root: Node3D

var state: String = "STAND" # STAND, HELD, FLYING, DROPPED, RETURNING
var grab_state := GrabState.new()
var held_hand: String = ""
var held_zone: String = ""
var held_hold: String = ""
var rel_tf := Transform3D.IDENTITY
var slide_offset: float = 0.0
var candidate_hand: String = ""
var candidate_zone: String = ""

var samples: Array = [] # Dictionary samples for the held hand
var sample_hand: String = ""
var _prev_hand_pos: Dictionary = {}
var _prev_hand_t: Dictionary = {}
var hand_speed: Dictionary = {"L": 0.0, "R": 0.0}

var throw_count: int = 0
var last_hold_text: String = "-"
var last_distance_in: float = -1.0
var last_flip_rev: float = 0.0
var last_turn_rev: float = 0.0
var last_ringer: bool = false

var recorder: ThrowRecorder
var recorder_path: String = "user://throws.jsonl"
var release_cache: Dictionary = {}
var flip_rot: float = 0.0
var turn_rot: float = 0.0
var has_contact: bool = false
var first_contact_pos: Vector3 = Vector3.ZERO
var _fly_time: float = 0.0
var _still_time: float = 0.0
var _wait_time: float = 0.0

# Test hooks (used by the headless suites / render proofs only).
var test_hand_tf: Dictionary = {}
var test_grip: Dictionary = {}
var test_trigger: Dictionary = {}
var test_stick: Dictionary = {}
var debug_show_zones: bool = false


func _ready() -> void:
	recorder = ThrowRecorder.new(recorder_path)
	_init_stands()
	_build_world()
	_build_rig()
	_build_board()
	_spawn_shoe()
	head_tracking_ok = _head_tracking_ok()
	print("VR Horseshoes toss test ready. xr_ok=", xr_ok, " head_tracking=", head_tracking_ok)
	_update_board()


func _mat(c: Color, emission: float = 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	if emission > 0.0:
		m.emission_enabled = true
		m.emission = c
		m.emission_energy_multiplier = emission
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


func _static_box(pos: Vector3, size: Vector3, mat: Material, phys: PhysicsMaterial) -> StaticBody3D:
	var body := StaticBody3D.new()
	if phys != null:
		body.physics_material_override = phys
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat
	body.add_child(mi)
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = size
	cs.shape = bs
	body.add_child(cs)
	body.position = pos
	add_child(body)
	return body


static func line_z_for_ft(line_ft: int) -> float:
	return FOUL_30_Z if line_ft == 30 else FOUL_40_Z


static func make_stand_tf(line_ft: int) -> Transform3D:
	# Pedestal rule (Fix Pass 3): behind the line and to the side,
	# NEVER inside the stance box (|x| <= 0.85, line z +/- 0.40) -
	# the pass-1/2 pedestal sat where the pitcher's feet go.
	return Transform3D(
		Basis.from_euler(Vector3(deg_to_rad(-14.0), deg_to_rad(-30.0), 0.0)),
		Vector3(STAND_SIDE_X, STAND_SHOE_Y, line_z_for_ft(line_ft) + STAND_BEHIND_M))


func _init_stands() -> void:
	stand_tfs = {
		40: make_stand_tf(40),
		30: make_stand_tf(30),
	}
	active_stand_line_ft = 40
	stand_tf = stand_tfs[active_stand_line_ft]


func _set_active_stand(line_ft: int) -> void:
	active_stand_line_ft = line_ft
	stand_tf = stand_tfs[line_ft]


## "The shoe waits where you are" (Fix Pass 7). While the shoe sits
## stocked (STAND), the home pedestal follows the PLAYER: standing
## at a foul line - ThrowMath.standing_line_ft, the FP3 release
## classification with a proximity gate, read off the head - with
## the shoe homed to the other line relocates the stocked shoe to
## that line's pedestal. Instant and silent: the shoe is frozen at
## rest, so this is a clean teleport, never a visible flight.
## Runs only in STAND - a held, flying or still-settling shoe is
## never touched - and at neither line the shoe stays where it is.
##
## Defect history: before this pass the home was set ONLY at latch
## time, from the shoe's own position (_nearest_stand_line). The
## shoe starts on the 40 ft pedestal and can only reach a pedestal
## by being returned to the current home, so every latch re-homed
## it to the pedestal it was already sitting on - the 30 ft
## pedestal could become home only by being grabbed from, which
## required the shoe to already be there. It never was. Chris, in
## the headset: "the shorter distance podium doesn't spawn a
## horseshoe, very stingy."
func _restock_to_player_line() -> void:
	if state != "STAND":
		return
	var line_ft: int = ThrowMath.standing_line_ft(cam.global_position, STAKE_POS)
	if line_ft != 0 and line_ft != active_stand_line_ft:
		_set_active_stand(line_ft)
		shoe.freeze = true
		shoe.global_transform = stand_tf
		shoe.clear_highlights()


func _nearest_stand_line() -> int:
	var best_line: int = active_stand_line_ft
	var best_dist: float = INF
	for line_ft: int in [40, 30]:
		var tf: Transform3D = stand_tfs[line_ft]
		var d: float = shoe.global_position.distance_to(tf.origin)
		if d < best_dist:
			best_dist = d
			best_line = line_ft
	return best_line


func _build_pedestal(tf: Transform3D) -> void:
	var p: Vector3 = tf.origin
	_box(self, Vector3(p.x, 0.37, p.z), Vector3(0.07, 0.74, 0.07), _mat(Color(0.40, 0.29, 0.17)))
	var plate := _box(self, Vector3(p.x, 0.755, p.z), Vector3(0.34, 0.03, 0.34), _mat(Color(0.48, 0.35, 0.21)))
	plate.rotation_degrees = Vector3(-14.0, -30.0, 0.0)


func _build_world() -> void:
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48.0, -24.0, 0.0)
	sun.light_energy = 1.1
	add_child(sun)
	var we := WorldEnvironment.new()
	var env := Environment.new()
	# Fix Pass 10: a real sky (procedural gradient + sun disc)
	# replaces the flat clear colour - one of the static references
	# the comfort dressing hangs on. Ambient stays the settled
	# colour source so the judged court lighting does not move.
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.22, 0.44, 0.78)
	sky_mat.sky_horizon_color = Color(0.72, 0.81, 0.90)
	sky_mat.sky_curve = 0.12
	sky_mat.ground_bottom_color = Color(0.18, 0.24, 0.16)
	sky_mat.ground_horizon_color = Color(0.72, 0.81, 0.90)
	sky_mat.ground_curve = 0.08
	sky_mat.sun_angle_max = 25.0
	var sky := Sky.new()
	sky.sky_material = sky_mat
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.75, 0.78, 0.72)
	env.ambient_light_energy = 0.7
	we.environment = env
	add_child(we)

	var ground_phys := PhysicsMaterial.new()
	ground_phys.friction = 0.7
	ground_phys.bounce = 0.35
	_static_box(Vector3(0.0, -0.05, -6.0), Vector3(40.0, 0.1, 48.0), _mat(Color(0.32, 0.52, 0.26)), ground_phys)

	# Clay pit: high friction, almost no bounce - shoes deaden + slide.
	var clay_phys := PhysicsMaterial.new()
	clay_phys.friction = 1.0
	clay_phys.bounce = 0.04
	var pit_pos := Vector3(STAKE_POS.x, 0.025, STAKE_POS.z)
	_static_box(pit_pos, PIT_SIZE, _mat(Color(0.62, 0.44, 0.30)), clay_phys)
	# Pit frame boards.
	var frame_mat := _mat(Color(0.45, 0.33, 0.20))
	_box(self, Vector3(0.0, 0.03, STAKE_POS.z - PIT_SIZE.z * 0.5 - 0.03), Vector3(PIT_SIZE.x + 0.12, 0.06, 0.06), frame_mat)
	_box(self, Vector3(0.0, 0.03, STAKE_POS.z + PIT_SIZE.z * 0.5 + 0.03), Vector3(PIT_SIZE.x + 0.12, 0.06, 0.06), frame_mat)
	_box(self, Vector3(-PIT_SIZE.x * 0.5 - 0.03, 0.03, STAKE_POS.z), Vector3(0.06, 0.06, PIT_SIZE.z), frame_mat)
	_box(self, Vector3(PIT_SIZE.x * 0.5 + 0.03, 0.03, STAKE_POS.z), Vector3(0.06, 0.06, PIT_SIZE.z), frame_mat)

	# Stake: 1 in steel, top 14.5 in above the pit, leaning ~8 deg so
	# the top sits ~3 in toward the pitcher. Pivot at the pit surface.
	var stake_pivot := Node3D.new()
	stake_pivot.position = STAKE_POS
	stake_pivot.rotation_degrees = Vector3(8.0, 0.0, 0.0)
	add_child(stake_pivot)
	var stake_body := StaticBody3D.new()
	stake_pivot.add_child(stake_body)
	var smi := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = STAKE_VISUAL_RADIUS
	cyl.bottom_radius = STAKE_VISUAL_RADIUS
	cyl.height = 0.62
	smi.mesh = cyl
	smi.position = Vector3(0.0, 0.058, 0.0)
	smi.material_override = _mat(Color(0.55, 0.57, 0.62))
	stake_body.add_child(smi)
	# Fix Pass 8 - the stake is NOT hollow, and never was: the
	# collision shape is a solid CylinderShape3D, audited in code
	# and at runtime. The hole is step size: at 60 Hz a 9 m/s shoe
	# travels ~15 cm per physics step past a 25 mm target, and the
	# shoe's shape-cast CCD sweeps its LINEAR motion only - it
	# cannot sweep the tumble. Chris's one ghost in 88 throws
	# (2026-11-02) crossed ~9 cm off centre at 0.18 m height,
	# mid-skip after a touchdown: exactly the phase a step or a
	# linear cast can slip. The collision core therefore runs
	# +3 mm fat (the mesh stays a true 1 in) - enough to close
	# graze-phase gaps, small enough to stay inside the visual
	# contact tolerance of a 21-27 mm thick shoe, so no honest
	# near-miss gets stolen. Scoring geometry (ringer window,
	# landing distance) still measures against the true 1 in
	# stake; only contact wears the extra 3 mm.
	var scs := CollisionShape3D.new()
	var scyl := CylinderShape3D.new()
	scyl.radius = STAKE_COLLISION_RADIUS
	scyl.height = 0.62
	scs.shape = scyl
	scs.position = Vector3(0.0, 0.058, 0.0)
	stake_body.add_child(scs)
	# Fix Pass 9: even the fat core + CCD does not stop a fast
	# FLAT shoe in the upper band (measured ghosts at centre
	# heights 0.21-0.34, sub-step graze windows the cast misses).
	# The shoe therefore carries a sweep guard against this
	# stake (see shoe.gd): hand it the body and the collision
	# cylinder's world axis endpoints.
	stake_body_node = stake_body
	stake_axis_a = stake_pivot.global_transform * Vector3(0.0, 0.058 - 0.31, 0.0)
	stake_axis_b = stake_pivot.global_transform * Vector3(0.0, 0.058 + 0.31, 0.0)

	# Foul lines the pitcher stands behind: the 40 ft standard and
	# the 30 ft short line (NHPA learning distance, Fix Pass 3).
	for line_ft: int in [40, 30]:
		_box(self, Vector3(0.0, 0.006, line_z_for_ft(line_ft)),
			Vector3(1.6, 0.012, 0.07), _mat(Color(0.92, 0.92, 0.90)))

	# One shoe pedestal per line, both placed by the same rule:
	# behind the line, to the side, clear of the stance box.
	for stand_line: int in [40, 30]:
		var tf: Transform3D = stand_tfs[stand_line]
		_build_pedestal(tf)

	_build_scenery()


## Fix Pass 10 scenery / comfort dressing: the first sketch of the
## backyard. Chris gets queasy moving in the bare test court - his
## diagnosis: "lack of anything in background, no objects, flat
## plane." Everything here is a STATIC VISUAL REFERENCE at some
## distance (mow stripes underfoot, fence at the yard edge, trees
## and a shed mid/far, sky + clouds above); nothing collides,
## nothing moves, and the judged court surfaces - pit, lines,
## pedestals, stake - are untouched. Placement keeps the court
## apron (|x| <= 2.3, z -14.8..1.6) bare of stripes and keeps the
## board sightline from both foul lines clear; the smoke suite
## asserts the sightline clearance so dressing can never creep
## in front of the board.
func _build_scenery() -> void:
	scenery_root = Node3D.new()
	scenery_root.name = "Scenery"
	add_child(scenery_root)

	# --- Mow stripes: light bands laid over the base green,
	# running down the yard (away from the pitcher), skipping the
	# court apron. Thin visual-only boxes, no collision.
	var stripes := Node3D.new()
	stripes.name = "Stripes"
	scenery_root.add_child(stripes)
	var stripe_mat := _mat(Color(0.40, 0.60, 0.30))
	var band_w: float = 1.4
	var band_i: int = 0
	var band_x: float = -19.6 + band_w * 0.5
	while band_x < 19.6:
		if band_i % 2 == 0:
			if absf(band_x) < 3.0:
				# Band crosses the apron: two stubs, behind the
				# foul lines and beyond the pit.
				_box(stripes, Vector3(band_x, 0.002, 9.8), Vector3(band_w, 0.004, 16.4), stripe_mat)
				_box(stripes, Vector3(band_x, 0.002, -22.4), Vector3(band_w, 0.004, 15.2), stripe_mat)
			else:
				_box(stripes, Vector3(band_x, 0.002, -6.0), Vector3(band_w, 0.004, 48.0), stripe_mat)
		band_i += 1
		band_x += band_w

	# --- Perimeter fence: vertical wooden slats + two rails per
	# run, at the yard edge (x +/-13, z -20 / +7) - the backyard
	# fence from Chris's photo feed. One shared slat mesh.
	var fence := Node3D.new()
	fence.name = "Fence"
	scenery_root.add_child(fence)
	var slat_mesh := BoxMesh.new()
	slat_mesh.size = Vector3(0.24, 1.75, 0.03)
	var wood_a := _mat(Color(0.52, 0.40, 0.26))
	var wood_b := _mat(Color(0.47, 0.36, 0.23))
	var rail_mat := _mat(Color(0.44, 0.33, 0.21))
	var post_mesh := BoxMesh.new()
	post_mesh.size = Vector3(0.12, 1.85, 0.12)
	# Runs: [start, end] pairs along the rectangle.
	var runs: Array = [
		[Vector2(-13.0, -20.0), Vector2(13.0, -20.0)],
		[Vector2(-13.0, 7.0), Vector2(13.0, 7.0)],
		[Vector2(-13.0, -20.0), Vector2(-13.0, 7.0)],
		[Vector2(13.0, -20.0), Vector2(13.0, 7.0)],
	]
	for run: Array in runs:
		var a: Vector2 = run[0]
		var b: Vector2 = run[1]
		var run_len: float = a.distance_to(b)
		var dir2: Vector2 = (b - a) / run_len
		var yaw: float = atan2(dir2.x, dir2.y) + PI * 0.5
		var n_slats: int = int(run_len / 0.275)
		for s: int in n_slats:
			var c2: Vector2 = a + dir2 * (0.14 + float(s) * 0.275)
			var slat := MeshInstance3D.new()
			slat.mesh = slat_mesh
			slat.material_override = wood_a if s % 2 == 0 else wood_b
			slat.position = Vector3(c2.x, 0.875, c2.y)
			slat.rotation_degrees = Vector3(0.0, rad_to_deg(yaw), 0.0)
			fence.add_child(slat)
		for rail_y: float in [0.50, 1.35]:
			var rail := MeshInstance3D.new()
			var rail_mesh := BoxMesh.new()
			rail_mesh.size = Vector3(run_len, 0.09, 0.04)
			rail.mesh = rail_mesh
			rail.material_override = rail_mat
			var mid2: Vector2 = (a + b) * 0.5
			rail.position = Vector3(mid2.x, rail_y, mid2.y)
			rail.rotation_degrees = Vector3(0.0, rad_to_deg(yaw), 0.0)
			fence.add_child(rail)
		var n_posts: int = int(run_len / 3.25)
		for p: int in range(n_posts + 1):
			var c2: Vector2 = a + dir2 * (float(p) * run_len / float(n_posts))
			var post := MeshInstance3D.new()
			post.mesh = post_mesh
			post.material_override = rail_mat
			post.position = Vector3(c2.x, 0.925, c2.y)
			fence.add_child(post)

	# --- Trees: trunk + canopy masses at varied distances.
	var trunk_mat := _mat(Color(0.35, 0.25, 0.16))
	var leaf_a := _mat(Color(0.22, 0.42, 0.18))
	var leaf_b := _mat(Color(0.27, 0.48, 0.21))
	var tree_spots: Array = [
		[Vector3(-8.5, 0.0, -19.5), 1.15],
		[Vector3(7.0, 0.0, -19.0), 1.0],
		[Vector3(-11.5, 0.0, -9.0), 1.25],
		[Vector3(11.0, 0.0, -5.0), 0.95],
		[Vector3(-7.5, 0.0, 4.5), 1.05],
		[Vector3(12.0, 0.0, 3.0), 1.2],
	]
	var tree_i: int = 0
	for spot: Array in tree_spots:
		tree_i += 1
		var tp: Vector3 = spot[0]
		var sc: float = spot[1]
		var tree := Node3D.new()
		tree.name = "Tree%d" % tree_i
		tree.position = tp
		scenery_root.add_child(tree)
		var trunk := MeshInstance3D.new()
		var trunk_mesh := CylinderMesh.new()
		trunk_mesh.top_radius = 0.14 * sc
		trunk_mesh.bottom_radius = 0.22 * sc
		trunk_mesh.height = 2.2 * sc
		trunk.mesh = trunk_mesh
		trunk.material_override = trunk_mat
		trunk.position = Vector3(0.0, 1.1 * sc, 0.0)
		tree.add_child(trunk)
		var blobs: Array = [
			[Vector3(0.0, 3.1, 0.0) * sc, 1.6],
			[Vector3(0.85, 2.55, 0.3) * sc, 1.1],
			[Vector3(-0.8, 2.65, -0.35) * sc, 1.05],
		]
		var blob_i: int = 0
		for blob: Array in blobs:
			blob_i += 1
			var bp2: Vector3 = blob[0]
			var br: float = float(blob[1]) * sc
			var can := MeshInstance3D.new()
			var sm := SphereMesh.new()
			sm.radius = br
			sm.height = br * 2.0
			sm.radial_segments = 12
			sm.rings = 8
			can.mesh = sm
			can.material_override = leaf_a if blob_i % 2 == 1 else leaf_b
			can.position = bp2
			tree.add_child(can)

	# --- Shed: simple box body + pitched roof + door, off to the
	# right beyond the pit (Chris's photo feed has the white shed).
	var shed := Node3D.new()
	shed.name = "Shed"
	shed.position = Vector3(9.5, 0.0, -13.0)
	shed.rotation_degrees = Vector3(0.0, -12.0, 0.0)
	scenery_root.add_child(shed)
	var shed_mat := _mat(Color(0.62, 0.64, 0.66))
	_box(shed, Vector3(0.0, 1.075, 0.0), Vector3(2.8, 2.15, 2.1), shed_mat)
	var roof_mat := _mat(Color(0.30, 0.28, 0.28))
	var roof_l := _box(shed, Vector3(-0.72, 2.42, 0.0), Vector3(1.75, 0.07, 2.4), roof_mat)
	roof_l.rotation_degrees = Vector3(0.0, 0.0, 38.0)
	var roof_r := _box(shed, Vector3(0.72, 2.42, 0.0), Vector3(1.75, 0.07, 2.4), roof_mat)
	roof_r.rotation_degrees = Vector3(0.0, 0.0, -38.0)
	_box(shed, Vector3(0.0, 0.95, 1.06), Vector3(0.8, 1.5, 0.04), _mat(Color(0.45, 0.47, 0.50)))

	# --- Clouds: flattened bright puffs, unshaded, high and far.
	var clouds := Node3D.new()
	clouds.name = "Clouds"
	scenery_root.add_child(clouds)
	var cloud_mat := StandardMaterial3D.new()
	cloud_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	cloud_mat.albedo_color = Color(0.97, 0.98, 1.0)
	var cloud_spots: Array = [
		[Vector3(-14.0, 30.0, -34.0), Vector3(7.0, 1.1, 3.5)],
		[Vector3(6.0, 34.0, -28.0), Vector3(9.0, 1.4, 4.0)],
		[Vector3(16.0, 28.0, -12.0), Vector3(6.0, 1.0, 3.0)],
		[Vector3(-20.0, 32.0, -2.0), Vector3(8.0, 1.2, 3.6)],
		[Vector3(2.0, 36.0, -44.0), Vector3(11.0, 1.6, 4.5)],
		[Vector3(12.0, 30.0, 10.0), Vector3(6.5, 1.0, 3.2)],
	]
	for cspot: Array in cloud_spots:
		var cp: Vector3 = cspot[0]
		var cs2: Vector3 = cspot[1]
		var puff := MeshInstance3D.new()
		var pm := SphereMesh.new()
		pm.radius = 1.0
		pm.height = 2.0
		pm.radial_segments = 12
		pm.rings = 8
		puff.mesh = pm
		puff.material_override = cloud_mat
		puff.position = cp
		puff.scale = cs2
		clouds.add_child(puff)


func _build_rig() -> void:
	origin = XROrigin3D.new()
	origin.name = "Origin"
	add_child(origin)
	cam = XRCamera3D.new()
	origin.add_child(cam)
	var xr_interface: XRInterface = XRServer.find_interface("OpenXR")
	if xr_interface != null and xr_interface.is_initialized():
		get_viewport().use_xr = true
		xr_ok = true
	else:
		var fallback := Camera3D.new()
		fallback.position = Vector3(0.0, 1.55, 1.15)
		add_child(fallback)
		fallback.look_at(Vector3(0.0, 0.35, -5.5), Vector3.UP)
		fallback.current = true
	for hand: String in ["L", "R"]:
		var tracker_name: StringName = &"left_hand" if hand == "L" else &"right_hand"
		var c := XRController3D.new()
		c.tracker = tracker_name
		origin.add_child(c)
		hand_ctrl[hand] = c
		_build_controller_rep(c, hand)


func _build_controller_rep(ctrl: XRController3D, hand: String) -> void:
	var rep := Node3D.new()
	rep.name = "ControllerRep" + hand
	ctrl.add_child(rep)
	ctrl_rep[hand] = rep
	var accent: Color = Color(0.25, 0.85, 1.0) if hand == "L" else Color(1.0, 0.55, 0.2)
	var body := MeshInstance3D.new()
	var body_mesh := BoxMesh.new()
	body_mesh.size = Vector3(0.038, 0.026, 0.105)
	body.mesh = body_mesh
	body.material_override = _mat(Color(0.72, 0.74, 0.78))
	body.position = Vector3(0.0, -0.005, 0.005)
	body.rotation_degrees = Vector3(-18.0, 0.0, 0.0)
	rep.add_child(body)
	var band := MeshInstance3D.new()
	var band_mesh := BoxMesh.new()
	band_mesh.size = Vector3(0.040, 0.010, 0.024)
	band.mesh = band_mesh
	band.material_override = _mat(accent, 1.2)
	band.position = Vector3(0.0, 0.006, -0.018)
	band.rotation_degrees = Vector3(-18.0, 0.0, 0.0)
	rep.add_child(band)
	var tag := Label3D.new()
	tag.text = hand
	tag.font_size = 64
	tag.pixel_size = 0.0009
	tag.modulate = accent
	tag.outline_size = 8
	tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	tag.position = Vector3(0.0, 0.045, 0.0)
	rep.add_child(tag)


func _head_tracking_ok() -> bool:
	var t: XRPositionalTracker = XRServer.get_tracker(&"head") as XRPositionalTracker
	if t == null:
		return false
	var pose: XRPose = t.get_pose(&"default")
	if pose == null:
		return false
	return pose.has_tracking_data


func _build_board() -> void:
	board_root = Node3D.new()
	# Fix Pass 10 placement (Chris's order): BEYOND the pit, LEFT
	# of the stake from the pitcher's viewpoint, face turned back
	# at the pitching end - after a throw he reads the results
	# where he is already looking, instead of turning around to a
	# board by the foul line. Pass 2 put the FP1 board front-left
	# of the spot after pass 1's yaw sign pointed its face AWAY
	# from the player (he had been reading its back); the smoke
	# suite's facing assertion survives from that lesson and now
	# guards THIS spot. The board is scoreboard-sized (3 m wide,
	# slab top 3.2 m) because the stat lines must read from
	# 13-16 m: ~0.21 m capitals, with the controls list in smaller
	# type below for the one close-up read. Label Y positions are
	# laid out on the font's TRUE line pitch (get_height = 1.375x
	# font_size for the fallback font - a first cut that assumed
	# 1.0x overlapped title into status in the close-up proof).
	board_root.position = BOARD_POS
	board_root.rotation_degrees = Vector3(0.0, BOARD_YAW_DEG, 0.0)
	add_child(board_root)
	var wood := _mat(Color(0.30, 0.21, 0.12))
	_box(board_root, Vector3(-1.38, 1.75, -0.03), Vector3(0.09, 3.50, 0.09), wood)
	_box(board_root, Vector3(1.38, 1.75, -0.03), Vector3(0.09, 3.50, 0.09), wood)
	_box(board_root, Vector3(0.0, 1.85, -0.02), board_slab_size, wood)
	title_label = Label3D.new()
	title_label.text = "HORSESHOES - TOSS TEST"
	title_label.font_size = 56
	title_label.pixel_size = 0.0026
	title_label.modulate = Color(1.0, 0.93, 0.75)
	title_label.outline_size = 10
	title_label.outline_modulate = Color(0.1, 0.07, 0.03)
	title_label.position = Vector3(0.0, 3.04, 0.01)
	board_root.add_child(title_label)
	status_label = Label3D.new()
	status_label.font_size = 64
	status_label.pixel_size = 0.0031
	status_label.modulate = Color(0.95, 0.97, 0.90)
	status_label.outline_size = 8
	status_label.outline_modulate = Color(0.1, 0.07, 0.03)
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status_label.position = Vector3(0.0, 2.02, 0.01)
	board_root.add_child(status_label)
	controls_label = Label3D.new()
	controls_label.text = "CONTROLS\nGRAB: squeeze a glinting part of the shoe\ntoe = FLIP hold - side = TURN hold\nSLIDE: Grip + trigger: slide grip along shoe\nlet go of trigger to lock the new grip\nTHROW: swing, open hand (shoe returns)\nDROP: open hand while still\nLeft stick: move\nRight stick: turn\n30 FT LINE: up the court - learning distance\nRECENTER: menu long-press - seated/standing ok"
	controls_label.font_size = 34
	controls_label.pixel_size = 0.00105
	controls_label.line_spacing = 2.0
	controls_label.modulate = Color(0.88, 0.90, 0.82)
	controls_label.outline_size = 6
	controls_label.outline_modulate = Color(0.1, 0.07, 0.03)
	controls_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	controls_label.position = Vector3(0.0, 0.83, 0.01)
	board_root.add_child(controls_label)


func _update_board() -> void:
	if status_label == null:
		return
	var dist_text: String = "-"
	var flip_text: String = "-"
	var turn_text: String = "-"
	if last_distance_in >= 0.0:
		dist_text = "%.1f IN" % last_distance_in
		# Fix Pass 10 rotation readout (Chris approved): the same
		# flip_rot / turn_rot numbers the recorder writes to
		# throws.jsonl for this throw, so he can watch his turn
		# attempts actually turn (or not) from where he stands.
		flip_text = "%.2f REV" % last_flip_rev
		turn_text = "%.2f REV" % last_turn_rev
	var lines: String = "THROWS: %d\nHOLD: %s\nLAST: %s\nFLIP: %s\nTURN: %s" % [
		throw_count, last_hold_text, dist_text, flip_text, turn_text]
	if last_ringer:
		lines += "\nRINGER!"
	status_label.text = lines


func _spawn_shoe() -> void:
	shoe = Shoe.new()
	add_child(shoe)
	shoe.guard_axis_a = stake_axis_a
	shoe.guard_axis_b = stake_axis_b
	shoe.guard_radius = STAKE_COLLISION_RADIUS
	shoe.guard_body = stake_body_node
	shoe.guard_enabled = true
	shoe.freeze = true
	shoe.global_transform = stand_tf
	shoe.body_entered.connect(_on_shoe_body_entered)
	state = "STAND"


# --- Hand access (test overrides first, then the real controllers) ---

func _hand_tf(hand: String) -> Transform3D:
	if test_hand_tf.has(hand):
		var tf: Transform3D = test_hand_tf[hand]
		return tf
	var c: XRController3D = hand_ctrl[hand]
	return c.global_transform


func _grip_value(hand: String) -> float:
	if test_grip.has(hand):
		return float(test_grip[hand])
	var c: XRController3D = hand_ctrl[hand]
	var v: Variant = c.get_input(&"grip")
	if v == null:
		return 0.0
	return float(v)


func _trigger_value(hand: String) -> float:
	if test_trigger.has(hand):
		return float(test_trigger[hand])
	var c: XRController3D = hand_ctrl[hand]
	var v: Variant = c.get_input(&"trigger")
	if v == null:
		return 0.0
	return float(v)


func _stick_value(hand: String) -> Vector2:
	if test_stick.has(hand):
		var tv: Vector2 = test_stick[hand]
		return tv
	var c: XRController3D = hand_ctrl[hand]
	return c.get_vector2(&"primary")


func _track_hand_speed(hand: String) -> void:
	var now: float = float(Time.get_ticks_msec()) / 1000.0
	var pos: Vector3 = _hand_tf(hand).origin
	if _prev_hand_t.has(hand):
		var dt: float = now - float(_prev_hand_t[hand])
		if dt > 0.0005:
			var prev: Vector3 = _prev_hand_pos[hand]
			var inst: float = (pos - prev).length() / dt
			hand_speed[hand] = lerpf(float(hand_speed[hand]), inst, 0.45)
	_prev_hand_pos[hand] = pos
	_prev_hand_t[hand] = now


# --- Sampling ---

func _add_sample() -> void:
	if held_hand == "":
		return
	var now: float = float(Time.get_ticks_msec()) / 1000.0
	if not samples.is_empty():
		var last: Dictionary = samples[samples.size() - 1]
		if now - float(last["t"]) < 0.004:
			return
	var tf: Transform3D = _hand_tf(held_hand)
	samples.append(ThrowMath.make_sample(now, tf.origin, tf.basis.get_rotation_quaternion(), origin.global_position))
	while samples.size() > 2:
		var first: Dictionary = samples[0]
		if now - float(first["t"]) <= SAMPLE_KEEP_SEC:
			break
		samples.pop_front()


# --- Grab processing (render rate) ---

func _find_candidate() -> void:
	candidate_hand = ""
	candidate_zone = ""
	if state != "STAND":
		return
	var best_dist: float = CANDIDATE_RADIUS
	for hand: String in ["L", "R"]:
		var hp: Vector3 = _hand_tf(hand).origin
		for zone: String in Shoe.zones().keys():
			var d: float = hp.distance_to(shoe.zone_world_center(zone))
			if d < best_dist:
				best_dist = d
				candidate_hand = hand
				candidate_zone = zone


## Thumbstick locomotion (Fix Pass 2; STANDARD twin-stick scheme
## restored in Fix Pass 6 at Chris's field order: the LEFT stick
## walks, the RIGHT stick turns - the two are read independently
## and applied in the same frame so they blend into a curved
## path). Runs BEFORE sampling/grab so every hand transform this
## frame already includes the new origin. Walk is head-relative and
## direct; the smooth turn rotates the origin about the camera so
## turning never translates the player.
func _process_locomotion(delta: float) -> void:
	if delta <= 0.0:
		return
	var ls: Vector2 = _stick_value("L")
	var disp: Vector3 = Locomotion.walk_displacement(ls, cam.global_transform.basis, delta)
	if disp != Vector3.ZERO:
		origin.global_position = Locomotion.clamp_origin(origin.global_position + disp)
	var rs: Vector2 = _stick_value("R")
	var ang: float = Locomotion.turn_angle(rs.x, delta)
	if not is_zero_approx(ang):
		origin.global_transform = Locomotion.rotate_about(
			origin.global_transform, cam.global_position, deg_to_rad(ang))


func _process(_delta: float) -> void:
	_process_locomotion(_delta)
	_track_hand_speed("L")
	_track_hand_speed("R")
	if state == "HELD":
		_add_sample()
	_process_grab()
	if state == "HELD" and not grab_state.sliding:
		shoe.global_transform = _hand_tf(held_hand) * rel_tf
	shoe.set_markers_visible(debug_show_zones and (state == "STAND" or state == "HELD"))


func _process_grab() -> void:
	var prev_zone: String = candidate_zone
	_find_candidate()
	if candidate_zone != prev_zone:
		shoe.clear_highlights()
		if candidate_zone != "" and state == "STAND":
			shoe.set_highlight(candidate_zone, true)
			var c: XRController3D = hand_ctrl[candidate_hand]
			if c != null:
				c.trigger_haptic_pulse(&"haptic", 0.0, 0.35, 0.04, 0.0)
			recorder.log_record({
				"type": "grab", "event": "zone_acquired",
				"hand": candidate_hand, "zone": candidate_zone,
				"ts": Time.get_datetime_string_from_system(),
			})
	var in_hand: String = ""
	var in_zone: String = ""
	var in_grip: float = 0.0
	var in_speed: float = 0.0
	var in_trigger: float = 0.0
	if grab_state.latched:
		in_hand = held_hand
		in_zone = held_zone
		in_grip = _grip_value(held_hand)
		in_speed = float(hand_speed[held_hand])
		in_trigger = _trigger_value(held_hand)
	elif candidate_hand != "":
		in_hand = candidate_hand
		in_zone = candidate_zone
		in_grip = _grip_value(candidate_hand)
		in_speed = float(hand_speed[candidate_hand])
		in_trigger = _trigger_value(candidate_hand)
	var ev: String = grab_state.update(in_hand, in_zone, in_grip, in_speed, in_trigger)
	match ev:
		"latch":
			_do_latch(in_hand, in_zone)
		"slide_start":
			pass # shoe simply stops following; slide resolves at lock
		"slide_end":
			_do_slide_end()
		"release":
			_do_release()


func _do_latch(hand: String, zone: String) -> void:
	# Home starts as the pedestal the shoe was just grabbed from.
	# It does not stay glued there: a throw re-homes to the line
	# it was released from (see _settle_throw), a drop returns
	# here, and while the shoe sits stocked the home follows the
	# line the player is standing at (Fix Pass 7).
	_set_active_stand(_nearest_stand_line())
	held_hand = hand
	held_zone = zone
	var z: Dictionary = Shoe.zones()[zone]
	held_hold = String(z["hold"])
	slide_offset = 0.0
	rel_tf = Shoe.hold_transform(zone, hand)
	shoe.freeze = true
	shoe.global_transform = _hand_tf(hand) * rel_tf
	state = "HELD"
	samples.clear()
	sample_hand = hand
	shoe.set_highlight(zone, true)
	recorder.log_record({
		"type": "grab", "event": "latch", "hand": hand, "zone": zone,
		"hold": held_hold, "ts": Time.get_datetime_string_from_system(),
	})


func _do_slide_end() -> void:
	var hand_tf: Transform3D = _hand_tf(held_hand)
	var z: Dictionary = Shoe.zones()[held_zone]
	var axis: Vector3 = z["slide_axis"]
	var smax: float = float(z["slide_max"])
	var center: Vector3 = z["center"]
	var anchor_local: Vector3 = shoe.global_transform.affine_inverse() * hand_tf.origin
	var off: float = (anchor_local - center).dot(axis)
	var clamped: float = clampf(off, -smax, smax)
	if not is_equal_approx(off, clamped):
		var shift_local: Vector3 = axis * (off - clamped)
		shoe.global_position += shoe.global_transform.basis * shift_local
	slide_offset = clamped
	rel_tf = hand_tf.affine_inverse() * shoe.global_transform
	recorder.log_record({
		"type": "grab", "event": "slide", "hand": held_hand, "zone": held_zone,
		"slide_offset_m": clamped, "ts": Time.get_datetime_string_from_system(),
	})


func _do_release() -> void:
	_release_shoe(samples)


## The throw itself. Release position/orientation are the shoe's
## CURRENT transform (cached by the follow code at the release event);
## velocity/angular velocity come from the windowed fit over the
## sample buffer - never a single-frame delta, never recomputed later.
func _release_shoe(release_samples: Array) -> void:
	# Origin-relative (Fix Pass 2): if the player is walking while he
	# releases, the origin's share of the hand's world motion is
	# removed first - the shoe gets the ARM's velocity, not the
	# thumbstick's. Standing still this is the pass-1 estimate.
	var vel: Vector3 = ThrowMath.estimate_velocity_origin_relative(
		release_samples, origin.global_transform.basis)
	var ang: Vector3 = ThrowMath.estimate_angular_velocity_windowed(release_samples)
	var speed: float = vel.length()
	var release_tf: Transform3D = shoe.global_transform
	var hand_was: String = held_hand
	var zone_was: String = held_zone
	var hold_was: String = held_hold
	var slide_was: float = slide_offset
	held_hand = ""
	sample_hand = ""
	shoe.clear_highlights()
	if speed >= THROW_MIN_SPEED:
		release_cache = {
			"hand": hand_was, "zone": zone_was, "hold": hold_was,
			"slide_offset_m": slide_was,
			"line_ft": ThrowMath.line_ft_for_release(release_tf.origin, STAKE_POS),
			"origin_pos": origin.global_position,
			# Stance evidence, captured at the release moment: where
			# the HEAD faced vs how the whole RIG was yawed (stick
			# turns or a crooked recenter). Their difference separates
			# "he turned his head" from "the rig was rotated".
			"head_yaw_deg": ThrowMath.yaw_deg(-cam.global_transform.basis.z),
			"origin_yaw_deg": ThrowMath.yaw_deg(-origin.global_transform.basis.z),
			"samples": release_samples.duplicate(true),
			"release_pos": release_tf.origin,
			"release_quat": release_tf.basis.get_rotation_quaternion(),
			"velocity": vel, "angular_velocity": ang,
		}
		flip_rot = 0.0
		turn_rot = 0.0
		has_contact = false
		_fly_time = 0.0
		_still_time = 0.0
		state = "FLYING"
		shoe.reset_stake_guard()
		shoe.freeze = false
		shoe.global_transform = release_tf
		shoe.linear_velocity = vel
		shoe.angular_velocity = ang
	else:
		state = "DROPPED"
		_still_time = 0.0
		_wait_time = 0.0
		shoe.freeze = false
		shoe.global_transform = release_tf
		shoe.linear_velocity = Vector3.ZERO
		shoe.angular_velocity = Vector3.ZERO
		recorder.log_record({
			"type": "grab", "event": "drop", "hand": hand_was, "zone": zone_was,
			"release_speed_mps": speed, "ts": Time.get_datetime_string_from_system(),
		})


# --- Flight / settle ---

func _on_shoe_body_entered(_body: Node) -> void:
	if state == "FLYING" and not has_contact:
		has_contact = true
		first_contact_pos = shoe.global_position


func _physics_process(delta: float) -> void:
	_restock_to_player_line()
	if state == "HELD":
		_add_sample()
		if not grab_state.sliding:
			shoe.global_transform = _hand_tf(held_hand) * rel_tf
	match state:
		"FLYING":
			_fly_time += delta
			var av: Vector3 = shoe.angular_velocity
			var x_axis: Vector3 = shoe.global_transform.basis.x.normalized()
			flip_rot += av.dot(x_axis) * delta / TAU
			turn_rot += av.y * delta / TAU
			if _fly_time > 0.6:
				if shoe.linear_velocity.length() < 0.10 and shoe.angular_velocity.length() < 0.30:
					_still_time += delta
				else:
					_still_time = 0.0
				if _still_time > SETTLE_STILL_SEC:
					_settle_throw()
			if shoe.global_position.length() > 40.0 or shoe.global_position.y < -2.0:
				_settle_throw()
		"DROPPED":
			if shoe.linear_velocity.length() < 0.10 and shoe.angular_velocity.length() < 0.30:
				_still_time += delta
			else:
				_still_time = 0.0
			if _still_time > SETTLE_STILL_SEC:
				state = "RETURNING"
				_wait_time = 0.0
		"RETURNING":
			_wait_time += delta
			if _wait_time > RETURN_WAIT_SEC:
				_return_to_stand()


func _settle_throw() -> void:
	if state != "FLYING":
		return
	var stake_at_shoe := Vector3(STAKE_POS.x, shoe.global_position.y, STAKE_POS.z)
	var dist_in: float = ThrowMath.nearest_distance_inches(
		shoe.global_transform, stake_at_shoe, Shoe.WIDTH * 0.5, Shoe.LENGTH * 0.5)
	var ringer: bool = ThrowMath.is_ringer(
		shoe.global_transform, stake_at_shoe,
		Shoe.RINGER_INNER_HALF, Shoe.RINGER_Z_MIN, Shoe.RINGER_Z_MAX)
	throw_count += 1
	last_hold_text = "%s (%s)" % [String(release_cache["hold"]).to_upper(), String(release_cache["zone"]).to_upper()]
	last_distance_in = dist_in
	last_flip_rev = flip_rot
	last_turn_rev = turn_rot
	last_ringer = ringer
	_update_board()
	var vel: Vector3 = release_cache["velocity"]
	var ang: Vector3 = release_cache["angular_velocity"]
	var origin_at_release: Vector3 = release_cache["origin_pos"]
	var rp: Vector3 = release_cache["release_pos"]
	var rq: Quaternion = release_cache["release_quat"]
	var samples_copy: Array = release_cache["samples"]
	recorder.log_record({
		"type": "throw",
		"ts": Time.get_datetime_string_from_system(),
		"throw_index": throw_count,
		"hand": String(release_cache["hand"]),
		"hold": String(release_cache["hold"]),
		"zone": String(release_cache["zone"]),
		"slide_offset_m": float(release_cache["slide_offset_m"]),
		"line_ft": int(release_cache["line_ft"]),
		"origin_release_pos": ThrowRecorder.vec3_arr(origin_at_release),
		"head_yaw_deg": float(release_cache["head_yaw_deg"]),
		"origin_yaw_deg": float(release_cache["origin_yaw_deg"]),
		"samples": ThrowRecorder.sample_arr(samples_copy),
		"release_pos": ThrowRecorder.vec3_arr(rp),
		"release_quat": ThrowRecorder.quat_arr(rq),
		"release_velocity": ThrowRecorder.vec3_arr(vel),
		"release_angular_velocity": ThrowRecorder.vec3_arr(ang),
		"first_contact_pos": ThrowRecorder.vec3_arr(first_contact_pos) if has_contact else [],
		"settle_pos": ThrowRecorder.vec3_arr(shoe.global_position),
		"settle_quat": ThrowRecorder.quat_arr(shoe.global_transform.basis.get_rotation_quaternion()),
		"landing_distance_in": dist_in,
		"ringer": ringer,
		"flip_rotations": flip_rot,
		"turn_rotations": turn_rot,
	})
	# The next shoe stocks where the throw was made from (Fix
	# Pass 7): home follows the release's own line classification,
	# so the return below lands directly on the throwing line's
	# pedestal instead of whichever pedestal the shoe was grabbed
	# from (a shoe grabbed at 40 and pitched from 30 restocks at 30).
	_set_active_stand(int(release_cache["line_ft"]))
	state = "RETURNING"
	_wait_time = 0.0 # no linger: rhythm matters (Fix Pass 3)


func _return_to_stand() -> void:
	shoe.freeze = true
	shoe.global_transform = stand_tf
	shoe.clear_highlights()
	has_contact = false
	release_cache.clear()
	state = "STAND"
