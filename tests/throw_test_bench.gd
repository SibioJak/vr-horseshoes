extends SceneTree

## Fix Pass 43 bench: the throw test, proven four ways.
##
## The disease, measured on Chris's throws-19: the launch
## follows the RECORDED release faithfully (near-identical
## recorded releases land within ~10-14 in of each other),
## but the FP14 read samples the fitted velocity at the one
## instant the un-squeeze crosses - while the hand is still
## accelerating at a median ~19 m/s per second, so a frame of
## let-go timing jitter deals a different release (~0.32 m/s,
## ~27 in of carry) to a swing that felt the same. And the
## carry gain itself is true physics (~82 in per m/s), so his
## whole release-speed scatter lands on the pit at full size.
##
## 1. WINDOW UNIT: a constant-velocity stream reads
##    identically through the instantaneous and the windowed
##    read; a steadily accelerating stream (19 m/s^2, the
##    field median) reads through the window trailing the
##    instant by half the window's worth of acceleration -
##    the analytic amount. A window reaching before the
##    buffer starts clamps to the recorded motion.
## 2. JITTER: a swing stream with Chris's shape - speed
##    ramping at 19 m/s^2 into a crest just past the nominal
##    release - released at 300 jittered instants (uniform
##    +-2 frames at 60 Hz, the un-squeeze's own timing
##    noise). Carry scatter is measured three ways: the FP42
##    single-instant read, the windowed read alone, and the
##    full FP43 read (window + soften). Analytic projectile
##    carry from the read's own release position/velocity is
##    the instrument - it isolates the release path, which
##    is the thing under test.
## 3. COMPRESSION: scripted releases at the centre speed
##    +-0.5 and +-1.0 m/s land at ~half the FP42 carry
##    deviation, direction preserved exactly, the centre
##    throw itself on the stake; ill-conditioned solves
##    (steep, flat, point-blank) fall back unmodified.
## 4. PRODUCTION PATH: a real grab through main's test
##    hooks, a fabricated grip history, _do_release - the
##    cache and the throw record must carry the windowed raw
##    read beside the softened launch; the negative control
##    (throw_test_enabled off) reproduces the FP42 velocity
##    on the same path, exactly.
##
## Run: godot --headless --path . --script tests/throw_test_bench.gd

var failures: int = 0
var checks: int = 0
var main: Node

const STAKE := Vector3(0.0, 0.0, -12.192)
const GRAV: float = 9.8
const FRAME: float = 1.0 / 60.0
const SAMPLE_DT: float = 1.0 / 90.0
const WINDOW_SEC: float = 0.060

# Part 2 swing profile: direction fixed at 42 deg elevation;
# speed ramps at 19 m/s^2 until the crest at SW_TC, then
# rolls off quadratically. Nominal release at 0.30 s.
const SW_DIR := Vector3(0.0, 0.669131, -0.743145)
const SW_TC: float = 0.315
const SW_TSTAR: float = 0.30


func check(cond: bool, msg: String) -> void:
	checks += 1
	if cond:
		print("  PASS  ", msg)
	else:
		failures += 1
		print("  FAIL  ", msg)


func sd_of(vals: Array) -> float:
	if vals.size() < 2:
		return 0.0
	var mean: float = 0.0
	for raw_v: Variant in vals:
		mean += float(raw_v)
	mean /= float(vals.size())
	var acc: float = 0.0
	for raw_v2: Variant in vals:
		var dv: float = float(raw_v2) - mean
		acc += dv * dv
	return sqrt(acc / float(vals.size() - 1))


## Signed carry miss in inches (positive = long, past the
## stake) for an analytic projectile from release_pos/vel
## landing on the y=0 plane.
func carry_miss_in(release_pos: Vector3, vel: Vector3) -> float:
	var disc: float = vel.y * vel.y + 2.0 * GRAV * release_pos.y
	var t_land: float = (vel.y + sqrt(maxf(disc, 0.0))) / GRAV
	var land_z: float = release_pos.z + vel.z * t_land
	return (STAKE.z - land_z) * 39.3701


# ============================================================
# Part 1: the windowed read's unit behaviour
# ============================================================

