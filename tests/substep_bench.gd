extends SceneTree

## Fix Pass 14 bench: the sub-step release read, proven four ways.
##
## The disease, measured on Chris's throws-12 before this pass:
## the legacy read takes the fitted velocity AT THE PEAK-SPEED
## SAMPLE, but the grip's let-go crossing lands a median ~83 ms
## after that peak (the analog needs time to fall), with the
## hand's direction sweeping ~800 deg/s locally - so the legacy
## launch elevation sits a median 34.8 deg off the direction his
## hand actually had at the crossing. The pass reads the SAME fit
## at the interpolated crossing instant t* instead.
##
## 1. PART Q (exactness): a short quadratic whip segment - the
##    family the production fit is exact on - with the crossing
##    placed at controlled offsets inside a 60 Hz step. Ground
##    truth is analytic. Gate: sub-step error <= 2 deg everywhere;
##    the legacy error must show the disease (>= 8 deg somewhere).
## 2. PART P (faithful motion): a prescribed-velocity swing with
##    Chris's measured shape - direction sweeping ~770 deg/s at
##    the speed peak, settling after it; speed peaking BEFORE the
##    buffer ends; the grip falling on a curved (logistic) ramp
##    so the crossing lands ~70 ms after the peak, as his does.
##    Truth splits in two: the GRID-PLACEMENT error is measured
##    against the fit's own read at the exact t* (the only error
##    this pass exists to remove - gate <= 2 deg), and the fit's
##    pre-existing smoothing residual against the analytic truth
##    is printed for honesty (on Chris's real data that residual
##    is a median 13 deg; the fit is NOT changed by this pass).
## 3. REAL DATA: Chris's recorded streams carry no grip stream,
##    so they can only prove the fitted read is continuous across
##    grid steps (1 ms probes), show the legacy read's own poll
##    sensitivity (truncation spread), and bound the sub-step
##    read's grid exposure (the whole-bracket envelope). The
##    full chain is covered by Parts Q/P and the production
##    path below.
## 4. PRODUCTION PATH: a real grab through main's test hooks, a
##    fabricated grip history on the sample buffer's own clock,
##    and _do_release - plus the negative control: the same
##    release with main's sub-step flag off must reproduce the
##    legacy velocity exactly and mark the record "grid".
##
## Run: godot --headless --path . --script tests/substep_bench.gd

var failures: int = 0
var checks: int = 0
var main: Node

const STEP: float = 1.0 / 60.0
const OFFSETS: Array = [0.0, 0.02, 0.25, 0.5, 0.75, 0.95]
const SPIN_TRUE := Vector3(0.0, 0.0, 5.0) # quats rotate about +Z (Vector3.BACK) at 5 rad/s

# Part Q constants: velocity/acceleration of the whip segment at
# its anchor tick (t = 0). Launch elevation 38 deg at the anchor,
# direction sweeping ~888 deg/s there.
const Q_V := Vector3(0.0, 2.46, -3.15)
const Q_A := Vector3(0.0, 71.0, 0.0)
const Q_P := Vector3(0.25, 1.30, -0.40)
const RAMP_DUR: float = 0.060 / 0.7 # linear grip 1.0 -> 0.0 crossing 0.30 exactly at t*

# Part P constants: the crossing instant in motion time, and the
# logistic grip fall that crosses GRIP_OFF there.
const P_USTAR: float = 0.070
const P_GRIP_CENTER: float = 0.06492
const P_GRIP_SCALE: float = 0.006

var _p_times: Array = []
var _p_pos: Array = []


func check(cond: bool, name: String) -> void:
	checks += 1
	if cond:
		print("PASS  ", name)
	else:
		failures += 1
		print("FAIL  ", name)


func elev_of(v: Vector3) -> float:
	return rad_to_deg(atan2(v.y, Vector2(v.x, v.z).length()))


# ============================================================
# Part Q: fit-exact whip segment
# ============================================================

func q_pos(t: float) -> Vector3:
	return Q_P + Q_V * t + 0.5 * Q_A * t * t


func q_vel(t: float) -> Vector3:
	return Q_V + Q_A * t


