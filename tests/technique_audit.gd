extends SceneTree

## Technique envelope audit (Fix Pass 9, PERMANENT suite).
##
## Chris's requirement (2026-11-02): "make sure our physics
## release allows people the different techniques, whatever they
## are." The release is 1:1 - no assist, no canned spin - so this
## suite scripts each REAL pitching technique as a synthetic hand
## stream, fires it through the PRODUCTION estimator + physics
## (the same _release_shoe path a real hand takes, the FP8 smoke
## pattern), and judges the technique on ARRIVAL: the planned
## rotation count completed (the recorder's own flip/turn
## accounting, snapshotted at stake contact / stake-plane
## crossing) and the shoe's opening facing the stake.
##
## The techniques (grip literature: Roy W. Smith via NHPA /
## keskinen.org; horseshoeamerica coaches' corner):
##   FLIP      - one full end-over-end revolution. Toe hold. The
##               scripted spin sign matches Chris's real throws
##               (throws-8/9/10: release omega about +X, recorder
##               flip total negative, |omega| ~10-12 rad/s).
##   TURN 3/4  - flat spin, 0.75 rev. Shank hold, "hooks up" grip
##               phase (release phase pi in this fixture).
##   TURN 1-1/4 - THE FRANCIS CASE: flat spin, lazy ~1 rev/s,
##               1.25 rev, the most common grip in the game.
##   TURN 1-3/4 - flat spin, 1.75 rev, hooks-up phase.
##   REVERSE 1-1/4 - opposite yaw sign, mirrored (left) hand.
##
## Hold geometry (asserted by the logic suite): the R-hand turn
## hold leaves the shoe's opening pointing -X at release, the
## L-hand hold +X. The spin SIGN that brings the opening onto
## the stake is NEGATIVE yaw for the R-hand hold (mirrored:
## positive for the L-hand reverse), with grip phase 0 for the
## 1-1/4 and phase pi for the "hooks up" 3/4 and 1-3/4. This
## was settled by the APPROACH measurement (see
## approach_snapshot): an early version of this suite measured
## the opening at the crossing poll, where the direction to
## the stake collapses to a near-zero vector and the readings
## were confident garbage that briefly "proved" the opposite
## sign. The wrong-sign CONTROL below guards the convention:
## same case, flipped spin, the opening must arrive facing
## AWAY. (Chris's handful of recorded turn attempts total
## +0.24 rev mean - at that size they are wrist noise, not a
## technique, and say nothing about the convention either way.)
##
## Tolerances (stated per the pass-9 brief): arrived rotation
## within +/-0.15 rev of plan; opening within 30 deg of the
## direction to the stake; estimator bias in the pass-1 order
## (velocity 0.35 m/s under jitter; angular 0.30 rad/s on a clean
## quaternion stream); free-flight spin axis deviation (wobble)
## within 12 deg; spin retention at arrival >= 95% of imparted.
## "Arrival" = stake contact or stake-plane crossing; a first
## contact within 0.30 m short of the plane (sliding in) also
## counts - a landing well short does not.
##
## FIRST RUN FINDING (the reason Shoe pins its damping to zero):
## the shoe had silently inherited the physics space's default
## 0.1 linear + angular damp - spin bled ~10%/s in free flight
## and throws landed ~1 m short of their own ballistic line.
## No technique can be calibrated against an unnamed engine
## default, so the shoe now flies ballistic with preserved spin.
##
## Run: godot --headless --path . --script tests/technique_audit.gd

var failures: int = 0
var checks: int = 0
var main: Node
var stake_body: StaticBody3D = null
var stake_hit_flag: bool = false

const GRAV: float = 9.8
const FLIGHT_T_40: float = 1.20 # planned stake-plane arrival, 40 ft cases
const FLIGHT_T_30: float = 0.95 # planned arrival, 30 ft flip


func check(cond: bool, name: String) -> void:
	checks += 1
	if cond:
		print("PASS  ", name)
	else:
		failures += 1
		print("FAIL  ", name)


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