func test_window_unit() -> void:
	print("--- Part 1: window unit behaviour ---")
	# 1a: constant velocity - windowed == instantaneous == truth.
	var vc := Vector3(0.35, 6.90, -7.60)
	var stream_a: Array = []
	for k: int in range(0, 37):
		var t: float = float(k) * SAMPLE_DT
		stream_a.append(ThrowMath.make_sample(
			t, Vector3(0.55, 0.55, 0.95) + vc * t, Quaternion.IDENTITY))
	var inst_a: Vector3 = ThrowMath.velocity_origin_relative_at_time(
		stream_a, Basis.IDENTITY, 0.30)
	var avg_a: Vector3 = ThrowMath.average_velocity_origin_relative_at_time(
		stream_a, Basis.IDENTITY, 0.30, WINDOW_SEC)
	print("  constant stream: inst %s | windowed %s | truth %s" % [inst_a, avg_a, vc])
	check(inst_a.distance_to(vc) < 0.02,
		"window unit: instantaneous read is the constant velocity (err %.3f)" % inst_a.distance_to(vc))
	check(avg_a.distance_to(vc) < 0.02,
		"window unit: windowed read is the constant velocity (err %.3f)" % avg_a.distance_to(vc))
	check(avg_a.distance_to(inst_a) < 0.01,
		"window unit: windowed == instantaneous on a constant stream (err %.3f)" % avg_a.distance_to(inst_a))

	# 1b: steady acceleration 19 m/s^2 - the window trails the
	# instant by exactly half the window's worth: the average
	# over [t-0.06, t] of a linear velocity is v(t - 0.03).
	var acc := Vector3(0.0, 13.43, -13.43) # |a| = 18.99
	var v0 := Vector3(0.0, 3.04, -3.04)
	var stream_b: Array = []
	for k2: int in range(0, 37):
		var t2: float = float(k2) * SAMPLE_DT
		stream_b.append(ThrowMath.make_sample(
			t2, Vector3(0.55, 0.60, 0.90) + v0 * t2 + 0.5 * acc * t2 * t2,
			Quaternion.IDENTITY))
	var inst_b: Vector3 = ThrowMath.velocity_origin_relative_at_time(
		stream_b, Basis.IDENTITY, 0.30)
	var avg_b: Vector3 = ThrowMath.average_velocity_origin_relative_at_time(
		stream_b, Basis.IDENTITY, 0.30, WINDOW_SEC)
	var truth_inst: Vector3 = v0 + acc * 0.30
	var truth_avg: Vector3 = v0 + acc * 0.27
	print("  accelerating stream: inst %.3f m/s | windowed %.3f m/s | trail %.3f m/s (analytic %.3f)" % [
		inst_b.length(), avg_b.length(), inst_b.length() - avg_b.length(),
		acc.length() * WINDOW_SEC * 0.5])
	check(inst_b.distance_to(truth_inst) < 0.03,
		"window unit: instantaneous read on the accelerating stream (err %.3f)" % inst_b.distance_to(truth_inst))
	check(avg_b.distance_to(truth_avg) < 0.03,
		"window unit: windowed read is the velocity at the window midpoint (err %.3f)" % avg_b.distance_to(truth_avg))
	var trail: float = inst_b.length() - avg_b.length()
	check(trail > 0.45 and trail < 0.68,
		"window unit: the window trails the instant by ~half the window at 19 m/s^2 (%.3f m/s)" % trail)

	# 1c: a window reaching before the buffer start clamps to
	# the recorded motion: at t=0.03 the average covers
	# [0.00, 0.03] - the velocity at 0.015.
	var avg_c: Vector3 = ThrowMath.average_velocity_origin_relative_at_time(
		stream_b, Basis.IDENTITY, 0.03, WINDOW_SEC)
	var truth_c: Vector3 = v0 + acc * 0.015
	check(avg_c.distance_to(truth_c) < 0.03,
		"window unit: early window clamps to the recorded motion (err %.3f)" % avg_c.distance_to(truth_c))


# ============================================================
# Part 2: release-phase jitter, three arms
# ============================================================

func sw_disp(t: float) -> float:
	if t <= SW_TC:
		return 4.40 * t + 9.5 * t * t
	var w: float = t - SW_TC
	return 2.3286375 + 10.385 * w - (125.0 / 3.0) * w * w * w


