extends SceneTree

## Logic suite for the toss test: release-window math (with the
## single-frame NEGATIVE CONTROL), angular velocity, ringer geometry,
## recorder schema, grab latch in both orders, the permanent grab-zone
## audit, and the ClassDB XR API-surface guard.
## Run: godot --headless --path . --script tests/run_tests.gd
## Verifies MATH + WIRING CONTRACTS, not headset feel.

var failures: int = 0
var checks: int = 0


func check(cond: bool, name: String) -> void:
	checks += 1
	if cond:
		print("PASS  ", name)
	else:
		failures += 1
		print("FAIL  ", name)


func _init() -> void:
	_run()


## Synthetic HAND arc at 90 Hz: a swinging hand accelerates into the
## release (it is not ballistic), so position is quadratic with a
## constant acceleration A and velocity at t is exactly v0 + A*t.
## Peak speed lands on the final sample, like a real grip opening.
func arc_samples(v0: Vector3, dur: float, hz: float = 90.0, jitter: float = 0.0, seed_val: int = 7) -> Array:
	return arc_samples_accel(v0, Vector3(1.0, 5.0, -11.0), dur, hz, jitter, seed_val)


func arc_samples_accel(v0: Vector3, accel: Vector3, dur: float, hz: float = 90.0, jitter: float = 0.0, seed_val: int = 7) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val
	var out: Array = []
	var p0 := Vector3(0.25, 1.15, 0.30)
	var steps: int = int(dur * hz)
	for i: int in steps + 1:
		var t: float = float(i) / hz
		var pos: Vector3 = p0 + v0 * t + 0.5 * accel * t * t
		if jitter > 0.0:
			pos += Vector3(rng.randf_range(-jitter, jitter), rng.randf_range(-jitter, jitter), rng.randf_range(-jitter, jitter))
		out.append(ThrowMath.make_sample(t, pos, Quaternion.IDENTITY))
	return out


func spin_samples(axis: Vector3, omega: float, dur: float, hz: float = 90.0) -> Array:
	var out: Array = []
	var steps: int = int(dur * hz)
	for i: int in steps + 1:
		var t: float = float(i) / hz
		var q := Quaternion(axis.normalized(), omega * t)
		out.append(ThrowMath.make_sample(t, Vector3(0.25, 1.15 + 0.8 * t, 0.30 - 1.6 * t), q))
	return out


func test_release_math() -> void:
	var v0 := Vector3(0.1, 0.6, -0.5)
	var accel := Vector3(1.0, 5.0, -11.0)
	var dur: float = 0.30
	var clean: Array = arc_samples(v0, dur)
	var v_true: Vector3 = v0 + accel * dur
	var v_est: Vector3 = ThrowMath.estimate_velocity_windowed(clean)
	check(v_est.distance_to(v_true) < 0.15,
		"windowed velocity on a clean arc within 0.15 m/s (err %.3f)" % v_est.distance_to(v_true))

	var noisy: Array = arc_samples(v0, dur, 90.0, 0.004)
	var v_win: Vector3 = ThrowMath.estimate_velocity_windowed(noisy)
	var win_err: float = v_win.distance_to(v_true)
	check(win_err < 0.35, "windowed velocity under 4 mm jitter within 0.35 m/s (err %.3f)" % win_err)

	# NEGATIVE CONTROL: the single-frame estimate must VIOLATE the
	# windowed tolerance on this same data - if it didn't, the test
	# would prove nothing about the implementation choice.
	var v_sf: Vector3 = ThrowMath.estimate_velocity_single_frame(noisy)
	var sf_err: float = v_sf.distance_to(v_true)
	check(sf_err > 0.35,
		"NEGATIVE CONTROL: single-frame estimate violates the 0.35 tolerance (err %.3f vs windowed %.3f)" % [sf_err, win_err])
	check(sf_err > win_err * 1.8,
		"NEGATIVE CONTROL: single-frame error is >1.8x the windowed error (%.3f vs %.3f)" % [sf_err, win_err])

	var pk: int = ThrowMath.peak_speed_index(clean)
	check(pk > 0, "peak speed index found in arc samples (%d)" % pk)
	var sub: Array = ThrowMath.window_subset(noisy)
	check(sub.size() >= 4, "release window subset holds >= 4 samples (%d)" % sub.size())