func find_stake() -> void:
	for child: Node in main.get_children():
		if child is Node3D and (child as Node3D).position.distance_to(main.STAKE_POS) < 0.001:
			for sub: Node in child.get_children():
				if sub is StaticBody3D:
					stake_body = sub as StaticBody3D


func _on_shoe_body_entered(body: Node) -> void:
	if body == stake_body:
		stake_hit_flag = true


## Z of the (leaning) stake axis at world height y: the stake
## leans 8 deg toward the pitcher about its pivot at STAKE_POS.
func axis_z_at(y: float) -> float:
	var sp: Vector3 = main.STAKE_POS
	return sp.z + (y - sp.y) * tan(deg_to_rad(8.0))


## Ballistic release velocity for a shoe released at release_pos
## that crosses the stake plane after t_f seconds at height 0.50,
## straight down the lane. The height carries margin: the pass-1
## estimator's jitter bias (up to ~-0.10 vy / +0.19 vz on these
## streams) costs up to ~0.28 m of arrival height, and a flip
## that grazes the pit on its way in has its arrival disturbed -
## 0.50 planned lands the shoe in the stake band after bias.
func ballistic_vel(release_pos: Vector3, t_f: float) -> Vector3:
	var sp: Vector3 = main.STAKE_POS
	var vz: float = (sp.z - release_pos.z) / t_f
	var vy: float = (0.50 - release_pos.y + 0.5 * GRAV * t_f * t_f) / t_f
	return Vector3(0.0, vy, vz)


## The synthetic hand stream: an accelerating swing (quadratic
## position profile, peak speed exactly at the release instant,
## the shape the pass-1 estimator was validated on), sampled at
## 90 Hz with 2 mm seeded position jitter, carrying a constant
## spin about a fixed world axis that reaches q_hand exactly at
## release. Timestamps are honest: the stream ends "now", exactly
## as the production sampler would have buffered it.
func build_stream(hand_pos: Vector3, q_hand: Quaternion, vel: Vector3,
		omega: Vector3, seed_val: int) -> Array:
	var hz: float = 90.0
	var steps: int = 30 # 0.333 s of swing
	var accel: Vector3 = vel.normalized() * 20.0
	var axis: Vector3 = omega.normalized()
	var rate: float = omega.length()
	var now: float = float(Time.get_ticks_msec()) / 1000.0
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val
	var out: Array = []
	for i: int in steps + 1:
		var tau: float = float(steps - i) / hz # seconds before release
		var pos: Vector3 = hand_pos - vel * tau + 0.5 * accel * tau * tau
		pos += Vector3(rng.randf_range(-0.002, 0.002),
			rng.randf_range(-0.002, 0.002), rng.randf_range(-0.002, 0.002))
		var q: Quaternion = Quaternion(axis, -rate * tau) * q_hand
		out.append(ThrowMath.make_sample(now - tau, pos, q))
	return out


## Opening error in degrees: angle between the shoe's opening
## direction (local +Z, the open end) and the direction from the
## shoe to the stake axis at the shoe's height.
func opening_error(pos: Vector3) -> float:
	var od: Vector3 = main.shoe.global_transform.basis * Vector3(0.0, 0.0, 1.0)
	var sp: Vector3 = main.STAKE_POS
	var stake_pt := Vector3(sp.x, pos.y, axis_z_at(pos.y))
	var d: Vector3 = stake_pt - pos
	if d.length() < 0.03:
		return rad_to_deg(od.angle_to(Vector3(0.0, 0.0, -1.0)))
	return rad_to_deg(od.angle_to(d.normalized()))


func flight_snapshot(how: String, spin_len: float) -> Dictionary:
	var p: Vector3 = main.shoe.global_position
	return {
		"how": how,
		"flip": float(main.flip_rot),
		"turn": float(main.turn_rot),
		"open_err": opening_error(p),
		"av_len": spin_len,
		"t": float(main._fly_time),
		"z": p.z,
		"axis_z": axis_z_at(p.y),
	}