func sw_pos(t: float) -> Vector3:
	# Anchored so sw_pos(SW_TSTAR) == (0.55, 1.25, -0.95).
	return Vector3(0.55, 1.25, -0.95) + SW_DIR * (sw_disp(t) - 2.175)


func test_jitter() -> void:
	print("--- Part 2: jitter bench (300 releases, +-2 frames) ---")
	var samples: Array = []
	var k: int = 0
	var t: float = 0.08
	while t <= 0.4801:
		samples.append(ThrowMath.make_sample(t, sw_pos(t), Quaternion.IDENTITY))
		k += 1
		t = 0.08 + float(k) * SAMPLE_DT
	var rng := RandomNumberGenerator.new()
	rng.seed = 4301
	var miss42: Array = []
	var miss_win: Array = []
	var miss43: Array = []
	for trial: int in 300:
		var off: float = rng.randf_range(-2.0, 2.0) * FRAME
		var t_rel: float = SW_TSTAR + off
		var pos_rel: Vector3 = ThrowMath.position_at_time(samples, t_rel)
		var ev: Dictionary = ThrowMath.evaluate_release_at(
			samples, Basis.IDENTITY, t_rel, true)
		var vel42: Vector3 = ev["vel"]
		var vel_win: Vector3 = ThrowMath.average_velocity_origin_relative_at_time(
			samples, Basis.IDENTITY, t_rel, WINDOW_SEC)
		var vel43: Vector3 = ThrowMath.soften_velocity(
			vel_win, pos_rel, STAKE, 0.5)
		miss42.append(carry_miss_in(pos_rel, vel42))
		miss_win.append(carry_miss_in(pos_rel, vel_win))
		miss43.append(carry_miss_in(pos_rel, vel43))
	var sd42: float = sd_of(miss42)
	var sd_win: float = sd_of(miss_win)
	var sd43: float = sd_of(miss43)
	print("  carry scatter SD: FP42 instant %.1f in | windowed only %.1f in | FP43 full %.1f in" % [
		sd42, sd_win, sd43])
	print("  ratios: windowed/FP42 %.2f | FP43/FP42 %.2f" % [sd_win / sd42, sd43 / sd42])
	check(sd42 > 10.0,
		"jitter: the FP42 path shows the disease on this stream (SD %.1f in)" % sd42)
	check(sd43 < sd42,
		"jitter: FP43 scatter is lower than FP42 (%.1f < %.1f in)" % [sd43, sd42])
	check(sd43 <= 0.65 * sd42,
		"jitter: FP43 scatter is materially lower (ratio %.2f <= 0.65)" % (sd43 / sd42))


# ============================================================
# Part 3: the compression
# ============================================================