## Linear grip ramp crossing GRIP_OFF exactly at t_star.
func grip_lin(t: float, t_star: float) -> float:
	var start: float = t_star - 0.060
	if t <= start:
		return 1.0
	return clampf(1.0 - (t - start) / RAMP_DUR, 0.0, 1.0)


func test_q_row(frac: float) -> void:
	var t_star: float = frac * STEP
	var k_det: int = 0
	while grip_lin(float(k_det) * STEP, t_star) > GrabState.GRIP_OFF:
		k_det += 1
	var samples: Array = []
	for k: int in range(-3, k_det + 1):
		var t: float = float(k) * STEP
		samples.append(ThrowMath.make_sample(
			t, q_pos(t), Quaternion(Vector3.BACK, 5.0 * t)))
	var t_prev: float = float(k_det - 1) * STEP
	var t_now: float = float(k_det) * STEP
	var t_est: float = ThrowMath.release_crossing_time(
		t_prev, grip_lin(t_prev, t_star), t_now, grip_lin(t_now, t_star),
		GrabState.GRIP_OFF)
	var truth_elev: float = elev_of(q_vel(t_star))
	var ev_old: Dictionary = ThrowMath.evaluate_release_at(samples, Basis.IDENTITY, -1.0, false)
	var ev_new: Dictionary = ThrowMath.evaluate_release_at(samples, Basis.IDENTITY, t_est, true)
	var ev_ctl: Dictionary = ThrowMath.evaluate_release_at(samples, Basis.IDENTITY, t_est, false)
	var old_vel: Vector3 = ev_old["vel"]
	var new_vel: Vector3 = ev_new["vel"]
	var ctl_vel: Vector3 = ev_ctl["vel"]
	var new_ang: Vector3 = ev_new["ang"]
	var old_ang: Vector3 = ev_old["ang"]
	var err_old: float = absf(elev_of(old_vel) - truth_elev)
	var err_new: float = absf(elev_of(new_vel) - truth_elev)
	var pos_old_err: float = q_pos(t_prev).distance_to(q_pos(t_star))
	var pos_new_err: float = ThrowMath.position_at_time(samples, t_est).distance_to(q_pos(t_star))
	print("  Q offset %.2f: legacy err %.2f deg | sub-step err %.2f deg | pos legacy %.3f m, sub-step %.4f m" % [
		frac, err_old, err_new, pos_old_err, pos_new_err])
	check(absf(t_est - t_star) < 0.000001,
		"Q %.2f: interpolated crossing recovers t* exactly (linear ramp)" % frac)
	check(err_new <= 2.0,
		"Q %.2f: SUB-STEP elevation error %.2f deg <= 2 deg gate" % [frac, err_new])
	check(ctl_vel.distance_to(old_vel) < 0.00001,
		"Q %.2f: NEGATIVE CONTROL - flag off reproduces the legacy velocity exactly" % frac)
	check(new_ang.distance_to(SPIN_TRUE) < 0.35 and old_ang.distance_to(SPIN_TRUE) < 0.35,
		"Q %.2f: spin read at t* stays true (new err %.3f, legacy err %.3f rad/s)" % [
			frac, new_ang.distance_to(SPIN_TRUE), old_ang.distance_to(SPIN_TRUE)])
	check(pos_new_err < 0.01,
		"Q %.2f: position read at t* is the fitted position (err %.4f m)" % [frac, pos_new_err])
	if frac == 0.0:
		check(err_old >= 8.0,
			"Q: the bench can SEE the disease - legacy error %.1f deg at offset 0" % err_old)


func test_crossing_time() -> void:
	var t: float = ThrowMath.release_crossing_time(0.0, 1.0, STEP, 0.0, GrabState.GRIP_OFF)
	check(absf(t - 0.7 * STEP) < 0.000001,
		"crossing time interpolates the threshold (got %.5f, want %.5f)" % [t, 0.7 * STEP])
	check(ThrowMath.release_crossing_time(0.0, 0.2, STEP, 0.0, GrabState.GRIP_OFF) == STEP,
		"crossing: already below threshold at bracket start -> grid answer")
	check(ThrowMath.release_crossing_time(0.0, 1.0, STEP, 0.9, GrabState.GRIP_OFF) == STEP,
		"crossing: threshold never crossed in bracket -> grid answer")
	check(ThrowMath.release_crossing_time(STEP, 1.0, STEP, 0.0, GrabState.GRIP_OFF) == STEP,
		"crossing: zero-width bracket -> grid answer")


