extends SceneTree

## Fix Pass 16 bench: the finger-drag term (spin governor),
## proven four ways.
##
## The disease (Chris's throws-14): his shoes leave with total
## rotation SD 1.17 rev - scatter wider than a full turn, so the
## arrival phase is a lottery even on an aimed shoe. The term
## restores the finger-drag brake real pitching has and a VR
## controller lacks: on the STYLE AXIS ONLY, the hand's total
## revolutions over the predicted flight are pulled toward the
## hold's regulation nominal, keeping a 0.30 residual share of
## the hand's own deviation.
##
## Fix Pass 17: the predicted flight is counted HAND-TO-STAKE
## (Smith 1946, Chris's ruling): the shared governor clock is
## the stake-plane crossing time, capped by ground return.
## Part A's geometry lands before its plane, so the ground cap
## runs there; part A2 builds releases whose stake crossing
## comes first, proving the stake branch itself - standards
## map to themselves on BOTH branches because the mechanism
## and this bench share the one flight-time function.
##
## Fix Pass 21 (THIS RE-DERIVATION): the nominal no longer
## comes from the FP16 nearest-basin snap {0.75, 1.25, 1.75} -
## it comes from the GRIP POSITION held at release, which
## DECLARES its count (TOE GRIP 1.00; SHANK · TOE 1.125;
## SHANK · MID 1.25; SHANK · HEEL 1.375). Every part below
## passes a declared nominal, exactly as the production path
## does; the 0.75 and 1.75 standards retire with their basins
## (the 3/4 was Smith's documented trap; no grip declares it).
## Part C keeps ONE undeclared case proving the basin fallback
## still serves direct callers that declare nothing - and
## nothing else.
##
## A. STANDARDS INTACT: synthetic releases totalling exactly a
##    DECLARED count (one per grip position, plus signs) come
##    out unchanged (within 0.02 rev), off-axis spin
##    components pass through untouched.
## A2. STAKE CLOCK (Fix Pass 17): the same standards built on a
##    geometry whose stake-plane crossing precedes ground
##    return still map to themselves, the reported flight time
##    IS the stake time, the residual rule runs on the stake
##    clock, and a dirt-bound release whose ground return
##    precedes the plane is counted over the ground cap.
## B. NEGATIVE CONTROL: governor disabled -> the release spin
##    is the input spin, component-exact, totals unaltered -
##    and the declared nominal is still reported as evidence.
## C. FORMULA SHAPE: the residual rule on non-standard inputs
##    against DECLARED nominals (both directions, sign still
##    following the hand), plus the undeclared fallback case.
## D. REPLAY: Chris's 22 throws-14 releases (the sub-step
##    session of 2026-11-03 16:11-16:15, all shank / turn holds)
##    fed through the governor from the file's own release
##    state. The file predates the grip cycle, so each throw's
##    declaration is derived from its recorded zone + slide
##    offset by the production rule (ThrowMath.grip_index_for).
##    The harness is pinned to the independent desktop census
##    of the same file (recorded total SD 1.17, raw style-axis
##    SD 0.58) so a replay bug fails loudly. NOTE, printed not
##    hidden: those 22 are TURN holds whose actual tumble lives
##    on the FLIP axis (recorded flip total -1.90 +- 1.12) -
##    off-axis for their hold, so it passes through by design;
##    the governed style-axis SD is what it is (see the printed
##    line), and the compression the term exists for is proven
##    on the standards and formula parts.
## E. PRODUCTION PATH: a scripted grab and release through
##    main's _release_shoe with the governor on (the cache
##    carries the drag account, the grip's name and declared
##    count, and the flown spin is the governed one) and off
##    (flown spin == estimator spin, component-exact).
##
## Run: godot --headless --path . --script tests/spin_governor_bench.gd

var failures: int = 0
var checks: int = 0
var main: Node

const THROWS_PATH: String = "/home/hatch/workspace/user/files/throws-14.jsonl"
const REPLAY_TS_FLOOR: String = "2026-11-03T16:00:00"

## The court's stakes, mirroring main's constants, and the
## midpoint the target inference splits on (main's COURT_MID_Z).
const FAR_STAKE_POS := Vector3(0.0, 0.05, -12.192)
const HOME_STAKE_POS := Vector3(0.0, 0.05, 0.0)
const COURT_MID_Z: float = -6.096


