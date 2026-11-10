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
	# Fix Pass 30: THE LINE BARRIER (Locomotion.line_barrier_origin).
	# The barrier judges the HEAD's ground position against the
	# line (z -0.914, the 37 ft line) with a 0.05 m epsilon; the
	# origin retreats by exactly the head's excess. Chris's law:
	# "looking straight down from your throwing spot, the line
	# stays under your toes."
	var bl_line: float = -0.914
	var bl_eps: float = 0.05
	var bl_limit: float = bl_line - bl_eps
	# A head behind the line, or exactly ON the limit, never
	# moves the origin.
	var bl_calm := Vector3(0.3, 0.0, 0.2)
	check(Locomotion.line_barrier_origin(bl_calm,
			Vector3(0.3, 1.62, bl_line + 0.30), bl_line, bl_eps) == bl_calm,
		"FP30 barrier: a head behind the line leaves the origin untouched")
	check(Locomotion.line_barrier_origin(bl_calm,
			Vector3(0.3, 1.45, bl_limit), bl_line, bl_eps) == bl_calm,
		"FP30 barrier: a head exactly on the limit leaves the origin untouched")
	# NEGATIVE CONTROL - the FP20 conviction geometry, the one
	# from Chris's screenshot: the origin sits AT FP20's plane
	# (line - 0.40, fully obedient under the old rule - assert
	# that obedience first) while the head, stooped to look
	# straight down, leans 0.30 m ahead of it. The old guard
	# passed this frame; the barrier must pull the origin back
	# until the head's ground point is ON the limit, 0.70 m of
	# trespass down to the epsilon.
	var bl_old_plane: float = bl_line - 0.40
	var bl_origin := Vector3(0.0, 0.0, bl_old_plane)
	var bl_head := Vector3(0.0, 1.45, bl_old_plane - 0.30)
	check(absf(bl_origin.z - bl_old_plane) < 0.001
			and bl_head.z < bl_line - 0.60,
		"FP30 barrier (control setup): FP20's plane holds the origin (z %.3f) while the leaned head is ~0.70 m past the line (z %.3f)"
		% [bl_origin.z, bl_head.z])
	var bl_fixed: Vector3 = Locomotion.line_barrier_origin(
		bl_origin, bl_head, bl_line, bl_eps)
	check(absf((bl_head.z + (bl_fixed.z - bl_origin.z)) - bl_limit) < 0.001,
		"FP30 barrier: the leaned head ends ON the limit (head z %.3f, limit %.3f)"
		% [bl_head.z + (bl_fixed.z - bl_origin.z), bl_limit])
	check(absf(bl_fixed.x - bl_origin.x) < 0.001 and bl_fixed.y == bl_origin.y,
		"FP30 barrier: only the origin's z moves - sliding along the line stays free")
	# The room-scale leak: origin parked legally BEHIND the
	# line, a physical step carries the head past it. FP20
	# never saw the step (the origin never moved); the barrier
	# retreats the origin all the same.
	var bl_step_origin := Vector3(0.0, 0.0, bl_line + 0.50)
	var bl_step_head := Vector3(0.0, 1.62, bl_line - 0.50)
	var bl_step_fixed: Vector3 = Locomotion.line_barrier_origin(
		bl_step_origin, bl_step_head, bl_line, bl_eps)
	check(absf((bl_step_head.z + (bl_step_fixed.z - bl_step_origin.z)) - bl_limit) < 0.001,
		"FP30 barrier: a physical step past the line is answered too (origin retreats to z %.3f)"
		% bl_step_fixed.z)


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
	check(beds.size() == 4, "Stage A: four planting beds ring the yard (%d)" % beds.size())
	# Keep-out rects [x0, z0, x1, z1], each already carrying
	# its safety margin: the lane corridor (the apron the FP10
	# dressing rules keep bare), the pitcher's box zone around
	# the stake, both stations' timber envelopes, the 30 ft
	# peg post's envelope, and the pit + ties themselves.
	# Stage B re-derivation: the stations' envelope moved
	# back with the stations (behind the line, on the patio -
	# z -0.36..0.93 now, was -1.62..-0.28 at the line), and
	# the patio slab itself joins the list: no bed may touch
	# the slab.
	var keep_outs: Array = [
		[-2.30, -11.30, 2.30, 1.60],
		[-1.22, -13.41, 1.22, -10.98],
		[-2.62, -0.36, 2.62, 0.93],
		[1.78, -4.52, 2.58, -3.42],
		[-0.70, -13.40, 0.70, -10.99],
		[-3.55, -0.60, 3.55, 4.95],
	]
	for bi: int in beds.size():
		var bed: Array = beds[bi]
		for ki: int in keep_outs.size():
			var ko: Array = keep_outs[ki]
			check(not rects_overlap(bed, ko),
				"Stage A: bed %d clears keep-out %d" % [bi, ki])
	# Side beds: inner edge outside the berm toe (|x| 2.60)
	# and the station timbers' reach (2.54).
	for bi: int in beds.size() - 1:
		var bed: Array = beds[bi]
		check(float(bed[2]) <= -2.70 or float(bed[0]) >= 2.70,
			"Stage A: side bed %d inner edge clears the berms and stations" % bi)
	# Stage B: the side beds end at the patio's front
	# corners (rear edge z -0.60, at the slab's front edge),
	# and the right bed carries the gate gap (z -6.55..-5.45,
	# centred on the gate's z -6.0).
	check(absf(float(beds[0][3]) + 0.60) < 0.01
		and absf(float(beds[2][3]) + 0.60) < 0.01,
		"Stage B: the side beds end at the patio's front corners")
	check(absf(float(beds[1][3]) + 6.55) < 0.01
		and absf(float(beds[2][1]) + 5.45) < 0.01,
		"Stage B: the right bed carries the gate gap at z -6.55..-5.45")
	# Far bed: behind the pit's back tie (outer face -13.35),
	# short of the board (z -16.2).
	var far_bed: Array = beds[beds.size() - 1]
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


