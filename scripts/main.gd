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
var stand_tfs: Dictionary = {} # line_ft (30/40) -> pedestal shoe transform
var stand_tf: Transform3D # the pedestal the shoe currently belongs to
var active_stand_line_ft: int = 40
var board_root: Node3D
var status_label: Label3D
var controls_label: Label3D

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
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.45, 0.62, 0.78)
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
	cyl.top_radius = 0.0127
	cyl.bottom_radius = 0.0127
	cyl.height = 0.62
	smi.mesh = cyl
	smi.position = Vector3(0.0, 0.058, 0.0)
	smi.material_override = _mat(Color(0.55, 0.57, 0.62))
	stake_body.add_child(smi)
	var scs := CollisionShape3D.new()
	var scyl := CylinderShape3D.new()
	scyl.radius = 0.0127
	scyl.height = 0.62
	scs.shape = scyl
	scs.position = Vector3(0.0, 0.058, 0.0)
	stake_body.add_child(scs)

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
	# Duel placement pattern (Fix Pass 2): front-LEFT of the pitching
	# spot, ~35 deg off the throw lane, ~2.1 m out, face turned back
	# at the foul line. Pass 1 put it at z=-0.30 with the yaw sign
	# flipped, so its face pointed AWAY from the player - Chris had
	# to walk around behind it to read it. Never again: the smoke
	# suite asserts forward hemisphere + facing from now on.
	board_root.position = Vector3(-1.20, 0.0, -1.70)
	board_root.rotation_degrees = Vector3(0.0, 35.0, 0.0)
	add_child(board_root)
	var wood := _mat(Color(0.30, 0.21, 0.12))
	_box(board_root, Vector3(-0.62, 0.95, -0.03), Vector3(0.07, 1.90, 0.07), wood)
	_box(board_root, Vector3(0.62, 0.95, -0.03), Vector3(0.07, 1.90, 0.07), wood)
	_box(board_root, Vector3(0.0, 1.30, -0.02), Vector3(1.50, 1.30, 0.04), wood)
	var title := Label3D.new()
	title.text = "HORSESHOES - TOSS TEST"
	title.font_size = 56
	title.pixel_size = 0.0019
	title.modulate = Color(1.0, 0.93, 0.75)
	title.outline_size = 10
	title.outline_modulate = Color(0.1, 0.07, 0.03)
	title.position = Vector3(0.0, 1.80, 0.01)
	board_root.add_child(title)
	status_label = Label3D.new()
	status_label.font_size = 56
	status_label.pixel_size = 0.0018
	status_label.modulate = Color(0.95, 0.97, 0.90)
	status_label.outline_size = 8
	status_label.outline_modulate = Color(0.1, 0.07, 0.03)
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status_label.position = Vector3(0.0, 1.55, 0.01)
	board_root.add_child(status_label)
	controls_label = Label3D.new()
	controls_label.text = "CONTROLS\nGRAB: squeeze a glinting part of the shoe\ntoe = FLIP hold - side = TURN hold\nSLIDE: Grip + trigger: slide grip along shoe\nlet go of trigger to lock the new grip\nTHROW: swing, open hand (shoe returns)\nDROP: open hand while still\nLeft stick: move\nRight stick: turn\n30 FT LINE: up the court - learning distance\nRECENTER: menu long-press - seated/standing ok"
	controls_label.font_size = 38
	controls_label.pixel_size = 0.00105
	controls_label.line_spacing = 2.0
	controls_label.modulate = Color(0.88, 0.90, 0.82)
	controls_label.outline_size = 6
	controls_label.outline_modulate = Color(0.1, 0.07, 0.03)
	controls_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	controls_label.position = Vector3(0.0, 0.99, 0.01)
	board_root.add_child(controls_label)


func _update_board() -> void:
	if status_label == null:
		return
	var dist_text: String = "-"
	if last_distance_in >= 0.0:
		dist_text = "%.1f IN" % last_distance_in
	var lines: String = "THROWS: %d\nHOLD: %s\nLAST: %s" % [throw_count, last_hold_text, dist_text]
	if last_ringer:
		lines += "\nRINGER!"
	status_label.text = lines


func _spawn_shoe() -> void:
	shoe = Shoe.new()
	add_child(shoe)
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
	# The shoe belongs to the pedestal it was just grabbed from;
	# after the throw (or a drop) it returns to THAT pedestal.
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
	state = "RETURNING"
	_wait_time = 0.0 # no linger: rhythm matters (Fix Pass 3)


func _return_to_stand() -> void:
	shoe.freeze = true
	shoe.global_transform = stand_tf
	shoe.clear_highlights()
	has_contact = false
	release_cache.clear()
	state = "STAND"