## The approach snapshot: the shoe's state while it is still
## short of the stake and contact-free, PROJECTED forward to the
## stake plane by its own velocity and spin. Judging from the
## arrival poll instead reads the shoe one step AFTER it has
## clipped the stake - a post-impact tumble, not the arrival the
## pitcher controlled (the first version of this suite measured
## a 180 deg "opening error" on a 3/4 turn whose phase was exact:
## the shoe had already clanged and flipped). Projection error
## over the remaining ~0.2 m is ~0.03 rev / ~10 deg at the
## fastest spin in the suite, inside the stated tolerances.
func approach_snapshot() -> Dictionary:
	var shoe_node: RigidBody3D = main.shoe
	var p: Vector3 = shoe_node.global_position
	var lv: Vector3 = shoe_node.linear_velocity
	var av: Vector3 = shoe_node.angular_velocity
	var basis: Basis = shoe_node.global_transform.basis
	var dist: float = p.z - axis_z_at(p.y)
	var dt: float = dist / maxf(0.5, -lv.z) if lv.z < -0.5 else 0.0
	var dflip: float = av.dot(basis.x.normalized()) / TAU * dt
	var dturn: float = av.y / TAU * dt
	var od: Vector3 = basis * Vector3(0.0, 0.0, 1.0)
	if av.length() > 0.1 and dt > 0.0:
		od = od.rotated(av.normalized(), av.length() * dt)
	var sp: Vector3 = main.STAKE_POS
	var stake_pt := Vector3(sp.x, p.y, axis_z_at(p.y))
	var d: Vector3 = stake_pt - p
	var err: float = rad_to_deg(od.angle_to(Vector3(0.0, 0.0, -1.0))) \
		if d.length() < 0.03 else rad_to_deg(od.angle_to(d.normalized()))
	return {
		"how": "approach, projected to the plane",
		"flip": float(main.flip_rot) + dflip,
		"turn": float(main.turn_rot) + dturn,
		"open_err": err,
		"av_len": av.length(),
		"t": float(main._fly_time) + dt,
		"z": p.z,
		"axis_z": axis_z_at(p.y),
	}