func test_compression() -> void:
	print("--- Part 3: compression bench ---")
	var rel_pos := Vector3(0.55, 1.25, -0.95)
	var elev: float = deg_to_rad(42.0)
	var centre: float = ThrowMath.centre_speed(elev, rel_pos, STAKE)
	print("  centre speed at 42 deg from the 40 ft neighbourhood: %.3f m/s" % centre)
	check(centre > 6.0 and centre < 13.0,
		"compression: centre speed solves inside the clamp (%.3f)" % centre)
	var to_stake := Vector2(STAKE.x - rel_pos.x, STAKE.z - rel_pos.z).normalized()
	var dir := Vector3(to_stake.x * cos(elev), sin(elev), to_stake.y * cos(elev))
	var c_miss: float = carry_miss_in(rel_pos, dir * centre)
	print("  centre throw carry miss: %.2f in" % c_miss)
	check(absf(c_miss) < 3.0,
		"compression: a throw AT the centre speed lands on the stake (miss %.2f in)" % c_miss)
	for raw_d: Variant in [-1.0, -0.5, 0.5, 1.0]:
		var delta: float = float(raw_d)
		var raw_vel: Vector3 = dir * (centre + delta)
		var soft: Vector3 = ThrowMath.soften_velocity(raw_vel, rel_pos, STAKE, 0.5)
		check(absf(soft.length() - (centre + 0.5 * delta)) < 0.002,
			"compression: centre %+.1f -> effective speed %.3f (expected %.3f)" % [
				delta, soft.length(), centre + 0.5 * delta])
		check(soft.angle_to(raw_vel) < 0.0001,
			"compression: direction preserved exactly at centre %+.1f" % delta)
		var dev42: float = carry_miss_in(rel_pos, raw_vel)
		var dev43: float = carry_miss_in(rel_pos, soft)
		var ratio: float = dev43 / dev42
		print("  centre %+.1f m/s: FP42 deviation %+.1f in | FP43 %+.1f in | ratio %.2f" % [
			delta, dev42, dev43, ratio])
		check(ratio > 0.40 and ratio < 0.60,
			"compression: carry deviation lands at ~half (ratio %.2f)" % ratio)
	# Fallbacks: the unmodified speed flies.
	var steep := Vector3(0.0, 9.9, -1.05) # ~84 deg elevation
	check(ThrowMath.soften_velocity(steep, rel_pos, STAKE, 0.5) == steep,
		"compression fallback: >80 deg elevation unmodified")
	var flat := Vector3(0.0, -0.1, -10.0) # below horizontal
	check(ThrowMath.soften_velocity(flat, rel_pos, STAKE, 0.5) == flat,
		"compression fallback: downward throw unmodified")
	var near_pos: Vector3 = STAKE + Vector3(0.1, 1.0, 0.0)
	check(ThrowMath.soften_velocity(dir * 10.0, near_pos, STAKE, 0.5) == dir * 10.0,
		"compression fallback: point-blank release unmodified")


# ============================================================
# Part 4: the production path through main
# ============================================================

func frames(n: int) -> void:
	for i: int in n:
		await process_frame


func wait_state(want: String, timeout_sec: float) -> bool:
	var elapsed: float = 0.0
	while elapsed < timeout_sec:
		if String(main.state) == want:
			return true
		await create_timer(0.2).timeout
		elapsed += 0.2
	return String(main.state) == want


## Linear grip ramp crossing GRIP_OFF exactly at t_star
## (mirrors tests/substep_bench.gd).
func grip_lin(t: float, t_star: float) -> float:
	var start: float = t_star - 0.060
	if t <= start:
		return 1.0
	return clampf(1.0 - (t - start) / (0.060 / 0.7), 0.0, 1.0)