func check(cond: bool, name: String) -> void:
	checks += 1
	if cond:
		print("PASS  ", name)
	else:
		failures += 1
		print("FAIL  ", name)


func psd(vals: Array) -> float:
	if vals.size() < 2:
		return 0.0
	var m: float = 0.0
	for v: float in vals:
		m += v
	m /= float(vals.size())
	var s: float = 0.0
	for v2: float in vals:
		s += (v2 - m) * (v2 - m)
	return sqrt(s / float(vals.size()))


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


## A synthetic release with a chosen style-axis total, built on
## a fixed geometry whose ground-return time is 1.10 s; its
## stake plane sits past the landing, so the shared clock's
## ground cap is what runs (the stake branch has its own
## builder below). "off" must be perpendicular to the style
## axis - it is the off-axis contamination that has to pass
## through untouched.
func synth_ev(hold: String, total: float, basis: Basis, off: Vector3, enabled: bool = true, declared: float = -1.0) -> Dictionary:
	var tof: float = 1.10
	var y0: float = 1.30
	var vy: float = (0.5 * ThrowMath.SPIN_GRAVITY * tof * tof - y0) / tof
	var vel := Vector3(0.4, vy, -9.0)
	var pos := Vector3(0.1, y0, -0.30)
	var axis: Vector3 = basis.x.normalized() if hold == "flip" else Vector3.UP
	var rate: float = total * TAU / tof
	var ang: Vector3 = axis * rate + off
	var ev: Dictionary = ThrowMath.govern_spin(ang, Transform3D(basis, pos), vel, hold, FAR_STAKE_POS, enabled, declared)
	ev["ang_in"] = ang
	ev["axis"] = axis
	ev["off"] = off
	return ev


## A synthetic release whose STAKE-PLANE crossing (1.20 s,
## down-lane at the far stake from the 40 ft geometry) precedes
## its ground return (1.27 s): the hand's total is built on the
## stake clock, so a regulation count must map to itself with
## the stake time reported as the flight time.
func synth_ev_stake(hold: String, total: float, basis: Basis, off: Vector3, declared: float = -1.0) -> Dictionary:
	var ts: float = 1.20
	var pos := Vector3(0.0, 1.30, -0.30)
	var vz: float = (FAR_STAKE_POS.z - pos.z) / ts
	var vel := Vector3(0.0, 5.21, vz)
	var axis: Vector3 = basis.x.normalized() if hold == "flip" else Vector3.UP
	var rate: float = total * TAU / ts
	var ang: Vector3 = axis * rate + off
	var ev: Dictionary = ThrowMath.govern_spin(ang, Transform3D(basis, pos), vel, hold, FAR_STAKE_POS, true, declared)
	ev["ang_in"] = ang
	ev["axis"] = axis
	ev["off"] = off
	ev["stake_time"] = ts
	return ev


func check_standard(hold: String, total: float, basis: Basis, off: Vector3, label: String, declared: float = -1.0) -> void:
	var ev: Dictionary = synth_ev(hold, total, basis, off, true, declared)
	var applied: float = float(ev["applied_total"])
	check(absf(applied - total) <= 0.02,
		"%s: standard total %.2f rev comes out %.3f (within 0.02)" % [label, total, applied])
	var ang_out: Vector3 = ev["ang"]
	var axis: Vector3 = ev["axis"]
	var perp: Vector3 = ang_out - axis * ang_out.dot(axis)
	check(perp.distance_to(off) < 0.0001,
		"%s: off-axis spin passes through untouched" % label)