func test_angular_math() -> void:
	var turn: Array = spin_samples(Vector3.UP, 3.0, 0.30)
	var av: Vector3 = ThrowMath.estimate_angular_velocity_windowed(turn)
	check(av.distance_to(Vector3(0.0, 3.0, 0.0)) < 0.35,
		"windowed angular velocity recovers a 3 rad/s turn (got %s)" % str(av))
	var flip: Array = spin_samples(Vector3.RIGHT, -6.5, 0.30)
	var av2: Vector3 = ThrowMath.estimate_angular_velocity_windowed(flip)
	check(av2.distance_to(Vector3(-6.5, 0.0, 0.0)) < 0.45,
		"windowed angular velocity recovers a -6.5 rad/s flip (got %s)" % str(av2))
	var still: Array = spin_samples(Vector3.UP, 0.0, 0.30)
	check(ThrowMath.estimate_angular_velocity_windowed(still).length() < 0.05,
		"zero rotation estimates as ~zero angular velocity")


func test_ringer_geometry() -> void:
	var stake := Vector3(0.0, 0.08, -12.192)
	var half_w: float = Shoe.WIDTH * 0.5
	var half_l: float = Shoe.LENGTH * 0.5
	# Shoe centred flat on the stake = ringer, distance 0.
	var tf := Transform3D(Basis.IDENTITY, stake)
	check(ThrowMath.is_ringer(tf, stake, Shoe.RINGER_INNER_HALF, Shoe.RINGER_Z_MIN, Shoe.RINGER_Z_MAX),
		"centred flat shoe on the stake is a ringer")
	check(ThrowMath.nearest_distance_inches(tf, stake, half_w, half_l) < 0.01,
		"centred shoe nearest distance is 0 in")
	# Stake beside the shoe - not a ringer.
	var tf2 := Transform3D(Basis.IDENTITY, stake + Vector3(0.14, 0.0, 0.0))
	check(not ThrowMath.is_ringer(tf2, stake, Shoe.RINGER_INNER_HALF, Shoe.RINGER_Z_MIN, Shoe.RINGER_Z_MAX),
		"stake 14 cm to the side is not a ringer")
	# Shoe short of the stake (stake behind the toe) - not a ringer.
	var tf3 := Transform3D(Basis.IDENTITY, stake + Vector3(0.0, 0.0, 0.16))
	check(not ThrowMath.is_ringer(tf3, stake, Shoe.RINGER_INNER_HALF, Shoe.RINGER_Z_MIN, Shoe.RINGER_Z_MAX),
		"stake behind the toe line is not a ringer")
	# Shoe open-end reversed over the stake (yaw PI) with centre on
	# the stake: still encircles - a ringer by the straight-edge test.
	var tf4 := Transform3D(Basis.from_euler(Vector3(0.0, PI, 0.0)), stake)
	check(ThrowMath.is_ringer(tf4, stake, Shoe.RINGER_INNER_HALF, Shoe.RINGER_Z_MIN, Shoe.RINGER_Z_MAX),
		"reversed shoe centred on stake still encircles it")
	# Shoe tipped up on edge - not a ringer even centred.
	var tf5 := Transform3D(Basis.from_euler(Vector3(deg_to_rad(65.0), 0.0, 0.0)), stake)
	check(not ThrowMath.is_ringer(tf5, stake, Shoe.RINGER_INNER_HALF, Shoe.RINGER_Z_MIN, Shoe.RINGER_Z_MAX),
		"shoe on edge over the stake is not a ringer")
	# Distance: shoe centre 0.5 m left of stake -> nearest edge ~16 in.
	var tf6 := Transform3D(Basis.IDENTITY, stake + Vector3(0.5, 0.0, 0.0))
	var d: float = ThrowMath.nearest_distance_inches(tf6, stake, half_w, half_l)
	check(absf(d - 16.06) < 0.6, "nearest distance at 0.5 m offset is ~16.1 in (got %.2f)" % d)
	# Leaner range: centre 0.12 m away -> within 6 in scoring distance.
	var tf7 := Transform3D(Basis.IDENTITY, stake + Vector3(0.12, 0.0, 0.05))
	var d2: float = ThrowMath.nearest_distance_inches(tf7, stake, half_w, half_l)
	check(d2 < 6.0, "shoe at 0.12 m offset lands inside the 6 in zone (%.2f in)" % d2)