## Stage B layout guards (Stage 2, the yard pass): the
## patio, house rear, gate, fountain and Phineas are
## visual-only dressing whose layout lives as data tables
## in main.gd - guard the DATA numerically here (the smoke
## suite guards the built tree): the patio stays behind the
## foul line and holds both stations; the house wall stands
## on the patio's rear edge; every patio object stands on
## the slab, off the walk corridor and off the stations;
## the gate sits in the right fence mid-yard with its
## approach clear of tree trunks; the fountain sits in
## the left bed's rear corner nook (Fix Pass 29); Phineas
## stands on the ground in the corner pocket beside the
## far bed's west end, out of the planting entirely.
func circle_rect_clear(c: Vector3, r: float, rect: Array) -> bool:
	var nx: float = clampf(c.x, float(rect[0]), float(rect[2]))
	var nz: float = clampf(c.z, float(rect[1]), float(rect[3]))
	return Vector2(c.x - nx, c.z - nz).length() > r


func test_stage_b_layout() -> void:
	var main_script: GDScript = load("res://scripts/main.gd")
	var patio: Array = main_script.stage_b_patio_rect()
	check(float(patio[1]) > float(main_script.FOUL_40_Z)
		and float(patio[1]) < 0.0,
		"Stage B: the patio starts behind the 40 ft foul line (front edge %.2f)" % float(patio[1]))
	check(float(patio[3]) < 7.0 and float(patio[0]) >= -13.0
		and float(patio[2]) <= 13.0,
		"Stage B: the patio stands inside the fence")
	# Both 40 ft stations stand ON the slab: a conservative
	# envelope box around each rack's two slots (slot span
	# plus the timber body's reach) inside the patio rect.
	for is_ai: bool in [false, true]:
		var tf: Transform3D = main_script.make_rack_tf(40, is_ai)
		var o: Vector3 = tf.origin
		var env: Array = [o.x - 0.55, o.z - 0.62, o.x + 0.55, o.z + 0.40]
		check(float(env[0]) >= float(patio[0]) and float(env[2]) <= float(patio[2])
			and float(env[1]) >= float(patio[1]) and float(env[3]) <= float(patio[3]),
			"Stage B: the %s station stands on the patio (slots at %s)"
			% ["AI" if is_ai else "player", str(o)])
		check(absf((o.z - float(main_script.FOUL_40_Z)) - float(main_script.STAND_BACK_Z)) < 0.01,
			"Stage B: the %s station stands %.2f m behind the line"
			% ["AI" if is_ai else "player", float(main_script.STAND_BACK_Z)])
	# The house wall stands on the patio's rear edge, and
	# its door and windows stand on the wall.
	var hd: Dictionary = main_script.stage_b_house()
	check(absf(float(hd["wall_z"]) - float(patio[3])) < 0.01,
		"Stage B: the house wall stands at the patio's rear edge")
	check(absf(float(hd["door_x"])) + 0.55 < float(hd["half_x"]),
		"Stage B: the back door stands on the wall")
	var win_xs: Array = hd["window_x"]
	for wv: Variant in win_xs:
		check(absf(float(wv)) + 0.65 < float(hd["half_x"]),
			"Stage B: a window stands on the wall (x %.2f)" % float(wv))
	# Patio objects: on the slab, off the walk corridor
	# (patio -> foul line), off both stations' envelopes.
	var corridor: Array = [-0.30, -0.55, 1.50, 3.60]
	var station_envs: Array = [
		[1.45, -0.40, 2.65, 1.00], [-2.65, -0.40, -1.45, 1.00]]
	var spots: Array = main_script.stage_b_object_spots()
	check(spots.size() == 6, "Stage B: six patio objects dress the slab (%d)" % spots.size())
	for spot: Array in spots:
		var opos: Vector3 = spot[1]
		var orad: float = float(spot[2])
		check(opos.x - orad >= float(patio[0]) and opos.x + orad <= float(patio[2])
			and opos.z - orad >= float(patio[1]) and opos.z + orad <= float(patio[3]),
			"Stage B: %s stands on the patio (at %s)" % [String(spot[0]), str(opos)])
		check(circle_rect_clear(opos, orad, corridor),
			"Stage B: %s keeps clear of the walk line to the foul line" % String(spot[0]))
		for ei: int in station_envs.size():
			check(circle_rect_clear(opos, orad, station_envs[ei]),
				"Stage B: %s keeps clear of station envelope %d" % [String(spot[0]), ei])
	# The patio chairs face the table they ring: each
	# chair's seat front (local -Z - its backrest stands at
	# local +Z) under the builder's yaw must point at the
	# table centre from the chair's own spot (Fix Pass 28).
	var chair_angles: Array = main_script.stage_b_chair_angles()
	check(chair_angles.size() == 3,
		"Stage B: three patio chairs ring the table (%d)" % chair_angles.size())
	for cav: Variant in chair_angles:
		var ca: float = deg_to_rad(float(cav))
		var cpos: Vector3 = (Vector3(sin(ca), 0.0, cos(ca))
			* float(main_script.STAGE_B_CHAIR_R))
		var cyaw: float = float(main_script.stage_b_chair_yaw(cpos))
		var cfacing := Vector3(-sin(cyaw), 0.0, -cos(cyaw))
		var cdot: float = cfacing.dot(-cpos.normalized())
		check(cdot >= 0.99,
			"Stage B: the patio chair at %.0f deg faces the table centre (dot %.3f)"
			% [float(cav), cdot])
	# The gate: in the right fence, mid-yard, a doorway wide.
	var gate: Dictionary = main_script.stage_b_gate()
	check(absf(float(gate["x"]) - 13.0) < 0.01,
		"Stage B: the gate stands in the right fence")
	var gz_c: float = (float(gate["z_hinge"]) + float(gate["z_latch"])) * 0.5
	var gz_w: float = float(gate["z_latch"]) - float(gate["z_hinge"])
	check(gz_c > -6.6 and gz_c < -5.4 and gz_w > 1.2 and gz_w < 1.8,
		"Stage B: the gate is centred mid-yard (z %.2f, %.2f m wide)" % [gz_c, gz_w])
	# The gate gap in the right bed matches the gate's z span
	# (bed gap -6.55..-5.45 against the fence gap -6.75..-5.25:
	# the path crosses the bed inside the fence opening).
	var beds: Array = main_script.stage_a_bed_rects()
	check(float(beds[1][3]) < float(gate["z_latch"])
		and float(beds[2][1]) > float(gate["z_hinge"]),
		"Stage B: the bed gap sits inside the gate's fence opening")
	# The gate approach: no foreground tree trunk stands
	# within 1.2 m laterally of the gate's centre axis on
	# the approach side (the yard side of the right fence,
	# the stepping-stone path's run) - Fix Pass 29: the
	# tree at (11.0, -5.0) stood 1.0 m off the axis with
	# its canopy over the path; it now stands at z -2.2.
	var fg_spots: Array = main_script.scenery_tree_spots()
	check(fg_spots.size() == 6,
		"Stage B: the foreground trees stand (%d trees)" % fg_spots.size())
	for fgs: Array in fg_spots:
		var ftp: Vector3 = fgs[0]
		check(ftp.y == 0.0,
			"Stage B: foreground tree at %s stands on the ground plane" % str(ftp))
		if ftp.x > 2.0 and ftp.x < 13.2:
			check(absf(ftp.z - gz_c) >= 1.2,
				"Stage B: no trunk in the gate approach (tree at %s, %.2f m off the axis)"
				% [str(ftp), absf(ftp.z - gz_c)])
	# The fountain: its basin fits inside the left bed,
	# seated in the bed's REAR CORNER nook (Fix Pass 29) -
	# its centre in the bed's rear quarter, its rear rim a
	# stone's width short of the bed's end line, and the
	# basin clear of the patio slab it corners against.
	var fp: Vector3 = main_script.STAGE_B_FOUNTAIN_POS
	var fr: float = float(main_script.STAGE_B_FOUNTAIN_R)
	var left_bed: Array = beds[0]
	check(fp.x - fr >= float(left_bed[0]) and fp.x + fr <= float(left_bed[2])
		and fp.z - fr >= float(left_bed[1]) and fp.z + fr <= float(left_bed[3]),
		"Stage B: the fountain basin fits inside the left bed (at %s)" % str(fp))
	var bed_rear: float = float(left_bed[3])
	var bed_front: float = float(left_bed[1])
	check(fp.z > bed_front + (bed_rear - bed_front) * 0.75,
		"Stage B: the fountain sits in the bed's rear quarter (centre z %.2f)" % fp.z)
	check(bed_rear - (fp.z + fr) >= 0.0 and bed_rear - (fp.z + fr) <= 0.35,
		"Stage B: the fountain's rim meets the bed's end (%.2f m short)"
		% (bed_rear - (fp.z + fr)))
	check(circle_rect_clear(fp, fr, patio),
		"Stage B: the fountain basin keeps off the patio slab")
	check(circle_rect_clear(fp, fr, [-2.30, -11.30, 2.30, 1.60]),
		"Stage B: the fountain keeps clear of the lane corridor")
	# Phineas (Fix Pass 29): OUT of the far bed entirely -
	# on the ground inside the stated corner pocket beside
	# the far bed's west end, his body clear of every bed
	# rect, aligned beside the bed's end, feet on the
	# ground plane, clear of pit and board.
	var pp: Vector3 = main_script.STAGE_B_PHINEAS_POS
	var far_bed: Array = beds[beds.size() - 1]
	var pocket: Array = main_script.stage_b_phineas_pocket()
	check(pp.x - 0.30 >= float(pocket[0]) and pp.x + 0.30 <= float(pocket[2])
		and pp.z - 0.30 >= float(pocket[1]) and pp.z + 0.30 <= float(pocket[3]),
		"Stage B: Phineas stands inside the corner pocket %s (at %s)"
		% [str(pocket), str(pp)])
	check(circle_rect_clear(pp, 0.30, far_bed),
		"Stage B: Phineas stands clear of the far bed (no planting under him)")
	check(circle_rect_clear(pp, 0.30, beds[0]),
		"Stage B: Phineas stands clear of the left bed")
	check(pp.x + 0.30 < float(far_bed[0])
		and absf(pp.z - (float(far_bed[1]) + float(far_bed[3])) * 0.5) <= 1.0,
		"Stage B: Phineas stands beside the far bed's west end (at %s)" % str(pp))
	check(pp.y == 0.0,
		"Stage B: Phineas's feet are on the ground plane")
	check(pp.distance_to(main_script.STAKE_POS) > 4.0,
		"Stage B: Phineas holds the far-left corner, clear of the pit")


