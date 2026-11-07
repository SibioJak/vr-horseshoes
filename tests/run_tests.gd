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


func test_line_classification() -> void:
	# Fix Pass 3: every throw record carries the foul line it was
	# pitched from, classified by the release point's horizontal
	# distance to the stake (nearer 8.230 m = 30, nearer
	# 11.278 m = 40). Fix Pass 19: the lines are the TRUE foul
	# lines - the 27 ft line stands at z -3.962 (8.230 m from
	# the stake) and the 37 ft line at z -0.914 (11.278 m).
	var stake := Vector3(0.0, 0.05, -12.192)
	check(ThrowMath.line_ft_for_release(Vector3(0.0, 1.4, -3.962), stake) == 30,
		"line: a release on the 27 ft foul line classifies as 30")
	check(ThrowMath.line_ft_for_release(Vector3(0.0, 1.4, -0.914), stake) == 40,
		"line: a release on the 37 ft foul line classifies as 40")
	check(ThrowMath.line_ft_for_release(Vector3(0.0, 1.4, -6.0), stake) == 30,
		"line: a mid-court release nearer the short line classifies as 30")
	check(ThrowMath.line_ft_for_release(Vector3(0.0, 1.4, -1.0), stake) == 40,
		"line: a between-lines release nearer the standard distance classifies as 40")
	check(ThrowMath.line_ft_for_release(Vector3(0.30, 1.5, -3.10), stake) == 30,
		"line: release height and a small lateral offset do not change the class")


func test_standing_line() -> void:
	# Fix Pass 7: stocking follows the player, so "which line is he
	# standing at" needs an answer with a NEITHER - the release
	# classifier alone always answers 30 or 40. standing_line_ft is
	# that classifier plus a proximity gate on stake distance.
	var stake := Vector3(0.0, 0.05, -12.192)
	check(ThrowMath.standing_line_ft(Vector3(0.0, 1.6, -3.962), stake) == 30,
		"standing: on the 27 ft foul line is the 30 ft line")
	check(ThrowMath.standing_line_ft(Vector3(0.0, 1.6, -0.914), stake) == 40,
		"standing: on the 37 ft foul line is the 40 ft line")
	check(ThrowMath.standing_line_ft(Vector3(0.0, 1.6, -3.462), stake) == 30,
		"standing: half a metre behind the short line (a stance) still counts")
	check(ThrowMath.standing_line_ft(Vector3(0.75, 1.6, -3.462), stake) == 30,
		"standing: beside the short pedestal, reaching for it, still counts")
	check(ThrowMath.standing_line_ft(Vector3(0.0, 1.6, -0.414), stake) == 40,
		"standing: half a metre behind the standard line still counts")
	check(ThrowMath.standing_line_ft(Vector3(0.0, 0.2, -3.962), stake) == 30,
		"standing: head height is ignored (seated play reads the same)")
	check(ThrowMath.standing_line_ft(Vector3(0.0, 1.6, -6.096), stake) == 0,
		"standing: mid-court between the lines is NEITHER line")
	check(ThrowMath.standing_line_ft(Vector3(0.0, 1.6, -12.0), stake) == 0,
		"standing: up at the pit inspecting a landing is NEITHER line")
	check(ThrowMath.standing_line_ft(Vector3(0.0, 1.6, -4.9), stake) == 0,
		"standing: past the short line toward the pit, beyond the gate, is NEITHER")