## Fire one scripted technique through the production path and
## watch the whole flight. Returns the measured row.
func run_case(hand: String, zone: String, line_ft: int,
		release_pos: Vector3, vel: Vector3, omega: Vector3,
		phase: float, kind: String, seed_val: int) -> Dictionary:
	var res: Dictionary = {"fired": false, "held": false, "arrived": false}
	# Stand the player at the case's line and let the pass-7
	# watcher stock the shoe on that line's pedestal.
	main.test_hand_tf.erase("L")
	main.test_hand_tf.erase("R")
	main.test_grip["L"] = 0.0
	main.test_grip["R"] = 0.0
	main.origin.global_transform = Transform3D(Basis.IDENTITY,
		Vector3(0.0, 0.0, main.line_z_for_ft(line_ft)))
	var want_tf: Transform3D = main.stand_tfs[line_ft]
	var waited: float = 0.0
	while waited < 2.5:
		if String(main.state) == "STAND" \
				and main.shoe.global_position.distance_to(want_tf.origin) < 0.01:
			break
		await create_timer(0.1).timeout
		waited += 0.1
	# Grab the case's zone through the production latch.
	var zone_c: Vector3 = main.shoe.zone_world_center(zone)
	main.test_hand_tf[hand] = Transform3D(Basis.IDENTITY, zone_c)
	main.test_grip[hand] = 1.0
	await frames(6)
	for i: int in 2:
		await physics_frame
	res["held"] = String(main.state) == "HELD"
	if not bool(res["held"]):
		return res
	# Park the hand at the release pose: the shoe's release
	# transform is the follow cache (hand * hold rel), so solve
	# the hand pose that puts the SHOE at release_pos with the
	# planned phase.
	var rel_tf: Transform3D = Shoe.hold_transform(zone, hand)
	var q_hand: Quaternion = Basis.from_euler(Vector3(0.0, phase, 0.0)).get_rotation_quaternion()
	var hand_pos: Vector3 = release_pos - Basis(q_hand) * rel_tf.origin
	main.test_hand_tf[hand] = Transform3D(Basis(q_hand), hand_pos)
	await frames(4)
	for i: int in 2:
		await physics_frame
	# Fire: inject the stream and release through production code.
	stake_hit_flag = false
	var saves0: int = int(main.shoe.stake_guard_saves)
	var samples: Array = build_stream(hand_pos, q_hand, vel, omega, seed_val)
	main.samples = samples
	main._release_shoe(samples)
	res["v_est"] = main.release_cache.get("velocity", Vector3.ZERO)
	res["w_est"] = main.release_cache.get("angular_velocity", Vector3.ZERO)
	main.grab_state.reset()
	main.test_grip[hand] = 0.0
	res["fired"] = String(main.state) == "FLYING"
	if not bool(res["fired"]):
		return res
	# Watch the flight: wobble in clean free flight, arrival at
	# stake contact or stake-plane crossing (recorder accounting
	# snapshotted there), first contact kept as the secondary row.
	# The spin figure is read from the last FREE-FLIGHT poll: the
	# poll that detects a contact already reads post-impact spin.
	var arrived: Dictionary = {}
	var contact_snap: Dictionary = {}
	var approach: Dictionary = {}
	var wobble_max: float = 0.0
	var elapsed: float = 0.0
	var prev_pos: Vector3 = main.shoe.global_position
	var free_av: float = main.shoe.angular_velocity.length()
	while elapsed < 8.0:
		await physics_frame
		elapsed += 1.0 / 60.0
		if String(main.state) != "FLYING":
			break
		var p: Vector3 = main.shoe.global_position
		var av: Vector3 = main.shoe.angular_velocity
		if arrived.is_empty() and contact_snap.is_empty() \
				and not bool(main.has_contact) and not stake_hit_flag \
				and int(main.shoe.stake_guard_saves) == saves0:
			# Free flight only: the window closes at first contact,
			# at a solver stake hit, or at a sweep-guard save (the
			# save's bounce is a clang response, not flight).
			if av.length() > 1.0:
				var axis_now: Vector3 = Vector3.UP
				if kind == "flip":
					axis_now = main.shoe.global_transform.basis.x.normalized()
				var dev: float = rad_to_deg(av.normalized().angle_to(axis_now))
				dev = minf(dev, 180.0 - dev)
				wobble_max = maxf(wobble_max, dev)
			free_av = av.length()
			if p.z - axis_z_at(p.y) >= 0.20:
				approach = approach_snapshot()
		if arrived.is_empty():
			var crossed: bool = prev_pos.z > axis_z_at(prev_pos.y) \
				and p.z <= axis_z_at(p.y) and p.y < 1.0
			if stake_hit_flag or crossed:
				var spin_now: float = free_av if stake_hit_flag else av.length()
				arrived = flight_snapshot(
					"stake contact" if stake_hit_flag else "plane crossing", spin_now)
			elif bool(main.has_contact) and contact_snap.is_empty():
				contact_snap = flight_snapshot("first contact", free_av)
		prev_pos = p
	res["wobble"] = wobble_max
	res["guard_save"] = int(main.shoe.stake_guard_saves) > saves0
	if not arrived.is_empty():
		res["arrived"] = true
		res["arr_close"] = true
		res["arr"] = arrived
	elif not contact_snap.is_empty():
		res["arr"] = contact_snap
		# A touchdown within 0.30 m short of the plane, sliding in,
		# still counts as the technique arriving (the brief's
		# "crossing / first contact"); a landing a metre short -
		# what the pre-fix damped physics produced - does not.
		res["arr_close"] = float(contact_snap["z"]) >= float(contact_snap["axis_z"]) - 0.30
	if not approach.is_empty() and (bool(res.get("arrived", false)) or bool(res.get("arr_close", false))
			or bool(res.get("guard_save", false))):
		# The shoe demonstrably reached the stake (crossing,
		# contact, a close touchdown, or a sweep-guard save);
		# judge the technique on its contact-free approach state,
		# projected to the plane - not on the post-clang poll.
		var mode: String = String(res["arr"].get("how", "")) if res.has("arr") else "guard save"
		approach["how"] = "approach projected (arrival: %s)" % mode
		res["arr"] = approach
		res["arr_close"] = true
	# Return the shoe for the next case.
	if not await wait_state("STAND", 15.0):
		if String(main.state) == "FLYING":
			main._settle_throw()
		await wait_state("STAND", 4.0)
	res["back"] = String(main.state) == "STAND"
	return res