func test_production_path() -> void:
	print("--- Part 4: production path ---")
	var rec_path: String = "user://bench_throws43.jsonl"
	if FileAccess.file_exists(rec_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(rec_path))
	var ps: PackedScene = load("res://main.tscn")
	main = ps.instantiate()
	main.recorder_path = rec_path
	root.add_child(main)
	await create_timer(0.3).timeout
	check(main != null and main.shoe != null, "production: main scene instantiated")

	# Grab the toe through the production latch.
	var toe_c: Vector3 = main.shoe.zone_world_center("toe")
	main.test_hand_tf["R"] = Transform3D(Basis.IDENTITY, toe_c)
	main.test_grip["R"] = 1.0
	await frames(6)
	for i: int in 2:
		await physics_frame
	check(String(main.state) == "HELD", "production: grab latches (state %s)" % String(main.state))

	# The Part 2 swing on the wall clock, samples at 60 Hz,
	# grip crossing GRIP_OFF at t* inside its step (frac 0.35).
	var base: float = float(Time.get_ticks_msec()) / 1000.0 - 0.40
	var frac: float = 0.35
	var t_star: float = base + 0.30 + frac * FRAME
	var samples: Array = []
	for k: int in range(0, 25):
		var u: float = float(k) * FRAME
		samples.append(ThrowMath.make_sample(
			base + u, sw_pos(u), Quaternion.IDENTITY))
	main.samples = samples
	var t_prev: float = base + 0.30
	var t_now: float = base + 0.30 + FRAME
	main._grip_hist = [
		{"t": t_prev, "g": grip_lin(t_prev - base, t_star - base)},
		{"t": t_now, "g": grip_lin(t_now - base, t_star - base)},
	]
	main._do_release()
	main.grab_state.reset()
	main.test_grip["R"] = 0.0
	check(String(main.state) == "FLYING", "production: release throws (state %s)" % String(main.state))
	check(String(main.release_cache.get("release_timing", "")) == "substep",
		"production: release cache marks the read 'substep'")
	var basis: Basis = main.origin.global_transform.basis
	var expect_raw: Vector3 = ThrowMath.average_velocity_origin_relative_at_time(
		samples, basis, t_star, WINDOW_SEC)
	var got_raw: Vector3 = main.release_cache.get("raw_velocity", Vector3.ZERO)
	check(got_raw.distance_to(expect_raw) < 0.02,
		"production: cache raw velocity is the windowed read (err %.3f m/s)" % got_raw.distance_to(expect_raw))
	var rel_pos_cache: Vector3 = main.release_cache.get("release_pos", Vector3.ZERO)
	var expect_vel: Vector3 = ThrowMath.soften_velocity(
		expect_raw, rel_pos_cache, main.target_stake_pos(), 0.5)
	var got_vel: Vector3 = main.release_cache.get("velocity", Vector3.ZERO)
	check(got_vel.distance_to(expect_vel) < 0.02,
		"production: cache velocity is the softened launch (err %.3f m/s)" % got_vel.distance_to(expect_vel))
	var ev42: Dictionary = ThrowMath.evaluate_release_at(samples, basis, t_star, true)
	var vel42: Vector3 = ev42["vel"]
	print("  production speeds: FP42 instant %.3f | windowed raw %.3f | FP43 launched %.3f m/s" % [
		vel42.length(), got_raw.length(), got_vel.length()])

	# The record must carry both releases.
	check(await wait_state("STAND", 25.0), "production: throw settles and restocks")
	var rec_text: String = FileAccess.get_file_as_string(rec_path)
	var found: bool = false
	for line: String in rec_text.split("\n"):
		if line.strip_edges() == "":
			continue
		var parsed: Variant = JSON.parse_string(line)
		if parsed is Dictionary:
			var rec: Dictionary = parsed
			if String(rec.get("type", "")) == "throw" and String(rec.get("release_timing", "")) == "substep":
				found = true
				var raw_arr: Array = rec.get("raw_release_velocity", [])
				check(raw_arr.size() == 3,
					"recorder: throw record carries raw_release_velocity")
				check(absf(float(rec.get("raw_release_speed", -1.0)) - got_raw.length()) < 0.01,
					"recorder: raw_release_speed is the windowed speed (%.3f)" % float(rec.get("raw_release_speed", -1.0)))
				var launched: Array = rec.get("release_velocity", [])
				check(launched.size() == 3 and absf(Vector3(
					float(launched[0]), float(launched[1]), float(launched[2])).length()
					- got_vel.length()) < 0.01,
					"recorder: release_velocity stays the launched truth")
	check(found, "recorder: a substep throw record was written")

	# Negative control: same path, throw test off - the FP42
	# velocity comes back exactly, and raw == launched.
	main.throw_test_enabled = false
	main._release_shoe(samples, t_star, {"offset_ms": frac * FRAME * 1000.0, "grip_bracket": [0.9, 0.1]})
	main.grab_state.reset()
	var ctl_vel: Vector3 = main.release_cache.get("velocity", Vector3.ZERO)
	check(ctl_vel.distance_to(vel42) < 0.0001,
		"production NEGATIVE CONTROL: flag off reproduces the FP42 velocity (err %.5f)" % ctl_vel.distance_to(vel42))
	var ctl_raw: Vector3 = main.release_cache.get("raw_velocity", Vector3.ZERO)
	check(ctl_raw.distance_to(ctl_vel) < 0.0001,
		"production NEGATIVE CONTROL: flag off records raw == launched")
	main.throw_test_enabled = true
	await wait_state("STAND", 25.0)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(rec_path))


func _init() -> void:
	_run()


func _run() -> void:
	print("--- Fix Pass 43 bench: throw test ---")
	test_window_unit()
	test_jitter()
	test_compression()
	await test_production_path()
	print("---")
	if failures == 0:
		print("THROW TEST BENCH: ALL %d CHECKS PASSED" % checks)
	else:
		print("THROW TEST BENCH: %d of %d CHECKS FAILED" % [failures, checks])
	quit(1 if failures > 0 else 0)