func test_recorder_schema() -> void:
	var test_path: String = "user://test_throws.jsonl"
	var abs_path: String = ProjectSettings.globalize_path(test_path)
	if FileAccess.file_exists(test_path):
		DirAccess.remove_absolute(abs_path)
	var rec := ThrowRecorder.new(test_path)
	var samples: Array = arc_samples(Vector3(0.0, 2.0, -3.0), 0.2)
	var ok: bool = rec.log_record({
		"type": "throw", "ts": "test", "throw_index": 1, "hand": "R",
		"hold": "flip", "zone": "toe", "slide_offset_m": 0.0, "line_ft": 40,
		"origin_release_pos": [0.0, 0.0, 0.0],
		"origin_pitch_deg": 0.0, "origin_roll_deg": 0.0,
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
				"origin_release_pos", "line_ft", "origin_pitch_deg", "origin_roll_deg",
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
				check(s0.has("o"), "sample entries carry the origin position 'o' (pass 2)")
	DirAccess.remove_absolute(abs_path)


func test_grab_state() -> void:
	# Order A: hand in zone first, then squeeze. (5th arg = trigger.)
	var a := GrabState.new()
	check(a.update("R", "toe", 0.0, 0.0, 0.0) == "", "order A: no latch without grip")
	check(a.update("R", "toe", 0.9, 0.0, 0.0) == "latch", "order A: squeeze in zone latches")
	check(a.update("R", "toe", 0.95, 0.2, 0.0) == "", "order A: latch fires exactly once")
	check(a.latched and a.zone == "toe", "order A: latched on the toe zone")
	# Hysteresis: mid grip keeps the latch (and, pass 2, nothing more).
	check(a.update("R", "toe", 0.5, 0.0, 0.0) == "" and a.latched,
		"hysteresis: mid grip does not drop the latch")
	# NEGATIVE CONTROL: the pass-1 entry - loosening into the mid
	# grip band while still - must NOT enter slide mode anymore.
	var nc_events: String = ""
	for i: int in 4:
		nc_events += a.update("R", "toe", 0.5, 0.0, 0.0)
	check(nc_events == "" and not a.slide_mode and not a.sliding,
		"NEGATIVE CONTROL: pass-1 mid-band loosening no longer enters slide")
	# A trigger press while the grip is only mid-band is not a slide
	# either: slide entry demands the grip fully held.
	check(a.update("R", "toe", 0.5, 0.0, 0.9) == "" and not a.slide_mode,
		"trigger press at mid grip does not enter slide")
	check(a.update("R", "toe", 0.5, 0.0, 0.0) == "", "trigger released again, still plain hold")
	# Chris's model: grip fully held + FRESH trigger press = slide.
	check(a.update("R", "toe", 0.95, 0.0, 0.0) == "", "back to full grip, no event")
	check(a.update("R", "toe", 0.95, 0.0, 0.85) == "slide_start",
		"grip + fresh trigger press enters slide mode")
	check(a.slide_mode and a.sliding, "slide mode at rest means the shoe is frozen (sliding)")
	check(a.update("R", "toe", 0.95, 0.0, 0.9) == "", "slide_start fires exactly once")
	# Swing-speed safety: trigger still down but the hand is swinging -
	# the freeze must NOT apply, so no anchor shift under a throw.
	check(a.update("R", "toe", 0.95, 2.5, 0.9) == "" and not a.sliding and a.slide_mode,
		"at swing speed the shoe is NOT frozen even in slide mode")
	check(a.update("R", "toe", 0.95, 0.0, 0.9) == "" and a.sliding,
		"hand still again: the freeze applies")
	# Exit: let go of the trigger, grip still held - the hold locks.
	check(a.update("R", "toe", 0.95, 0.0, 0.1) == "slide_end",
		"trigger released while gripping ends the slide (lock)")
	check(not a.slide_mode and not a.sliding and a.latched, "after slide_end the plain hold remains")
	# Grip release is always the throw/drop path.
	check(a.update("R", "toe", 0.1, 0.0, 0.0) == "release", "open hand releases")
	check(not a.latched, "released state is clean")

	# Order B: squeeze held first, hand enters the zone after.
	var b := GrabState.new()
	check(b.update("R", "", 0.95, 0.0, 0.0) == "", "order B: squeeze with no zone does not latch")
	check(not b.latched, "order B: still unlatched outside the zone")
	check(b.update("R", "shank_right", 0.95, 0.0, 0.0) == "latch",
		"order B: held squeeze latches the frame the hand enters the zone")
	check(b.update("R", "shank_right", 0.95, 0.0, 0.0) == "", "order B: latch fires exactly once")

	# Trigger FIRST, then grip: that grab must not become a slide.
	# The pre-held trigger is consumed by the latch; only a fresh
	# press while already holding can start one.
	var d := GrabState.new()
	check(d.update("R", "", 0.0, 0.0, 0.95) == "", "trigger alone does nothing")
	check(d.update("R", "toe", 0.95, 0.0, 0.95) == "latch",
		"trigger-first then grip still latches the grab")
	check(d.update("R", "toe", 0.95, 0.0, 0.95) == "" and not d.slide_mode,
		"the pre-held trigger does NOT start a slide after the grab")
	check(d.update("R", "toe", 0.95, 0.0, 0.0) == "", "trigger let go while holding: no event")
	check(d.update("R", "toe", 0.95, 0.0, 0.9) == "slide_start",
		"a FRESH trigger press while holding starts the slide")
	check(d.update("R", "toe", 0.95, 0.0, 0.0) == "slide_end", "and releasing it locks again")

	# Mid grip alone never latches (hysteresis low side).
	var c := GrabState.new()
	check(c.update("L", "toe", 0.5, 0.0, 0.0) == "" and not c.latched,
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
	# Fix Pass 26: the FAR hold (the other shank in the same
	# hand - the reverse-turn grip) seats mirrored: its open
	# end points to the OPPOSITE side from the same hand's
	# home hold, not the same way with a different anchor.
	var far_rel_r: Transform3D = Shoe.hold_transform("shank_left", "R")
	var open_dir_far_r: Vector3 = far_rel_r.basis * Vector3(0.0, 0.0, 1.0)
	check(open_dir_far_r.x > 0.99,
		"far turn hold (R): shoe open end points to hand +X - flipped from the home hold's -X (the reverse setup)")
	var far_rel_l: Transform3D = Shoe.hold_transform("shank_right", "L")
	var open_dir_far_l: Vector3 = far_rel_l.basis * Vector3(0.0, 0.0, 1.0)
	check(open_dir_far_l.x < -0.99,
		"far turn hold (L): shoe open end points to hand -X - flipped from the home hold's +X")


func test_locomotion_math() -> void:
	var ident := Basis.IDENTITY
	# Full forward push walks down -Z at 2 m/s. On Chris's rig the
	# forward push reads y=+1 (Fix Pass 4 field correction - the
	# pass-2 paper convention, y=-1, walked him backward).
	var d1: Vector3 = Locomotion.walk_displacement(Vector2(0.0, 1.0), ident, 1.0)
	check(d1.distance_to(Vector3(0.0, 0.0, -2.0)) < 0.01,
		"walk: full forward push (y=+1 on the target rig) = 2 m/s toward head -Z (got %s)" % str(d1))
	var d2: Vector3 = Locomotion.walk_displacement(Vector2(1.0, 0.0), ident, 1.0)
	check(d2.distance_to(Vector3(2.0, 0.0, 0.0)) < 0.01,
		"walk: full right push strafes +X at 2 m/s (got %s)" % str(d2))
	var d3: Vector3 = Locomotion.walk_displacement(Vector2(0.0, -1.0), ident, 1.0)
	check(d3.distance_to(Vector3(0.0, 0.0, 2.0)) < 0.01,
		"walk: full back pull (y=-1) walks backward (got %s)" % str(d3))
	# Radial deadzone swallows small inputs entirely.
	check(Locomotion.walk_displacement(Vector2(0.0, 0.10), ident, 1.0) == Vector3.ZERO,
		"walk: input inside the 0.15 deadzone does not move")
	check(Locomotion.walk_displacement(Vector2(0.14, 0.0), ident, 1.0) == Vector3.ZERO,
		"walk: 0.14 deflection still inside the deadzone")
	# Half push is proportional (rescaled): clearly walking, not full pace.
	var dh: Vector3 = Locomotion.walk_displacement(Vector2(0.0, 0.5), ident, 1.0)
	check(dh.length() > 0.65 and dh.length() < 1.0 and dh.z < -0.65,
		"walk: half push is proportional (~0.82 m/s, got %.3f)" % dh.length())
	# Over-long diagonal clamps to unit: no faster than straight.
	var dd: Vector3 = Locomotion.walk_displacement(Vector2(1.0, 1.0), ident, 1.0)
	check(dd.length() <= 2.001 and dd.x > 0.0 and dd.z < 0.0, "walk: diagonal is not faster than straight (%.3f m/s) and runs forward-right" % dd.length())
	# Head-relative: with the head yawed +90 deg, forward push goes -X.
	var yawed := Basis(Vector3.UP, deg_to_rad(90.0))
	var d4: Vector3 = Locomotion.walk_displacement(Vector2(0.0, 1.0), yawed, 1.0)
	check(d4.distance_to(Vector3(-2.0, 0.0, 0.0)) < 0.01,
		"walk: displacement follows the HEAD, not the world (got %s)" % str(d4))
	# Play-area clamp: radial pull-in to 25 m of court centre, y kept.
	var clamped: Vector3 = Locomotion.clamp_origin(Vector3(40.0, 1.7, -6.096))
	check(absf(clamped.x - 25.0) < 0.01 and absf(clamped.y - 1.7) < 0.001,
		"clamp: origin 40 m out is pulled to the 25 m disc (got %s)" % str(clamped))
	var inside := Vector3(1.0, 0.0, -6.0)
	check(Locomotion.clamp_origin(inside) == inside, "clamp: a position inside the disc is untouched")


func test_smooth_turn() -> void:
	# Fix Pass 5 (Chris's field order): the snap steps are GONE - the
	# turn stick turns CONTINUOUSLY at a deflection-proportional rate.
	# Deadzone: centred and small inputs produce exactly nothing.
	check(Locomotion.turn_angle(0.0, 0.016) == 0.0, "turn: centred stick does nothing")
	check(Locomotion.turn_angle(0.14, 0.016) == 0.0, "turn: 0.14 deflection is inside the 0.15 deadzone")
	check(Locomotion.turn_angle(-0.10, 0.016) == 0.0, "turn: -0.10 deflection is inside the deadzone")
	# Full push for a full second = the max rate, signed both ways:
	# push right turns right (negative Godot yaw), push left positive.
	check(absf(Locomotion.turn_angle(1.0, 1.0) + 100.0) < 0.01,
		"turn: full push right = -100 deg/s (got %.2f)" % Locomotion.turn_angle(1.0, 1.0))
	check(absf(Locomotion.turn_angle(-1.0, 1.0) - 100.0) < 0.01,
		"turn: full push left = +100 deg/s (got %.2f)" % Locomotion.turn_angle(-1.0, 1.0))
	# Proportionality: the rescale maps 0.575 to exactly half rate,
	# and the rate grows monotonically with deflection.
	check(absf(Locomotion.turn_angle(0.575, 1.0) + 50.0) < 0.01,
		"turn: 0.575 deflection is exactly half rate (-50 deg/s, got %.2f)" % Locomotion.turn_angle(0.575, 1.0))
	var r_half: float = absf(Locomotion.turn_angle(0.5, 1.0))
	var r_mid: float = absf(Locomotion.turn_angle(0.75, 1.0))
	var r_full: float = absf(Locomotion.turn_angle(1.0, 1.0))
	check(r_half < r_mid and r_mid < r_full,
		"turn: rate grows with deflection (%.1f < %.1f < %.1f deg/s)" % [r_half, r_mid, r_full])
	# NO-STEP regression: hold a full push for 0.5 s at 60 fps and
	# apply each frame's angle about a camera pivot exactly as main
	# does. Every single-frame step must be small (~1.7 deg, nowhere
	# near the old 30 deg snap), the total lands at ~50 deg (half a
	# second at the 100 deg/s max), and the camera never translates.
	var pivot := Vector3(0.35, 1.6, 0.25)
	var tf := Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, 0.0))
	var cam_local := Transform3D(Basis.IDENTITY, pivot)
	var max_step: float = 0.0
	var total: float = 0.0
	for i: int in 30:
		var step: float = Locomotion.turn_angle(1.0, 1.0 / 60.0)
		max_step = maxf(max_step, absf(step))
		total += step
		tf = Locomotion.rotate_about(tf, pivot, deg_to_rad(step))
	check(max_step < 3.0,
		"turn: NO STEP - largest single-frame change is %.2f deg (the old snap jumped 30)" % max_step)
	check(absf(absf(total) - 50.0) < 0.5,
		"turn: 0.5 s at full push totals ~50 deg (got %.2f)" % total)
	var cam_after: Vector3 = tf * cam_local.origin
	check(cam_after.distance_to(pivot) < 0.0001,
		"turn: smooth turning about the camera never translates it (moved %.5f m)" % cam_after.distance_to(pivot))


func test_rotate_about() -> void:
	# Camera sits offset from the origin (the normal recentered case).
	var pivot := Vector3(0.35, 1.6, 0.25)
	var origin_tf := Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, 0.0))
	var cam_local := Transform3D(Basis.IDENTITY, pivot)
	var ang: float = deg_to_rad(-30.0)
	var out: Transform3D = Locomotion.rotate_about(origin_tf, pivot, ang)
	var cam_after: Vector3 = out * cam_local.origin
	check(cam_after.distance_to(pivot) < 0.0001,
		"rotate-about: the camera's world position is invariant (moved %.5f m)" % cam_after.distance_to(pivot))
	var head_after: Vector3 = out.basis * Vector3(0.0, 0.0, -1.0)
	var head_expect: Vector3 = Basis(Vector3.UP, ang) * Vector3(0.0, 0.0, -1.0)
	check(head_after.distance_to(head_expect) < 0.0001,
		"rotate-about: heading rotates by exactly the applied angle")
	# A point fixed in origin space (the shoe stand) rides a circle
	# around the camera's XZ: its distance to the pivot XZ is kept.
	var p_local := Vector3(0.52, 0.785, 0.32)
	var before: Vector3 = origin_tf * p_local
	var after: Vector3 = out * p_local
	var d_before: float = Vector2(before.x - pivot.x, before.z - pivot.z).length()
	var d_after: float = Vector2(after.x - pivot.x, after.z - pivot.z).length()
	check(absf(d_after - d_before) < 0.0001,
		"rotate-about: origin-space points keep their distance from the camera XZ (no drift)")