# ============================================================
# Part P: faithful prescribed-velocity swing
# ============================================================

## Velocity elevation (rad) at motion time u: sweeps from -22 deg
## in the downswing through ~0 at the speed peak (u = 0) to
## 37.6 deg at the crossing (u = 0.070), rotating ~770 deg/s at
## the peak and settling to ~130 deg/s by the crossing - the
## shape of Chris's recorded swings.
func p_phi(u: float) -> float:
	return deg_to_rad(40.0 - 62.0 / (1.0 + exp((u - 0.012) / 0.018)))


## Hand speed at motion time u: peaks at 7.6 m/s at u = 0, still
## ~7.0 at the crossing.
func p_speed(u: float) -> float:
	return 7.6 * (1.0 - 0.35 * (u / 0.15) * (u / 0.15))


func p_vel(u: float) -> Vector3:
	var ph: float = p_phi(u)
	var s: float = p_speed(u)
	return Vector3(0.0, s * sin(ph), -s * cos(ph))


## Curved grip fall crossing GRIP_OFF exactly at P_USTAR.
func p_grip(u: float) -> float:
	return 1.0 / (1.0 + exp((u - P_GRIP_CENTER) / P_GRIP_SCALE))


## Integrate the prescribed velocity once, densely; grid samples
## are read off the table (position error < 0.1 mm).
func p_build_table() -> void:
	_p_times.clear()
	_p_pos.clear()
	var du: float = 0.0001
	var pos := Vector3(0.25, 1.02, 0.62)
	var u: float = -0.30
	_p_times.append(u)
	_p_pos.append(pos)
	while u < 0.15:
		var v0: Vector3 = p_vel(u)
		var v1: Vector3 = p_vel(u + du)
		pos += 0.5 * (v0 + v1) * du
		u += du
		_p_times.append(u)
		_p_pos.append(pos)


func p_pos(u: float) -> Vector3:
	var idx: int = clampi(int(round((u + 0.30) / 0.0001)), 0, _p_pos.size() - 1)
	var p: Vector3 = _p_pos[idx]
	return p


func test_p_row(frac: float) -> void:
	# Grid ticks, phase-shifted by frac of a step; buffer ends at
	# the detection poll (first tick at/below the threshold).
	var ticks: Array = []
	var k: int = 0
	while true:
		var u: float = -0.20 + frac * STEP + float(k) * STEP
		if u > 0.20:
			break
		ticks.append(u)
		k += 1
	var u_det: float = 9.0
	for raw_u: Variant in ticks:
		var tu: float = float(raw_u)
		if p_grip(tu) <= GrabState.GRIP_OFF:
			u_det = tu
			break
	var samples: Array = []
	for raw_u2: Variant in ticks:
		var tu2: float = float(raw_u2)
		if tu2 <= u_det:
			samples.append(ThrowMath.make_sample(
				tu2, p_pos(tu2), Quaternion(Vector3.BACK, 5.0 * tu2)))
	var u_prev: float = -9.0
	for raw_u3: Variant in ticks:
		var tu3: float = float(raw_u3)
		if tu3 < u_det:
			u_prev = tu3
	var t_est: float = ThrowMath.release_crossing_time(
		u_prev, p_grip(u_prev), u_det, p_grip(u_det), GrabState.GRIP_OFF)
	var ev_old: Dictionary = ThrowMath.evaluate_release_at(samples, Basis.IDENTITY, -1.0, false)
	var ev_ref: Dictionary = ThrowMath.evaluate_release_at(samples, Basis.IDENTITY, P_USTAR, true)
	var ev_new: Dictionary = ThrowMath.evaluate_release_at(samples, Basis.IDENTITY, t_est, true)
	var old_vel: Vector3 = ev_old["vel"]
	var ref_vel: Vector3 = ev_ref["vel"]
	var new_vel: Vector3 = ev_new["vel"]
	var grid_old: float = absf(elev_of(old_vel) - elev_of(ref_vel))
	var grid_new: float = absf(elev_of(new_vel) - elev_of(ref_vel))
	var residual: float = absf(elev_of(ref_vel) - elev_of(p_vel(P_USTAR)))
	print("  P offset %.2f: grid err legacy %.1f deg | grid err sub-step %.2f deg | fit residual %.1f deg | t* err %+.1f ms" % [
		frac, grid_old, grid_new, residual, (t_est - P_USTAR) * 1000.0])
	check(grid_new <= 2.0,
		"P %.2f: SUB-STEP grid-placement error %.2f deg <= 2 deg gate" % [frac, grid_new])
	check(grid_old >= 8.0,
		"P %.2f: legacy grid-placement error %.1f deg shows the disease" % [frac, grid_old])
	check(absf(t_est - P_USTAR) <= 0.004,
		"P %.2f: curved-ramp crossing recovered within 4 ms (err %+.1f ms)" % [
			frac, (t_est - P_USTAR) * 1000.0])
	check(residual < 30.0,
		"P %.2f: fit residual vs analytic at t* is %.1f deg (pre-existing smoothing, reported not gated)" % [
			frac, residual])