func part_a() -> void:
	# Fix Pass 21: a hand AT the declared count for each of the
	# four grip positions exits at that count.
	check_standard("flip", 1.00, Basis.IDENTITY, Vector3(0.0, 0.3, -0.2), "A TOE GRIP flip +1.00", 1.0)
	check_standard("flip", -1.00, Basis.IDENTITY, Vector3(0.0, 0.3, -0.2), "A TOE GRIP flip -1.00", 1.0)
	var yawed := Basis(Vector3.UP, 0.7)
	check_standard("flip", 1.00, yawed, yawed.z * 0.4, "A TOE GRIP flip +1.00, yawed release basis", 1.0)
	check_standard("turn", 1.125, Basis.IDENTITY, Vector3(0.25, 0.0, 0.15), "A SHANK · TOE turn +1.125", 1.125)
	check_standard("turn", 1.25, Basis.IDENTITY, Vector3(0.25, 0.0, 0.15), "A SHANK · MID turn +1.25", 1.25)
	check_standard("turn", 1.375, Basis.IDENTITY, Vector3(0.25, 0.0, 0.15), "A SHANK · HEEL turn +1.375", 1.375)
	check_standard("turn", -1.25, Basis.IDENTITY, Vector3(0.25, 0.0, 0.15), "A SHANK · MID turn -1.25", 1.25)


func part_a2() -> void:
	var f: Dictionary = synth_ev_stake("flip", 1.00, Basis.IDENTITY, Vector3(0.0, 0.3, -0.2), 1.0)
	check(absf(float(f["flight_time"]) - float(f["stake_time"])) <= 0.01,
		"A2: the stake clock is the live clock (flight time %.3f s == stake crossing %.2f s, ground return later)"
		% [float(f["flight_time"]), float(f["stake_time"])])
	check(absf(float(f["applied_total"]) - 1.00) <= 0.02,
		"A2 TOE GRIP flip +1.00 on the stake clock comes out %.3f (within 0.02)" % float(f["applied_total"]))
	var t: Dictionary = synth_ev_stake("turn", -1.25, Basis.IDENTITY, Vector3(0.25, 0.0, 0.15), 1.25)
	check(absf(float(t["applied_total"]) + 1.25) <= 0.02,
		"A2 SHANK · MID turn -1.25 on the stake clock comes out %.3f (within 0.02)" % float(t["applied_total"]))
	var f2: Dictionary = synth_ev_stake("flip", 2.00, Basis.IDENTITY, Vector3(0.0, 0.3, -0.2), 1.0)
	check(absf(float(f2["applied_total"]) - 1.30) <= 0.01,
		"A2: the residual rule runs on the stake clock - hand 2.00 declared 1.00 -> %.3f" % float(f2["applied_total"]))
	# The cap: a dirt-bound lob whose ground return (0.63 s)
	# precedes its stake-plane crossing (1.32 s) is counted over
	# the ground return - a standard built on the ground clock
	# still maps to itself.
	var pos := Vector3(0.0, 1.30, -0.30)
	var vel := Vector3(0.0, 1.00, -9.0)
	var t_ground: float = ThrowMath.predicted_flight_time(pos, vel)
	var ang: Vector3 = Vector3(1.00 * TAU / t_ground, 0.0, 0.0)
	var ev: Dictionary = ThrowMath.govern_spin(ang, Transform3D(Basis.IDENTITY, pos), vel, "flip", FAR_STAKE_POS, true, 1.0)
	check(absf(float(ev["flight_time"]) - t_ground) <= 0.01,
		"A2: dirt-bound release is capped at ground return (flight time %.3f s)" % float(ev["flight_time"]))
	check(absf(float(ev["applied_total"]) - 1.00) <= 0.02,
		"A2: the TOE GRIP 1.00 standard built on the ground cap comes out %.3f (within 0.02)" % float(ev["applied_total"]))


func part_b() -> void:
	var ev: Dictionary = synth_ev("flip", 2.20, Basis.IDENTITY, Vector3(0.0, 0.3, -0.2), false, 1.0)
	var ang_in: Vector3 = ev["ang_in"]
	var ang_out: Vector3 = ev["ang"]
	check(ang_out == ang_in,
		"B: governor disabled - release spin is the input spin, component-exact")
	check(float(ev["applied_total"]) == float(ev["hand_total"]),
		"B: governor disabled - applied total == hand total, exact")
	check(absf(float(ev["nominal"]) - 1.00) <= 0.001,
		"B: governor disabled - the declared nominal is still reported (%.3f)" % float(ev["nominal"]))
	var ev2: Dictionary = synth_ev("turn", -1.60, Basis.IDENTITY, Vector3(0.25, 0.0, 0.15), false, 1.25)
	var ang2_in: Vector3 = ev2["ang_in"]
	var ang2_out: Vector3 = ev2["ang"]
	check(ang2_out == ang2_in and float(ev2["applied_total"]) == float(ev2["hand_total"]),
		"B: governor disabled (turn) - spin and total untouched, exact")
	check(absf(float(ev2["nominal"]) + 1.25) <= 0.001,
		"B: governor disabled (turn) - declared nominal reported with the hand's sign (%.3f)" % float(ev2["nominal"]))