func test_level_origin() -> void:
	# Fix Pass 15: the origin may only ever be YAWED - pitch and
	# roll belong to the head, never to the rig. (Field fault:
	# seat while looking down at the pit and the world slanted
	# ~10 deg for the rest of the session.)
	check(absf(Locomotion.yaw_of(Basis.IDENTITY)) < 0.0001,
		"level: identity basis has yaw 0")
	check(absf(Locomotion.yaw_of(Basis(Vector3.UP, 0.7)) - 0.7) < 0.0001,
		"level: yaw_of reads back a pure yaw")
	# The head as Chris holds it at the B tap: pitched down 12,
	# yawed, a touch of roll. Its HEADING is still recoverable.
	var held := Basis.from_euler(Vector3(deg_to_rad(-12.0), 0.4, deg_to_rad(2.5)))
	check(absf(Locomotion.yaw_of(held) - 0.4) < 0.01,
		"level: a pitched/rolled head still yields its heading (got %.3f rad)" % Locomotion.yaw_of(held))
	check(Locomotion.tilt_deg(Basis.IDENTITY) < 0.001, "level: identity is level")
	check(Locomotion.tilt_deg(Basis(Vector3.UP, 2.2)) < 0.001, "level: a pure yaw is level")
	check(Locomotion.tilt_deg(Basis(Vector3.UP, 0.7)) < 0.0001,
		"level: tilt_deg reads yaw 0.7 as exactly level too (Quaternion.angle_to's float floor read 0.0396 deg here)")
	check(Locomotion.tilt_deg(held) > 11.5 and Locomotion.tilt_deg(held) < 13.0,
		"level: tilt_deg sees the held head's ~12.3 deg tilt (got %.2f)" % Locomotion.tilt_deg(held))
	# level_transform: strips the tilt, keeps position + heading.
	var tf := Transform3D(held, Vector3(1.0, 0.0, -3.0))
	var lv: Transform3D = Locomotion.level_transform(tf)
	check(Locomotion.tilt_deg(lv.basis) < 0.001,
		"level: level_transform strips pitch/roll")
	check(lv.origin == tf.origin and absf(Locomotion.yaw_of(lv.basis) - 0.4) < 0.01,
		"level: level_transform keeps the position and the heading")
	# NEGATIVE CONTROL - the old seat formula, numerically: fed
	# this head pose it writes the head's tilt into the origin.
	# (The same reproduction, driven through production code,
	# is in the smoke's FP15 section.)
	var cam_local := Transform3D(held, Vector3(0.05, 1.62, 0.02))
	var want_pos := Vector3(0.05, 1.62, -0.55)
	var legacy: Transform3D = Transform3D(Basis(Vector3.UP, PI), want_pos) * cam_local.inverse()
	check(Locomotion.tilt_deg(legacy.basis) > 11.0,
		"NEGATIVE CONTROL: the pre-FP15 seat formula pitches the origin by the head's tilt (got %.2f deg)"
		% Locomotion.tilt_deg(legacy.basis))
	# The seat: same inputs - level origin, the camera lands on
	# the spot facing the wanted yaw, at both ends.
	for want_yaw: float in [0.0, PI]:
		var seat: Transform3D = Locomotion.seat_transform(cam_local, want_pos, want_yaw)
		check(Locomotion.tilt_deg(seat.basis) < 0.001,
			"level: the seat's origin is level (want_yaw %.2f)" % want_yaw)
		var cam_world: Transform3D = seat * cam_local
		check(cam_world.origin.distance_to(want_pos) < 0.0001,
			"level: the seat lands the camera on the spot (want_yaw %.2f, off %.5f m)"
			% [want_yaw, cam_world.origin.distance_to(want_pos)])
		check(absf(wrapf(Locomotion.yaw_of(cam_world.basis) - want_yaw, -PI, PI)) < 0.01,
			"level: the seated camera faces the wanted yaw (want %.2f, got %.2f)"
			% [want_yaw, Locomotion.yaw_of(cam_world.basis)])
	# The turn door sheds tilt too: a (hypothetically) pitched
	# frame turned about the camera comes out level, its origin
	# riding the same pivot circle the composed form produced.
	var pivot := Vector3(0.35, 1.6, 0.25)
	var turned: Transform3D = Locomotion.rotate_about(tf, pivot, deg_to_rad(-30.0))
	check(Locomotion.tilt_deg(turned.basis) < 0.001,
		"level: rotate_about returns a level basis even from a pitched input")
	var expect_origin: Vector3 = pivot + Basis(Vector3.UP, deg_to_rad(-30.0)) * (tf.origin - pivot)
	check(turned.origin.distance_to(expect_origin) < 0.0001,
		"level: rotate_about keeps the pivot-circle origin path from a pitched input")
	# And from a LEVEL input - the only input production can
	# hand it - it is the old composed rotation exactly: the
	# judged turn rate, pivot and feel cannot move.
	var level_in := Transform3D(Basis(Vector3.UP, 0.9), Vector3(1.0, 0.0, -3.0))
	var t2: Transform3D = Locomotion.rotate_about(level_in, pivot, deg_to_rad(-30.0))
	var legacy2: Basis = Basis(Vector3.UP, deg_to_rad(-30.0)) * level_in.basis
	check(t2.basis.get_rotation_quaternion().angle_to(legacy2.get_rotation_quaternion()) < 0.0001,
		"level: from a level input rotate_about is the pre-FP15 rotation, bit for bit")
	var local_at_pivot: Vector3 = level_in.affine_inverse() * pivot
	check((t2 * local_at_pivot).distance_to(pivot) < 0.0001,
		"level: rotate_about still never translates the camera")