func judge_case(label: String, res: Dictionary, vel: Vector3, omega: Vector3,
		kind: String, plan_rev: float) -> void:
	check(bool(res.get("held", false)) and bool(res.get("fired", false)),
		"%s: grabbed and released through the production path" % label)
	var v_est: Vector3 = res.get("v_est", Vector3.ZERO)
	var w_est: Vector3 = res.get("w_est", Vector3.ZERO)
	var v_err: float = v_est.distance_to(vel)
	var w_err: float = w_est.distance_to(omega)
	check(v_err <= 0.35,
		"%s: estimator velocity bias in the pass-1 order (err %.3f m/s)" % [label, v_err])
	check(w_err <= 0.30,
		"%s: estimator angular bias small (err %.3f rad/s on %.2f imparted)" % [label, w_err, omega.length()])
	var arr: Dictionary = res.get("arr", {})
	var got_rev: float = float(arr.get("flip" if kind == "flip" else "turn", 0.0))
	check(bool(res.get("arr_close", false)) and absf(got_rev - plan_rev) <= 0.15,
		"%s: arrived rotation %.2f rev vs plan %.2f (within 0.15; by %s at t=%.2f s)"
		% [label, got_rev, plan_rev, String(arr.get("how", "never")), float(arr.get("t", -1.0))])
	var open_err: float = float(arr.get("open_err", 999.0))
	check(open_err <= 30.0,
		"%s: opening faces the stake on arrival (err %.0f deg, tolerance 30)" % [label, open_err])
	var wob: float = float(res.get("wobble", 999.0))
	check(wob <= 12.0,
		"%s: no tennis-racket wobble - spin axis held within %.1f deg in free flight" % [label, wob])
	var spin_kept: float = 0.0
	if w_est.length() > 0.1:
		spin_kept = float(arr.get("av_len", 0.0)) / w_est.length()
	check(spin_kept >= 0.95,
		"%s: spin survives the flight - %.0f%% of imparted spin still on the shoe at arrival"
		% [label, spin_kept * 100.0])
	check(bool(res.get("back", false)), "%s: shoe settled and returned for the next case" % label)
	print("  ROW  %-28s v_err %.3f  w_err %.3f  arrived %+.2f / plan %+.2f rev  open %.0f deg  wobble %.1f deg  spin %.0f%%"
		% [label, v_err, w_err, got_rev, plan_rev, open_err, wob,
			spin_kept * 100.0])


func _init() -> void:
	_run()