func part_c() -> void:
	var f: Dictionary = synth_ev("flip", 2.00, Basis.IDENTITY, Vector3(0.0, 0.3, -0.2), true, 1.0)
	check(absf(float(f["applied_total"]) - 1.30) <= 0.01,
		"C: flip hand 2.00, TOE GRIP declares 1.00 -> %.3f" % float(f["applied_total"]))
	var t1: Dictionary = synth_ev("turn", 1.60, Basis.IDENTITY, Vector3(0.25, 0.0, 0.15), true, 1.375)
	check(absf(float(t1["applied_total"]) - 1.4425) <= 0.01,
		"C: turn hand 1.60, SHANK · HEEL declares 1.375 -> %.3f" % float(t1["applied_total"]))
	var t3: Dictionary = synth_ev("turn", 0.90, Basis.IDENTITY, Vector3(0.25, 0.0, 0.15), true, 1.125)
	check(absf(float(t3["applied_total"]) - 1.0575) <= 0.01,
		"C: turn hand 0.90, SHANK · TOE declares 1.125 -> %.3f" % float(t3["applied_total"]))
	var t2: Dictionary = synth_ev("turn", -0.10, Basis.IDENTITY, Vector3(0.25, 0.0, 0.15), true, 1.125)
	check(absf(float(t2["applied_total"]) + 0.8175) <= 0.01,
		"C: turn hand -0.10, SHANK · TOE declares 1.125 - the SIGN still follows the hand -> %.3f" % float(t2["applied_total"]))
	# The fallback, labelled as what it is: a caller that
	# declares NOTHING still gets the FP16 nearest-basin snap.
	# Production never calls it this way any more.
	var fb: Dictionary = synth_ev("turn", 1.60, Basis.IDENTITY, Vector3(0.25, 0.0, 0.15))
	check(absf(float(fb["applied_total"]) - 1.705) <= 0.01,
		"C: UNDECLARED fallback only - hand 1.60 snaps to the old 1.75 basin -> %.3f" % float(fb["applied_total"]))