## Samples where the ORIGIN slides forward at 1.5 m/s (-Z) while the
## hand rides it: hand world pos = origin pos + local(t). With
## local(t) constant the arm is perfectly still in origin space.
func origin_slide_samples(local_v0: Vector3, local_accel: Vector3, dur: float, hz: float = 90.0) -> Array:
	var out: Array = []
	var o0 := Vector3(0.0, 0.0, 2.0)
	var ov := Vector3(0.0, 0.0, -1.5)
	var h0 := Vector3(0.25, 1.15, 0.30)
	var steps: int = int(dur * hz)
	for i: int in steps + 1:
		var t: float = float(i) / hz
		var opos: Vector3 = o0 + ov * t
		var local: Vector3 = h0 + local_v0 * t + 0.5 * local_accel * t * t
		out.append(ThrowMath.make_sample(t, opos + local, Quaternion.IDENTITY, opos))
	return out


func test_origin_relative_velocity() -> void:
	var dur: float = 0.30
	# NEGATIVE CONTROL pair: arm still, origin sliding at 1.5 m/s.
	var still: Array = origin_slide_samples(Vector3.ZERO, Vector3.ZERO, dur)
	var bogus: Vector3 = ThrowMath.estimate_velocity_windowed(still)
	check(bogus.length() > 1.2,
		"NEGATIVE CONTROL: WITHOUT the correction a still arm on a sliding origin reads %.2f m/s" % bogus.length())
	var fixed: Vector3 = ThrowMath.estimate_velocity_origin_relative(still, Basis.IDENTITY)
	check(fixed.length() < 0.05,
		"origin-relative: the same data WITH the correction reads ~zero (%.3f m/s)" % fixed.length())
	# Arm swinging in origin space while the origin slides: the
	# correction must recover the ARM's velocity, not zero it out.
	var v0 := Vector3(0.1, 0.6, -0.5)
	var accel := Vector3(1.0, 5.0, -11.0)
	var swing: Array = origin_slide_samples(v0, accel, dur)
	var v_true: Vector3 = v0 + accel * dur
	var v_corr: Vector3 = ThrowMath.estimate_velocity_origin_relative(swing, Basis.IDENTITY)
	check(v_corr.distance_to(v_true) < 0.15,
		"origin-relative: recovers the arm's true velocity under origin slide (err %.3f)" % v_corr.distance_to(v_true))
	var v_raw: Vector3 = ThrowMath.estimate_velocity_windowed(swing)
	check(v_raw.distance_to(v_corr) > 1.0,
		"origin-relative: uncorrected estimate differs by the origin's ~1.5 m/s (diff %.3f)" % v_raw.distance_to(v_corr))
	# Standing still (origin walked somewhere earlier, now constant):
	# the corrected estimate equals the pass-1 estimate.
	var stand: Array = arc_samples(v0, dur)
	for raw: Variant in stand:
		var s: Dictionary = raw
		s["opos"] = Vector3(5.0, 0.0, -3.0)
	var v_plain: Vector3 = ThrowMath.estimate_velocity_windowed(stand)
	var v_rel: Vector3 = ThrowMath.estimate_velocity_origin_relative(stand, Basis.IDENTITY)
	check(v_rel.distance_to(v_plain) < 0.001,
		"origin-relative: standing still it IS the pass-1 estimate (diff %.5f)" % v_rel.distance_to(v_plain))
	var v_rel_yaw: Vector3 = ThrowMath.estimate_velocity_origin_relative(
		stand, Basis(Vector3.UP, deg_to_rad(40.0)))
	check(v_rel_yaw.distance_to(v_plain) < 0.01,
		"origin-relative: a rotated release frame still returns the world velocity (diff %.4f)" % v_rel_yaw.distance_to(v_plain))