## Stage B (the light) guards: the time-of-day preset
## table genuinely separates the three states (sun angle,
## colour and energy, sky, ambient all differ pairwise),
## NOON reproduces the pre-Stage-B build's constants value
## for value, the cycle order is CLOUDY -> NOON -> DUSK ->
## CLOUDY, and the fire pit's surveyed spot stands clear
## of everything the patio already holds. Fix Pass 31:
## CLOUDY (which replaced MORNING) carries the overcast
## signature in the table itself - a weak cool sun, a grey
## near-neutral sky, a cool ambient that carries the
## scene, eased adjustment, a breath of fog - and a saved
## MORNING setting migrates to it on load.
func test_stage_b_light() -> void:
	var main_script: GDScript = load("res://scripts/main.gd")
	var presets: Dictionary = main_script.time_of_day_presets()
	check(presets.size() == 3 and presets.has("CLOUDY")
		and presets.has("NOON") and presets.has("DUSK")
		and not presets.has("MORNING"),
		"Stage B light: the preset table names exactly CLOUDY / NOON / DUSK")
	var names: Array = ["CLOUDY", "NOON", "DUSK"]
	var keys: Array = ["sun_euler", "sun_color", "sun_energy",
		"sky_top", "sky_horizon", "ambient_color", "ambient_energy"]
	for ki: int in keys.size():
		var key: String = String(keys[ki])
		for ai: int in names.size():
			for bi2: int in names.size():
				if bi2 <= ai:
					continue
				var va: Variant = presets[names[ai]][key]
				var vb: Variant = presets[names[bi2]][key]
				var differ: bool
				if va is float:
					differ = absf(float(va) - float(vb)) > 0.001
				else:
					differ = va != vb
				check(differ,
					"Stage B light: %s differs between %s and %s (%s vs %s)"
					% [key, String(names[ai]), String(names[bi2]), str(va), str(vb)])
	# NOON is the accepted look, value for value.
	var noon: Dictionary = presets["NOON"]
	var noon_euler: Vector3 = noon["sun_euler"]
	check(noon_euler == Vector3(-48.0, -24.0, 0.0)
		and absf(float(noon["sun_energy"]) - 1.1) < 0.0001,
		"Stage B light: NOON keeps the accepted sun (-48/-24 at 1.1)")
	var noon_top: Color = noon["sky_top"]
	var noon_amb: Color = noon["ambient_color"]
	check(noon_top == Color(0.22, 0.44, 0.78)
		and noon_amb == Color(0.75, 0.78, 0.72)
		and absf(float(noon["ambient_energy"]) - 0.7) < 0.0001,
		"Stage B light: NOON keeps the accepted sky and ambient")
	# Dusk stays readable on paper: a real sun and a held
	# ambient, not a blackout.
	var dusk: Dictionary = presets["DUSK"]
	check(float(dusk["sun_energy"]) >= 0.7
		and float(dusk["ambient_energy"]) >= 0.45,
		"Stage B light: DUSK holds its light (sun %.2f, ambient %.2f) - a mood, not a tax"
		% [float(dusk["sun_energy"]), float(dusk["ambient_energy"])])
	# DUSK's preset is untouched by Fix Pass 31, value for
	# value, air included (the neutral 1.0s, no fog).
	var dusk_euler: Vector3 = dusk["sun_euler"]
	var dusk_scol: Color = dusk["sun_color"]
	var dusk_top: Color = dusk["sky_top"]
	var dusk_amb: Color = dusk["ambient_color"]
	check(dusk_euler == Vector3(-11.0, 32.0, 0.0)
		and dusk_scol == Color(1.0, 0.55, 0.29)
		and absf(float(dusk["sun_energy"]) - 0.85) < 0.0001
		and dusk_top == Color(0.13, 0.16, 0.38)
		and dusk_amb == Color(0.46, 0.45, 0.58)
		and absf(float(dusk["ambient_energy"]) - 0.52) < 0.0001
		and absf(float(dusk["adjustment_saturation"]) - 1.0) < 0.0001
		and absf(float(dusk["adjustment_contrast"]) - 1.0) < 0.0001
		and absf(float(dusk["fog_density"])) < 0.0001,
		"Fix Pass 31: DUSK's preset stands exactly as accepted")
	# CLOUDY's overcast signature, in the table: the sun is
	# cut to a weak cool presence (at most 0.35, and at
	# least 0.70 below NOON's), tinted cool-neutral.
	var cloudy: Dictionary = presets["CLOUDY"]
	var cloudy_scol: Color = cloudy["sun_color"]
	check(float(cloudy["sun_energy"]) <= 0.35
		and float(noon["sun_energy"]) - float(cloudy["sun_energy"]) >= 0.70
		and cloudy_scol.b >= cloudy_scol.r
		and cloudy_scol.b - cloudy_scol.r <= 0.20,
		"Fix Pass 31: CLOUDY's sun is a weak cool presence (%.2f vs NOON %.2f, colour %s)"
		% [float(cloudy["sun_energy"]), float(noon["sun_energy"]), str(cloudy_scol)])
	# The sky is flat grey: near-neutral overhead (channel
	# spread at most 0.08, no blue cast beyond a whisper),
	# lightening slightly at the horizon, still near zero
	# warmth there.
	var cloudy_top: Color = cloudy["sky_top"]
	var cloudy_hor: Color = cloudy["sky_horizon"]
	var top_spread: float = maxf(maxf(cloudy_top.r, cloudy_top.g), cloudy_top.b) \
		- minf(minf(cloudy_top.r, cloudy_top.g), cloudy_top.b)
	check(top_spread <= 0.08 and cloudy_top.b - cloudy_top.r <= 0.06
		and cloudy_hor.r > cloudy_top.r and cloudy_hor.g > cloudy_top.g
		and absf(cloudy_hor.r - cloudy_hor.b) <= 0.04,
		"Fix Pass 31: CLOUDY's sky is flat grey, lighter at the horizon (top %s spread %.2f, horizon %s)"
		% [str(cloudy_top), top_spread, str(cloudy_hor)])
	# The ambient carries the scene: slightly cool grey,
	# and strong - a grey day, not a dark one.
	var cloudy_amb: Color = cloudy["ambient_color"]
	check(cloudy_amb.b > cloudy_amb.r
		and float(cloudy["ambient_energy"]) >= 0.72,
		"Fix Pass 31: CLOUDY's ambient is cool grey and carries the scene (colour %s at %.2f)"
		% [str(cloudy_amb), float(cloudy["ambient_energy"])])
	# The air: contrast and saturation eased, a breath of
	# fog - and NOON's air is the neutral pass-through.
	check(float(cloudy["adjustment_saturation"]) <= 0.85
		and float(cloudy["adjustment_contrast"]) <= 0.94
		and float(cloudy["adjustment_brightness"]) <= 0.99
		and float(cloudy["fog_density"]) >= 0.006
		and float(cloudy["fog_density"]) <= 0.015,
		"Fix Pass 31: CLOUDY's air is eased and hazed (sat %.2f, contrast %.2f, fog %.3f)"
		% [float(cloudy["adjustment_saturation"]),
			float(cloudy["adjustment_contrast"]), float(cloudy["fog_density"])])
	check(absf(float(noon["adjustment_saturation"]) - 1.0) < 0.0001
		and absf(float(noon["adjustment_contrast"]) - 1.0) < 0.0001
		and absf(float(noon["adjustment_brightness"]) - 1.0) < 0.0001
		and absf(float(noon["fog_density"])) < 0.0001,
		"Fix Pass 31: NOON's air is neutral - the accepted look passes through")
	# The cycle order.
	check(String(main_script.time_after("CLOUDY")) == "NOON"
		and String(main_script.time_after("NOON")) == "DUSK"
		and String(main_script.time_after("DUSK")) == "CLOUDY",
		"Stage B light: the cycle runs CLOUDY -> NOON -> DUSK -> CLOUDY")
	# The saved-setting migration: the shipped build's
	# MORNING lands on CLOUDY, unknown values on NOON.
	check(String(main_script.time_setting_or_default("MORNING")) == "CLOUDY"
		and String(main_script.time_setting_or_default("CLOUDY")) == "CLOUDY"
		and String(main_script.time_setting_or_default("BOGUS")) == "NOON",
		"Fix Pass 31: a saved MORNING migrates to CLOUDY; an unknown value falls back to NOON")
	# The fire pit: on the slab, and its footprint clears
	# every other patio spot, the table's chair ring, the
	# walk corridor, both station envelopes and the back
	# door's step - measured, not eyeballed.
	var patio: Array = main_script.stage_b_patio_rect()
	var spots: Array = main_script.stage_b_object_spots()
	var fire: Array = []
	var table_spot: Array = []
	for spot: Array in spots:
		if String(spot[0]) == "fire_pit":
			fire = spot
		if String(spot[0]) == "table":
			table_spot = spot
	check(fire.size() == 3, "Stage B light: the fire pit has a surveyed spot")
	if fire.size() == 3:
		var fpos: Vector3 = fire[1]
		var frad: float = float(fire[2])
		check(fpos.x - frad >= float(patio[0]) and fpos.x + frad <= float(patio[2])
			and fpos.z - frad >= float(patio[1]) and fpos.z + frad <= float(patio[3]),
			"Stage B light: the fire pit stands on the patio (at %s)" % str(fpos))
		for spot: Array in spots:
			if String(spot[0]) == "fire_pit":
				continue
			var opos: Vector3 = spot[1]
			var orad: float = float(spot[2])
			check(fpos.distance_to(opos) > frad + orad,
				"Stage B light: the fire pit clears the %s (%.2f m between centres, %.2f needed)"
				% [String(spot[0]), fpos.distance_to(opos), frad + orad])
		# The chair ring rides at STAGE_B_CHAIR_R around the
		# table plus a chair's own depth - clear of the pit.
		var tpos: Vector3 = table_spot[1]
		check(fpos.distance_to(tpos)
			> frad + float(main_script.STAGE_B_CHAIR_R) + 0.21,
			"Stage B light: the fire pit clears the table's chair ring")
		check(circle_rect_clear(fpos, frad, [-0.30, -0.55, 1.50, 3.60]),
			"Stage B light: the fire pit keeps clear of the walk line to the foul line")
		var station_envs: Array = [
			[1.45, -0.40, 2.65, 1.00], [-2.65, -0.40, -1.45, 1.00]]
		for ei: int in station_envs.size():
			check(circle_rect_clear(fpos, frad, station_envs[ei]),
				"Stage B light: the fire pit keeps clear of station envelope %d" % ei)
		var hd: Dictionary = main_script.stage_b_house()
		var door_x: float = float(hd["door_x"])
		var wall_z: float = float(hd["wall_z"])
		check(circle_rect_clear(fpos, frad,
			[door_x - 0.60, wall_z - 0.56, door_x + 0.60, wall_z]),
			"Stage B light: the fire pit keeps clear of the back door's step")
		# Visible from the throwing line: inside the yard's
		# look-back cone from the player's pitching spot.
		var spot40: Vector3 = main_script.spot_pos(40, false)
		check(absf(fpos.x - spot40.x) < 4.5 and fpos.z > float(main_script.FOUL_40_Z),
			"Stage B light: the fire pit stands on the patio behind the line, in the look-back view")