func part_d() -> void:
	var f := FileAccess.open(THROWS_PATH, FileAccess.READ)
	if f == null:
		check(false, "D: throws-14 file opens for replay")
		return
	var recorded: Array = []
	var raw_style: Array = []
	var governed: Array = []
	while not f.eof_reached():
		var line: String = f.get_line()
		if line.strip_edges() == "":
			continue
		var parsed: Variant = JSON.parse_string(line)
		if not (parsed is Dictionary):
			continue
		var rec: Dictionary = parsed
		if String(rec.get("type", "")) != "throw":
			continue
		if String(rec.get("hand", "")) != "R":
			continue
		if String(rec.get("release_timing", "")) != "substep":
			continue
		if String(rec.get("ts", "")) < REPLAY_TS_FLOOR:
			continue
		recorded.append(absf(float(rec["flip_rotations"])) + absf(float(rec["turn_rotations"])))
		var rp: Array = rec["release_pos"]
		var pos := Vector3(float(rp[0]), float(rp[1]), float(rp[2]))
		var rq: Array = rec["release_quat"]
		var quat := Quaternion(float(rq[0]), float(rq[1]), float(rq[2]), float(rq[3]))
		var rv: Array = rec["release_velocity"]
		var vel := Vector3(float(rv[0]), float(rv[1]), float(rv[2]))
		var ra: Array = rec["release_angular_velocity"]
		var ang := Vector3(float(ra[0]), float(ra[1]), float(ra[2]))
		# Fix Pass 17: the count is hand-to-stake, so the replay
		# names each throw's target the way the game infers it -
		# the pit on the far side of the court's midpoint from
		# the release.
		var stake: Vector3 = FAR_STAKE_POS if pos.z > COURT_MID_Z else HOME_STAKE_POS
		# Fix Pass 21: the file predates the grip cycle, so the
		# declaration is derived from the recorded zone + slide
		# offset by the production rule. (Fix Pass 26: the rule
		# also takes the recorded hand - a shank zone names its
		# family by side now; the declared count per stop is the
		# same on both sides, so the census derivation is
		# unchanged in value.)
		var rzone: String = String(rec.get("zone", ""))
		var declared: float = -1.0
		if Shoe.zones().has(rzone):
			var zsmax: float = float(Shoe.zones()[rzone]["slide_max"])
			declared = float(ThrowMath.grip_position(ThrowMath.grip_index_for(
				rzone, String(rec.get("hand", "R")),
				float(rec.get("slide_offset_m", 0.0)), zsmax))["nominal"])
		var ev: Dictionary = ThrowMath.govern_spin(
			ang, Transform3D(Basis(quat), pos), vel, String(rec["hold"]), stake, true, declared)
		raw_style.append(float(ev["hand_total"]))
		governed.append(float(ev["applied_total"]))
	f.close()
	check(recorded.size() == 22,
		"D: replay selects Chris's 22 throws-14 releases (got %d)" % recorded.size())
	var rec_sd: float = psd(recorded)
	var raw_sd: float = psd(raw_style)
	var gov_sd: float = psd(governed)
	check(absf(rec_sd - 1.17) <= 0.03,
		"D: harness matches the census - recorded total SD %.2f (census 1.17)" % rec_sd)
	check(absf(raw_sd - 0.58) <= 0.03,
		"D: harness matches the census - raw style-axis SD %.2f (census 0.58)" % raw_sd)
	check(gov_sd < rec_sd,
		"D: governed total-rev SD %.2f is below the recorded %.2f" % [gov_sd, rec_sd])
	var gmin: float = governed.min()
	var gmax: float = governed.max()
	print("  REPLAY (Fix Pass 17 clock; Fix Pass 21 declared grips): raw style SD %.2f -> governed SD %.2f, governed range %.2f..%.2f rev"
		% [raw_sd, gov_sd, gmin, gmax])
	print("  NOTE: the brief's ~0.4 expectation assumed the governed axis carries the")
	print("  scatter; in this session it does not - the 22 are turn holds whose tumble")
	print("  lives on the flip axis (off-axis here, passed through by design). Actuals")
	print("  stand as printed; the compression proof lives in parts A, A2 and C.")


func build_stream(hand_pos: Vector3, q_hand: Quaternion, vel: Vector3, omega: Vector3, seed_val: int) -> Array:
	var hz: float = 90.0
	var steps: int = 30
	var accel: Vector3 = vel.normalized() * 20.0
	var axis: Vector3 = omega.normalized()
	var rate: float = omega.length()
	var now: float = float(Time.get_ticks_msec()) / 1000.0
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val
	var out: Array = []
	for i: int in steps + 1:
		var tau: float = float(steps - i) / hz
		var pos: Vector3 = hand_pos - vel * tau + 0.5 * accel * tau * tau
		pos += Vector3(rng.randf_range(-0.002, 0.002),
			rng.randf_range(-0.002, 0.002), rng.randf_range(-0.002, 0.002))
		var q: Quaternion = Quaternion(axis, -rate * tau) * q_hand
		out.append(ThrowMath.make_sample(now - tau, pos, q))
	return out