func test_yaw_deg() -> void:
	# The recorder's stance fields (pass 2, third addition): head and
	# origin yaw on the azimuth convention - 0 facing the stake down
	# -Z, NEGATIVE to the left of the line.
	var ahead: Vector3 = Basis.IDENTITY * Vector3(0.0, 0.0, -1.0)
	check(absf(ThrowMath.yaw_deg(ahead)) < 0.01, "yaw: facing -Z down the court reads 0")
	var left10: Vector3 = Basis(Vector3.UP, deg_to_rad(10.0)) * Vector3(0.0, 0.0, -1.0)
	check(absf(ThrowMath.yaw_deg(left10) + 10.0) < 0.01,
		"yaw: facing 10 deg LEFT reads -10 (got %.2f)" % ThrowMath.yaw_deg(left10))
	var right25: Vector3 = Basis(Vector3.UP, deg_to_rad(-25.0)) * Vector3(0.0, 0.0, -1.0)
	check(absf(ThrowMath.yaw_deg(right25) - 25.0) < 0.01,
		"yaw: facing 25 deg RIGHT reads +25 (got %.2f)" % ThrowMath.yaw_deg(right25))
	# Only the XZ projection is read (a pitched gaze keeps its heading
	# as long as the horizon projection is the same direction).
	var pitched: Vector3 = Vector3(left10.x, 0.55, left10.z)
	check(absf(ThrowMath.yaw_deg(pitched) + 10.0) < 0.01,
		"yaw: pitch (y component) is ignored, projection only")
	check(ThrowMath.yaw_deg(Vector3(0.0, 1.0, 0.0)) == 0.0,
		"yaw: straight up/down has no heading and reads 0, no NaN")


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
		["XRController3D", "get_vector2"],
		["XRController3D", "is_button_pressed"],
	]
	for p: Array in pairs:
		check(ClassDB.class_has_method(String(p[0]), String(p[1])),
			"API guard: %s.%s exists" % [String(p[0]), String(p[1])])