func _run() -> void:
	var rec_path: String = "user://audit_throws.jsonl"
	if FileAccess.file_exists(rec_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(rec_path))
	var ps: PackedScene = load("res://main.tscn")
	main = ps.instantiate()
	main.recorder_path = rec_path
	root.add_child(main)
	await create_timer(0.3).timeout
	check(main != null and main.shoe != null, "audit: main scene instantiated with its shoe")
	find_stake()
	check(stake_body != null, "audit: stake body found in the built scene")
	main.shoe.body_entered.connect(_on_shoe_body_entered)

	var rp40 := Vector3(0.0, 1.30, -0.30)
	var v40: Vector3 = ballistic_vel(rp40, FLIGHT_T_40)
	var rp30 := Vector3(0.0, 1.30, -3.35)
	var v30: Vector3 = ballistic_vel(rp30, FLIGHT_T_30)

	# 1. FLIP, one revolution, 40 ft. Spin about +X - the sign
	# Chris's own flips impart (recorder total lands at -1.00).
	var r1: Dictionary = await run_case("R", "toe", 40, rp40, v40,
		Vector3(TAU / FLIGHT_T_40, 0.0, 0.0), 0.0, "flip", 101)
	judge_case("FLIP 1 rev, 40 ft", r1, v40, Vector3(TAU / FLIGHT_T_40, 0.0, 0.0), "flip", -1.00)

	# 2. FLIP, one revolution, 30 ft (shorter flight, faster rate).
	var r2: Dictionary = await run_case("R", "toe", 30, rp30, v30,
		Vector3(TAU / FLIGHT_T_30, 0.0, 0.0), 0.0, "flip", 202)
	judge_case("FLIP 1 rev, 30 ft", r2, v30, Vector3(TAU / FLIGHT_T_30, 0.0, 0.0), "flip", -1.00)

	# 3. TURN 3/4, 40 ft - hooks-up phase, negative yaw (the
	# sign the approach measurement proves arrives open).
	var w34: Vector3 = Vector3(0.0, -TAU * 0.75 / FLIGHT_T_40, 0.0)
	var r3: Dictionary = await run_case("R", "shank_left", 40, rp40, v40, w34, PI, "turn", 303)
	judge_case("TURN 3/4, 40 ft", r3, v40, w34, "turn", -0.75)

	# 4. TURN 1-1/4, 40 ft - THE FRANCIS CASE: lazy rate, phase 0.
	var w114: Vector3 = Vector3(0.0, -TAU * 1.25 / FLIGHT_T_40, 0.0)
	var r4: Dictionary = await run_case("R", "shank_left", 40, rp40, v40, w114, 0.0, "turn", 404)
	judge_case("TURN 1-1/4 (Francis), 40 ft", r4, v40, w114, "turn", -1.25)

	# 5. TURN 1-3/4, 40 ft - hooks-up phase, negative yaw.
	var w134: Vector3 = Vector3(0.0, -TAU * 1.75 / FLIGHT_T_40, 0.0)
	var r5: Dictionary = await run_case("R", "shank_left", 40, rp40, v40, w134, PI, "turn", 505)
	judge_case("TURN 1-3/4, 40 ft", r5, v40, w134, "turn", -1.75)

	# 6. REVERSE TURN 1-1/4, 40 ft - left hand, positive yaw.
	var wrev: Vector3 = Vector3(0.0, TAU * 1.25 / FLIGHT_T_40, 0.0)
	var r6: Dictionary = await run_case("L", "shank_right", 40, rp40, v40, wrev, 0.0, "turn", 606)
	judge_case("REVERSE TURN 1-1/4, 40 ft", r6, v40, wrev, "turn", 1.25)

	# CONTROL: the Francis case with the spin sign flipped. The
	# physics must still deliver 1.25 rev - but the opening must
	# arrive facing AWAY (the approach measurement reads ~180
	# deg on the flipped spin). If this reads a small opening
	# error, the metric or the sign convention is broken, not
	# the shoe.
	var wctl: Vector3 = Vector3(0.0, TAU * 1.25 / FLIGHT_T_40, 0.0)
	var rc: Dictionary = await run_case("R", "shank_left", 40, rp40, v40, wctl, 0.0, "turn", 707)
	var carr: Dictionary = rc.get("arr", {})
	check(bool(rc.get("fired", false)), "CONTROL (wrong-way 1-1/4): fired through the production path")
	check(absf(float(carr.get("turn", 0.0)) - 1.25) <= 0.15,
		"CONTROL: physics still delivers the flipped spin (arrived %+.2f rev)" % float(carr.get("turn", 0.0)))
	check(float(carr.get("open_err", 0.0)) > 90.0,
		"CONTROL: wrong-way spin arrives with the opening facing AWAY (err %.0f deg) - the metric discriminates"
		% float(carr.get("open_err", 0.0)))

	main.origin.global_transform = Transform3D.IDENTITY
	DirAccess.remove_absolute(ProjectSettings.globalize_path(rec_path))

	print("---")
	if failures == 0:
		print("TECHNIQUE AUDIT: ALL %d CHECKS PASSED" % checks)
	else:
		print("TECHNIQUE AUDIT: %d of %d CHECKS FAILED" % [failures, checks])
	quit(1 if failures > 0 else 0)