func test_recorder_schema() -> void:
	var test_path: String = "user://test_throws.jsonl"
	var abs_path: String = ProjectSettings.globalize_path(test_path)
	if FileAccess.file_exists(test_path):
		DirAccess.remove_absolute(abs_path)
	var rec := ThrowRecorder.new(test_path)
	var samples: Array = arc_samples(Vector3(0.0, 2.0, -3.0), 0.2)
	var ok: bool = rec.log_record({
		"type": "throw", "ts": "test", "throw_index": 1, "hand": "R",
		"hold": "flip", "zone": "toe", "slide_offset_m": 0.0,
		"samples": ThrowRecorder.sample_arr(samples),
		"release_pos": [0.0, 1.2, 0.0], "release_quat": [0.0, 0.0, 0.0, 1.0],
		"release_velocity": [0.0, 2.0, -3.0], "release_angular_velocity": [0.0, 0.0, 0.0],
		"first_contact_pos": [0.0, 0.0, -8.0], "settle_pos": [0.0, 0.05, -12.0],
		"settle_quat": [0.0, 0.0, 0.0, 1.0], "landing_distance_in": 3.2,
		"ringer": false, "flip_rotations": 1.1, "turn_rotations": 0.2,
	})
	check(ok, "recorder writes a throw record")
	check(rec.log_record({"type": "grab", "event": "latch", "hand": "R", "zone": "toe"}),
		"recorder appends a grab record")
	var f: FileAccess = FileAccess.open(test_path, FileAccess.READ)
	check(f != null, "recorder file reopens")
	if f != null:
		var lines: PackedStringArray = f.get_as_text().split("\n", false)
		check(lines.size() == 2, "recorder file holds exactly 2 JSONL lines (%d)" % lines.size())
		var parsed: Variant = JSON.parse_string(lines[0])
		check(parsed is Dictionary, "throw line parses as JSON object")
		if parsed is Dictionary:
			var recd: Dictionary = parsed
			var required: Array[String] = ["type", "hand", "hold", "zone", "samples",
				"release_velocity", "release_angular_velocity", "first_contact_pos",
				"settle_pos", "landing_distance_in", "ringer", "flip_rotations", "turn_rotations"]
			for key: String in required:
				check(recd.has(key), "throw record carries field '%s'" % key)
			var smp: Array = recd["samples"]
			check(smp.size() > 3, "recorded samples present (%d)" % smp.size())
			if smp.size() > 0:
				var s0: Dictionary = smp[0]
				check(s0.has("t") and s0.has("p") and s0.has("q"),
					"sample entries carry t/p/q")
	DirAccess.remove_absolute(abs_path)


func test_grab_state() -> void:
	# Order A: hand in zone first, then squeeze.
	var a := GrabState.new()
	check(a.update("R", "toe", 0.0, 0.0) == "", "order A: no latch without grip")
	check(a.update("R", "toe", 0.9, 0.0) == "latch", "order A: squeeze in zone latches")
	check(a.update("R", "toe", 0.95, 0.2) == "", "order A: latch fires exactly once")
	check(a.latched and a.zone == "toe", "order A: latched on the toe zone")
	# Hysteresis: mid grip keeps the latch (slide band while still).
	var ev: String = a.update("R", "toe", 0.5, 0.0)
	check(a.latched, "hysteresis: mid grip does not drop the latch")
	check(ev == "slide_start", "mid grip while still enters the slide band")
	check(a.update("R", "toe", 0.9, 0.0) == "slide_end", "full grip again ends the slide (lock)")
	# Slide must NOT trigger mid-swing: mid grip at speed stays locked.
	check(a.update("R", "toe", 0.5, 2.5) == "" and not a.sliding,
		"mid grip at swing speed does not enter slide")
	check(a.update("R", "toe", 0.1, 2.5) == "release", "open hand releases")
	check(not a.latched, "released state is clean")

	# Order B: squeeze held first, hand enters the zone after.
	var b := GrabState.new()
	check(b.update("R", "", 0.95, 0.0) == "", "order B: squeeze with no zone does not latch")
	check(not b.latched, "order B: still unlatched outside the zone")
	check(b.update("R", "shank_right", 0.95, 0.0) == "latch",
		"order B: held squeeze latches the frame the hand enters the zone")
	check(b.update("R", "shank_right", 0.95, 0.0) == "", "order B: latch fires exactly once")

	# Mid grip alone never latches (hysteresis low side).
	var c := GrabState.new()
	check(c.update("L", "toe", 0.5, 0.0) == "" and not c.latched,
		"mid grip in a zone does not latch")