func test_impact_fx() -> void:
	# Impact Dressing Pass: routing, scaling, pooling, lifecycle.
	var events: Array = ["sand_thud", "stake_clang", "shoe_clink", "ringer",
		"wood_knock", "grass_thud"]
	var paths: Array = []
	for ev: String in events:
		var p: String = ImpactFX.stream_path_for_event(ev)
		check(p != "" and ResourceLoader.exists(p),
			"Impact FX: event %s routes to a real audio file (%s)" % [ev, p])
		check(not paths.has(p), "Impact FX: event %s has its OWN sound" % ev)
		paths.append(p)
	check(ImpactFX.stream_path_for_event("bogus") == "",
		"Impact FX: an unknown event routes nowhere")
	for ev2: String in events:
		check(ImpactFX.volume_db_for(ev2, 0.0) <= ImpactFX.volume_db_for(ev2, 0.5)
			and ImpactFX.volume_db_for(ev2, 0.5) <= ImpactFX.volume_db_for(ev2, 1.0),
			"Impact FX: %s volume grows with impact strength" % ev2)
	check(ImpactFX.plume_scale_for(ImpactFX.KIND_TURF, 1.0)
		< ImpactFX.plume_scale_for(ImpactFX.KIND_SAND, 0.5),
		"Impact FX: a grass scuff plume is clearly lesser than a sand plume")
	check(ImpactFX.divot_radius_for(ImpactFX.KIND_SAND, 1.0)
		> ImpactFX.divot_radius_for(ImpactFX.KIND_TURF, 1.0),
		"Impact FX: a sand divot is bigger than a grass scuff")
	check(ImpactFX.divot_radius_for(ImpactFX.KIND_SAND, 0.0)
		< ImpactFX.divot_radius_for(ImpactFX.KIND_SAND, 1.0),
		"Impact FX: divot size grows with impact strength")
	var fx_node := ImpactFX.new()
	root.add_child(fx_node)
	await process_frame
	check(fx_node.plume_slots() == ImpactFX.PLUME_SLOTS,
		"Impact FX: the plume pool is pre-allocated (%d slots)" % ImpactFX.PLUME_SLOTS)
	check(fx_node.player_count() == ImpactFX.PLAYER_COUNT,
		"Impact FX: the audio pool is pre-allocated (%d players)" % ImpactFX.PLAYER_COUNT)
	fx_node.debug_surface_impact(ImpactFX.KIND_SAND,
		Vector3(0.0, 0.02, -12.19), Vector3(0.0, -3.0, -6.0), 0.9)
	check(fx_node.divot_count() == 1, "Impact FX: a sand impact stamps one divot")
	check(fx_node.play_log.size() == 1
		and String(fx_node.play_log[0]["event"]) == "sand_thud",
		"Impact FX: a sand impact routes the thud")
	fx_node.debug_surface_impact(ImpactFX.KIND_TURF,
		Vector3(1.0, 0.0, -6.0), Vector3(0.0, -2.0, -4.0), 0.9)
	check(fx_node.divot_count() == 2, "Impact FX: a grass impact stamps a scuff too")
	# Fix Pass 33: grass has its OWN sound now - Chris's
	# FP32 field test heard a lawn landing as silence. The
	# grass thud is its own event/file, never the sand thud.
	check(fx_node.play_log.size() == 2
		and String(fx_node.play_log[1]["event"]) == "grass_thud",
		"Impact FX (FP33): a grass impact routes its own soft thud")
	for i: int in 40:
		fx_node.surface_impact(ImpactFX.KIND_SAND,
			Vector3(0.1 * float(i % 5), 0.02, -12.0), Vector3(0.0, -3.0, -6.0), 0.5)
	check(fx_node.divot_count() == ImpactFX.DIVOT_CAP,
		"Impact FX: divots cap at %d and the oldest recycle" % ImpactFX.DIVOT_CAP)
	fx_node.play_event("ringer", Vector3.ZERO, 1.0)
	fx_node.play_event("ringer", Vector3.ZERO, 1.0)
	var rings: int = 0
	for entry: Dictionary in fx_node.play_log:
		if String(entry["event"]) == "ringer":
			rings += 1
	check(rings == 2, "Impact FX: each routed ringer rings exactly once per call")
	fx_node.clear_marks()
	check(fx_node.divot_count() == 0, "Impact FX: the rake leaves clean sand")
	# Fix Pass 32: the silence conviction, kept as guards. The
	# chain is tuned for THIS court (12 m line-to-pit): the
	# dressing's unit_size 2.0 measured a full-strength ring at
	# -27.5 dBFS at the line - inaudible. These assert the
	# retune; tests/audio_measure.gd proves it end-to-end
	# through genuine landings.
	check(fx_node.debug_player_unit_size() == 7.0,
		"Impact FX (FP32): players are tuned to the 12 m court (unit_size 7)")
	check(fx_node.debug_player_filter_db() == 0.0,
		"Impact FX (FP32): the distance low-pass is off - no muffling at 12 m")
	check(ImpactFX.volume_db_for("sand_thud", 0.0) >= -12.0,
		"Impact FX (FP32): even a strength-0 sand contact thuds audibly")
	check(ImpactFX.volume_db_for("stake_clang", 0.0) >= -10.0,
		"Impact FX (FP32): a stake strike clangs even at solver-eaten speed")
	check(ImpactFX.volume_db_for("ringer", 1.0) >= -1.5,
		"Impact FX (FP32): the ring plays near full volume - it carries the yard")
	# Fix Pass 33 floors, in the FP32 spirit: the wood knock
	# floors with the clang family (a frame strike is a real
	# event, audible at 12 m); the grass thud floors UNDER
	# the sand thud at every strength (a lawn landing is a
	# lesser event) yet high enough to survive the trip to
	# the line - tests/audio_measure.gd proves both through
	# genuine landings.
	check(ImpactFX.volume_db_for("wood_knock", 0.0) >= -7.0,
		"Impact FX (FP33): a frame strike knocks audibly even at solver-eaten speed (its floor runs 3 dB hotter than the clang's - the measured transient is wider, see impact_fx)")
	check(ImpactFX.volume_db_for("grass_thud", 0.0)
			< ImpactFX.volume_db_for("sand_thud", 0.0)
		and ImpactFX.volume_db_for("grass_thud", 1.0)
			< ImpactFX.volume_db_for("sand_thud", 1.0),
		"Impact FX (FP33): the grass thud sits under the sand thud at every strength")
	check(ImpactFX.volume_db_for("grass_thud", 0.0) >= -16.0,
		"Impact FX (FP33): the grass floor still reaches the throwing line")
	var lim_found: bool = false
	for bi: int in AudioServer.get_bus_effect_count(0):
		var eff: AudioEffect = AudioServer.get_bus_effect(0, bi)
		if eff is AudioEffectLimiter \
				and (eff as AudioEffectLimiter).ceiling_db <= -3.0:
			lim_found = true
	check(lim_found,
		"Impact FX (FP32): a master-bus limiter caps stacked ringside impacts")
	# Fix Pass 32: one plume per flight. A later episode of the
	# same landing stamps its divot but fires NO second burst
	# (the bounce re-fires were the lingering sparkle cluster).
	var fires0: int = fx_node.debug_plume_fire_count()
	var div0: int = fx_node.divot_count()
	fx_node.surface_impact(ImpactFX.KIND_SAND,
		Vector3(0.0, 0.02, -12.19), Vector3(0.0, -3.0, -6.0), 0.9, false)
	check(fx_node.debug_plume_fire_count() == fires0,
		"Impact FX (FP32): a later-episode impact fires no second plume")
	check(fx_node.divot_count() == div0 + 1,
		"Impact FX (FP32): a later-episode impact still stamps its divot")
	fx_node.surface_impact(ImpactFX.KIND_SAND,
		Vector3(0.0, 0.02, -12.19), Vector3(0.0, -3.0, -6.0), 0.9, true)
	check(fx_node.debug_plume_fire_count() == fires0 + 1,
		"Impact FX (FP32): a first-of-flight impact fires exactly one plume")
	fx_node.queue_free()


func _run() -> void:
	test_release_math()
	await test_impact_fx()
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
	test_stage_b_layout()
	test_stage_b_light()
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