func test_grip_positions() -> void:
	# Fix Pass 21: the grip cycle's named positions - the table
	# itself (cycle order, declared counts, families) and the
	# derivation that names a hold from its zone + slide offset.
	# Fix Pass 26: the circuit is seven stops - the far shank's
	# three (the reverse family) follow the home shank's three.
	check(ThrowMath.grip_position_count() == 7, "grip cycle: seven named positions")
	var want_names: Array = ["TOE GRIP", "SHANK · TOE", "SHANK · MID", "SHANK · HEEL",
		"FAR SHANK · TOE", "FAR SHANK · MID", "FAR SHANK · HEEL"]
	var want_nom: Array = [1.0, 1.125, 1.25, 1.375, 1.125, 1.25, 1.375]
	var want_hold: Array = ["flip", "turn", "turn", "turn", "turn", "turn", "turn"]
	var want_side: Array = ["none", "home", "home", "home", "far", "far", "far"]
	for i: int in 7:
		var p: Dictionary = ThrowMath.grip_position(i)
		check(String(p["name"]) == String(want_names[i]),
			"grip cycle: position %d is %s (got %s)" % [i, want_names[i], p["name"]])
		check(is_equal_approx(float(p["nominal"]), float(want_nom[i])),
			"grip cycle: %s declares %.3f rev" % [want_names[i], want_nom[i]])
		check(String(p["hold"]) == String(want_hold[i]),
			"grip cycle: %s is the %s family" % [want_names[i], want_hold[i]])
		check(String(p["side"]) == String(want_side[i]),
			"grip cycle: %s is on the %s side" % [want_names[i], want_side[i]])
	# Derivation at the stops and across the neighbourhood
	# boundaries (stops at frac -1/0/+1, split at +-0.5).
	# The R hand's home shank is shank_right; the same zones in
	# the L hand mirror (its home shank is shank_left), and the
	# other zone in either hand names the FAR family.
	var smax: float = 0.045 # the shank zones' slide_max (Shoe.zones)
	check(ThrowMath.grip_index_for("toe", "R", 0.0, 0.022) == 0, "grip derive: the toe zone is TOE GRIP")
	check(ThrowMath.grip_index_for("shank_right", "R", -smax, smax) == 1, "grip derive: shank toe-end stop")
	check(ThrowMath.grip_index_for("shank_left", "L", 0.0, smax) == 2, "grip derive: shank middle stop (L home)")
	check(ThrowMath.grip_index_for("shank_right", "R", smax, smax) == 3, "grip derive: shank heel-end stop")
	check(ThrowMath.grip_index_for("shank_right", "R", -0.49 * smax, smax) == 2,
		"grip derive: just inside the toe/mid boundary names MID")
	check(ThrowMath.grip_index_for("shank_right", "R", -0.51 * smax, smax) == 1,
		"grip derive: just past the toe/mid boundary names TOE")
	check(ThrowMath.grip_index_for("shank_left", "L", 0.51 * smax, smax) == 3,
		"grip derive: just past the mid/heel boundary names HEEL")
	check(ThrowMath.grip_index_for("shank_left", "R", -smax, smax) == 4,
		"grip derive: the far shank's toe-end stop (R hand across the shoe)")
	check(ThrowMath.grip_index_for("shank_left", "R", 0.0, smax) == 5,
		"grip derive: the far shank's middle stop")
	check(ThrowMath.grip_index_for("shank_right", "L", 0.0, smax) == 5,
		"grip derive: the far shank's middle stop, mirrored (L hand)")
	check(ThrowMath.grip_index_for("shank_left", "R", smax, smax) == 6,
		"grip derive: the far shank's heel-end stop")
	check(ThrowMath.grip_index_for("shank_left", "R", 0.51 * smax, smax) == 6,
		"grip derive: just past the far mid/heel boundary names FAR HEEL")
	# The stops' slide offsets are the slide range's ends and middle.
	check(is_equal_approx(ThrowMath.grip_slide_offset(1, smax), -smax), "grip stops: TOE stop at -slide_max")
	check(is_equal_approx(ThrowMath.grip_slide_offset(2, smax), 0.0), "grip stops: MID stop at 0")
	check(is_equal_approx(ThrowMath.grip_slide_offset(3, smax), smax), "grip stops: HEEL stop at +slide_max")
	check(is_equal_approx(ThrowMath.grip_slide_offset(0, 0.022), 0.0), "grip stops: TOE GRIP carries no slide")
	check(is_equal_approx(ThrowMath.grip_slide_offset(4, smax), -smax), "grip stops: FAR TOE stop at -slide_max")
	check(is_equal_approx(ThrowMath.grip_slide_offset(5, smax), 0.0), "grip stops: FAR MID stop at 0")
	check(is_equal_approx(ThrowMath.grip_slide_offset(6, smax), smax), "grip stops: FAR HEEL stop at +slide_max")