# ============================================================
# Real data: continuity of the fitted read
# ============================================================

func recorded_samples(rec: Dictionary) -> Array:
	var out: Array = []
	var smps: Array = rec.get("samples", [])
	for raw: Variant in smps:
		var s: Dictionary = raw
		var p: Array = s["p"]
		var q: Array = s["q"]
		var o: Array = s.get("o", [0.0, 0.0, 0.0])
		out.append(ThrowMath.make_sample(
			float(s["t"]),
			Vector3(float(p[0]), float(p[1]), float(p[2])),
			Quaternion(float(q[0]), float(q[1]), float(q[2]), float(q[3])),
			Vector3(float(o[0]), float(o[1]), float(o[2]))))
	return out


func test_real_data_continuity() -> void:
	var path: String = "/home/hatch/workspace/user/files/throws-12.jsonl"
	if not FileAccess.file_exists(path):
		print("SKIP  real-data continuity (throws-12.jsonl not on this machine)")
		return
	var text: String = FileAccess.get_file_as_string(path)
	var throws: Array = []
	for line: String in text.split("\n"):
		if line.strip_edges() == "":
			continue
		var parsed: Variant = JSON.parse_string(line)
		if parsed is Dictionary:
			var rec: Dictionary = parsed
			if String(rec.get("type", "")) == "throw" and String(rec.get("hand", "")) == "R":
				var smps: Array = rec.get("samples", [])
				if smps.size() >= 14:
					throws.append(rec)
		if throws.size() >= 30:
			break
	check(throws.size() >= 10, "real data: %d of Chris's recorded throws loaded" % throws.size())
	var ms_deltas: Array = []
	var spreads_old: Array = []
	var spreads_new: Array = []
	for rec_v: Variant in throws:
		var rec: Dictionary = rec_v
		var samples: Array = recorded_samples(rec)
		if samples.size() < 14:
			continue
		var n: int = samples.size()
		var last: Dictionary = samples[n - 1]
		var t_last: float = float(last["t"])
		# Continuity: probe the fitted read every 1 ms across the
		# final 80 ms of the recorded motion.
		var prev_elev: float = -999.0
		var probe: float = t_last - 0.080
		while probe <= t_last - 0.004:
			var v: Vector3 = ThrowMath.velocity_at_time(samples, probe)
			if v.length() > 0.5:
				var e: float = elev_of(v)
				if prev_elev > -900.0:
					ms_deltas.append(absf(e - prev_elev))
				prev_elev = e
			probe += 0.001
		# Truncation spread of the LEGACY read: the same swing
		# "detected" at each of the last few polls - how much the
		# old answer moves when the poll phase moves. (The
		# sub-step read is NOT compared this way: across
		# truncations its bracket sits at a different TRUE
		# instant, and his hand really does rotate between them -
		# that difference is physics, not grid scatter.)
		var elevs_old: Array = []
		for j: int in range(n - 5, n):
			var buf: Array = samples.slice(0, j + 1)
			var ev_o: Dictionary = ThrowMath.evaluate_release_at(buf, Basis.IDENTITY, -1.0, false)
			var vo: Vector3 = ev_o["vel"]
			if vo.length() < 0.5:
				continue
			elevs_old.append(elev_of(vo))
		if elevs_old.size() >= 3:
			spreads_old.append(elevs_old.max() - elevs_old.min())
		# The sub-step read's own grid exposure: within the FINAL
		# bracket (one step), how far can the read move if the
		# interpolated crossing were wrong by the whole step?
		# Part P shows the interpolation is good to ~2 ms, so the
		# real cost is a small fraction of this envelope.
		var sa: Dictionary = samples[n - 2]
		var sb: Dictionary = samples[n - 1]
		var bracket_elevs: Array = []
		for fr: float in [0.0, 0.5, 1.0]:
			var t_at: float = float(sa["t"]) + fr * (float(sb["t"]) - float(sa["t"]))
			var vb: Vector3 = ThrowMath.velocity_at_time(samples, t_at)
			if vb.length() > 0.5:
				bracket_elevs.append(elev_of(vb))
		if bracket_elevs.size() == 3:
			spreads_new.append(bracket_elevs.max() - bracket_elevs.min())
	ms_deltas.sort()
	spreads_old.sort()
	spreads_new.sort()
	var med_ms: float = float(ms_deltas[ms_deltas.size() / 2]) if not ms_deltas.is_empty() else 99.0
	var med_old: float = float(spreads_old[spreads_old.size() / 2]) if not spreads_old.is_empty() else 0.0
	var med_new: float = float(spreads_new[spreads_new.size() / 2]) if not spreads_new.is_empty() else 99.0
	print("  real data: median 1 ms read step %.2f deg | legacy poll-truncation spread %.1f deg | sub-step whole-bracket envelope %.1f deg (medians over %d throws)" % [
		med_ms, med_old, med_new, spreads_old.size()])
	check(med_ms < 1.5,
		"real data: the fitted read is CONTINUOUS across steps (median %.2f deg per 1 ms probe)" % med_ms)
	check(med_new <= 10.0,
		"real data: even a WHOLE-STEP crossing error costs a median %.1f deg (<= 10) - and the interpolation is good to ~2 ms, not a whole step" % med_new)