func test_zone_audit(shoe_node: Shoe) -> void:
	# Permanent audit: each grab zone must sit on its visible part -
	# centre within the part's AABB (grown slightly), size comparable.
	for zone: String in Shoe.zones().keys():
		var za: AABB = Shoe.zone_aabb(zone)
		var part: MeshInstance3D = shoe_node.parts[zone]
		var mesh_aabb: AABB = part.mesh.get_aabb()
		var part_tf := Transform3D(part.basis, part.position)
		var pa: AABB = part_tf * mesh_aabb
		var grown: AABB = pa.grow(0.012)
		check(grown.has_point(za.get_center()),
			"zone audit: %s zone centre sits on its mesh part" % zone)
		var zs: Vector3 = za.size
		var ps: Vector3 = pa.size
		check(absf(zs.x - ps.x) < 0.075 and absf(zs.z - ps.z) < 0.075,
			"zone audit: %s zone footprint matches part (zone %s vs part %s)" % [zone, str(zs), str(ps)])
	# Hold sanity: flip hold points the open end forward, turn hold sideways.
	var flip_rel: Transform3D = Shoe.hold_transform("toe", "R")
	var open_dir_flip: Vector3 = flip_rel.basis * Vector3(0.0, 0.0, 1.0)
	check(open_dir_flip.z < -0.99, "flip hold: shoe open end points along hand -Z (forward)")
	var turn_rel: Transform3D = Shoe.hold_transform("shank_right", "R")
	var open_dir_turn: Vector3 = turn_rel.basis * Vector3(0.0, 0.0, 1.0)
	check(open_dir_turn.x < -0.99, "turn hold (R): shoe open end points to hand -X (left)")
	var turn_rel_l: Transform3D = Shoe.hold_transform("shank_left", "L")
	var open_dir_turn_l: Vector3 = turn_rel_l.basis * Vector3(0.0, 0.0, 1.0)
	check(open_dir_turn_l.x > 0.99, "turn hold (L): shoe open end points to hand +X (right)")


func test_api_guard() -> void:
	# Every XR call the build makes, probed on the receiver's ACTUAL
	# class (static import catches none of these - dynamic dispatch).
	var pairs: Array = [
		["XRServer", "find_interface"], ["XRServer", "get_tracker"],
		["XRPositionalTracker", "get_pose"],
		["XRPose", "get_has_tracking_data"],
		["XRInterface", "is_initialized"],
		["XRController3D", "get_input"], ["XRController3D", "trigger_haptic_pulse"],
		["XRController3D", "get_is_active"],
	]
	for p: Array in pairs:
		check(ClassDB.class_has_method(String(p[0]), String(p[1])),
			"API guard: %s.%s exists" % [String(p[0]), String(p[1])])


func _run() -> void:
	test_release_math()
	test_angular_math()
	test_ringer_geometry()
	test_recorder_schema()
	test_grab_state()
	test_api_guard()
	var shoe_node := Shoe.new()
	root.add_child(shoe_node)
	await physics_frame
	await process_frame
	test_zone_audit(shoe_node)
	print("---")
	if failures == 0:
		print("LOGIC: ALL %d CHECKS PASSED" % checks)
	else:
		print("LOGIC: %d of %d CHECKS FAILED" % [failures, checks])
	quit(1 if failures > 0 else 0)