func test_scoring() -> void:
	# Backyard Game v1: NHPA cancellation scoring, hand-computed
	# cases. A shoe entry is {owner, dist_in, ringer}; a ringer is
	# worth 3 and ringers cancel in pairs; then only the side
	# holding the closest point shoe(s) scores, 1 per shoe inside
	# 6 in and closer than the opponent's closest.
	var r := {"owner": "P", "dist_in": 0.0, "ringer": true}
	var ra := {"owner": "AI", "dist_in": 0.0, "ringer": true}
	var res: Dictionary = Scoring.score_inning([r, ra,
		{"owner": "P", "dist_in": 4.0, "ringer": false},
		{"owner": "AI", "dist_in": 5.0, "ringer": false}])
	check(int(res["points_p"]) == 1 and int(res["points_ai"]) == 0,
		"scoring: ringer cancels ringer, closer point shoe takes the inning 1-0")
	res = Scoring.score_inning([r, {"owner": "P", "dist_in": 0.0, "ringer": true}, ra])
	check(int(res["points_p"]) == 3 and int(res["points_ai"]) == 0,
		"scoring: 2 ringers vs 1 leaves one standing = 3")
	res = Scoring.score_inning([
		{"owner": "P", "dist_in": 3.0, "ringer": false},
		{"owner": "AI", "dist_in": 5.0, "ringer": false}])
	check(int(res["points_p"]) == 1, "scoring: a lone closer point shoe = 1")
	res = Scoring.score_inning([
		{"owner": "P", "dist_in": 2.0, "ringer": false},
		{"owner": "P", "dist_in": 4.0, "ringer": false},
		{"owner": "AI", "dist_in": 5.0, "ringer": false}])
	check(int(res["points_p"]) == 2,
		"scoring: two point shoes vs one farther = 2")
	res = Scoring.score_inning([
		{"owner": "P", "dist_in": 7.0, "ringer": false},
		{"owner": "AI", "dist_in": 9.0, "ringer": false}])
	check(int(res["points_p"]) == 0 and int(res["points_ai"]) == 0
		and String(res["scorer"]) == "",
		"scoring: shoes outside 6 in score nothing")
	res = Scoring.score_inning([
		{"owner": "P", "dist_in": 3.0, "ringer": false},
		{"owner": "AI", "dist_in": 3.0, "ringer": false}])
	check(int(res["points_p"]) == 0 and int(res["points_ai"]) == 0,
		"scoring: tied closest shoes = scoreless inning")
	res = Scoring.score_inning([r,
		{"owner": "AI", "dist_in": 2.0, "ringer": false}])
	check(int(res["points_p"]) == 3 and int(res["points_ai"]) == 0,
		"scoring: an uncancelled ringer blocks the opponent's point shoe")
	res = Scoring.score_inning([r,
		{"owner": "P", "dist_in": 4.0, "ringer": false},
		{"owner": "AI", "dist_in": 5.0, "ringer": false}])
	check(int(res["points_p"]) == 4,
		"scoring: ringer + own point shoe inside the opponent's closest = 4")
	res = Scoring.score_inning([ra])
	check(int(res["points_ai"]) == 3 and String(res["scorer"]) == "AI",
		"scoring: a lone AI ringer = 3 for the AI")
	# Fix Pass 20: the insert cam's breakdown text - per-shoe
	# lines and the cancellation arithmetic in plain words,
	# driven off the same settled results the scorer reads.
	var shoes20: Array = [
		{"owner": "P", "dist_in": 0.0, "ringer": true},
		{"owner": "P", "dist_in": 30.0, "ringer": false},
		{"owner": "AI", "dist_in": 4.5, "ringer": false},
		{"owner": "AI", "dist_in": 40.0, "ringer": false}]
	var sl: Array = Scoring.shoe_lines(shoes20)
	check(sl.size() == 4 and String(sl[0]) == "YOU 1: RINGER"
		and String(sl[1]) == "YOU 2: NO SCORE (30.0 IN)"
		and String(sl[2]) == "OPP 1: 4.5 IN"
		and String(sl[3]) == "OPP 2: NO SCORE (40.0 IN)",
		"FP20 breakdown: per-shoe lines name owner, number and result (%s)" % str(sl))
	var res20: Dictionary = Scoring.score_inning(shoes20)
	var ex: Array = Scoring.explain_lines(shoes20, res20)
	check(ex.has("YOUR RINGER STANDS: +3"),
		"FP20 breakdown: a standing ringer is explained (%s)" % str(ex))
	check(ex.has("CLOSEST ONLY SCORES"),
		"FP20 breakdown: the ringer shut out the opponent's point shoe, and the text says why (%s)" % str(ex))
	var both_ring: Array = [
		{"owner": "P", "dist_in": 0.0, "ringer": true},
		{"owner": "AI", "dist_in": 0.0, "ringer": true},
		{"owner": "P", "dist_in": 3.0, "ringer": false},
		{"owner": "AI", "dist_in": 5.0, "ringer": false}]
	var ex2: Array = Scoring.explain_lines(both_ring,
		Scoring.score_inning(both_ring))
	check(ex2.has("RINGERS CANCEL IN PAIRS")
		and ex2.has("YOUR CLOSEST SHOE SCORES: +1"),
		"FP20 breakdown: cancelled ringers, then the closest shoe decides (%s)" % str(ex2))
	var dud_round: Array = [
		{"owner": "P", "dist_in": 20.0, "ringer": false},
		{"owner": "AI", "dist_in": 25.0, "ringer": false}]
	var ex3: Array = Scoring.explain_lines(dud_round,
		Scoring.score_inning(dud_round))
	check(ex3.size() == 1 and String(ex3[0]) == "NO SCORE THIS ROUND",
		"FP20 breakdown: a scoreless round says so plainly (%s)" % str(ex3))