# ============================================================
# Production path through main
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


## Gentle pendulum for the production path (positions near the
## court, a slow flat throw that settles quickly).
func prod_pos(u: float) -> Vector3:
	var th: float = -0.5 + 2.0 * u
	return Vector3(0.25, 1.95 - 0.62 * cos(th), -0.10 - 0.62 * sin(th))


func test_production_path() -> void:
	var rec_path: String = "user://bench_throws.jsonl"
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

	# A synthetic swing on the wall clock (the clock the grip
	# history and the sample buffer share in production).
	var base: float = float(Time.get_ticks_msec()) / 1000.0 - 0.40
	var frac: float = 0.05
	var t_star: float = base + 0.30 + frac * STEP
	var samples: Array = []
	for k: int in range(0, 25):
		var t: float = base + float(k) * STEP
		samples.append(ThrowMath.make_sample(
			t, prod_pos(t - base), Quaternion(Vector3.BACK, 5.0 * (t - base))))
	main.samples = samples
	# The grip bracket around t*: previous poll above the
	# threshold, detection poll below it (linear ramp -> the
	# interpolated crossing is exact).
	var t_prev: float = base + 0.30
	var t_now: float = base + 0.30 + STEP
	main._grip_hist = [
		{"t": t_prev, "g": grip_lin(t_prev - base, t_star - base)},
		{"t": t_now, "g": grip_lin(t_now - base, t_star - base)},
	]
	main._do_release()
	main.grab_state.reset()
	main.test_grip["R"] = 0.0
	check(String(main.state) == "FLYING", "production: sub-step release throws (state %s)" % String(main.state))
	check(String(main.release_cache.get("release_timing", "")) == "substep",
		"production: release cache marks the read 'substep'")
	check(absf(float(main.release_cache.get("substep_offset_ms", -1.0)) - frac * STEP * 1000.0) < 0.6,
		"production: recorded offset %.2f ms matches t*'s place in its step (%.2f ms)" % [
			float(main.release_cache.get("substep_offset_ms", -1.0)), frac * STEP * 1000.0])
	var bracket: Array = main.release_cache.get("grip_bracket", [])
	check(bracket.size() == 2 and float(bracket[0]) > GrabState.GRIP_OFF and float(bracket[1]) <= GrabState.GRIP_OFF,
		"production: recorded grip bracket straddles the threshold")
	var ev_expect: Dictionary = ThrowMath.evaluate_release_at(samples, Basis.IDENTITY, t_star, true)
	var expect_vel: Vector3 = ev_expect["vel"]
	var got_vel: Vector3 = main.release_cache.get("velocity", Vector3.ZERO)
	check(got_vel.distance_to(expect_vel) < 0.05,
		"production: release velocity is the fitted velocity AT t* (err %.3f m/s)" % got_vel.distance_to(expect_vel))
	var expect_tf: Transform3D = Transform3D(
		Basis(ThrowMath.orientation_at_time(samples, t_star)),
		ThrowMath.position_at_time(samples, t_star)) * main.rel_tf
	var got_pos: Vector3 = main.release_cache.get("release_pos", Vector3.ZERO)
	check(got_pos.distance_to(expect_tf.origin) < 0.01,
		"production: release position is the fitted position AT t* (err %.4f m)" % got_pos.distance_to(expect_tf.origin))

	# Let it settle: the recorder must carry the new fields.
	check(await wait_state("STAND", 25.0), "production: sub-step throw settles and restocks")
	var rec_text: String = FileAccess.get_file_as_string(rec_path)
	var found_sub: bool = false
	for line: String in rec_text.split("\n"):
		if line.strip_edges() == "":
			continue
		var parsed: Variant = JSON.parse_string(line)
		if parsed is Dictionary:
			var rec: Dictionary = parsed
			if String(rec.get("type", "")) == "throw" and String(rec.get("release_timing", "")) == "substep":
				found_sub = true
				var gb: Array = rec.get("grip_bracket", [])
				check(gb.size() == 2, "recorder: sub-step throw record carries the grip bracket")
				check(float(rec.get("substep_offset_ms", -1.0)) > 0.0,
					"recorder: sub-step throw record carries the offset (%.2f ms)" % float(rec.get("substep_offset_ms", -1.0)))
	check(found_sub, "recorder: a throw record with release_timing 'substep' was written")

	# Negative control through the production function: same
	# inputs, flag off -> the legacy grid read and a 'grid' mark.
	main.substep_release_enabled = false
	main._release_shoe(samples, t_star, {"offset_ms": frac * STEP * 1000.0, "grip_bracket": [0.9, 0.1]})
	main.grab_state.reset()
	check(String(main.release_cache.get("release_timing", "")) == "grid",
		"production NEGATIVE CONTROL: flag off marks the read 'grid'")
	var ev_legacy: Dictionary = ThrowMath.evaluate_release_at(samples, Basis.IDENTITY, -1.0, false)
	var legacy_vel: Vector3 = ev_legacy["vel"]
	var grid_vel: Vector3 = main.release_cache.get("velocity", Vector3.ZERO)
	check(grid_vel.distance_to(legacy_vel) < 0.0001,
		"production NEGATIVE CONTROL: flag off reproduces the legacy velocity (err %.5f)" % grid_vel.distance_to(legacy_vel))
	main.substep_release_enabled = true
	await wait_state("STAND", 25.0)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(rec_path))


func _init() -> void:
	_run()


func _run() -> void:
	print("--- Fix Pass 14 bench: sub-step release timing ---")
	test_crossing_time()
	for raw_f: Variant in OFFSETS:
		test_q_row(float(raw_f))
	p_build_table()
	for raw_f2: Variant in OFFSETS:
		test_p_row(float(raw_f2))
	test_real_data_continuity()
	await test_production_path()
	print("---")
	if failures == 0:
		print("SUBSTEP BENCH: ALL %d CHECKS PASSED" % checks)
	else:
		print("SUBSTEP BENCH: %d of %d CHECKS FAILED" % [failures, checks])
	quit(1 if failures > 0 else 0)