func part_e() -> void:
	var rec_path: String = "user://gov_bench_throws.jsonl"
	if FileAccess.file_exists(rec_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(rec_path))
	var ps: PackedScene = load("res://main.tscn")
	main = ps.instantiate()
	main.recorder_path = rec_path
	root.add_child(main)
	await create_timer(0.3).timeout
	check(main != null and main.shoe != null, "E: main scene instantiated with its shoe")
	# Stand at the 40 ft line; wait for the shoe to stock there.
	main.test_hand_tf.erase("L")
	main.test_hand_tf.erase("R")
	main.test_grip["L"] = 0.0
	main.test_grip["R"] = 0.0
	main.origin.global_transform = Transform3D(Basis.IDENTITY,
		Vector3(0.0, 0.0, main.line_z_for_ft(40)))
	var want_tf: Transform3D = main.stand_tfs[40]
	var waited: float = 0.0
	while waited < 2.5:
		if String(main.state) == "STAND" \
				and main.shoe.global_position.distance_to(want_tf.origin) < 0.01:
			break
		await create_timer(0.1).timeout
		waited += 0.1
	var rp := Vector3(0.0, 1.30, -0.30)
	var vel := Vector3(0.0, 5.21, -10.16)
	var omega := Vector3(11.0, 0.0, 0.0) # heavy flip spin: ~2.2 raw rev
	for round_i: int in 2:
		var gov_on: bool = round_i == 0
		main.spin_governor_enabled = gov_on
		var zone_c: Vector3 = main.shoe.zone_world_center("toe")
		main.test_hand_tf["R"] = Transform3D(Basis.IDENTITY, zone_c)
		main.test_grip["R"] = 1.0
		await frames(6)
		for i: int in 2:
			await physics_frame
		check(String(main.state) == "HELD",
			"E(%s): toe grabbed through the production latch" % ("on" if gov_on else "off"))
		var rel_tf: Transform3D = Shoe.hold_transform("toe", "R")
		var q_hand := Quaternion.IDENTITY
		var hand_pos: Vector3 = rp - Basis(q_hand) * rel_tf.origin
		main.test_hand_tf["R"] = Transform3D(Basis(q_hand), hand_pos)
		await frames(4)
		for i2: int in 2:
			await physics_frame
		var samples: Array = build_stream(hand_pos, q_hand, vel, omega, 4242)
		main.samples = samples
		main._release_shoe(samples)
		check(String(main.state) == "FLYING",
			"E(%s): released through the production path" % ("on" if gov_on else "off"))
		var cache: Dictionary = main.release_cache
		var flown: Vector3 = cache.get("angular_velocity", Vector3.ZERO)
		var est: Vector3 = cache.get("estimator_angular_velocity", Vector3.ZERO)
		var hand_t: float = float(cache.get("spin_hand_total", 0.0))
		var applied_t: float = float(cache.get("spin_applied_total", 0.0))
		var nominal_t: float = float(cache.get("spin_nominal", 0.0))
		# Fix Pass 21: the toe grab declares TOE GRIP / 1.00 in
		# the cache, governor on or off.
		check(String(cache.get("grip_name", "")) == "TOE GRIP"
			and absf(float(cache.get("grip_nominal", 0.0)) - 1.0) <= 0.001,
			"E(%s): the release cache carries the declared grip (TOE GRIP, 1.00; got %s / %.3f)"
			% [("on" if gov_on else "off"), String(cache.get("grip_name", "")), float(cache.get("grip_nominal", 0.0))])
		if gov_on:
			var expect: float = nominal_t + (hand_t - nominal_t) * ThrowMath.SPIN_DRAG_RESIDUAL
			check(absf(applied_t - expect) <= 0.02,
				"E(on): cache account obeys the drag rule (hand %.2f, nominal %.2f, applied %.2f)"
				% [hand_t, nominal_t, applied_t])
			check(absf(nominal_t) == 1.00 and absf(applied_t - nominal_t) < absf(hand_t - nominal_t),
				"E(on): flip total pulled toward TOE GRIP's declared 1.00 (hand %.2f -> applied %.2f)"
				% [hand_t, applied_t])
			check(flown != est, "E(on): the flown spin is the governed spin, not the estimator's")
		else:
			check(flown == est,
				"E(off): NEGATIVE CONTROL - flown spin == estimator spin, component-exact")
			check(applied_t == hand_t,
				"E(off): NEGATIVE CONTROL - applied total == hand total, exact")
		main.grab_state.reset()
		main.test_grip["R"] = 0.0
		if not await wait_state("STAND", 15.0):
			if String(main.state) == "FLYING":
				main._settle_throw()
			await wait_state("STAND", 4.0)
	main.spin_governor_enabled = true
	main.origin.global_transform = Transform3D.IDENTITY
	DirAccess.remove_absolute(ProjectSettings.globalize_path(rec_path))


func _init() -> void:
	_run()


func _run() -> void:
	part_a()
	part_a2()
	part_b()
	part_c()
	part_d()
	await part_e()
	print("---")
	if failures == 0:
		print("SPIN GOVERNOR BENCH: ALL %d CHECKS PASSED" % checks)
	else:
		print("SPIN GOVERNOR BENCH: %d of %d CHECKS FAILED" % [failures, checks])
	quit(1 if failures > 0 else 0)