func test_ai_release() -> void:
	# The AI's constructed release: a ballistic flip that crosses
	# the target stake's plane at scoring height, spinning about
	# the shoe's lateral axis toward the target. Fix Pass 19:
	# one-way only - the far-end mirror case is RETIRED with the
	# two-pit court (there is no far-end throw to mirror), and
	# the release is derived from the AI's real box at the true
	# 37 ft line.
	var far_stake := Vector3(0.0, 0.0, -12.192)
	var rel: Dictionary = AIPitcher.base_release(
		AIPitcher.release_base_pos(-0.914), far_stake)
	var p0: Vector3 = rel["pos"]
	var v0: Vector3 = rel["vel"]
	check(v0.z < 0.0, "AI release: the throw travels toward -z (the one-way court)")
	var t_cross: float = (far_stake.z - p0.z) / v0.z
	var y_cross: float = p0.y + v0.y * t_cross - 4.9 * t_cross * t_cross
	check(absf(y_cross - AIPitcher.ARRIVE_H) < 0.02,
		"AI release: crosses the stake plane at ARRIVE_H (got %.2f)" % y_cross)
	check(absf(p0.x + v0.x * t_cross) < 0.01,
		"AI release: crosses the stake plane on the centre line (from its off-centre box)")
	check((rel["ang"] as Vector3).x > 0.0
		and absf((rel["ang"] as Vector3).length() - TAU / AIPitcher.FLIGHT_T) < 0.01,
		"AI release: one flip revolution per flight at the FLIGHT_T cadence, about the travel frame's lateral axis")


## Stage A layout guards (Stage 2, the ground): the planting
## beds and background tree line are visual-only dressing whose
## layout lives as data tables in main.gd - guard the DATA
## numerically here (the smoke suite guards the built tree):
## no bed may touch the lane corridor, the pitcher's box zone,
## a station envelope, the peg envelope, or the pit itself,
## and every background trunk must stand outside the fence and
## on the ground plane.
func rects_overlap(a: Array, b: Array) -> bool:
	return float(a[0]) < float(b[2]) and float(a[2]) > float(b[0]) \
		and float(a[1]) < float(b[3]) and float(a[3]) > float(b[1])


func test_stage_a_layout() -> void:
	var main_script: GDScript = load("res://scripts/main.gd")
	var beds: Array = main_script.stage_a_bed_rects()
	check(beds.size() == 3, "Stage A: three planting beds ring the yard (%d)" % beds.size())
	# Keep-out rects [x0, z0, x1, z1], each already carrying
	# its safety margin: the lane corridor (the apron the FP10
	# dressing rules keep bare), the pitcher's box zone around
	# the stake, both stations' timber envelopes, the 30 ft
	# peg post's envelope, and the pit + ties themselves.
	var keep_outs: Array = [
		[-2.30, -11.30, 2.30, 1.60],
		[-1.22, -13.41, 1.22, -10.98],
		[-2.62, -1.62, 2.62, -0.28],
		[1.78, -4.52, 2.58, -3.42],
		[-0.70, -13.40, 0.70, -10.99],
	]
	for bi: int in beds.size():
		var bed: Array = beds[bi]
		for ki: int in keep_outs.size():
			var ko: Array = keep_outs[ki]
			check(not rects_overlap(bed, ko),
				"Stage A: bed %d clears keep-out %d" % [bi, ki])
	# Side beds: inner edge outside the berm toe (|x| 2.60)
	# and the station timbers' reach (2.54).
	for bi: int in 2:
		var bed: Array = beds[bi]
		check(float(bed[2]) <= -2.70 or float(bed[0]) >= 2.70,
			"Stage A: side bed %d inner edge clears the berms and stations" % bi)
	# Far bed: behind the pit's back tie (outer face -13.35),
	# short of the board (z -16.2).
	var far_bed: Array = beds[2]
	check(float(far_bed[3]) <= -13.80 and float(far_bed[1]) >= -15.90,
		"Stage A: the far bed sits behind the pit, clear of pit and board")
	# Tree line: outside the fence rectangle, on the ground.
	var spots: Array = main_script.stage_a_tree_spots()
	check(spots.size() == 17, "Stage A: the tree line stands (%d trees)" % spots.size())
	for spot: Array in spots:
		var tp: Vector3 = spot[0]
		check(absf(tp.x) > 13.2 or tp.z < -20.2 or tp.z > 7.2,
			"Stage A: tree at %s stands beyond the fence" % str(tp))
		check(absf(tp.x) <= 19.5 and tp.z >= -29.5 and tp.z <= 17.5,
			"Stage A: tree at %s stands on the ground plane" % str(tp))


func _run() -> void:
	test_release_math()
	test_angular_math()
	test_ringer_geometry()
	test_line_classification()
	test_standing_line()
	test_recorder_schema()
	test_grab_state()
	test_locomotion_math()
	test_smooth_turn()
	test_rotate_about()
	test_level_origin()
	test_origin_relative_velocity()
	test_yaw_deg()
	test_grip_positions()
	test_api_guard()
	test_scoring()
	test_ai_release()
	test_stage_a_layout()
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
