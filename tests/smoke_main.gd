extends SceneTree

## Scene smoke suite (headless): instances the real main scene and
## drives the production grab/throw code with test hand transforms +
## test grip values (the XR input transport itself is exercised by
## the render proofs with fake trackers, and judged on the headset).
## Run: godot --headless --path . --script tests/smoke_main.gd

var failures: int = 0
var checks: int = 0
var main: Node
var stake_body: StaticBody3D = null
var stake_contacts: Array = []


func check(cond: bool, name: String) -> void:
	checks += 1
	if cond:
		print("PASS  ", name)
	else:
		failures += 1
		print("FAIL  ", name)


func wait_state(want: String, timeout_sec: float) -> bool:
	var elapsed: float = 0.0
	while elapsed < timeout_sec:
		if String(main.state) == want:
			return true
		await create_timer(0.2).timeout
		elapsed += 0.2
	return String(main.state) == want


func frames(n: int) -> void:
	for i: int in n:
		await process_frame


## Time from the thrown shoe first satisfying the settle detector's
## own rest condition (same thresholds main.gd uses, after the same
## minimum flight time) until it is back on its pedestal in STAND.
## Returns -1 if either milestone never happens in the timeout.
func wait_rest_to_stand(timeout_sec: float) -> float:
	var start_msec: int = Time.get_ticks_msec()
	var rest_msec: int = -1
	while float(Time.get_ticks_msec() - start_msec) / 1000.0 < timeout_sec:
		if rest_msec < 0 and String(main.state) == "FLYING" \
				and float(main._fly_time) > 0.6 \
				and main.shoe.linear_velocity.length() < 0.10 \
				and main.shoe.angular_velocity.length() < 0.30:
			rest_msec = Time.get_ticks_msec()
		if String(main.state) == "STAND":
			if rest_msec >= 0:
				return float(Time.get_ticks_msec() - rest_msec) / 1000.0
			return -1.0
		await physics_frame
	return -1.0


## Fix Pass 7: seconds until the shoe is stocked (homed) on the
## given line's pedestal, or -1 on timeout.
func wait_shoe_at(line_ft: int, timeout_sec: float) -> float:
	var t0: int = Time.get_ticks_msec()
	while float(Time.get_ticks_msec() - t0) / 1000.0 < timeout_sec:
		if int(main.active_stand_line_ft) == line_ft \
				and main.shoe.global_position.distance_to(main.stand_tfs[line_ft].origin) < 0.01:
			return float(Time.get_ticks_msec() - t0) / 1000.0
		await create_timer(0.05).timeout
	return -1.0


## Fix Pass 8: find the stake body in the built scene (a
## StaticBody3D under the pivot at Main.STAKE_POS).
func find_stake() -> void:
	for child: Node in main.get_children():
		if child is Node3D and (child as Node3D).position.distance_to(main.STAKE_POS) < 0.001:
			for sub: Node in child.get_children():
				if sub is StaticBody3D:
					stake_body = sub as StaticBody3D


func _on_stake_test_body_entered(body: Node) -> void:
	stake_contacts.append(body)


## Fix Pass 10: parse a "KEY: <float> REV" line out of the board's
## status text. Returns NAN when the line is absent or still the
## pre-throw dash, so a missing readout fails comparisons loudly.
func board_rev(text: String, key: String) -> float:
	var at: int = text.find(key)
	if at < 0:
		return NAN
	var rest: String = text.substr(at + key.length())
	var end: int = rest.find(" REV")
	if end < 0:
		return NAN
	var num: String = rest.substr(0, end).strip_edges()
	if not num.is_valid_float():
		return NAN
	return num.to_float()


## Fix Pass 10: horizontal distance from a point to the board
## sightline segment (the player's pitching spot -> board
## centre, XZ). Fix Pass 19: the spot is his side of the
## 37 ft line now, not the court centre.
func sightline_dist(p: Vector3) -> float:
	var spot: Vector3 = main.spot_pos(40, false)
	var a := Vector2(spot.x, spot.z)
	var b := Vector2(main.BOARD_POS.x, main.BOARD_POS.z)
	var q := Vector2(p.x, p.z)
	var ab: Vector2 = b - a
	var t: float = clampf((q - a).dot(ab) / ab.length_squared(), 0.0, 1.0)
	return (a + ab * t).distance_to(q)


## Fix Pass 19: one rack's layout assertions, under the FP13
## law translated to the one-pit pitching end - the rack
## stands beside its owner's pitching SPOT at its foul line
## (the player's station and peg post, the AI's station -
## there is one end now, no per-end racks), slot 0 at
## 1.15-1.30 m reach-over FROM THE SPOT, slot 1 stepping
## DOWN-LANE along the turned rail, the hanging shoe
## presenting FACE-ON to the spot. Both slots stay outside
## the stance box (|x| <= 0.85 in the box's old court-centre
## terms, line z +/- 0.40) and within a reach-over.
## Stage B re-derivation (the yard pass): the 40 ft racks
## left the line for the patio behind it - slot 0 now stands
## STAND_BACK_Z behind the line, its spot reach 1.63-1.80 m:
## past any arm, inside the re-derived LONG_ARM_RADIUS that
## serves it (the FP25 far tier is now the station's grab).
## The FP19 law survives untouched at the 30 ft peg, which
## did not move; the face-on and down-lane-step laws hold at
## both lines.
## Fix Pass 35: no 40 ft rack is asserted here any more -
## both game stations are corner stations with their own
## guard (check_game_station). This helper now serves the
## 30 ft peg alone; its patio branches remain as the Stage B
## record.
func check_rack(line_ft: int, is_ai: bool) -> void:
	var lz: float = main.line_z_for_ft(line_ft)
	var side: float = main.station_side(is_ai)
	var who: String = "AI" if is_ai else "player"
	var on_patio: bool = line_ft == 40
	var spot: Vector2 = Vector2(main.spot_pos(line_ft, is_ai).x, lz)
	for idx: int in [0, 1]:
		var rp: Vector3 = main.rack_slot_tf(line_ft, is_ai, idx).origin
		var in_stance: bool = absf(rp.x) <= main.STANCE_HALF_WIDTH \
			and absf(rp.z - lz) <= main.STANCE_HALF_DEPTH
		check(not in_stance,
			"FP19: %s rack slot %d at the %d ft line is OUTSIDE the stance box (at %s)"
			% [who, idx, line_ft, str(rp)])
		var reach: float = Vector2(rp.x, rp.z).distance_to(spot)
		if on_patio:
			check(reach >= 1.55 and reach <= 1.90 and reach <= main.LONG_ARM_RADIUS,
				"Stage B: %s rack slot %d at the 40 ft line is a long-arm grab from its spot (%.2f m, radius %.2f)"
				% [who, idx, reach, main.LONG_ARM_RADIUS])
		else:
			check(reach >= 0.90 and reach <= 1.35,
				"FP19: %s rack slot %d at the %d ft line is a reach-over grab (%.2f m from its spot)"
				% [who, idx, line_ft, reach])
	var rp0: Vector3 = main.rack_slot_tf(line_ft, is_ai, 0).origin
	var rp1: Vector3 = main.rack_slot_tf(line_ft, is_ai, 1).origin
	if on_patio:
		check(absf((rp0.z - lz) - main.STAND_BACK_Z) < 0.05,
			"Stage B: %s rack at the 40 ft line stands BEHIND the line on the patio (slot 0 %.2f m back)"
			% [who, rp0.z - lz])
	else:
		check(absf(rp0.z - lz) < 0.05,
			"FP19: %s rack at the %d ft line stands AT the line, not behind the player (dz %.2f)"
			% [who, line_ft, rp0.z - lz])
	check(signf(rp0.x) == side
		and absf(absf(rp0.x) - (absf(spot.x) + main.STAND_SIDE_X)) < 0.05,
		"FP19: %s rack at the %d ft line sits on its owner's side, a reach-over outboard of its spot (x %.2f)"
		% [who, line_ft, rp0.x])
	var reach0: float = Vector2(rp0.x, rp0.z).distance_to(spot)
	if on_patio:
		check(reach0 >= 1.70 and reach0 <= 1.90,
			"Stage B: %s rack slot 0 at the 40 ft line sits in the 1.70-1.90 m band from its spot (%.2f m)"
			% [who, reach0])
	else:
		check(reach0 >= 1.15 and reach0 <= 1.30,
			"FP19: %s rack slot 0 at the %d ft line sits in the 1.15-1.30 m band from its spot (%.2f m)"
			% [who, line_ft, reach0])
	check(absf(rp1.x - rp0.x) < 0.01
		and absf((rp1.z - rp0.z) - (-1.0) * main.SLOT_STEP) < 0.01,
		"FP19: %s rack at the %d ft line steps slot 1 DOWN-LANE along the turned rail (step %s)"
		% [who, line_ft, str(rp1 - rp0)])
	# Face-on: the hang basis' face normal (shoe local +Y,
	# tipped by the hang) must aim from the slot back at the
	# owner's spot across the court. The solved hang's normal
	# dots ~0.85 with that direction; FP11's down-lane hang
	# dotted ~0.49 at best (and pointed AWAY at two racks).
	var hang: Transform3D = main.rack_slot_tf(line_ft, is_ai, 0)
	var face_n: Vector3 = hang.basis * Vector3.UP
	var to_spot: Vector3 = (Vector3(spot.x, rp0.y, spot.y) - rp0).normalized()
	check(face_n.dot(to_spot) > 0.7,
		"FP19: %s rack at the %d ft line presents its shoes FACE-ON to its spot (facing %.2f)"
		% [who, line_ft, face_n.dot(to_spot)])


## Fix Pass 36: THE CORNER STATIONS after the Shelf War
## Treaty - each station on its OWNER's side (the FP19
## side law): the player's shelf on HIS side (+x), the
## AI's station on its side (-x), IN FRONT OF THE FOUNTAIN
## (Chris's FP35 law, verbatim: "one shelf need to be in
## front of fountain there" - the fountain spot is the
## AI's now). Each stands on the grass at its patio front
## corner at the fountain's latitude, facing its owner
## dead-on; from the owner's spot each is abeam on the
## owner's OWN side - a glance (bearing ~66 deg off the
## pit-facing axis), not a turnaround - and the long-arm
## radius was re-derived to reach the player's pair, the
## A-seat's far (left) hand to slot 1 governing.
func check_game_station(is_ai: bool) -> void:
	var who: String = "AI station" if is_ai else "shelf"
	var want0: Vector3 = main.AI_SLOT0 if is_ai else main.SHELF_SLOT0
	var rp0: Vector3 = main.rack_slot_tf(40, is_ai, 0).origin
	var rp1: Vector3 = main.rack_slot_tf(40, is_ai, 1).origin
	check(rp0.distance_to(want0) < 0.01,
		"FP36: the %s's game shoes stock at its slot (%s)" % [who, str(rp0)])
	check(signf(rp0.x) == main.station_side(is_ai),
		"FP36: the %s stands on its OWNER's side of the lane (x %.2f)" % [who, rp0.x])
	var lz: float = main.line_z_for_ft(40)
	var in_stance: bool = absf(rp0.x) <= main.STANCE_HALF_WIDTH \
		and absf(rp0.z - lz) <= main.STANCE_HALF_DEPTH
	check(not in_stance,
		"FP36: the %s stands outside the stance box (at %s)" % [who, str(rp0)])
	var env: Array = main.ai_station_envelope() if is_ai \
		else main.player_shelf_envelope()
	var patio: Array = main.stage_b_patio_rect()
	var on_slab: bool = float(env[0]) < float(patio[2]) and float(env[2]) > float(patio[0]) \
		and float(env[1]) < float(patio[3]) and float(env[3]) > float(patio[1])
	check(not on_slab,
		"FP36: the %s stands on grass, off the patio slab" % who)
	var beds: Array = main.stage_a_bed_rects()
	for bi: int in beds.size():
		var b: Array = beds[bi]
		var overlap: bool = float(env[0]) < float(b[2]) and float(env[2]) > float(b[0]) \
			and float(env[1]) < float(b[3]) and float(env[3]) > float(b[1])
		check(not overlap, "FP36: the %s envelope clears bed %d" % [who, bi])
	if is_ai:
		var fn: Vector3 = main.STAGE_B_FOUNTAIN_POS
		var fd: float = Vector2(fn.x, fn.z).distance_to(
			Vector2(clampf(fn.x, float(env[0]), float(env[2])),
				clampf(fn.z, float(env[1]), float(env[3]))))
		check(fd >= main.STAGE_B_FOUNTAIN_R + 0.15,
			"FP36: the AI station envelope clears the fountain circle (%.2f m)" % fd)
		check(absf(rp0.z - fn.z) < 0.01 and rp0.x > fn.x,
			"FP36: the AI station stands in front of the fountain, at its latitude")
		check(float(env[0]) - float(beds[0][2]) >= 0.05,
			"FP36: the AI station keeps its grass gap inside the left bed (%.2f m)"
			% (float(env[0]) - float(beds[0][2])))
	else:
		check(float(beds[2][0]) - float(env[2]) >= 0.05,
			"FP36: the shelf keeps its grass gap inside the right bed (%.2f m)"
			% (float(beds[2][0]) - float(env[2])))
	var spot: Vector3 = main.spot_pos(40, is_ai)
	var hang: Transform3D = main.rack_slot_tf(40, is_ai, 0)
	var face_n: Vector3 = hang.basis * Vector3.UP
	var to_spot: Vector3 = (Vector3(spot.x, rp0.y, spot.z) - rp0).normalized()
	check(face_n.dot(to_spot) > 0.7,
		"FP36: the %s presents its shoes FACE-ON to its spot (facing %.2f)"
		% [who, face_n.dot(to_spot)])
	var to_slot := Vector3(rp0.x - spot.x, 0.0, rp0.z - spot.z).normalized()
	var bearing: float = rad_to_deg(acos(clampf(
		to_slot.dot(Vector3(0.0, 0.0, -1.0)), -1.0, 1.0)))
	var outboard: bool = signf(to_slot.x) == main.station_side(is_ai)
	check(outboard and bearing > 55.0 and bearing < 80.0,
		"FP36: from its spot the %s is abeam on its owner's OWN side - a glance, not a turnaround (bearing %.0f deg)" % [who, bearing])
	check(absf(rp1.x - rp0.x) < 0.01
		and absf((rp1.z - rp0.z) - (-1.0) * main.SLOT_STEP) < 0.01,
		"FP36: the %s steps slot 1 down-lane along the rail (step %s)" % [who, str(rp1 - rp0)])
	if not is_ai:
		var hand_l := Vector3(spot.x - 0.25, 0.85, spot.z)
		check(hand_l.distance_to(rp0) > 1.60 and hand_l.distance_to(rp0) < 1.80,
			"FP36: the far-hand reach to the shelf is %.2f m" % hand_l.distance_to(rp0))
		var seat_l := Vector3(spot.x - 0.25, 0.85, spot.z + 0.70)
		check(main.LONG_ARM_RADIUS >= seat_l.distance_to(rp1)
			and main.LONG_ARM_RADIUS < seat_l.distance_to(rp1) + 0.35,
			"FP36: the re-derived long-arm radius (%.2f) covers the governing seat reach (%.2f m)"
			% [main.LONG_ARM_RADIUS, seat_l.distance_to(rp1)])


## Fix Pass 8: fire one shot at the stake through the production
## grab/release path and watch it the whole way: was the stake
## body hit, and how deep past the stake's axis plane did the
## shoe's centre ever get while lined up with the stake (a ringer
## wrap legitimately reaches ~0.07 m; a ghost sails far past)?
## Fix Pass 9 re-derivation: "hit" now means the stake was
## engaged by EITHER the physics solver (body_entered) OR the
## shoe's sweep guard (stake_guard_saves) - the guard exists
## because the solver + CCD demonstrably miss a fast flat shoe
## in the upper band. The guarded property is unchanged: a
## dead-centre full-speed shoe must not pass the stake untouched.
func fire_at_stake(release_pos: Vector3, vel: Vector3, omega: float) -> Dictionary:
	# Wait for the shoe to sit stocked at its home pedestal, then
	# stand the player at that home line so the pass-7 restock
	# watcher cannot relocate the shoe mid-grab.
	for i: int in 120:
		await physics_frame
		if String(main.state) == "STAND":
			var home_tf: Transform3D = main.stand_tfs[int(main.active_stand_line_ft)]
			if main.shoe.global_position.distance_to(home_tf.origin) < 0.01:
				break
	main.origin.global_transform = Transform3D(Basis.IDENTITY,
		Vector3(0.0, 0.0, main.line_z_for_ft(int(main.active_stand_line_ft))))
	stake_contacts.clear()
	var saves0: int = int(main.shoe.stake_guard_saves)
	var toe_c: Vector3 = main.shoe.zone_world_center("toe")
	main.test_hand_tf["R"] = Transform3D(Basis.IDENTITY, toe_c)
	main.test_grip["R"] = 1.0
	await frames(6)
	if String(main.state) != "HELD":
		return {"fired": false, "contact": false, "max_beyond": 0.0}
	# Toe/flip hold, identity hand: shoe origin = hand + this offset.
	var hand_pos: Vector3 = release_pos - Vector3(0.0, -0.018, -0.0834)
	main.test_hand_tf["R"] = Transform3D(Basis.IDENTITY, hand_pos)
	await frames(4)
	var now: float = float(Time.get_ticks_msec()) / 1000.0
	var dur: float = 0.30
	var hz: float = 90.0
	var samples: Array = []
	for i: int in int(dur * hz) + 1:
		var t: float = float(i) / hz
		var q := Quaternion(Vector3.RIGHT, omega * (t - dur))
		samples.append(ThrowMath.make_sample(now - dur + t,
			release_pos + vel * (t - dur), q))
	main.samples = samples
	# Fix Pass 16: this fixture's choreographed spin IS its
	# specification - the section's subject is the stake's
	# collision and sweep guard, and the finger-drag term would
	# rewrite the tumble toward the regulation total before the
	# guard ever saw it. The governor's production behaviour is
	# proven where the release is the subject
	# (tests/spin_governor_bench.gd, the technique audit).
	var gov_was: bool = main.spin_governor_enabled
	main.spin_governor_enabled = false
	main._release_shoe(samples)
	main.spin_governor_enabled = gov_was
	main.grab_state.reset()
	main.test_grip["R"] = 0.0
	var fired: bool = String(main.state) == "FLYING"
	var stake_pos: Vector3 = main.STAKE_POS
	var max_beyond: float = -1e9
	var elapsed: float = 0.0
	while String(main.state) == "FLYING" and elapsed < 12.0:
		await physics_frame
		elapsed += 1.0 / 60.0
		var p: Vector3 = main.shoe.global_position
		if p.y > -0.05 and p.y < 0.50 and absf(p.x) < 0.11:
			var h: float = (p.y - stake_pos.y) / cos(deg_to_rad(8.0))
			var axis_z: float = stake_pos.z + h * sin(deg_to_rad(8.0))
			max_beyond = maxf(max_beyond, axis_z - p.z)
	return {"fired": fired,
		"contact": stake_contacts.has(stake_body) or int(main.shoe.stake_guard_saves) > saves0,
		"guard_save": int(main.shoe.stake_guard_saves) > saves0,
		"axis_dist": Vector2(main.shoe.global_position.x - stake_pos.x,
			main.shoe.global_position.z - stake_pos.z).length(),
		"max_beyond": max_beyond}


## Wait until the tracked test-hand speed estimate settles (a
## teleported test hand spikes it; a drop needs a still hand).
func wait_hand_still(hand: String) -> void:
	for i: int in 40:
		if float(main.hand_speed[hand]) < 0.3:
			break
		await process_frame


## Fix Pass 22 battery rulers: the held shoe's orientation
## error against the hand-relative carry (degrees), and the
## hand-to-shoe separation (metres). A healthy hold reads
## ~0 on both, under every input.
func held_orient_error() -> float:
	var want: Basis = (main.test_hand_tf[main.held_hand] * main.rel_tf).basis.orthonormalized()
	var got: Basis = main.shoe.global_transform.basis.orthonormalized()
	return rad_to_deg(want.get_rotation_quaternion().angle_to(got.get_rotation_quaternion()))


func held_separation() -> float:
	return main.test_hand_tf[main.held_hand].origin.distance_to(main.shoe.global_position)


func _init() -> void:
	_run()


## Synthetic swing stream (the technique audit's shape): an
## accelerating swing sampled at 90 Hz ending at the release
## instant, carrying a constant spin about a fixed axis.
func build_stream(hand_pos: Vector3, q_hand: Quaternion, vel: Vector3,
		omega: Vector3, seed_val: int) -> Array:
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


## One player throw in a game, entirely through the production
## path (the audit's injection pattern): grab the toe of the
## active shoe, park the hand at the solved release pose, inject
## the swing stream, release. A plain club flip at the target
## stake, whichever end the inning is played toward.
func scripted_game_throw() -> bool:
	if String(main.state) != "STAND":
		return false
	var thrown_shoe: Shoe = main.shoe
	var line_z: float = main.game_line_z()
	var travel: float = -1.0 # Fix Pass 19: one-way, always toward the pit
	var target: Vector3 = main.target_stake_pos()
	var release_pos := Vector3(0.25, 1.25, line_z - 0.35 * travel)
	var t_f: float = 1.15
	var vel := Vector3((target.x - release_pos.x) / t_f,
		(0.50 - release_pos.y + 4.9 * t_f * t_f) / t_f,
		(target.z - release_pos.z) / t_f)
	var omega := Vector3(-travel * TAU / t_f, 0.0, 0.0)
	main.test_hand_tf["R"] = Transform3D(Basis.IDENTITY,
		thrown_shoe.zone_world_center("toe"))
	main.test_grip["R"] = 1.0
	await frames(6)
	for i: int in 2:
		await physics_frame
	if String(main.state) != "HELD":
		return false
	var rel_tf: Transform3D = Shoe.hold_transform("toe", "R")
	var hand_pos: Vector3 = release_pos - rel_tf.origin
	main.test_hand_tf["R"] = Transform3D(Basis.IDENTITY, hand_pos)
	await frames(4)
	for i: int in 2:
		await physics_frame
	main.samples = build_stream(hand_pos, Quaternion.IDENTITY, vel, omega, 777)
	# Fix Pass 16: the choreographed club flip stands in for a
	# player in sections whose subject is game flow (and the
	# FP15 game's level horizon), not release shaping - the
	# finger-drag term stays off for the fixture's release and
	# is restored immediately after. Its production behaviour
	# is proven in tests/spin_governor_bench.gd and the
	# technique audit, where the release IS the subject.
	var gov_was: bool = main.spin_governor_enabled
	main.spin_governor_enabled = false
	main._release_shoe(main.samples)
	main.spin_governor_enabled = gov_was
	main.grab_state.reset()
	main.test_grip["R"] = 0.0
	if String(main.state) != "FLYING":
		return false
	var waited: float = 0.0
	while waited < 10.0:
		if String(main.shoe_status[thrown_shoe]) == "DOWN":
			return true
		await create_timer(0.2).timeout
		waited += 0.2
	return false


## Fix Pass 19: the AI's box at the one pitching end, in the
## brief's own terms (Chris's one-pit call: both pitchers
## share the end, throws near-parallel): behind the 37 ft
## line, LEVEL with the player's stance depth (0.55 m behind
## the line), ~1.6 m from the PLAYER'S pitching spot, on the
## lane's other side, facing the pit down-lane. (FP13's
## 3.60 m separation at two ends was the diagonal throw
## Chris called out from the headset.)
func check_ai_box() -> void:
	var lz: float = main.game_line_z()
	var pos: Vector3 = main.ai_pitcher.position
	var spot: Vector3 = main.spot_pos(40, false)
	check(pos.z > lz,
		"FP19: the AI's box is BEHIND the 37 ft line (z %.2f, line %.2f)"
		% [pos.z, lz])
	check(absf(pos.z - (lz + 0.55)) <= 0.5,
		"FP19: the AI stands LEVEL with the player's stance depth (his z %.2f, stance z %.2f)"
		% [pos.z, lz + 0.55])
	var sep: float = Vector2(pos.x, pos.z).distance_to(
		Vector2(spot.x, lz + 0.55))
	check(sep >= 1.4 and sep <= 1.8,
		"FP19: the two pitching spots sit ~1.6 m apart (%.2f m)" % sep)
	check(pos.x < 0.0,
		"FP19: the AI pitches from the lane's other side (x %.2f)" % pos.x)
	var fwd: Vector3 = -main.ai_pitcher.global_transform.basis.z
	check(fwd.dot(Vector3(0.0, 0.0, -1.0)) > 0.9,
		"FP19: the AI faces the pit down-lane")


## Fix Pass 13: one SCRIPTED player shot through the production
## grab / estimator / release path. Same latch as
## scripted_game_throw, but the release is the constructed
## "good flip" profile (AIPitcher.base_release) aimed at the
## target stake plus a per-kind offset, the test hand is posed
## so the shoe leaves with that profile's exact release basis,
## and the injected stream is LINEAR (fire_at_stake's precise
## shape) so the windowed fit recovers the solved velocity.
## Calibrated at the home end, bit-deterministic on repeat:
##   "ringer": aim at the stake - rings, dist 0.0.
##   "point":  aim 0.30 m short - settles ~5.8 in, no ringer.
##   "dud":    aim 2.5 m wide - settles ~95 in out.
func scripted_shot(kind: String) -> bool:
	if String(main.state) != "STAND":
		return false
	var thrown_shoe: Shoe = main.shoe
	var line_z: float = main.game_line_z()
	var travel: float = -1.0 # Fix Pass 19: one-way, always toward the pit
	var target: Vector3 = main.target_stake_pos()
	var aim: Vector3 = target
	if kind == "point":
		aim = target + Vector3(0.0, 0.0, -0.30 * travel)
	elif kind == "dud":
		aim = target + Vector3(2.5, 0.0, 0.0)
	var release_pos := Vector3(0.25, 1.25, line_z - 0.35 * travel)
	var rel: Dictionary = AIPitcher.base_release(release_pos, aim)
	var vel: Vector3 = rel["vel"]
	var ang: Vector3 = rel["ang"]
	main.test_hand_tf["R"] = Transform3D(Basis.IDENTITY,
		thrown_shoe.zone_world_center("toe"))
	main.test_grip["R"] = 1.0
	await frames(6)
	for i: int in 2:
		await physics_frame
	if String(main.state) != "HELD":
		return false
	var rel_tf: Transform3D = Shoe.hold_transform("toe", "R")
	var hand_basis: Basis = (rel["basis"] as Basis) * rel_tf.basis.inverse()
	var hand_pos: Vector3 = release_pos - hand_basis * rel_tf.origin
	main.test_hand_tf["R"] = Transform3D(hand_basis, hand_pos)
	await frames(4)
	for i: int in 2:
		await physics_frame
	var dur: float = 0.30
	var hz: float = 90.0
	var steps: int = int(dur * hz)
	var now: float = float(Time.get_ticks_msec()) / 1000.0
	var axis: Vector3 = ang.normalized()
	var rate: float = ang.length()
	var samples: Array = []
	for i: int in steps + 1:
		var t_rel: float = float(i - steps) / hz
		samples.append(ThrowMath.make_sample(now + t_rel,
			release_pos + vel * t_rel, Quaternion(axis, rate * t_rel)))
	main.samples = samples
	# Fix Pass 16: scripted_shot exists to put a shoe at an
	# exact scoring state so the FP13 sections can judge
	# SCORING and ATTRIBUTION; the constructed profile
	# (AIPitcher.base_release) is the fixture's specification,
	# so the finger-drag term stays off for its release and is
	# restored immediately after. The governor's production
	# behaviour is proven where the release is the subject
	# (tests/spin_governor_bench.gd, the technique audit).
	var gov_was2: bool = main.spin_governor_enabled
	main.spin_governor_enabled = false
	main._release_shoe(samples)
	main.spin_governor_enabled = gov_was2
	main.grab_state.reset()
	main.test_grip["R"] = 0.0
	if String(main.state) != "FLYING":
		return false
	var waited: float = 0.0
	while waited < 12.0:
		if String(main.shoe_status[thrown_shoe]) == "DOWN":
			return true
		await create_timer(0.2).timeout
		waited += 0.2
	return false


## Fix Pass 40: release the player's shoe with
## scripted_shot's exact construction (the calibrated
## AIPitcher.base_release profile through the production
## release path), but return the moment it flies so the
## caller can sample the flight frame by frame. Kinds:
##   "line": aimed at the stake - a straight line drive.
##   "pull": aimed 3.0 m LEFT of the stake - the hard
##     pulled throw that sent FP39's camera swinging.
func fp40_release(kind: String) -> bool:
	if String(main.state) != "STAND":
		return false
	var thrown_shoe: Shoe = main.shoe
	var line_z: float = main.game_line_z()
	var travel: float = -1.0
	var target: Vector3 = main.target_stake_pos()
	var aim: Vector3 = target
	if kind == "pull":
		aim = target + Vector3(-3.0, 0.0, 0.0)
	var release_pos := Vector3(0.25, 1.25, line_z - 0.35 * travel)
	var rel: Dictionary = AIPitcher.base_release(release_pos, aim)
	var vel: Vector3 = rel["vel"]
	var ang: Vector3 = rel["ang"]
	main.test_hand_tf["R"] = Transform3D(Basis.IDENTITY,
		thrown_shoe.zone_world_center("toe"))
	main.test_grip["R"] = 1.0
	await frames(6)
	for i: int in 2:
		await physics_frame
	if String(main.state) != "HELD":
		return false
	var rel_tf: Transform3D = Shoe.hold_transform("toe", "R")
	var hand_basis: Basis = (rel["basis"] as Basis) * rel_tf.basis.inverse()
	var hand_pos: Vector3 = release_pos - hand_basis * rel_tf.origin
	main.test_hand_tf["R"] = Transform3D(hand_basis, hand_pos)
	await frames(4)
	for i: int in 2:
		await physics_frame
	var dur: float = 0.30
	var hz: float = 90.0
	var steps: int = int(dur * hz)
	var now: float = float(Time.get_ticks_msec()) / 1000.0
	var axis: Vector3 = ang.normalized()
	var rate: float = ang.length()
	var samples: Array = []
	for i: int in steps + 1:
		var t_rel: float = float(i - steps) / hz
		samples.append(ThrowMath.make_sample(now + t_rel,
			release_pos + vel * t_rel, Quaternion(axis, rate * t_rel)))
	main.samples = samples
	var gov_was: bool = main.spin_governor_enabled
	main.spin_governor_enabled = false
	main._release_shoe(samples)
	main.spin_governor_enabled = gov_was
	main.grab_state.reset()
	main.test_grip["R"] = 0.0
	return String(main.state) == "FLYING"


## Fix Pass 40: the pit camera's yaw in degrees, read off
## its damped state - the number Chris's eyes judge.
func fp40_cam_yaw() -> float:
	var d: Vector3 = main.pitcam_look - main.pitcam_pos
	return rad_to_deg(atan2(-d.x, -d.z))


## Fix Pass 40: the yaw FP39's follow ASKED for at a given
## shoe position - its desired look (the stake and the
## shoe half-and-half) from its drifted desired position,
## recomputed from FP39's own formulas, so one flight
## yields both passes' excursions.
func fp40_legacy_yaw(sp: Vector3) -> float:
	var look: Vector3 = Vector3(main.STAKE_POS.x, 0.05, main.STAKE_POS.z) * 0.5 \
		+ Vector3(sp.x, clampf(sp.y, 0.02, 2.5), sp.z) * 0.5
	var pos: Vector3 = main.PITCAM_BASE_POS + Vector3(
		clampf(sp.x, -1.2, 1.2) * 0.30,
		clampf(sp.y - 0.5, 0.0, 1.5) * 0.10, 0.0)
	var d: Vector3 = look - pos
	return rad_to_deg(atan2(-d.x, -d.z))


## Fix Pass 41: release the player's shoe with the skid
## profile the design probe measured - a low, flat toss
## from 4 m out (a practice toss at the pit, through the
## production grab / estimator / release path): it lands
## at the pit's front and PLOWS - 0.250 m of ground
## travel after its first sand contact, where dead
## arrivals run 0.12 m or less. The construction is
## fp40_release's, with the probe's exact initial state
## (identity basis, -9 rad/s flip).
func fp41_release_skid() -> bool:
	if String(main.state) != "STAND":
		return false
	var thrown_shoe: Shoe = main.shoe
	var release_pos := Vector3(0.10, 0.80, -8.20)
	var vel := Vector3(0.20, 0.80, -6.80)
	var ang := Vector3(-9.0, 0.0, 0.0)
	main.test_hand_tf["R"] = Transform3D(Basis.IDENTITY,
		thrown_shoe.zone_world_center("toe"))
	main.test_grip["R"] = 1.0
	await frames(6)
	for i: int in 2:
		await physics_frame
	if String(main.state) != "HELD":
		return false
	var rel_tf: Transform3D = Shoe.hold_transform("toe", "R")
	var hand_basis: Basis = rel_tf.basis.inverse()
	main.test_hand_tf["R"] = Transform3D(hand_basis,
		release_pos - hand_basis * rel_tf.origin)
	await frames(4)
	for i: int in 2:
		await physics_frame
	var dur: float = 0.30
	var hz: float = 90.0
	var steps: int = int(dur * hz)
	var now: float = float(Time.get_ticks_msec()) / 1000.0
	var axis: Vector3 = ang.normalized()
	var rate: float = ang.length()
	var samples: Array = []
	for i: int in steps + 1:
		var t_rel: float = float(i - steps) / hz
		samples.append(ThrowMath.make_sample(now + t_rel,
			release_pos + vel * t_rel, Quaternion(axis, rate * t_rel)))
	main.samples = samples
	var gov_was: bool = main.spin_governor_enabled
	main.spin_governor_enabled = false
	main._release_shoe(samples)
	main.spin_governor_enabled = gov_was
	main.grab_state.reset()
	main.test_grip["R"] = 0.0
	return String(main.state) == "FLYING"


## Fix Pass 13: wait for a game phase, holding the AI's own
## sampler off meanwhile (ai_delay frozen) so a scripted AI
## throw is never pre-empted by the game's sampled one.
func wait_phase(want: String, timeout_sec: float) -> bool:
	var elapsed: float = 0.0
	while elapsed < timeout_sec:
		main.ai_delay = 100000.0
		if String(main.phase) == want:
			return true
		await create_timer(0.1).timeout
		elapsed += 0.1
	return String(main.phase) == want


## Fix Pass 13: one SCRIPTED AI throw through the production
## swing / flight / settle path - the very play_throw call
## _ai_next_throw makes, with the release CONSTRUCTED instead
## of sampled ("ringer": the un-sampled good flip at the
## stake; "dud": the same profile aimed 2.5 m wide). Only the
## sampler is bypassed; flight, stake guard, settle and the
## scoring record are the game's own.
func scripted_ai_throw(kind: String) -> bool:
	if String(main.phase) != "AI_TURN" or main.ai_throw_pending:
		return false
	main.ai_delay = 100000.0
	var next_shoe: Shoe = null
	for s: Shoe in main.ai_pair:
		if String(main.shoe_status[s]) == "RAILED":
			next_shoe = s
			break
	if next_shoe == null:
		return false
	main.ai_pitcher.place_at(main.game_line_z())
	var from_pos: Vector3 = AIPitcher.release_base_pos(main.game_line_z())
	var aim: Vector3 = main.target_stake_pos()
	if kind == "dud":
		aim += Vector3(2.5, 0.0, 0.0)
	var rel: Dictionary = AIPitcher.base_release(from_pos, aim)
	main.ai_pending_shoe = next_shoe
	main.ai_pending_release = rel
	main.ai_throw_pending = true
	main.shoe_status[next_shoe] = "HELD"
	next_shoe.freeze = true
	main.ai_pitcher.play_throw(next_shoe, rel, main._ai_release_now, main._ai_swing_done)
	var waited: float = 0.0
	while waited < 20.0:
		if String(main.shoe_status[next_shoe]) == "DOWN":
			return true
		await create_timer(0.2).timeout
		waited += 0.2
	return false


## Fix Pass 13 / 19 / 20: play ONE inning with scripted
## shots on both sides (production paths throughout): the
## player's shots from p_kinds in throw order, the AI's from
## ai_kinds. Returns when the inning is fully THROWN (phase
## TABULATE - Fix Pass 20: the round then posts ITSELF after
## the beat and the insert appears; the callers wait for
## INSERT - or OVER, which posts through the same beat).
## INSERT also completes it: the 0.75 s beat can elapse
## between polls while a slow scripted shot settles.
func play_scripted_inning(p_kinds: Array, ai_kinds: Array) -> bool:
	var p_i: int = 0
	var a_i: int = 0
	var guard: float = 0.0
	while guard < 240.0:
		main.ai_delay = 100000.0
		if String(main.phase) == "TABULATE" or String(main.phase) == "INSERT" \
				or String(main.phase) == "OVER":
			return p_i == p_kinds.size() and a_i == ai_kinds.size()
		if String(main.phase) == "P_TURN":
			if p_i >= p_kinds.size():
				return false
			if not await scripted_shot(String(p_kinds[p_i])):
				return false
			p_i += 1
		elif String(main.phase) == "AI_TURN":
			if not main.ai_throw_pending and main.ai_flight.is_empty():
				if a_i >= ai_kinds.size():
					return false
				if not await scripted_ai_throw(String(ai_kinds[a_i])):
					return false
				a_i += 1
		await create_timer(0.1).timeout
		guard += 0.1
	return false


## Fix Pass 12 / 19: worst distance (m) of any shoe from the
## slot the gather should have put it on, at the pitching end.
func max_slot_error() -> float:
	var worst: float = 0.0
	for s: Shoe in main._all_shoes():
		var slot: Transform3D = main.rack_slot_tf(40,
			main._is_ai_shoe(s), main._pair_index_of(s))
		worst = maxf(worst, s.global_position.distance_to(slot.origin))
	return worst


func all_railed() -> bool:
	for s: Shoe in main._all_shoes():
		if String(main.shoe_status[s]) != "RAILED":
			return false
	return true


## Fix Pass 12 / 19 / 20: park a fresh game at the round-end
## beat with a manufactured thrown inning (the win probes'
## method - honest path to the tabulation, no throws needed).
## Fix Pass 20: _begin_tabulate starts the settle beat; the
## round posts itself ~0.75 s later and the insert appears.
func manufacture_round() -> void:
	main.origin.global_transform = Transform3D.IDENTITY
	main.test_grip["L"] = 0.0
	main.test_grip["R"] = 0.0
	main.start_game()
	main.inning_results = [
		{"owner": "AI", "dist_in": 0.0, "ringer": true},
		{"owner": "P", "dist_in": 30.0, "ringer": false},
		{"owner": "P", "dist_in": 40.0, "ringer": false}]
	main._begin_tabulate()


## Pulse a game button through the production poll (the A/B
## test transport), the way the field presses it.
func pulse_button(btn: String) -> void:
	main.test_button[btn] = true
	await frames(4)
	main.test_button[btn] = false
	await frames(4)


## Pulse ONE hand's face button (the per-hand test
## transport) - the grip cycle walk needs per-hand presses
## (Fix Pass 22: any hand's A/X cycles, so the walk drives
## both hands on purpose).
func pulse_hand_button(hand: String, btn: String) -> void:
	var per: Dictionary = {}
	per[btn] = true
	main.test_button_hand[hand] = per
	await frames(4)
	main.test_button_hand.erase(hand)
	await frames(4)


## Fix Pass 25: drive a long-arm grab on instance m - park
## the hand at pos (far-tier range of m's stocked active
## shoe, NOT on a zone), squeeze, and wait for the latch.
func long_arm_grab(m: Node, hand: String, pos: Vector3) -> bool:
	m.test_hand_tf[hand] = Transform3D(Basis.IDENTITY, pos)
	m.test_grip[hand] = 1.0
	var t: float = 0.0
	while t < 3.0:
		if String(m.state) == "HELD":
			return true
		await create_timer(0.05).timeout
		t += 0.05
	return String(m.state) == "HELD"


## Fix Pass 25: release a held shoe on instance m with a
## still hand (a drop) and wait for it to restock (STAND).
func drop_and_restock(m: Node, hand: String) -> bool:
	var t0: float = 0.0
	while float(m.hand_speed[hand]) >= 0.3 and t0 < 3.0:
		await create_timer(0.05).timeout
		t0 += 0.05
	m.test_grip[hand] = 0.0
	var t: float = 0.0
	while t < 8.0:
		if String(m.state) == "STAND":
			return true
		await create_timer(0.1).timeout
		t += 0.1
	return String(m.state) == "STAND"


## Fix Pass 25: the last latch record in a recorder file.
func last_latch_record(rec: String) -> Dictionary:
	var out: Dictionary = {}
	var f: FileAccess = FileAccess.open(rec, FileAccess.READ)
	if f != null:
		for line: String in f.get_as_text().split("\n", false):
			var parsed: Variant = JSON.parse_string(line)
			if parsed is Dictionary and String(parsed.get("event", "")) == "latch":
				out = parsed
	return out


## Fix Pass 25: a fresh main instance on the given recorder
## + settings paths - the restart half of the settings
## round-trip (its _ready reads the settings file itself).
func spawn_fresh_main(rec: String, setp: String) -> Node:
	var ps2: PackedScene = load("res://main.tscn")
	var m2: Node = ps2.instantiate()
	m2.recorder_path = rec
	m2.settings_path = setp
	root.add_child(m2)
	return m2


## Hold the left stick forward (production walk input, FP4
## sign) for the given seconds - a plain straight walk down
## the lane from wherever the player stands.
func walk_forward_for(sec: float) -> void:
	main.test_stick["L"] = Vector2(0.0, 1.0)
	await create_timer(sec).timeout
	main.test_stick["L"] = Vector2.ZERO
	await frames(3)


## Fix Pass 15: tilt of a basis in degrees, measured HERE -
## from the Y axis (for any rotation, the image of world-up
## has y-component cos(tilt), and a pure yaw's is exactly 1)
## - never with the code under test's own ruler, and never
## with Quaternion.angle_to, whose float32 small-angle floor
## (~0.04 deg) once had the guard chasing a phantom.
func tilt_of(b: Basis) -> float:
	return rad_to_deg(acos(clampf(b.y.y, -1.0, 1.0)))


## Fix Pass 15: hold the head the way Chris holds it at the
## swap prompt - pitched down at the pit, some yaw, a touch
## of roll. Only the camera's LOCAL pose is set: the trackers
## own this transform on the headset and nothing in
## production writes it, which is the whole point - a head
## pose must be something the origin READS (its heading),
## never something that leaks into the origin's basis.
func pitch_head(deg: float) -> void:
	main.cam.transform = Transform3D(
		Basis.from_euler(Vector3(deg_to_rad(-deg), 0.4, deg_to_rad(2.5))),
		Vector3(0.05, 1.62, 0.02))


## Fix Pass 15: the origin reads level (pitch/roll 0.00 deg).
func check_origin_level(name: String) -> void:
	var t: float = tilt_of(main.origin.global_transform.basis)
	check(t < 0.005, "%s (origin tilt %.3f deg)" % [name, t])


## Fix Pass 15: let any in-flight AI turn finish before a
## section resets the game under it (the FP12 section's care).
func wait_ai_quiet() -> void:
	var waited: float = 0.0
	while waited < 15.0 and (main.ai_pitcher.is_throwing() or not main.ai_flight.is_empty()):
		await create_timer(0.25).timeout
		waited += 0.25


func _run() -> void:
	var rec_path: String = "user://smoke_throws.jsonl"
	if FileAccess.file_exists(rec_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(rec_path))
	# Fix Pass 25: the settings file is redirected too - the
	# default-grip round-trip must start from a first run and
	# must never read (or write) the player's real default.
	var set_path: String = "user://smoke_settings.json"
	if FileAccess.file_exists(set_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(set_path))
	var ps: PackedScene = load("res://main.tscn")
	main = ps.instantiate()
	main.recorder_path = rec_path
	main.settings_path = set_path
	root.add_child(main)
	await create_timer(0.3).timeout
	check(main != null, "main scene instantiated")

	# Rig binding: census names, one controller per hand, default pose.
	var rig_ctrls: Array[Node] = main.origin.find_children("*", "XRController3D", true, false)
	check(rig_ctrls.size() == 2, "rig has exactly one XRController3D per hand (%d)" % rig_ctrls.size())
	for h: String in ["L", "R"]:
		var hc: XRController3D = main.hand_ctrl[h]
		var want: StringName = &"left_hand" if h == "L" else &"right_hand"
		check(hc.tracker == want, "%s controller bound to %s (field census)" % [h, String(want)])
		check(hc.pose == &"default", "%s controller pose at class default" % h)
		var rep: Node3D = main.ctrl_rep[h]
		check(rep != null and rep.get_child_count() >= 3, "controller rep built for %s" % h)

	# Court pieces.
	check(main.shoe != null, "shoe exists")
	check(main.state == "STAND", "shoe starts on the stand")
	check(main.status_label != null and main.controls_label != null
		and main.score_label != null and main.board_breakdown_label != null
		and main.controls_label_r != null,
		"board labels exist (score, status, breakdown, two controls columns)")
	check(main.controls_full_text().contains("GRAB") and main.controls_full_text().contains("THROW")
		and main.controls_full_text().contains("SLIDE") and main.controls_full_text().contains("RECENTER"),
		"board lists every control (grab/slide/throw/recenter)")
	check(main.controls_full_text().contains("Left stick: move")
		and main.controls_full_text().contains("Right stick: turn"),
		"board lists the pass-6 standard stick controls (left moves, right turns)")
	check(main.controls_full_text().contains("30 FT LINE"),
		"board notes the 30 ft short line (pass 3)")
	check(main.controls_full_text().contains("A BUTTON")
		and main.controls_full_text().contains("B BUTTON"),
		"board lists the game buttons (A start/play again, B practice) - standing rule: every accepted command is listed")
	check(main.controls_full_text().contains("back to practice"),
		"FP19: the board's B line says what B does now - back to practice (no end-swap exists)")
	check(main.controls_full_text().contains("CHANGE GRIP"),
		"FP22: the board lists the grip cycle (A / X while holding a shoe) - standing rule: every accepted command is listed")
	check(main.controls_full_text().contains("A / X WHILE HOLDING A SHOE")
		and main.controls_full_text().contains("A BUTTON (EMPTY HAND)"),
		"FP22: the board's A/X lines carry their conditions - cycle while holding, game A with an empty hand")
	check(main.controls_full_text().contains("SQUEEZE FROM YOUR SPOT: SHOE COMES TO YOUR HAND"),
		"FP25: the board lists the long-arm grab - standing rule: every accepted command is listed")
	check(main.controls_full_text().contains("DEFAULT GRIP: TOE GRIP - SET BY CYCLING A HELD SHOE"),
		"FP25: the board names the default grip (smoke settings start clean: TOE GRIP)")
	check(main.status_label.text.contains("THROWS: 0"), "board starts at zero throws")

	# --- Backyard Game v1 / Fix Pass 19: one pit, pairs, the opponent ---
	check(main.stakes.size() == 1, "FP19: exactly ONE stake is built - the one-pit backyard (%d)" % main.stakes.size())
	var sp_far: Vector3 = main.stakes["FAR"]["pos"]
	check(sp_far.distance_to(main.STAKE_POS) < 0.001,
		"FP19: the one stake stands at the pit, 12.192 m from the old home stake's plane (at %s)" % str(sp_far))
	var home_pit_pieces: int = 0
	for child: Node in main.get_children():
		if child is MeshInstance3D and (child as MeshInstance3D).global_position.distance_to(Vector3(0.0, 0.25, 0.0)) < 0.75:
			home_pit_pieces += 1
	check(home_pit_pieces == 0,
		"FP19: no pit furniture stands at the old home end - the home pit is deleted (%d pieces)" % home_pit_pieces)
	check(absf(main.line_z_for_ft(40) - main.FOUL_40_Z) < 0.001
		and absf(main.line_z_for_ft(30) - main.FOUL_30_Z) < 0.001
		and absf(main.FOUL_40_Z + 0.914) < 0.001
		and absf(main.FOUL_30_Z + 3.962) < 0.001,
		"FP19: the foul lines are the TRUE lines at the pitching end (37 ft at -0.914, 27 ft at -3.962)")
	check(main.player_pair.size() == 2 and main.ai_pair.size() == 2,
		"two pairs of shoes: the player's and the AI's")
	for s: Shoe in main._all_shoes():
		var want_slot: Transform3D = main.rack_slot_tf(40,
			main._is_ai_shoe(s), main._pair_index_of(s))
		check(s.global_position.distance_to(want_slot.origin) < 0.01,
			"shoe hangs on its owner's rack at boot (%s pair, slot %d)"
			% ["AI" if main._is_ai_shoe(s) else "player", main._pair_index_of(s)])
		check(String(main.shoe_status[s]) == "RAILED", "boot shoe is stocked (RAILED)")
	# Fix Pass 11: the pairs stock on SEPARATE racks - v1 hung
	# all four shoes on one shared rack (Chris's report).
	check(main.player_pair[0].global_position.distance_to(
			main.rack_slot_tf(40, true, 0).origin) > 1.5
		and main.ai_pair[0].global_position.distance_to(
			main.rack_slot_tf(40, false, 0).origin) > 1.5,
		"FP11: each pair stocks on its OWN rack - never all four on one")
	check(main.player_pair[0].tint == main.PLAYER_PAIR_COLOR
		and main.ai_pair[0].tint == main.AI_PAIR_COLOR,
		"pairs wear their colours: yellow player, blue AI")
	var slot0_pos: Vector3 = main.rack_slot_tf(40, false, 0).origin
	var rail_pieces: int = 0
	for child: Node in main.get_children():
		if child is MeshInstance3D and (child as MeshInstance3D).global_position.distance_to(slot0_pos) < 1.0:
			rail_pieces += 1
	check(rail_pieces >= 4,
		"station furniture (timber body, rail, shelf) stands at the pitching end's 40 ft stock point (%d pieces)" % rail_pieces)
	check(main.ai_pitcher != null and main.ai_pitcher.is_inside_tree(),
		"the AI opponent character stands at the pitching end")
	# Fix Pass 19: the AI's box at the pitching end - behind
	# the 37 ft line, LEVEL with the player's stance depth,
	# ~1.6 m from the player's spot on the lane's other side,
	# facing the pit. (FP13's 3.6 m two-end layout was the
	# diagonal Chris threw out with the second pit.)
	check_ai_box()

	# --- Board placement (pass-10 re-derivation of the pass-2 guard) ---
	# Pass 1's board faced AWAY from the player; pass 2 moved it
	# front-left of the spot and the facing assertion dates from
	# that lesson. Fix Pass 10 (Chris's order) moves the board
	# BEYOND the pit, LEFT of the stake, face turned back at the
	# pitching end - results are read where he is already looking.
	# Assert: past the pit's far edge, left of the lane, ~16 m out,
	# face pointing back at the pitching spot.
	var bp: Vector3 = main.board_root.position
	var pit_far_z: float = main.STAKE_POS.z - main.PIT_SIZE.z * 0.5
	check(bp.z < pit_far_z - 2.0,
		"board sits BEYOND the pit (z %.2f, pit far edge %.2f)" % [bp.z, pit_far_z])
	check(bp.x < -1.5, "board is LEFT of the stake/lane (x %.2f)" % bp.x)
	var board_dist: float = Vector2(bp.x, bp.z).length()
	check(board_dist > 15.0 and board_dist < 17.5,
		"board is ~16 m from the pitching spot (%.2f m)" % board_dist)
	var face_dir: Vector3 = main.board_root.global_transform.basis.z
	face_dir.y = 0.0
	face_dir = face_dir.normalized()
	var to_spot: Vector3 = Vector3(0.0, 0.0, 0.0) - bp
	to_spot.y = 0.0
	to_spot = to_spot.normalized()
	check(face_dir.dot(to_spot) > 0.9,
		"board FACE points back at the pitching spot (dot %.3f)" % face_dir.dot(to_spot))
	check(main.board_slab_size.x >= 2.8,
		"board is scoreboard-sized for distance reading (slab %.1f m wide)" % main.board_slab_size.x)
	# Every label's rendered text block must fit its ZONE on
	# the face (font metrics, not eyeballs): this is the
	# standing guard that no line can silently outgrow the
	# board again. Fix Pass 39 re-derives it per label - the
	# fresh look gives each block its own zone (the score
	# its band, the breakdown the status block's place, the
	# controls two columns), so each is measured against
	# the zone it actually stands in.
	var fb_font: Font = ThemeDB.fallback_font
	var zones39: Dictionary = main.board_label_zones()
	var zone_of: Dictionary = {
		main.title_label: "title",
		main.score_label: "score",
		main.status_label: "status",
		main.board_breakdown_label: "breakdown",
		main.controls_label: "controls",
		main.controls_label_r: "controls",
	}
	for lbl: Label3D in zone_of.keys():
		var zone: Vector2 = zones39[String(zone_of[lbl])]
		var text_lines: PackedStringArray = lbl.text.split("\n")
		var w_max: float = 0.0
		for ln: String in text_lines:
			var lw: float = fb_font.get_string_size(ln, HORIZONTAL_ALIGNMENT_LEFT, -1.0, lbl.font_size).x * lbl.pixel_size
			w_max = maxf(w_max, lw)
		var n_lines: float = float(text_lines.size())
		if lbl == main.status_label:
			n_lines += 1.0 # worst case: the RINGER! line joins the block
		# Line pitch is the font's TRUE height (1.375x font_size
		# for the fallback font), not font_size itself - a first
		# cut at 1.0x passed this check while the rendered board
		# overlapped its own lines (pass-10 close-up proof).
		var h_tot: float = n_lines * fb_font.get_height(lbl.font_size) * lbl.pixel_size \
			+ (n_lines - 1.0) * lbl.line_spacing * lbl.pixel_size
		check(w_max <= zone.x and h_tot <= zone.y,
			"FP39: board label '%s...' fits its %s zone (%.2f x %.2f m in %.2f x %.2f)"
			% [text_lines[0], String(zone_of[lbl]), w_max, h_tot, zone.x, zone.y])
	# The boot text never exercises the widest line the board
	# can show - measure the worst-case blocks with each
	# label's own font: every status state the flow shows
	# (Fix Pass 39: the score line stands on its own label
	# now, so the status blocks no longer carry it), the
	# score at two digits, and the breakdown's 12-line
	# compound worst case composed from Scoring's own line
	# formats (cancelled ringers + a standing ringer + a
	# shut-out point shoe).
	# Fix Pass 44: every status block below carries the
	# SCORING mode line the board now appends - the worst
	# cases stay the REAL worst cases, mode line included
	# (PROXIMITY is the longer word).
	var worst39: Array = [
		[main.status_label, "status",
			"THROWS: 999\nHOLD: TURN (SHANK_RIGHT)\nLAST: 123.4 IN\nFLIP: -1.24 REV\nTURN: -1.24 REV\nRINGER!\nA: START GAME\nSCORING: PROXIMITY"],
		[main.status_label, "status",
			"ROUND 99 THROWN\nLAST: 123.4 IN\nFLIP: -1.24 REV\nTURN: -1.24 REV\nRINGER!\nSCORING: PROXIMITY"],
		[main.status_label, "status",
			"INNING 99 - YOUR THROW 2 OF 2\nLAST: 123.4 IN\nFLIP: -1.24 REV\nTURN: -1.24 REV\nLAST INNING: OPP +7 (OPP RINGER)\nSCORING: PROXIMITY"],
		[main.status_label, "status",
			"YOU WIN!\nFINAL - 99 INNINGS\nA: PLAY AGAIN\nB: PRACTICE\nSCORING: PROXIMITY"],
		[main.score_label, "score", "YOU 99 - 99 OPP"],
		[main.board_breakdown_label, "breakdown",
			"FINAL - OPP WINS\nOPP 1: RINGER\nOPP 2: RINGER\nYOU 1: NO SCORE (123.4 IN)\nYOU 2: 5.9 IN\nRINGERS CANCEL IN PAIRS\nOPP RINGER STANDS: +3\nOPP CLOSEST SHOE SCORES: +1\nCLOSEST ONLY SCORES\nROUND: OPP +4\nMATCH: YOU 99 - 99 OPP\nA - PLAY AGAIN"],
	]
	for wc: Array in worst39:
		var w_lbl: Label3D = wc[0]
		var w_zone: Vector2 = zones39[String(wc[1])]
		var w_lines: PackedStringArray = String(wc[2]).split("\n")
		var w_worst: float = 0.0
		for ln2: String in w_lines:
			w_worst = maxf(w_worst, fb_font.get_string_size(ln2, HORIZONTAL_ALIGNMENT_LEFT, -1.0, w_lbl.font_size).x * w_lbl.pixel_size)
		var h_worst: float = float(w_lines.size()) * fb_font.get_height(w_lbl.font_size) * w_lbl.pixel_size \
			+ float(w_lines.size() - 1) * w_lbl.line_spacing * w_lbl.pixel_size
		check(w_worst <= w_zone.x and h_worst <= w_zone.y,
			"FP39: worst-case %s block fits its zone (%d lines, %.2f x %.2f m in %.2f x %.2f)"
			% [String(wc[1]), w_lines.size(), w_worst, h_worst, w_zone.x, w_zone.y])

	# --- Scenery dressing (Fix Pass 10 comfort) ---
	# Static references at several distances against the flat
	# void; the guards keep the dressing OUT of the court and off
	# the board sightline from the foul lines.
	check(main.scenery_root != null, "scenery dressing exists (pass 10)")
	if main.scenery_root != null:
		var stripes: Node = main.scenery_root.get_node_or_null("Stripes")
		check(stripes != null and stripes.get_child_count() >= 10,
			"mow stripes dress the ground (%d bands)" % (stripes.get_child_count() if stripes != null else 0))
		var fence: Node = main.scenery_root.get_node_or_null("Fence")
		check(fence != null and fence.get_child_count() > 300,
			"perimeter fence rings the yard (%d pieces)" % (fence.get_child_count() if fence != null else 0))
		var shed: Node = main.scenery_root.get_node_or_null("Shed")
		check(shed != null, "the shed stands off to the side")
		if shed != null:
			check(sightline_dist((shed as Node3D).global_position) > 2.5,
				"shed keeps clear of the board sightline (%.1f m)" % sightline_dist((shed as Node3D).global_position))
		var n_trees: int = 0
		for child: Node in main.scenery_root.get_children():
			if child.name.begins_with("Tree"):
				n_trees += 1
				check(sightline_dist((child as Node3D).global_position) > 2.5,
					"%s keeps clear of the board sightline (%.1f m)" % [child.name, sightline_dist((child as Node3D).global_position)])
		check(n_trees >= 5, "trees stand at varied distances (%d)" % n_trees)
		var clouds: Node = main.scenery_root.get_node_or_null("Clouds")
		check(clouds != null and clouds.get_child_count() >= 4,
			"clouds ride the sky (%d puffs)" % (clouds.get_child_count() if clouds != null else 0))
		# Fix Pass 18: landscaped rows where the deleted practice
		# shelves stood. Guards: both rows exist with their berm
		# and dotted shrubs; the berm stays a LOW mound (crest
		# under 0.5 m); every plant stands clear of the lane,
		# stances and swing space and between the ends; and no
		# plant reaches into the foul-line -> board sightline
		# (height-aware: the eye line passes well above the row
		# at every z along it).
		var lane_rows: Node = main.scenery_root.get_node_or_null("LaneRows")
		check(lane_rows != null,
			"FP18: landscaped rows line the lane where the practice shelves stood")
		if lane_rows != null:
			var board_top: Vector3 = main.board_root.global_transform * Vector3(0.0, 1.85, 0.0)
			for row_name: String in ["RowL", "RowR"]:
				var row: Node = lane_rows.get_node_or_null(row_name)
				check(row != null, "FP18: %s exists" % row_name)
				if row == null:
					continue
				var berm: Node = row.get_node_or_null("Berm")
				check(berm != null
					and (berm as MeshInstance3D).global_position.y + (berm as MeshInstance3D).scale.y <= 0.5,
					"FP18: %s is a low grass mound (crest %.2f m)"
					% [row_name, (berm as MeshInstance3D).scale.y if berm != null else -1.0])
				var n_shrubs: int = 0
				for piece: Node in row.get_children():
					var mi := piece as MeshInstance3D
					if mi == null or piece.name == "Berm":
						continue
					n_shrubs += 1
					var gp: Vector3 = mi.global_position
					check(absf(gp.x) >= 1.4 and gp.z > -10.6 and gp.z < -1.6,
						"FP18: %s plant stands clear of the lane and swing space (at %s)"
						% [row_name, str(gp)])
					var top: float = gp.y + (mi.mesh as SphereMesh).radius * mi.scale.y
					var h_line: float = 1.62 + (board_top.y - 1.62) * (main.FOUL_40_Z - gp.z) / (main.FOUL_40_Z - board_top.z)
					check(top < h_line - 0.6,
						"FP18: %s plant stays under the board sightline (top %.2f m, line %.2f m)"
						% [row_name, top, h_line])
				check(n_shrubs >= 9,
					"FP18: %s carries its dotted plants (%d shrubs)" % [row_name, n_shrubs])
	# --- Stage A: the planted perimeter (Stage 2, the ground) ---
	# Beds, stone and the tree line are VISUAL ONLY - the
	# structural guards: the stage exists fully planted, no
	# collision hides anywhere under it, the tree line stands
	# on its surveyed spots, and every background canopy wears
	# the sway shader with a live amplitude. (Footprints are
	# guarded numerically in the logic suite.)
	var stage_a: Node = null
	if main.scenery_root != null:
		stage_a = main.scenery_root.get_node_or_null("StageA")
	check(stage_a != null, "Stage A: the planted perimeter exists")
	if stage_a != null:
		var n_colliders: int = 0
		var stack: Array = [stage_a]
		while not stack.is_empty():
			var nd: Node = stack.pop_back()
			if nd is CollisionObject3D or nd is CollisionShape3D:
				n_colliders += 1
			for ch: Node in nd.get_children():
				stack.append(ch)
		check(n_colliders == 0,
			"Stage A: no collision anywhere in the planted perimeter (%d found)" % n_colliders)
		var beds_node: Node = stage_a.get_node_or_null("Beds")
		check(beds_node != null, "Stage A: the beds are built")
		if beds_node != null:
			var n_mulch: int = 0
			for ch: Node in beds_node.get_children():
				if ch is MeshInstance3D:
					n_mulch += 1
			check(n_mulch == 4, "Stage A: four mulch beds (%d)" % n_mulch)
			var stones: Node = beds_node.get_node_or_null("Stones")
			check(stones != null and (stones as MultiMeshInstance3D).multimesh.instance_count >= 200,
				"Stage A: stone edging rings the beds (%d stones)"
				% ((stones as MultiMeshInstance3D).multimesh.instance_count if stones != null else 0))
			var n_shrubs_a: int = 0
			for fi: int in 3:
				var sh: Node = beds_node.get_node_or_null("Shrubs%d" % fi)
				if sh != null:
					n_shrubs_a += (sh as MultiMeshInstance3D).multimesh.instance_count
			# Stage B re-derivation: the beds shrank (the
			# patio took the rear run, the gate gap took a
			# bite, the fountain nook clears its circle), so
			# the planting floors drop with them - shrubs 28
			# -> 23 planted, tufts 146 -> ~119.
			check(n_shrubs_a >= 20, "Stage A: the beds are planted with shrubs (%d)" % n_shrubs_a)
			var tufts: Node = beds_node.get_node_or_null("Tufts")
			check(tufts != null and (tufts as MultiMeshInstance3D).multimesh.instance_count >= 110,
				"Stage A: ornamental grass tufts fill the beds (%d)"
				% ((tufts as MultiMeshInstance3D).multimesh.instance_count if tufts != null else 0))
			var flowers: Node = beds_node.get_node_or_null("Flowers")
			check(flowers != null and (flowers as MultiMeshInstance3D).multimesh.instance_count >= 80,
				"Stage A: flowering accents dot the beds (%d)"
				% ((flowers as MultiMeshInstance3D).multimesh.instance_count if flowers != null else 0))
		var trees_node: Node = stage_a.get_node_or_null("Trees")
		check(trees_node != null and trees_node.get_child_count() == main.stage_a_tree_spots().size(),
			"Stage A: the tree line stands beyond the fence (%d trees)"
			% (trees_node.get_child_count() if trees_node != null else 0))
		if trees_node != null:
			var spot0: Array = main.stage_a_tree_spots()[0]
			var want0: Vector3 = spot0[0]
			check((trees_node.get_child(0) as Node3D).global_position.distance_to(want0) < 0.01,
				"Stage A: tree line stands on its surveyed spots")
			var sway_ok: bool = true
			for t: Node in trees_node.get_children():
				for cn: Node in t.get_children():
					if cn.name == "Canopy":
						var m: ShaderMaterial = (cn as MeshInstance3D).material_override as ShaderMaterial
						if m == null or m.get_shader_parameter("sway_amp") == null \
								or float(m.get_shader_parameter("sway_amp")) <= 0.0:
							sway_ok = false
			check(sway_ok, "Stage A: every background canopy wears the sway shader")

	# --- Stage B: the yard pass (Stage 2, second instalment) ---
	# The patio, house rear and objects are VISUAL ONLY - the
	# structural guards: the stage exists dressed, no collision
	# hides anywhere under it, the house wall stands at the
	# patio's rear edge, and the named objects are all built.
	# (Footprints are guarded numerically in the logic suite.)
	var stage_b: Node = null
	if main.scenery_root != null:
		stage_b = main.scenery_root.get_node_or_null("StageB")
	check(stage_b != null, "Stage B: the yard pass exists")
	if stage_b != null:
		var n_colliders_b: int = 0
		var stack_b: Array = [stage_b]
		while not stack_b.is_empty():
			var ndb: Node = stack_b.pop_back()
			if ndb is CollisionObject3D or ndb is CollisionShape3D:
				n_colliders_b += 1
			for chb: Node in ndb.get_children():
				stack_b.append(chb)
		check(n_colliders_b == 0,
			"Stage B: no collision anywhere in the yard pass (%d found)" % n_colliders_b)
		var patio_n: Node = stage_b.get_node_or_null("Patio")
		check(patio_n != null, "Stage B: the patio is built")
		if patio_n != null:
			var pavers: Node = patio_n.get_node_or_null("Pavers")
			check(pavers != null and (pavers as MultiMeshInstance3D).multimesh.instance_count >= 100,
				"Stage B: the patio is paved (%d pavers)"
				% ((pavers as MultiMeshInstance3D).multimesh.instance_count if pavers != null else 0))
			var house_n: Node = patio_n.get_node_or_null("HouseRear")
			check(house_n != null and house_n.get_child_count() >= 15,
				"Stage B: the house rear stands dressed (%d pieces)"
				% (house_n.get_child_count() if house_n != null else 0))
			for obj_name: String in ["Grill", "Table", "Cooler"]:
				check(patio_n.get_node_or_null(obj_name) != null,
					"Stage B: the patio's %s is built" % obj_name)
			var n_pots: int = 0
			var n_chairs: int = 0
			for chp: Node in patio_n.get_children():
				if chp.name.begins_with("Pot"):
					n_pots += 1
			var table_n: Node = patio_n.get_node_or_null("Table")
			if table_n != null:
				for cht: Node in table_n.get_children():
					if cht.name.begins_with("Chair"):
						n_chairs += 1
			check(n_pots == 2, "Stage B: potted plants flank the back door (%d)" % n_pots)
			check(n_chairs == 3, "Stage B: three chairs ring the patio table (%d)" % n_chairs)
			# Fix Pass 28: each built chair's seat front
			# (-Z of its own basis) points at the table
			# centre in the world, not just in the data.
			var table_w: Node = patio_n.get_node_or_null("Table")
			if table_w != null:
				var centre_w: Vector3 = (table_w as Node3D).global_position
				for chw: Node in table_w.get_children():
					if chw.name.begins_with("Chair"):
						var ch3: Node3D = chw as Node3D
						var fw: Vector3 = -ch3.global_transform.basis.z
						fw.y = 0.0
						var tw: Vector3 = centre_w - ch3.global_position
						tw.y = 0.0
						check(fw.normalized().dot(tw.normalized()) >= 0.99,
							"Stage B: %s faces the table centre in the built yard" % chw.name)
		# Fountain: built in its corner nook, ringed, watered.
		var fountain_n: Node = stage_b.get_node_or_null("Fountain")
		check(fountain_n != null, "Stage B: the fountain stands in the left bed's corner nook")
		if fountain_n != null:
			check(fountain_n.get_node_or_null("Water") != null,
				"Stage B: the fountain's basin holds still water")
			var ring: Node = fountain_n.get_node_or_null("BasinStones")
			check(ring != null and (ring as MultiMeshInstance3D).multimesh.instance_count >= 10,
				"Stage B: the basin is stone-ringed (%d stones)"
				% ((ring as MultiMeshInstance3D).multimesh.instance_count if ring != null else 0))
			check(absf((fountain_n as Node3D).position.distance_to(
				main.STAGE_B_FOUNTAIN_POS)) < 0.01,
				"Stage B: the fountain sits at its surveyed nook")
		# The gate: its own group, pivoted at the hinge,
		# closed, and the fence really does open behind it.
		var gate_n: Node = stage_b.get_node_or_null("Gate")
		check(gate_n != null, "Stage B: the gate group exists")
		if gate_n != null:
			var gd: Dictionary = main.stage_b_gate()
			check(absf((gate_n as Node3D).position.x - float(gd["x"])) < 0.01
				and absf((gate_n as Node3D).position.z - float(gd["z_hinge"])) < 0.01,
				"Stage B: the gate pivots on its hinge post")
			check(absf((gate_n as Node3D).rotation.y) < 0.001,
				"Stage B: the gate stands CLOSED this pass")
			check(gate_n.get_child_count() >= 10,
				"Stage B: the gate panel is built (%d pieces)" % gate_n.get_child_count())
		var fence_gap_blocked: int = 0
		for fch: Node in main.scenery_root.get_node("Fence").get_children():
			var fm: Node3D = fch as Node3D
			if fm != null and fm.global_position.x > 12.9 \
					and fm.global_position.z > -6.60 and fm.global_position.z < -5.40:
				fence_gap_blocked += 1
		check(fence_gap_blocked == 0,
			"Stage B: the fence opening behind the gate is truly open (%d pieces in the gap)"
			% fence_gap_blocked)
		var path_n: Node = stage_b.get_node_or_null("PathStones")
		check(path_n != null and (path_n as MultiMeshInstance3D).multimesh.instance_count >= 12,
			"Stage B: the stepping-stone path runs from the gate (%d stones)"
			% ((path_n as MultiMeshInstance3D).multimesh.instance_count if path_n != null else 0))
		# Phineas: in his corner, facing the stake, and clear
		# of the scoreboard's sightline from the pitching spot.
		var phin_n: Node = stage_b.get_node_or_null("Phineas")
		check(phin_n != null, "Stage B: Phineas stands in his corner")
		if phin_n != null:
			var pp: Vector3 = (phin_n as Node3D).global_position
			check(pp.distance_to(main.STAGE_B_PHINEAS_POS) < 0.01,
				"Stage B: Phineas is at his surveyed corner")
			var fwd: Vector3 = -(phin_n as Node3D).global_transform.basis.z
			fwd.y = 0.0
			var to_stake: Vector3 = main.STAKE_POS - pp
			to_stake.y = 0.0
			check(fwd.normalized().dot(to_stake.normalized()) > 0.9,
				"Stage B: Phineas faces the court and the stake (dot %.2f)"
				% fwd.normalized().dot(to_stake.normalized()))
			check(sightline_dist(pp) > 1.5,
				"Stage B: Phineas keeps clear of the board sightline (%.2f m)"
				% sightline_dist(pp))
			check(phin_n.get_node_or_null("GoldPan") != null,
				"Stage B: the gold pan is in his hand")
			# Fix Pass 29: he stands in a clear pocket - NO
			# planted shrub anywhere near him (he first
			# stood in the far bed with a shrub through his
			# legs). The measure reads the builder's own
			# placement record (main.stage_a_shrub_positions
			# - the origins the shrub MultiMeshes were built
			# from): MultiMesh instance transforms cannot be
			# read back under the headless dummy renderer
			# (probed in isolation this pass - every instance
			# reads as identity), so the record is the
			# measurable truth, cross-checked here against
			# the built multimeshes' instance counts.
			var planted: Array = main.stage_a_shrub_positions
			check(planted.size() > 0,
				"Stage B: the planted shrub record stands (%d shrubs)" % planted.size())
			var beds_b: Node = null
			if main.scenery_root != null:
				var stage_a_b: Node = main.scenery_root.get_node_or_null("StageA")
				if stage_a_b != null:
					beds_b = stage_a_b.get_node_or_null("Beds")
			var n_built_shrubs: int = 0
			if beds_b != null:
				for fi2: int in 3:
					var shn: Node = beds_b.get_node_or_null("Shrubs%d" % fi2)
					if shn != null:
						n_built_shrubs += (shn as MultiMeshInstance3D).multimesh.instance_count
			check(n_built_shrubs == planted.size(),
				"Stage B: the built shrubs match the placement record (%d built, %d recorded)"
				% [n_built_shrubs, planted.size()])
			var min_shrub_d: float = 1.0e9
			for sp2: Vector3 in planted:
				var d2: float = Vector2(sp2.x - pp.x, sp2.z - pp.z).length()
				if d2 < min_shrub_d:
					min_shrub_d = d2
			check(min_shrub_d > 0.85,
				"Stage B: no shrub intersects Phineas in his pocket (nearest %.2f m)"
				% min_shrub_d)
		# Fix Pass 29: the gate approach stands clear - no
		# tree trunk (foreground scatter or background line)
		# within 1.2 m laterally of the gate's centre axis
		# on the approach side, so the stepping-stone path
		# and the gate opening read clear from the court.
		if main.scenery_root != null:
			var gate_d2: Dictionary = main.stage_b_gate()
			var axis_z: float = (float(gate_d2["z_hinge"]) + float(gate_d2["z_latch"])) * 0.5
			var trunks_checked: int = 0
			var trunks_clear: bool = true
			var trunk_parents: Array = []
			for sc: Node in main.scenery_root.get_children():
				if sc.name.begins_with("Tree"):
					trunk_parents.append(sc)
			var stage_a_t: Node = main.scenery_root.get_node_or_null("StageA")
			if stage_a_t != null:
				var trees_t: Node = stage_a_t.get_node_or_null("Trees")
				if trees_t != null:
					for tc: Node in trees_t.get_children():
						trunk_parents.append(tc)
			for tn: Node in trunk_parents:
				var tp2: Vector3 = (tn as Node3D).global_position
				if tp2.x > 2.0 and tp2.x < 13.2:
					trunks_checked += 1
					if absf(tp2.z - axis_z) < 1.2:
						trunks_clear = false
			check(trunks_clear and trunks_checked > 0,
				"Stage B: the gate approach stands clear of tree trunks (%d in the corridor)"
				% trunks_checked)

	var sky_ok: bool = false
	for child: Node in main.get_children():
		if child is WorldEnvironment:
			sky_ok = (child as WorldEnvironment).environment.background_mode == Environment.BG_SKY
	check(sky_ok, "a real sky replaces the flat clear colour")

	# --- Stage B (the light): time of day, fire, birds ---
	# The fire pit stands built on the patio with its lit
	# half cold at NOON; the flock rides one mover, hidden.
	var fire_n: Node = null
	if main.scenery_root != null:
		fire_n = main.scenery_root.get_node_or_null("StageB/Patio/FirePit")
	check(fire_n != null, "Stage B light: the fire pit is built on the patio")
	if fire_n != null:
		check(fire_n.get_node_or_null("Flames") != null
			and fire_n.get_node_or_null("Embers") != null
			and fire_n.get_node_or_null("FireLight") != null,
			"Stage B light: the pit carries its flames, embers and one light")
		var fire_spots: Array = main.stage_b_object_spots()
		for fs: Array in fire_spots:
			if String(fs[0]) == "fire_pit":
				var fsp: Vector3 = fs[1]
				check((fire_n as Node3D).global_position.distance_to(fsp) < 0.01,
					"Stage B light: the built pit stands at its surveyed spot")
	check(main.bird_root != null
		and main.bird_root.get_child_count() == main.BIRD_COUNT_MAX,
		"Stage B light: the flock rides one mover (%d birds)"
		% (main.bird_root.get_child_count() if main.bird_root != null else 0))
	if main.bird_root != null:
		var wings_ok: bool = true
		for bd: Node in main.bird_root.get_children():
			if bd.get_node_or_null("WingL") == null \
					or bd.get_node_or_null("WingR") == null:
				wings_ok = false
		check(wings_ok, "Stage B light: every bird is a two-wing silhouette, not a sphere")
		check(not main.bird_active and not main.bird_root.visible,
			"Stage B light: no crossing is up at first run - birds are occasional")
	# The control state machine, through the production
	# button poll: B/Y in practice cycles; the board names
	# the selection; the fire is lit exactly at DUSK.
	check(main.time_of_day == "NOON",
		"Stage B light: a first run starts at NOON (the accepted look)")
	check(main.controls_full_text().contains(
		"TIME: NOON - B/Y IN PRACTICE: CHANGE TIME"),
		"Stage B light: the board names the time and its control - standing rule: every accepted command is listed")
	check(not main.fire_is_lit() and main.fire_light != null
		and not main.fire_light.visible,
		"Stage B light: the fire stands cold at NOON - no flames, no light")
	await pulse_hand_button("L", "B") # the left hand's Y counts too
	check(main.time_of_day == "DUSK",
		"Stage B light: B/Y in practice cycles NOON -> DUSK")
	await frames(6)
	check(main.fire_is_lit() and main.fire_light.visible
		and main.fire_light.light_energy > 1.0,
		"Stage B light: the fire is LIT at dusk (flickering, energy %.2f)"
		% main.fire_light.light_energy)
	check(main.controls_full_text().contains("TIME: DUSK"),
		"Stage B light: the board re-names the selection at DUSK")
	var dusk_preset: Dictionary = main.time_of_day_presets()["DUSK"]
	var dusk_euler: Vector3 = dusk_preset["sun_euler"]
	# Tolerance, not equality: the sun's euler reads back
	# through its basis with a float32 hair in it (probed:
	# (-11, 32, 0) prints exact and still fails ==).
	check((main.sun_light.rotation_degrees - dusk_euler).length() < 0.05
		and absf(main.world_env.ambient_light_energy
			- float(dusk_preset["ambient_energy"])) < 0.0001,
		"Stage B light: the DUSK preset drives the sun and ambient")
	await pulse_button("B")
	check(main.time_of_day == "CLOUDY" and not main.fire_is_lit(),
		"Stage B light: DUSK -> CLOUDY, and the fire goes cold")
	check(main.controls_full_text().contains("TIME: CLOUDY"),
		"Stage B light: the board re-names the selection at CLOUDY")
	await pulse_button("B")
	check(main.time_of_day == "NOON",
		"Stage B light: CLOUDY -> NOON - the cycle closes")
	# In a game, B keeps its job and the press is spent on
	# the exit: the time must NOT change with it.
	main.start_game()
	check(main.mode == "GAME", "Stage B light: a game starts for the B test")
	await pulse_button("B")
	check(main.mode == "PRACTICE" and main.time_of_day == "NOON",
		"Stage B light: B in a game returns to practice WITHOUT changing the time")
	# Persistence: the selection rides the settings file
	# beside the default grip, across a fresh instance.
	main.set_time_of_day("DUSK")
	var m2b: Node = spawn_fresh_main(rec_path, set_path)
	await frames(4)
	check(String(m2b.time_of_day) == "DUSK" and m2b.fire_is_lit(),
		"Stage B light: a fresh instance restores DUSK from the settings file, fire lit")
	m2b.queue_free()
	await frames(3)
	# A corrupt settings file falls back to NOON, grip 0.
	var bad_path: String = "user://smoke_settings_bad.json"
	var bf: FileAccess = FileAccess.open(bad_path, FileAccess.WRITE)
	bf.store_string("{not json")
	bf.close()
	var m3b: Node = spawn_fresh_main(rec_path, bad_path)
	await frames(4)
	check(String(m3b.time_of_day) == "NOON" and int(m3b.default_grip) == 0,
		"Stage B light: a corrupt settings file falls back to NOON / TOE GRIP")
	m3b.queue_free()
	await frames(3)
	# Fix Pass 31 migration: a settings file written by the
	# shipped build, holding MORNING, loads as CLOUDY - the
	# state that replaced it - with the fire cold.
	var legacy_path: String = "user://smoke_settings_legacy.json"
	var lf: FileAccess = FileAccess.open(legacy_path, FileAccess.WRITE)
	lf.store_string(JSON.stringify(
		{"default_grip": 0, "time_of_day": "MORNING"}))
	lf.close()
	var m4b: Node = spawn_fresh_main(rec_path, legacy_path)
	await frames(4)
	check(String(m4b.time_of_day) == "CLOUDY" and not m4b.fire_is_lit(),
		"Fix Pass 31: a saved MORNING loads as CLOUDY, fire cold")
	m4b.queue_free()
	await frames(3)
	main.set_time_of_day("NOON")
	# Birds: the hook forces a crossing; it moves on the
	# mover and despawns past the yard.
	main.debug_force_bird_crossing()
	check(main.bird_active and main.bird_root.visible,
		"Stage B light: the hook forces a crossing on demand")
	var bird_x0: float = main.bird_root.position.x
	await create_timer(0.6).timeout
	check(absf(main.bird_root.position.x - bird_x0) > 2.0,
		"Stage B light: the crossing moves (%.1f m in 0.6 s)"
		% absf(main.bird_root.position.x - bird_x0))
	main.bird_root.position = main.bird_dir * 100.0
	await frames(4)
	check(not main.bird_active and not main.bird_root.visible,
		"Stage B light: the crossing despawns past the yard - gone, not parked")
	# --- Impact Dressing: plumes, divots, sounds ---
	check(main.fx != null, "Impact Dressing: the FX node is built")
	check(main.shoe.impact_callback.is_valid(),
		"Impact Dressing: the shoe's impact hook is wired to main")
	var thuds0: int = 0
	for e0: Dictionary in main.fx.play_log:
		if String(e0["event"]) == "sand_thud":
			thuds0 += 1
	for k: int in 3:
		main.fx.debug_surface_impact(ImpactFX.KIND_SAND,
			Vector3(0.15 * float(k), 0.02, -12.05 + 0.2 * float(k)),
			Vector3(0.0, -3.0, -6.0), 0.95)
	# Fix Pass 37: sand landings stamp NO decal divots - in
	# the pit the mark is a real dent in the deformable sand
	# surface (stamped by main, proven in the latch section
	# below). The decal pool serves the lawn alone now.
	check(main.fx.divot_count() == 0,
		"Impact Dressing (FP37): sand landings stamp no decals - their mark is the dent (%d)"
		% main.fx.divot_count())
	var thuds1: int = 0
	for e1: Dictionary in main.fx.play_log:
		if String(e1["event"]) == "sand_thud":
			thuds1 += 1
	check(thuds1 == thuds0 + 3,
		"Impact Dressing: each sand landing routes its thud (%d -> %d)" % [thuds0, thuds1])
	main.fx.debug_surface_impact(ImpactFX.KIND_TURF,
		Vector3(1.2, 0.0, -6.0), Vector3(0.0, -2.0, -4.0), 0.8)
	check(main.fx.divot_count() == 1,
		"Impact Dressing (FP37): a grass landing adds its lighter scuff - the decal's remaining surface")
	var thuds2: int = 0
	var grass_thuds: int = 0
	for e2: Dictionary in main.fx.play_log:
		if String(e2["event"]) == "sand_thud":
			thuds2 += 1
		elif String(e2["event"]) == "grass_thud":
			grass_thuds += 1
	check(thuds2 == thuds1,
		"Impact Dressing: a grass landing never borrows the sand thud")
	check(grass_thuds == 1,
		"Impact Dressing (FP33): a grass landing sounds its own soft thud")
	# The in-flight gate: the same impact reported while the
	# shoe is NOT flying (at rest / held / hopping) is refused.
	# Fix Pass 37: the staged point sits off-stake, where a
	# leaked stamp WOULD dent - the surface must not move.
	var divots_before_gate: int = main.fx.divot_count()
	var depth_before_gate: float = main.sand_surface().max_abs_height()
	main._on_surface_impact(Shoe.ABSORB_SAND,
		Vector3(0.25, 0.02, -12.0), Vector3(0.0, -3.0, -6.0), 0.95, main.shoe)
	check(main.fx.divot_count() == divots_before_gate
		and is_equal_approx(main.sand_surface().max_abs_height(), depth_before_gate),
		"Impact Dressing: a resting shoe raises no plume, divot, dent, or thud")
	# Fix Pass 32: the one-plume-per-flight latch, through
	# main's own handler: two absorption episodes inside one
	# flight fire ONE plume but stamp BOTH marks (the bounce
	# re-fires were the lingering sparkle cluster). Fix Pass
	# 37: in the pit the mark is a DENT - both episodes punch
	# their own crater, staged off-stake where the stake
	# guard lets dents land.
	var state_was: String = main.state
	main.state = "FLYING"
	main._plume_flown[main.shoe] = false
	var latch_fires0: int = main.fx.debug_plume_fire_count()
	var latch_div0: int = main.fx.divot_count()
	main._on_surface_impact(Shoe.ABSORB_SAND,
		Vector3(-0.25, 0.02, -11.95), Vector3(0.0, -3.0, -6.0), 0.95, main.shoe)
	main._on_surface_impact(Shoe.ABSORB_SAND,
		Vector3(0.30, 0.02, -12.50), Vector3(0.0, -2.0, -4.0), 0.40, main.shoe)
	check(main.fx.debug_plume_fire_count() == latch_fires0 + 1,
		"Impact Dressing (FP32): two episodes in one flight fire ONE plume")
	check(main.fx.divot_count() == latch_div0
		and main.sand_surface().depth_at(Vector3(-0.25, 0.02, -11.95)) > 0.004
		and main.sand_surface().depth_at(Vector3(0.30, 0.02, -12.50)) > 0.002,
		"Impact Dressing (FP37): both episodes still stamp their mark - a dent each, no decals")
	main.state = state_was
	# The rake: the restock funnel cleans the pit.
	main._gather_to_rail(40)
	check(main.fx.divot_count() == 0,
		"Impact Dressing: restock rakes the pit clean for the next round")
	check(main.sand_surface().max_abs_height() < 0.0001,
		"Impact Dressing (FP37): the same restock flattens the pit's dents")
	# Fix Pass 37: THE SINK + SCORING. A shoe staged around
	# the stake with a full-strength flight stamp sinks the
	# full depth through main's production settle helper -
	# and the game's own measures still call it a ringer,
	# because both read horizontally. A point shoe keeps its
	# exact distance through the same sink.
	var sh37: Shoe = main.shoe
	sh37.freeze = true
	sh37.global_transform = Transform3D(Basis.IDENTITY,
		Vector3(main.STAKE_POS.x, 0.02, main.STAKE_POS.z))
	await physics_frame
	var at37 := Vector3(main.STAKE_POS.x, sh37.global_position.y,
		main.STAKE_POS.z)
	var ring_pre: bool = ThrowMath.is_ringer(sh37.global_transform, at37,
		Shoe.RINGER_INNER_HALF, Shoe.RINGER_Z_MIN, Shoe.RINGER_Z_MAX)
	sh37.debug_set_flight_sand_strength(1.0)
	var sunk37: float = main._sink_settled_shoe(sh37)
	check(ring_pre and sunk37 > 0.014,
		"FP37 sink: a full-strength arrival at the stake sinks (%.4f m)" % sunk37)
	var at37b := Vector3(main.STAKE_POS.x, sh37.global_position.y,
		main.STAKE_POS.z)
	check(ThrowMath.is_ringer(sh37.global_transform, at37b,
			Shoe.RINGER_INNER_HALF, Shoe.RINGER_Z_MIN, Shoe.RINGER_Z_MAX),
		"FP37 scoring: a half-buried ringer still registers as a ringer")
	sh37.global_transform = Transform3D(Basis.IDENTITY,
		Vector3(main.STAKE_POS.x + 0.32, 0.02, main.STAKE_POS.z))
	await physics_frame
	var at37c := Vector3(main.STAKE_POS.x, sh37.global_position.y,
		main.STAKE_POS.z)
	var dist_pre37: float = ThrowMath.nearest_distance_inches(
		sh37.global_transform, at37c, Shoe.WIDTH * 0.5, Shoe.LENGTH * 0.5)
	main._sink_settled_shoe(sh37)
	var at37d := Vector3(main.STAKE_POS.x, sh37.global_position.y,
		main.STAKE_POS.z)
	check(absf(ThrowMath.nearest_distance_inches(sh37.global_transform,
			at37d, Shoe.WIDTH * 0.5, Shoe.LENGTH * 0.5) - dist_pre37) < 0.01,
		"FP37 scoring: a buried point shoe measures its true distance (%.2f in)"
			% dist_pre37)
	main._gather_to_rail(40)
	# A full game at DUSK: manufactured rounds (the win
	# probes' method) to 21 - the game must complete under
	# dusk light, with the insert carrying its breakdown.
	main.set_time_of_day("DUSK")
	main.start_game()
	var dusk_rounds: int = 0
	while main.mode == "GAME" and main.phase != "OVER" and dusk_rounds < 12:
		await wait_ai_quiet()
		main.inning_results = [
			{"owner": "AI", "dist_in": 0.0, "ringer": true},
			{"owner": "P", "dist_in": 30.0, "ringer": false},
			{"owner": "P", "dist_in": 40.0, "ringer": false}]
		main._begin_tabulate()
		var waited_d: float = 0.0
		while waited_d < 10.0 and main.phase != "INSERT" \
				and main.phase != "OVER":
			await create_timer(0.1).timeout
			waited_d += 0.1
		dusk_rounds += 1
		if main.phase == "INSERT":
			check(main.board_breakdown_up
				and main.board_breakdown_label.text.contains("OPP +3"),
				"Stage B light: the scoreboard carries its breakdown at DUSK (round %d)"
				% dusk_rounds)
			await pulse_button("A")
	check(main.phase == "OVER" and main.score_opp >= 21,
		"Stage B light: a full game completes at DUSK (%d rounds, opponent %d)"
		% [dusk_rounds, main.score_opp])
	check(main.board_breakdown_up
		and main.board_breakdown_label.text.contains("FINAL"),
		"Stage B light: the final breakdown stands on the scoreboard at DUSK")
	main.set_time_of_day("NOON")
	await pulse_button("B") # exit the finished game - spent on the exit
	check(main.mode == "PRACTICE" and main.time_of_day == "NOON",
		"Stage B light: the yard is left in practice at NOON for the sections below")

	# --- Rack layout beside the stances (Fix Pass 11 re-derivation
	# of the pass-3 stance-box guards) ---
	# FP2 measured the stand from the SPAWN point (0.61 m) and called
	# it fine; Chris's photo showed it sitting on the foul line where
	# his stance goes, and the pass-3 guards fixed that by measuring
	# against the STANCE BOX at each line (|x| <= 0.85, line z
	# +/- 0.40). V1 kept the pass-3 slot-0 spot (0.75 m to the side,
	# 0.5 m BEHIND the line) for a shared four-slot rack.
	# Chris's v1 field reports killed both halves of that: the rack
	# sat directly behind him ("should be on right or left of line,
	# facing player so you can just reach over, grab a shoe, without
	# turning around"), both pairs hung on the one rack, and the AI
	# stood on his side of the pit in his grill. The FP11 layout the
	# helper below asserts, for every rack at both ends and lines:
	# slot 0 hangs AT its line's z, 1.0 m to its owner's side (the
	# player's racks on his right at both ends, the AI's mirrored
	# across the pit); every slot is outside the stance box and a
	# reach-over grab (0.90-1.35 m from the stance centre).
	# (FP18 narrowed "every rack": the AI's 30 ft racks no
	# longer exist to be asserted. FP19 narrows it again:
	# there is ONE end - the pitching end - and the racks are
	# asserted against each owner's SPOT there, below.)
	# Fix Pass 18 (Chris's Stage 1 verdict): the stock-point map
	# itself changed shape - the player keeps both lines at
	# both ends (the 30 ft peg post is his practice home), the
	# AI stocks ONLY at the 40 ft game lines: it never
	# practices, so it has no 30 ft point at all.
	check(main.stand_tfs.size() == 2,
		"FP19: the player stocks at both foul lines at the one pitching end (%d)"
		% [main.stand_tfs.size()])
	check(main.ai_stand_tfs.size() == 1 and not main.ai_stand_tfs.has(30),
		"FP18/19: the AI stocks only at the 40 ft game station - no practice stock point (%d)"
		% [main.ai_stand_tfs.size()])
	# Fix Pass 35: both 40 ft stations are corner stations
	# on the grass now - the shelf in front of the fountain,
	# the AI's on the opposing side - each with its own
	# guard, not check_rack.
	check_game_station(false)
	check_game_station(true)
	# The player's 30 ft slots keep their full FP13 layout
	# geometry - the slim peg post hangs the pair exactly
	# where the deleted shelf did.
	check_rack(30, false)
	# Fix Pass 18: what STANDS at the practice points - the
	# player's 30 ft home is ONE slim peg post (a post and two
	# pegs, nothing else), and at the AI's deleted 30 ft points
	# no furniture stands at all.
	var post_slot: Vector3 = main.rack_slot_tf(30, false, 0).origin
	var post_pieces: int = 0
	for child: Node in main.get_children():
		if child is MeshInstance3D and (child as MeshInstance3D).global_position.distance_to(post_slot) < 0.55:
			post_pieces += 1
	check(post_pieces == 3,
		"FP18/19: the 27 ft practice home is one slim peg post (post + two pegs, %d pieces)"
		% post_pieces)
	# Fix Pass 19: the far end carries NO stations - nobody
	# pitches from there. (The FP18-era far player station
	# stood at (1.22, 1.05, -12.192); nothing may stand there.)
	var ghost_pieces: int = 0
	for child2: Node in main.get_children():
		if child2 is MeshInstance3D and (child2 as MeshInstance3D).global_position.distance_to(Vector3(1.22, 1.05, -12.192)) < 0.55:
			ghost_pieces += 1
	check(ghost_pieces == 0,
		"FP19: no station furniture stands at the far end (%d pieces)" % ghost_pieces)
	check(main.active_stand_line_ft == 40, "the shoe starts homed to the 40 ft rack")

	# --- Locomotion through the production path (test stick hooks) ---
	# Pass-6 mapping (STANDARD twin-stick, Chris's field order): the
	# LEFT stick walks, with the FP4 field-corrected Y (his forward
	# push reads y=+1 on this rig), and the RIGHT stick X turns
	# smoothly (Fix Pass 5 math). The two blend (checked below).
	main.test_stick["L"] = Vector2(0.0, 1.0)
	await create_timer(2.0).timeout
	main.test_stick["L"] = Vector2.ZERO
	var walked: Vector3 = main.origin.global_position
	check(walked.z < -3.2 and walked.z > -4.8 and absf(walked.x) < 0.3,
		"left stick forward push walks the origin ~4 m in the facing direction in 2 s (got %s)" % str(walked))
	# Regression: the pass-4/5 assignment is dead - the right stick
	# no longer walks (its Y is unused; a full 0.5 s forward push
	# must not move the player).
	main.test_stick["R"] = Vector2(0.0, 1.0)
	await create_timer(0.5).timeout
	main.test_stick["R"] = Vector2.ZERO
	check(main.origin.global_position.distance_to(walked) < 0.01,
		"right stick no longer walks (pass-6 regression, moved %.3f m)" % main.origin.global_position.distance_to(walked))
	# Left stick X strafes with the unchanged sign and no longer
	# turns (heading must hold while the origin slides +X).
	var heading_lx: Vector3 = main.origin.global_transform.basis * Vector3(0.0, 0.0, -1.0)
	main.test_stick["L"] = Vector2(1.0, 0.0)
	await create_timer(0.5).timeout
	main.test_stick["L"] = Vector2.ZERO
	var heading_lx2: Vector3 = main.origin.global_transform.basis * Vector3(0.0, 0.0, -1.0)
	var lx_turn: float = rad_to_deg(Vector2(heading_lx.x, heading_lx.z).angle_to(
		Vector2(heading_lx2.x, heading_lx2.z)))
	check(absf(lx_turn) < 1.5,
		"left stick no longer turns (pass-6 regression, turned %.1f deg)" % lx_turn)
	check(main.origin.global_position.x > walked.x + 0.3,
		"left stick X strafes +X with the unchanged sign (x %.2f -> %.2f)" % [walked.x, main.origin.global_position.x])
	# Right stick X turns SMOOTHLY about the camera (Fix Pass 5
	# math, re-pointed at the right stick in Pass 6):
	# hold a full push, sampling the heading every ~0.1 s of real
	# time. The measured RATE must land at ~100 deg/s (timer pacing
	# varies between environments, so the assertion is on rate, not
	# a fixed total), no sampled step may come anywhere near the
	# old 30 deg snap, and the player must not translate. Against
	# the old snap both assertions fail: one 30 deg step, then a
	# ~44 deg/s average while the stick sits latched.
	var pre_turn: Vector3 = main.origin.global_position
	var last_heading: Vector3 = main.origin.global_transform.basis * Vector3(0.0, 0.0, -1.0)
	var max_step: float = 0.0
	var total_turn: float = 0.0
	main.test_stick["R"] = Vector2(1.0, 0.0)
	var turn_t0: int = Time.get_ticks_msec()
	for i: int in 5:
		await create_timer(0.1).timeout
		var h_now: Vector3 = main.origin.global_transform.basis * Vector3(0.0, 0.0, -1.0)
		var step_deg: float = absf(rad_to_deg(Vector2(last_heading.x, last_heading.z).angle_to(
			Vector2(h_now.x, h_now.z))))
		max_step = maxf(max_step, step_deg)
		total_turn += step_deg
		last_heading = h_now
	main.test_stick["R"] = Vector2.ZERO
	var turn_secs: float = float(Time.get_ticks_msec() - turn_t0) / 1000.0
	var turn_rate: float = total_turn / maxf(turn_secs, 0.001)
	check(turn_rate > 70.0 and turn_rate < 130.0,
		"right stick held turns smoothly at ~100 deg/s (got %.0f deg/s over %.2f s)" % [turn_rate, turn_secs])
	check(max_step < 24.0,
		"turning has NO STEP: largest sampled heading change %.1f deg (the old snap jumped 30 at once)" % max_step)
	check(main.origin.global_position.distance_to(pre_turn) < 0.01,
		"smooth turn does not translate the player (moved %.3f m)" % main.origin.global_position.distance_to(pre_turn))
	await frames(2)
	main.origin.global_transform = Transform3D.IDENTITY
	# --- BLEND (Pass 6): both sticks at once must curve the path ---
	# Left stick forward (walk) AND right stick sideways (turn),
	# held together for ~0.5 s. The player must BOTH displace
	# (> 0.5 m - a curved walk, not a turn in place) AND change
	# heading (> 20 deg of smooth turn), with no single sampled
	# step anywhere near the old snap. Neither stick alone can
	# produce both effects, so this fails if either assignment or
	# the same-frame application breaks.
	var blend_from: Vector3 = main.origin.global_position
	var blend_last: Vector3 = main.origin.global_transform.basis * Vector3(0.0, 0.0, -1.0)
	var blend_max_step: float = 0.0
	var blend_total: float = 0.0
	main.test_stick["L"] = Vector2(0.0, 1.0)
	main.test_stick["R"] = Vector2(1.0, 0.0)
	for i: int in 5:
		await create_timer(0.1).timeout
		var bh_now: Vector3 = main.origin.global_transform.basis * Vector3(0.0, 0.0, -1.0)
		var b_step: float = absf(rad_to_deg(Vector2(blend_last.x, blend_last.z).angle_to(
			Vector2(bh_now.x, bh_now.z))))
		blend_max_step = maxf(blend_max_step, b_step)
		blend_total += b_step
		blend_last = bh_now
	main.test_stick["L"] = Vector2.ZERO
	main.test_stick["R"] = Vector2.ZERO
	var blend_disp: float = main.origin.global_position.distance_to(blend_from)
	check(blend_disp > 0.5,
		"blended input walks WHILE turning: displaced %.2f m in ~0.5 s (walk alone would give ~1 m, turn alone ~0)" % blend_disp)
	check(blend_total > 20.0,
		"blended input turns WHILE walking: heading changed %.1f deg in ~0.5 s" % blend_total)
	check(blend_max_step < 24.0,
		"blended turning has NO STEP: largest sampled heading change %.1f deg" % blend_max_step)
	await frames(2)
	main.origin.global_transform = Transform3D.IDENTITY

	# --- Grab via production path (test hand at the toe zone) ---
	var toe_c: Vector3 = main.shoe.zone_world_center("toe")
	main.test_hand_tf["R"] = Transform3D(Basis.IDENTITY, toe_c)
	main.test_grip["R"] = 1.0
	await frames(5)
	check(main.grab_state.latched, "grab latches through the production path")
	check(main.state == "HELD", "shoe is HELD after latch")
	check(main.held_zone == "toe" and main.held_hold == "flip", "toe grab gives the FLIP hold")

	# --- Sticky slide, pass-2 model: grip + trigger (Chris's spec) ---
	# Let the tracked hand speed settle first (the test hand teleports
	# to the zone; its speed estimate spikes for a few frames).
	for i: int in 40:
		if float(main.hand_speed["R"]) < 0.3:
			break
		await process_frame
	var shoe_pos_before: Vector3 = main.shoe.global_position
	# The pass-1 way in must be gone: loosen to the mid grip band.
	main.test_grip["R"] = 0.5
	await frames(4)
	check(not main.grab_state.sliding and not main.grab_state.slide_mode,
		"mid grip band no longer enters slide (pass-2 removal)")
	main.test_grip["R"] = 1.0
	await frames(2)
	# Chris's way in: trigger pressed while the grip stays held.
	main.test_trigger["R"] = 1.0
	await frames(4)
	check(main.grab_state.sliding and main.grab_state.slide_mode,
		"grip + trigger enters slide mode")
	for i: int in 6:
		var tf: Transform3D = main.test_hand_tf["R"]
		tf.origin += Vector3(0.0, 0.0, 0.004)
		main.test_hand_tf["R"] = tf
		await frames(2)
	# Fix Pass 22: the pass-2 freeze assertion is REPLACED -
	# the freeze was the dislocation. The hand's travel here
	# runs ACROSS the toe's slide axis: the shoe must ride
	# the hand by the full travel, and the grip offset must
	# not shift (only along-axis travel adjusts it).
	check(main.shoe.global_position.distance_to(shoe_pos_before) > 0.018,
		"FP22: the shoe rides the hand while sliding - no world freeze (moved %.3f m with the hand)"
		% main.shoe.global_position.distance_to(shoe_pos_before))
	check(absf(main.slide_offset) < 0.004,
		"FP22: travel across the axis shifts no grip offset (got %.3f)" % main.slide_offset)
	main.test_trigger["R"] = 0.0
	await frames(4)
	check(not main.grab_state.sliding and not main.grab_state.slide_mode
		and main.grab_state.latched, "trigger release locks the new grip, hold kept")
	check(main.state == "HELD", "still held after slide lock")

	# --- Drop: open the hand with a still hand ---
	main.test_grip["R"] = 0.0
	await frames(4)
	check(main.state == "DROPPED", "open hand while still drops the shoe (state %s)" % main.state)
	check(await wait_state("STAND", 6.0), "dropped shoe returns itself to the stand")

	# --- Throw: re-grab the shank (TURN), feed a synthetic arc, release ---
	main.test_grip["R"] = 1.0
	await frames(5)
	check(main.state == "HELD" and main.held_hold == "flip",
		"re-grab works after the drop cycle (toe again, %s)" % main.held_hold)
	# Switch the test hand to the shank zone for a TURN throw: release
	# this grab first by dropping, then grab the shank.
	main.test_grip["R"] = 0.0
	await frames(3)
	check(await wait_state("STAND", 6.0), "second drop returns the shoe")
	var shank_c: Vector3 = main.shoe.zone_world_center("shank_right")
	main.test_hand_tf["R"] = Transform3D(Basis.IDENTITY, shank_c)
	main.test_grip["R"] = 1.0
	await frames(5)
	check(main.held_hold == "turn", "shank grab gives the TURN hold (got %s)" % main.held_hold)

	var now: float = float(Time.get_ticks_msec()) / 1000.0
	var samples: Array = []
	var v0 := Vector3(0.3, 3.4, -4.2)
	var g := Vector3(0.0, -9.8, 0.0)
	var p0 := Vector3(0.25, 1.15, 0.30)
	var hz: float = 90.0
	var dur: float = 0.30
	# Pass 10: the sample quats ROTATE at 5 rad/s, so the release
	# carries real spin and the board's new FLIP/TURN readout has
	# non-zero numbers to match against the recorder (below) -
	# identity quats would prove 0 == 0. The spin axis is world
	# Z: the right-hand TURN hold presents the shoe with its flip
	# axis along Z (Shoe.hold_transform, yaw -90 deg), so Z spin
	# is what the recorder's flip accounting will see.
	for i: int in int(dur * hz) + 1:
		var t: float = float(i) / hz
		var pos: Vector3 = p0 + v0 * t + 0.5 * g * t * t
		var q := Quaternion(Vector3.BACK, 5.0 * t)
		samples.append(ThrowMath.make_sample(now - dur + t, pos, q))
	main.samples = samples
	var expected_vel: Vector3 = ThrowMath.estimate_velocity_windowed(samples)
	main._release_shoe(samples)
	main.grab_state.reset()
	main.test_grip["R"] = 0.0
	check(main.state == "FLYING", "release with a swinging hand throws (state %s)" % main.state)
	await physics_frame
	var got_vel: Vector3 = main.shoe.linear_velocity
	check(got_vel.distance_to(expected_vel) < 0.6,
		"rigid body carries the windowed release velocity (err %.3f)" % got_vel.distance_to(expected_vel))
	var cycle_sec: float = await wait_rest_to_stand(14.0)
	check(cycle_sec >= 0.0, "thrown shoe settles and returns to the stand")
	check(cycle_sec >= 0.0 and cycle_sec <= 1.2,
		"quick turnaround: rest -> shoe grabbable on its pedestal in %.2f s (target ~1 s)" % cycle_sec)
	check(main.throw_count == 1, "board counted exactly one throw (%d)" % main.throw_count)
	check(main.status_label.text.contains("THROWS: 1"), "board shows THROWS: 1")
	check(main.status_label.text.contains("TURN"), "board shows the TURN hold")
	check(main.status_label.text.contains("FLIP:") and main.status_label.text.contains("TURN:")
		and not is_nan(board_rev(main.status_label.text, "FLIP:"))
		and not is_nan(board_rev(main.status_label.text, "TURN:")),
		"board shows the FLIP / TURN rotation readout (pass 10)")

	# Recorder file: a throw record with the full schema landed.
	var f: FileAccess = FileAccess.open(rec_path, FileAccess.READ)
	check(f != null, "smoke recorder file exists")
	var found_throw: bool = false
	if f != null:
		for line: String in f.get_as_text().split("\n", false):
			var parsed: Variant = JSON.parse_string(line)
			if parsed is Dictionary and String(parsed.get("type", "")) == "throw":
				found_throw = true
				var td: Dictionary = parsed
				for key: String in ["hand", "hold", "zone", "samples", "release_velocity",
						"release_angular_velocity", "settle_pos", "landing_distance_in",
						"ringer", "flip_rotations", "turn_rotations", "origin_release_pos",
						"head_yaw_deg", "origin_yaw_deg", "line_ft"]:
					check(td.has(key), "smoke throw record carries '%s'" % key)
				check(String(td["hold"]) == "turn", "smoke throw record hold is turn")
				# Pass 10: the board's FLIP / TURN readout must be
				# THIS throw's recorder numbers - the same flip_rot /
				# turn_rot values _settle_throw wrote to both.
				if td.has("flip_rotations") and td.has("turn_rotations"):
					var rec_flip: float = float(td["flip_rotations"])
					var rec_turn: float = float(td["turn_rotations"])
					var brd_flip: float = board_rev(main.status_label.text, "FLIP:")
					var brd_turn: float = board_rev(main.status_label.text, "TURN:")
					check(not is_nan(brd_flip) and absf(brd_flip - rec_flip) <= 0.011,
						"board FLIP readout matches the throw record (board %.2f vs record %.4f rev)"
						% [brd_flip, rec_flip])
					check(not is_nan(brd_turn) and absf(brd_turn - rec_turn) <= 0.011,
						"board TURN readout matches the throw record (board %.2f vs record %.4f rev)"
						% [brd_turn, rec_turn])
					check(absf(rec_flip) > 0.2,
						"the scripted spin really rotated (record flip %.3f rev - the match above is not 0 == 0)" % rec_flip)
				if td.has("line_ft"):
					check(int(td["line_ft"]) == 40,
						"smoke throw from the standard end records line_ft 40 (got %d)" % int(td["line_ft"]))
				if td.has("head_yaw_deg") and td.has("origin_yaw_deg"):
					check(absf(float(td["head_yaw_deg"])) < 0.5
						and absf(float(td["origin_yaw_deg"])) < 0.5,
						"head/origin yaw logged at release (~0 facing the stake here: %.2f / %.2f)"
						% [float(td["head_yaw_deg"]), float(td["origin_yaw_deg"])])
	check(found_throw, "smoke recorder holds a throw record")

	# --- Fix Pass 21: the grip cycle ---
	# (a) A toe grab in the RIGHT hand starts at TOE GRIP, and
	# the label naming it rides visibly by the shoe.
	main.test_hand_tf.erase("L")
	main.test_hand_tf.erase("R")
	var gtoe: Vector3 = main.shoe.zone_world_center("toe")
	main.test_hand_tf["R"] = Transform3D(Basis.IDENTITY, gtoe)
	main.test_grip["R"] = 1.0
	await frames(6)
	check(main.state == "HELD" and main.grip_label.text == "TOE GRIP · FLIP",
		"FP21: a toe grab starts at TOE GRIP, labelled (got '%s')" % main.grip_label.text)
	check(main.grip_label.visible, "FP21: the grip label rides visible while the shoe is held")
	check(main.grip_hint_label != null and main.grip_hint_label.text == "A/X - CHANGE GRIP"
		and main.grip_hint_label.is_visible_in_tree(),
		"FP22: the hint line rides under the grip name while a shoe is held (got '%s')"
		% (main.grip_hint_label.text if main.grip_hint_label != null else "<none>"))
	# (b) A free-hand button (left X) walks the cycle through
	# every named position and wraps; Fix Pass 22: the holding
	# hand's own button cycles too (checked right after).
	await pulse_hand_button("L", "A")
	check(main.grip_label.text == "SHANK · TOE · 1⅛ TURN" and main._grip_index() == 1,
		"FP21: tap 1 walks to SHANK · TOE (got '%s')" % main.grip_label.text)
	await pulse_hand_button("L", "A")
	check(main.grip_label.text == "SHANK · MID · 1¼ TURN" and main._grip_index() == 2,
		"FP21: tap 2 walks to SHANK · MID (got '%s')" % main.grip_label.text)
	await pulse_hand_button("L", "A")
	check(main.grip_label.text == "SHANK · HEEL · 1⅜ TURN" and main._grip_index() == 3,
		"FP21: tap 3 walks to SHANK · HEEL (got '%s')" % main.grip_label.text)
	# Fix Pass 26: the circuit crosses the shoe - the far
	# shank's three stops (the reverse family) follow the home
	# shank's, each seated on the OTHER zone, then the wrap.
	await pulse_hand_button("L", "A")
	check(main.grip_label.text == "FAR SHANK · TOE · 1⅛ TURN · REVERSE" and main._grip_index() == 4
		and main.held_zone == "shank_left",
		"FP26: tap 4 crosses to FAR SHANK · TOE, seated on the far zone (got '%s' / %s)"
		% [main.grip_label.text, main.held_zone])
	await pulse_hand_button("L", "A")
	check(main.grip_label.text == "FAR SHANK · MID · 1¼ TURN · REVERSE" and main._grip_index() == 5
		and main.held_zone == "shank_left",
		"FP26: tap 5 walks to FAR SHANK · MID (got '%s')" % main.grip_label.text)
	await pulse_hand_button("L", "A")
	check(main.grip_label.text == "FAR SHANK · HEEL · 1⅜ TURN · REVERSE" and main._grip_index() == 6
		and main.held_zone == "shank_left",
		"FP26: tap 6 walks to FAR SHANK · HEEL (got '%s')" % main.grip_label.text)
	await pulse_hand_button("L", "A")
	check(main.grip_label.text == "TOE GRIP · FLIP" and main._grip_index() == 0,
		"FP26: tap 7 wraps the full circuit back to TOE GRIP (got '%s')" % main.grip_label.text)
	await pulse_hand_button("R", "A")
	check(main._grip_index() == 1 and main.grip_label.text == "SHANK · TOE · 1⅛ TURN",
		"FP22: the HOLDING hand's own button cycles too - A or X, either hand (got '%s')"
		% main.grip_label.text)
	# Fix Pass 27: the label is CLAMPED - one uniform size for
	# all seven grips (it must not pulse as the cycle walks),
	# sized from the longest string so even FAR SHANK · HEEL
	# fits inside ~0.50 m at the shoe. At the pre-FP27 size
	# (0.00085) that string rendered 0.768 m wide and filled
	# Chris's view. Font metrics, the board guard's own method.
	var fb27: Font = ThemeDB.fallback_font
	var w27_worst: float = 0.0
	for i27: int in ThrowMath.grip_position_count():
		var p27: Dictionary = ThrowMath.grip_position(i27)
		var lw27: float = fb27.get_string_size(String(p27["label"]),
			HORIZONTAL_ALIGNMENT_LEFT, -1.0, main.grip_label.font_size).x * main.grip_label.pixel_size
		w27_worst = maxf(w27_worst, lw27)
	check(is_equal_approx(main.grip_label.pixel_size, main.GRIP_LABEL_PIXEL_SIZE)
		and is_equal_approx(main.grip_hint_label.pixel_size, main.GRIP_LABEL_PIXEL_SIZE),
		"FP27: one uniform label size for name and hint (%.5f)" % main.grip_label.pixel_size)
	check(w27_worst <= 0.50,
		"FP27: the longest grip label fits the clamp (worst %.3f m <= 0.50 m)" % w27_worst)
	check(main.grip_hint_label.font_size < main.grip_label.font_size
		and is_equal_approx(main.grip_hint_label.position.y, main.GRIP_HINT_OFFSET_Y),
		"FP27: the hint keeps its proportions - smaller font, scaled ride offset (%.3f)"
		% main.grip_hint_label.position.y)
	# (c) A thrown cycled grip lands with its declared count:
	# walk to SHANK · MID and pitch its 1-1/4 through the
	# production release; the cache and the throw record must
	# carry the grip's name and declared count, and the governed
	# total must be the declaration.
	await pulse_hand_button("L", "A")
	check(main._grip_index() == 2, "FP21: cycled to SHANK · MID for the throw")
	var line_z21: float = main.game_line_z()
	var target21: Vector3 = main.target_stake_pos()
	var rp21 := Vector3(0.25, 1.25, line_z21 + 0.35)
	var tf21: float = 1.15
	var vel21 := Vector3((target21.x - rp21.x) / tf21,
		(0.50 - rp21.y + 4.9 * tf21 * tf21) / tf21,
		(target21.z - rp21.z) / tf21)
	var om21 := Vector3(0.0, -TAU * 1.25 / tf21, 0.0)
	var rel21: Transform3D = main.rel_tf
	var hand_pos21: Vector3 = rp21 - rel21.origin
	main.test_hand_tf["R"] = Transform3D(Basis.IDENTITY, hand_pos21)
	await frames(4)
	main.samples = build_stream(hand_pos21, Quaternion.IDENTITY, vel21, om21, 999)
	main._release_shoe(main.samples)
	main.grab_state.reset()
	main.test_grip["R"] = 0.0
	check(main.state == "FLYING", "FP21: the cycled grip throws through the production path")
	check(String(main.release_cache.get("grip_name", "")) == "SHANK · MID"
		and absf(float(main.release_cache.get("grip_nominal", 0.0)) - 1.25) <= 0.001,
		"FP21: the release cache carries the cycled grip (got %s / %.3f)"
		% [String(main.release_cache.get("grip_name", "")), float(main.release_cache.get("grip_nominal", 0.0))])
	check(absf(float(main.release_cache.get("spin_applied_total", 0.0)) + 1.25) <= 0.15,
		"FP21: the thrown cycled grip lands with its declared count (applied %.2f rev, declared -1.25)"
		% float(main.release_cache.get("spin_applied_total", 0.0)))
	check(await wait_state("STAND", 12.0), "FP21: the cycled throw settles and returns")
	var last_throw21: Dictionary = {}
	var f21: FileAccess = FileAccess.open(rec_path, FileAccess.READ)
	if f21 != null:
		for line: String in f21.get_as_text().split("\n", false):
			var parsed21: Variant = JSON.parse_string(line)
			if parsed21 is Dictionary and String(parsed21.get("type", "")) == "throw":
				last_throw21 = parsed21
	check(String(last_throw21.get("grip_name", "")) == "SHANK · MID"
		and absf(float(last_throw21.get("grip_nominal", 0.0)) - 1.25) <= 0.001,
		"FP21: the throw record carries grip_name / grip_nominal (got %s / %.3f)"
		% [String(last_throw21.get("grip_name", "")), float(last_throw21.get("grip_nominal", 0.0))])
	# (d) The LEFT hand: a shank grab starts at SHANK · MID (the
	# stop nearest the grab point), the RIGHT hand's A walks the
	# cycle, and (Fix Pass 22) the left hand's own A cycles too -
	# while it holds, no A press from either hand may fire a
	# game job.
	main.test_hand_tf.erase("R")
	var gshank: Vector3 = main.shoe.zone_world_center("shank_left")
	main.test_hand_tf["L"] = Transform3D(Basis.IDENTITY, gshank)
	main.test_grip["L"] = 1.0
	await frames(6)
	check(main.state == "HELD" and main.held_hand == "L"
		and main.grip_label.text == "SHANK · MID · 1¼ TURN",
		"FP21: a left-hand shank grab starts at SHANK · MID (got '%s')" % main.grip_label.text)
	await pulse_hand_button("R", "A")
	check(main.grip_label.text == "SHANK · HEEL · 1⅜ TURN",
		"FP21: the right hand's A cycles the left hand's grip (got '%s')" % main.grip_label.text)
	# Fix Pass 26: the left hand's circuit crosses too - its
	# far shank is shank_right - and the walk wraps the full
	# seven stops home.
	await pulse_hand_button("L", "A")
	check(main._grip_index() == 4 and main.held_zone == "shank_right"
		and main.grip_label.text == "FAR SHANK · TOE · 1⅛ TURN · REVERSE",
		"FP26: the left hand crosses to its far shank (got '%s' / %s)"
		% [main.grip_label.text, main.held_zone])
	await pulse_hand_button("R", "A")
	check(main._grip_index() == 5 and main.grip_label.text == "FAR SHANK · MID · 1¼ TURN · REVERSE",
		"FP26: the left hand's far walk continues to FAR SHANK · MID (got '%s')" % main.grip_label.text)
	await pulse_hand_button("R", "A")
	check(main._grip_index() == 6 and main.grip_label.text == "FAR SHANK · HEEL · 1⅜ TURN · REVERSE",
		"FP26: the left hand's far walk ends at FAR SHANK · HEEL (got '%s')" % main.grip_label.text)
	await pulse_hand_button("L", "A")
	check(main._grip_index() == 0 and main.grip_label.text == "TOE GRIP · FLIP"
		and main.mode == "PRACTICE",
		"FP22: the holding left hand's own A cycles too (wraps the full circuit to TOE GRIP) - and still cannot start a game while it holds")
	await wait_hand_still("L")
	main.test_grip["L"] = 0.0
	await frames(4)
	check(main.state == "DROPPED" and not main.grip_label.visible
		and not main.grip_hint_label.is_visible_in_tree(),
		"FP21: the label is gone the instant the shoe is released (FP22: hint line with it)")
	check(await wait_state("STAND", 6.0), "FP21: the dropped shoe returns")
	# (e) A settled slide re-names the grip: grab the shank
	# (MID), slide heel-ward past the midpoint, lock - the
	# label follows the nearest stop. (The other hand's test
	# transform is erased first: a stale hand parked on a zone
	# centre wins the grab candidacy and the grab never lands.)
	main.test_hand_tf.erase("L")
	var gshank2: Vector3 = main.shoe.zone_world_center("shank_right")
	main.test_hand_tf["R"] = Transform3D(Basis.IDENTITY, gshank2)
	main.test_grip["R"] = 1.0
	await frames(6)
	check(main.grip_label.text == "SHANK · MID · 1¼ TURN",
		"FP21: the slide test starts at SHANK · MID (got '%s')" % main.grip_label.text)
	await wait_hand_still("R")
	main.test_trigger["R"] = 1.0
	await frames(4)
	check(main.grab_state.slide_mode, "FP21: the slide engages for the settle test")
	# (Transport strengthened in Fix Pass 22: 0.004 m steps
	# with settle frames - the offset accumulates per sliding
	# frame now, and coarse steps trip the speed gate for a
	# frame at a time under headless frame quantization. The
	# assertion below is unchanged from Fix Pass 21.)
	for i: int in 8:
		var tf_s: Transform3D = main.test_hand_tf["R"]
		tf_s.origin += Vector3(-0.004, 0.0, 0.0) # heel-ward for the R-hand turn seat
		main.test_hand_tf["R"] = tf_s
		await frames(3)
	main.test_trigger["R"] = 0.0
	await frames(4)
	check(main._grip_index() == 3 and main.grip_label.text == "SHANK · HEEL · 1⅜ TURN",
		"FP21: a slide settled past the midpoint re-names the grip SHANK · HEEL (got '%s', offset %.3f)"
		% [main.grip_label.text, main.slide_offset])
	await wait_hand_still("R")
	main.test_grip["R"] = 0.0
	await frames(4)
	check(await wait_state("STAND", 6.0), "FP21: the slide test shoe returns")
	# (f) With nothing held, A still starts a game and B still
	# returns to practice - the cycle never stole them.
	await pulse_button("A")
	check(main.mode == "GAME", "FP21: A still starts a game when nothing is held")
	await pulse_button("B")
	check(main.mode == "PRACTICE", "FP21: B still returns to practice (unchanged)")
	# Leave the test transports as this section found them: a
	# stale test hand parked on a zone centre wins the grab
	# candidacy (hands iterate L first) and silently blocks
	# every later grab in the suite.
	main.test_hand_tf.erase("L")
	main.test_hand_tf.erase("R")

	# --- Fix Pass 22: the dislocation battery (permanent).
	# Chris, button-hunting in the headset with a shoe in
	# hand, got his hand and the shoe ENTIRELY separated
	# while the hold persisted. The conviction probe on the
	# pre-fix code: a plain grab and a cycled grip carried a
	# 50 deg hand pitch at 0.000 deg error, but the SLIDE -
	# trigger in, hand travelling slowly - left the shoe
	# parked (0.000 m moved over 0.800 m of travel, separation
	# grown +0.757 m, a 50.000 deg orientation error when he
	# turned his hand down, and a 0.800 m teleport at the
	# re-lock). The freeze was the mechanism; the cycle was
	# innocent. This battery is that probe, kept: hand and
	# shoe cannot separate beyond the slide's clamped extent
	# under any input. ---
	main.origin.global_transform = Transform3D.IDENTITY
	var gtoe22: Vector3 = main.shoe.zone_world_center("toe")
	main.test_hand_tf["R"] = Transform3D(Basis.IDENTITY, gtoe22)
	main.test_grip["R"] = 1.0
	await frames(6)
	check(main.state == "HELD" and main.held_hand == "R",
		"FP22 battery: the right hand holds the toe for the battery")
	# (i) A plain grab carries rotation exactly.
	var down50: Basis = Basis.from_euler(Vector3(deg_to_rad(-50.0), 0.0, 0.0))
	main.test_hand_tf["R"] = Transform3D(down50, gtoe22)
	await frames(4)
	check(held_orient_error() < 0.5,
		"FP22 battery: a plain grab carries a 50 deg hand pitch exactly (err %.3f deg)"
		% held_orient_error())
	main.test_hand_tf["R"] = Transform3D(Basis.IDENTITY, gtoe22)
	await frames(4)
	# (ii) Cycle-then-rotate: the regression - the cycle was
	# innocent and must stay innocent under the new rule.
	await pulse_hand_button("L", "A")
	main.test_hand_tf["R"] = Transform3D(down50, gtoe22)
	await frames(4)
	check(held_orient_error() < 0.5,
		"FP22 battery: cycle-then-rotate - the cycled hold carries rotation like a fresh grab (err %.3f deg)"
		% held_orient_error())
	main.test_hand_tf["R"] = Transform3D(Basis.IDENTITY, gtoe22)
	await frames(4)
	# (iii) THE SLIDE, as Chris lived it: trigger in, hand
	# wanders off slowly, hand turns down.
	await wait_hand_still("R")
	main.test_trigger["R"] = 1.0
	await frames(6)
	check(main.grab_state.slide_mode, "FP22 battery: the slide engages")
	var sep_ref: float = held_separation()
	var shoe_at_slide: Vector3 = main.shoe.global_position
	var max_growth: float = 0.0
	var tf22: Transform3D = main.test_hand_tf["R"]
	for i: int in 120:
		tf22.origin += Vector3(0.005, 0.0, 0.0)
		main.test_hand_tf["R"] = tf22
		await frames(1)
		await frames(2)
		max_growth = maxf(max_growth, held_separation() - sep_ref)
	check(max_growth < 0.01,
		"FP22 battery: 0.6 m of hand travel mid-slide grows the separation by %.4f m (was +0.757 m on the freeze)"
		% max_growth)
	check(main.shoe.global_position.distance_to(shoe_at_slide) > 0.55,
		"FP22 battery: the shoe travelled WITH the hand (%.3f m)"
		% main.shoe.global_position.distance_to(shoe_at_slide))
	check(absf(main.slide_offset + 0.045) < 0.004,
		"FP22 battery: the offset saturated at the stop instead of stranding (got %.3f)"
		% main.slide_offset)
	var down60: Basis = Basis.from_euler(Vector3(deg_to_rad(-60.0), 0.0, 0.0))
	main.test_hand_tf["R"] = Transform3D(down60, tf22.origin)
	await frames(4)
	check(held_orient_error() < 0.5,
		"FP22 battery: turning the hand down mid-slide - the shoe follows (err %.3f deg; the freeze left 50.000)"
		% held_orient_error())
	main.test_hand_tf["R"] = Transform3D(Basis.IDENTITY, tf22.origin)
	await frames(4)
	var shoe_pre_lock: Vector3 = main.shoe.global_position
	main.test_trigger["R"] = 0.0
	await frames(4)
	check(main.shoe.global_position.distance_to(shoe_pre_lock) < 0.02
		and not main.grab_state.slide_mode,
		"FP22 battery: the re-lock does not teleport the shoe (moved %.4f m; the freeze teleported 0.800 m)"
		% main.shoe.global_position.distance_to(shoe_pre_lock))
	check(main._grip_index() == 1,
		"FP22 battery: the settled slide names the stop it saturated at (idx %d)"
		% main._grip_index())
	# (iv) A cycle tap mid-slide: walks the grip, hold intact.
	await wait_hand_still("R")
	main.test_trigger["R"] = 1.0
	await frames(6)
	check(main.grab_state.slide_mode, "FP22 battery: the slide re-engages for the mid-slide cycle")
	await pulse_button("A")
	check(main.state == "HELD" and main._grip_index() == 2,
		"FP22 battery: a cycle tap mid-slide walks the grip (idx %d) and the hold survives"
		% main._grip_index())
	check(held_orient_error() < 0.5 and held_separation() < 0.16,
		"FP22 battery: no stranding after the mid-slide cycle (err %.3f deg, sep %.4f m)"
		% [held_orient_error(), held_separation()])
	main.test_trigger["R"] = 0.0
	await frames(4)
	await wait_hand_still("R")
	main.test_grip["R"] = 0.0
	await frames(4)
	check(main.state == "DROPPED", "FP22 battery: the battery shoe drops clean")
	main.test_hand_tf.erase("R")
	await wait_state("STAND", 600)
	# (v) A mode switch mid-hold (B in a game) gathers the
	# shoe and resets the latch - no straddled hold - and the
	# hold works again immediately after.
	main.test_button["A"] = true
	await frames(4)
	main.test_button["A"] = false
	await frames(4)
	check(main.mode == "GAME", "FP22 battery: a game starts for the mode-switch leg")
	var gtoe22b: Vector3 = main.shoe.zone_world_center("toe")
	main.test_hand_tf["R"] = Transform3D(Basis.IDENTITY, gtoe22b)
	main.test_grip["R"] = 1.0
	await frames(6)
	check(main.state == "HELD", "FP22 battery: the game shoe is held")
	# Carry the shoe up off its rail before the switch: the
	# gather returns it to that same rail slot, and a hand
	# still parked there with the grip shut would simply
	# re-grab it - correct behaviour, not a straddle - so the
	# leg clears the rail first.
	var tf22b: Transform3D = main.test_hand_tf["R"]
	tf22b.origin += Vector3(0.0, 0.5, 0.0)
	main.test_hand_tf["R"] = tf22b
	await frames(4)
	main.test_button["B"] = true
	await frames(4)
	main.test_button["B"] = false
	await frames(4)
	check(main.mode == "PRACTICE" and main.state == "STAND"
		and not main.grab_state.latched,
		"FP22 battery: B mid-hold ends the hold cleanly - gathered, unlatched, nothing straddled")
	main.test_hand_tf["R"] = Transform3D(Basis.IDENTITY,
		main.shoe.zone_world_center("toe"))
	await frames(6)
	check(main.state == "HELD" and held_orient_error() < 0.5,
		"FP22 battery: the hold works again right after the switch (err %.3f deg)"
		% held_orient_error())
	await wait_hand_still("R")
	main.test_grip["R"] = 0.0
	await frames(4)
	check(await wait_state("STAND", 600),
		"FP22 battery: the mode-switch shoe settles back to the stand")
	main.test_hand_tf.erase("R")

	# --- Fix Pass 25: the long-arm grab + the default grip ---
	# Chris's nugget: two steps to the station to grab a shoe,
	# two steps back to the spot to throw it, every shoe,
	# every inning. The far tier ends the commute: squeeze
	# from the throwing spot and the stocked shoe hops into
	# the hand, arriving in the DEFAULT GRIP. The cycle is
	# the default's setting control, persisted to the
	# settings file (the smoke one, deleted at boot, so the
	# default starts at TOE GRIP - the first-run default).
	# The suite's own cycle walks above (FP21/FP22) have been
	# SETTING the default all along - that is the feature -
	# so first walk it home deterministically: near-grab the
	# stocked shoe and cycle until the held grip is TOE,
	# which lands the default on TOE with it.
	main.test_hand_tf["R"] = Transform3D(Basis.IDENTITY,
		main.shoe.zone_world_center("toe"))
	main.test_grip["R"] = 1.0
	var setup_frames: int = 0
	while main.state != "HELD" and setup_frames < 40:
		await frames(1)
		setup_frames += 1
	check(main.state == "HELD", "FP25: the setup grab latches for the default reset")
	var guard25: int = 0
	while main.default_grip != 0 and guard25 < 10:
		await pulse_hand_button("L", "A")
		guard25 += 1
	check(main.default_grip == 0 and main._grip_index() == 0,
		"FP25: the default is walked back to TOE for the section (got %d)" % main.default_grip)
	check(await drop_and_restock(main, "R"), "FP25: the reset shoe drops and restocks")
	main.test_hand_tf.erase("R")
	# Fix Pass 36: home the origin to the 40 ft line first
	# (the FP7 (d) idiom), so the pair's stock point for the
	# summon proof below is the game station itself.
	main.origin.global_transform = Transform3D(Basis.IDENTITY,
		Vector3(0.0, 0.0, main.FOUL_40_Z))
	check(await wait_shoe_at(40, 3.0) >= 0.0,
		"FP36: the shoe homes to the game station before the summon proof")
	var spot40: Vector3 = main.spot_pos(40, false)
	var hand_r40 := Vector3(spot40.x + 0.25, 0.85, spot40.z)
	var hand_l40 := Vector3(spot40.x - 0.25, 0.85, spot40.z)
	var d_far: float = hand_r40.distance_to(main.shoe.global_position)
	check(d_far > main.CANDIDATE_RADIUS and d_far <= main.LONG_ARM_RADIUS,
		"FP25: the throwing-spot hand sits in far-tier range of the station pair (%.2f m)" % d_far)
	# Fix Pass 36 - THE SUMMON'S ORIGIN (an ownership proof,
	# not just a latch): the shoe that answers the throwing-
	# spot squeeze must come off the PLAYER's OWN station -
	# the shelf on his side at (+2.14, -1.50) - never the
	# AI's station across the lane. Capture where the active
	# shoe sits stocked; after the latch, read the hop's own
	# origin record (hop_from) and name the station it came
	# from.
	var summon_origin: Vector3 = main.shoe.global_position
	var origin_slot: int = -1
	for oi: int in 2:
		if summon_origin.distance_to(main.rack_slot_tf(40, false, oi).origin) < 0.01:
			origin_slot = oi
	check(origin_slot >= 0 and summon_origin.x > 2.0,
		"FP36: the stocked shoe waits at the player's OWN-side station (+2.14) before the summon (at %s, slot %d)"
		% [str(summon_origin), origin_slot])
	# (a) Long-arm from the throwing spot, RIGHT hand.
	check(await long_arm_grab(main, "R", hand_r40),
		"FP25: a squeeze from the throwing spot latches the station shoe")
	check(main.hop_from.origin.distance_to(summon_origin) < 0.01,
		"FP36: the summoned shoe came FROM the player's own-side station (+2.14) (hop origin %s)"
		% str(main.hop_from.origin))
	check(main.held_zone == "toe" and main._grip_index() == 0
		and main.grip_label.text == "TOE GRIP · FLIP",
		"FP25: the long-arm arrival holds the default grip (TOE at first run, got idx %d / '%s')"
		% [main._grip_index(), main.grip_label.text])
	var latch_a: Dictionary = last_latch_record(rec_path)
	check(bool(latch_a.get("long_arm", false)),
		"FP25: the latch record flags the long-arm grab")
	# (b) The cycle is the settings control: two taps land
	# on SHANK · MID, and the default follows - on the board
	# and on disk, in the same moment.
	await pulse_hand_button("L", "A")
	await pulse_hand_button("L", "A")
	check(main._grip_index() == 2 and main.default_grip == 2,
		"FP25: cycling to SHANK · MID makes it the default (got %d)" % main.default_grip)
	check(main.controls_full_text().contains("DEFAULT GRIP: SHANK · MID"),
		"FP25: the board re-names the default the moment it changes")
	var set_f: FileAccess = FileAccess.open(set_path, FileAccess.READ)
	var set_parsed: Variant = JSON.parse_string(set_f.get_as_text()) if set_f != null else null
	check(set_parsed is Dictionary and int(set_parsed.get("default_grip", -1)) == 2,
		"FP25: the default is persisted to the settings file")
	check(await drop_and_restock(main, "R"), "FP25: the cycled shoe drops and restocks")
	main.test_hand_tf.erase("R")
	# (c) LEFT hand long-arm: arrives in the new default, on
	# the left hand's own shank.
	check(await long_arm_grab(main, "L", hand_l40),
		"FP25: a left-hand squeeze from the spot latches too")
	check(main.held_hand == "L" and main.held_zone == "shank_left"
		and main._grip_index() == 2
		and main.grip_label.text == "SHANK · MID · 1¼ TURN",
		"FP25: the left long-arm arrival holds the default on its own shank (got %s / '%s')"
		% [main.held_zone, main.grip_label.text])
	check(await drop_and_restock(main, "L"), "FP25: the left shoe drops and restocks")
	main.test_hand_tf.erase("L")
	# (d) A long-arm arrival THROWS its default: the release
	# cache (and with it the governor) carries the default's
	# name and declared count (the FP21 (c) stream method).
	check(await long_arm_grab(main, "R", hand_r40),
		"FP25: long-arm again, for the throw")
	var line_z25: float = main.game_line_z()
	var target25: Vector3 = main.target_stake_pos()
	var rp25 := Vector3(0.25, 1.25, line_z25 + 0.35)
	var tf25: float = 1.15
	var vel25 := Vector3((target25.x - rp25.x) / tf25,
		(0.50 - rp25.y + 4.9 * tf25 * tf25) / tf25,
		(target25.z - rp25.z) / tf25)
	var om25 := Vector3(0.0, -TAU * 1.25 / tf25, 0.0)
	var rel25: Transform3D = main.rel_tf
	var hand_pos25: Vector3 = rp25 - rel25.origin
	main.test_hand_tf["R"] = Transform3D(Basis.IDENTITY, hand_pos25)
	await frames(4)
	main.samples = build_stream(hand_pos25, Quaternion.IDENTITY, vel25, om25, 25)
	main._release_shoe(main.samples)
	main.grab_state.reset()
	main.test_grip["R"] = 0.0
	check(main.state == "FLYING", "FP25: the long-arm shoe throws through the production path")
	check(String(main.release_cache.get("grip_name", "")) == "SHANK · MID"
		and absf(float(main.release_cache.get("grip_nominal", 0.0)) - 1.25) <= 0.001,
		"FP25: the release serves the default's declared grip (got %s / %.3f)"
		% [String(main.release_cache.get("grip_name", "")), float(main.release_cache.get("grip_nominal", 0.0))])
	check(absf(float(main.release_cache.get("spin_applied_total", 0.0)) + 1.25) <= 0.15,
		"FP25: the governed total is the default's declaration (applied %.2f rev)"
		% float(main.release_cache.get("spin_applied_total", 0.0)))
	# (e) A shoe IN PLAY refuses: squeezed at mid-flight, no
	# hop starts and nothing latches.
	main.test_hand_tf["R"] = Transform3D(Basis.IDENTITY, hand_r40)
	main.test_grip["R"] = 1.0
	await create_timer(0.5).timeout
	check(main.hop_phase == "" and not main.grab_state.latched,
		"FP25: a mid-flight squeeze calls nothing (hop '%s')" % main.hop_phase)
	main.test_grip["R"] = 0.0
	main.test_hand_tf.erase("R")
	check(await wait_state("STAND", 12.0), "FP25: the thrown shoe settles and restocks")
	# (f) RESTART: a fresh instance reads the settings file
	# itself - the default survived, its board names it, and
	# its long-arm arrival holds it.
	var rec_b: String = "user://smoke_settings_throws.jsonl"
	if FileAccess.file_exists(rec_b):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(rec_b))
	var m2: Node = spawn_fresh_main(rec_b, set_path)
	await create_timer(0.3).timeout
	check(int(m2.default_grip) == 2,
		"FP25: the default survives a restart (read %d)" % int(m2.default_grip))
	check(m2.controls_full_text().contains("DEFAULT GRIP: SHANK · MID"),
		"FP25: the restarted board names the stored default")
	check(await long_arm_grab(m2, "R", hand_r40),
		"FP25: the restarted instance long-arms from the spot")
	check(m2._grip_index() == 2 and m2.held_zone == "shank_right",
		"FP25: the restarted long-arm arrival holds SHANK · MID (got idx %d / %s)"
		% [m2._grip_index(), m2.held_zone])
	m2.test_grip["R"] = 0.0
	m2.test_hand_tf.erase("R")
	root.remove_child(m2)
	m2.free()
	await frames(3)
	# (g) A NEAR grab is unchanged - its latch record carries
	# no long-arm flag - and a full cycle walk on it sets
	# the default back to TOE.
	var toe_c25: Vector3 = main.shoe.zone_world_center("toe")
	main.test_hand_tf["R"] = Transform3D(Basis.IDENTITY, toe_c25)
	main.test_grip["R"] = 1.0
	await frames(6)
	check(main.state == "HELD" and main.held_zone == "toe",
		"FP25: the near grab still latches at the zone")
	var latch_g: Dictionary = last_latch_record(rec_path)
	check(not bool(latch_g.get("long_arm", true)),
		"FP25: the near latch record is NOT flagged long-arm")
	for i25: int in 7:
		await pulse_hand_button("L", "A")
	check(main._grip_index() == 0 and main.default_grip == 0
		and main.controls_full_text().contains("DEFAULT GRIP: TOE GRIP"),
		"FP25: a full cycle walk sets the default back to TOE GRIP (got %d)" % main.default_grip)
	var set_f2: FileAccess = FileAccess.open(set_path, FileAccess.READ)
	var set_parsed2: Variant = JSON.parse_string(set_f2.get_as_text()) if set_f2 != null else null
	check(set_parsed2 is Dictionary and int(set_parsed2.get("default_grip", -1)) == 0,
		"FP25: TOE is persisted")
	check(await drop_and_restock(main, "R"), "FP25: the walked shoe drops and restocks")
	main.test_hand_tf.erase("R")
	# (h) RESTART again: TOE survived the round trip.
	var m3: Node = spawn_fresh_main(rec_b, set_path)
	await create_timer(0.3).timeout
	check(int(m3.default_grip) == 0,
		"FP25: the round trip ends at TOE (read %d)" % int(m3.default_grip))
	check(await long_arm_grab(m3, "R", hand_r40),
		"FP25: the second restart long-arms")
	check(m3._grip_index() == 0 and m3.grip_label.text == "TOE GRIP · FLIP",
		"FP25: the second restart arrives at TOE GRIP (got '%s')" % m3.grip_label.text)
	m3.test_grip["R"] = 0.0
	m3.test_hand_tf.erase("R")
	root.remove_child(m3)
	m3.free()
	await frames(3)
	# (i) Refusals. Fix Pass 36 re-derivation: the radius
	# is 2.40 m now (the FP35 cross-lane shelf's 3.75 m went
	# with the treaty swap) - first home the origin to the
	# 40 ft line (the FP7 (d) idiom) and let the shoe
	# restock at the SHELF, then stage the out-of-range hand
	# a measured 6.4 m from wherever the shoe actually sits.
	main.origin.global_transform = Transform3D(Basis.IDENTITY,
		Vector3(0.0, 0.0, main.FOUL_40_Z))
	check(await wait_shoe_at(40, 3.0) >= 0.0,
		"FP36: the shoe restocks at the shelf before the refusal legs")
	main.test_hand_tf["R"] = Transform3D(Basis.IDENTITY,
		main.shoe.global_position + Vector3(4.5, 0.07, 4.5))
	main.test_grip["R"] = 1.0
	await create_timer(0.6).timeout
	check(main.state == "STAND" and main.hop_phase == "" and not main.grab_state.latched,
		"FP25: an out-of-range squeeze starts nothing")
	main.test_grip["R"] = 0.0
	main.test_hand_tf.erase("R")
	await frames(3)
	# The AI's pair refuses at ANY range: a hand parked on
	# the AI's stocked shoe, squeezing - the far tier only
	# ever measures the player's active shoe. Fix Pass 36
	# re-derivation: the AI station now stands IN FRONT OF
	# THE FOUNTAIN on its own side; its slot sits 3.24 m
	# from the player's right-hand spot, and a hand parked
	# on it sits ~4.18 m from the player's stocked shoe -
	# outside the 2.40 m radius too, so the refusal is
	# double-locked. The refusal under test is the AI
	# pair's, so stage it with the player's shoe already
	# in hand: the parked squeeze must then call NOTHING at
	# all, and the AI's shoe must never move.
	var ai_slot: Vector3 = main.rack_slot_tf(40, true, 0).origin
	check(await long_arm_grab(main, "R", hand_r40),
		"FP36: the player's shoe comes to hand before the AI-refusal leg")
	main.test_hand_tf["L"] = Transform3D(Basis.IDENTITY, ai_slot + Vector3(0.1, 0.07, 0.0))
	main.test_grip["L"] = 1.0
	await create_timer(0.6).timeout
	check(main.state == "HELD" and main.hop_phase == ""
		and String(main.held_hand) == "R",
		"FP25: a squeeze parked on the AI's shoe calls nothing (state %s, hop '%s', held by %s)"
		% [String(main.state), String(main.hop_phase), String(main.held_hand)])
	check(main.ai_pair[0].global_position.distance_to(ai_slot) < 0.01,
		"FP25: the AI's shoe never moved")
	main.test_grip["L"] = 0.0
	main.test_hand_tf.erase("L")
	await frames(3)
	check(await drop_and_restock(main, "R"),
		"FP36: the refusal leg's shoe drops and restocks")
	main.test_hand_tf.erase("R")
	# A round's down shoes refuse: manufacture a tabulating
	# round (grab disarmed) and squeeze from the spot.
	manufacture_round()
	await frames(3)
	main.test_hand_tf["R"] = Transform3D(Basis.IDENTITY, hand_r40)
	main.test_grip["R"] = 1.0
	await create_timer(0.6).timeout
	check(main.hop_phase == "" and not main.grab_state.latched,
		"FP25: no long-arm while a round tabulates (the grab is disarmed)")
	main.test_grip["R"] = 0.0
	main.test_hand_tf.erase("R")
	await pulse_button("B")
	check(main.mode == "PRACTICE" and main.state == "STAND",
		"FP25: back to practice after the refusal legs")
	# (i2) Stage B: the long-arm FROM THE A-SEAT. The FP20
	# continue seats the camera 0.55 m behind the line, and
	# the far tier must still serve the seat - under Fix
	# Pass 36 the seat's far (left) hand to slot 1 (2.20 m)
	# is the governing reach LONG_ARM_RADIUS was re-derived
	# from.
	# Seat the origin through the production seat, hands at
	# throwing height a hand's breadth ahead of the seated
	# head, and squeeze with each hand in turn.
	main._seat_behind_line()
	await frames(3)
	var seat_z: float = main.game_line_z() + 0.55
	check(absf(main.cam.global_position.z - seat_z) < 0.05,
		"Stage B: the seat puts the camera 0.55 m behind the line (cam z %.3f)"
		% main.cam.global_position.z)
	var seat_hand_r := Vector3(spot40.x + 0.25, 0.85, seat_z + 0.15)
	var seat_hand_l := Vector3(spot40.x - 0.25, 0.85, seat_z + 0.15)
	var slot0_far: Vector3 = main.rack_slot_tf(40, false, 0).origin
	check(seat_hand_l.distance_to(slot0_far) <= main.LONG_ARM_RADIUS,
		"Stage B: the far seat hand sits inside the long-arm radius of slot 0 (%.2f m of %.2f)"
		% [seat_hand_l.distance_to(slot0_far), main.LONG_ARM_RADIUS])
	check(await long_arm_grab(main, "R", seat_hand_r),
		"Stage B: a squeeze from the A-seat pulls a station shoe into the right hand")
	check(await drop_and_restock(main, "R"), "Stage B: the seat grab's shoe drops and restocks")
	main.test_hand_tf.erase("R")
	check(await long_arm_grab(main, "L", seat_hand_l),
		"Stage B: a squeeze from the A-seat pulls a station shoe into the left hand too")
	check(await drop_and_restock(main, "L"), "Stage B: the left seat grab's shoe drops and restocks")
	main.test_hand_tf.erase("L")
	# (j) The peg pair at the short line (the FP7 walk):
	# the long-arm works there too, then the yard is left
	# as the next section expects it - player home, shoe
	# stocked at the standard end.
	main.test_stick["L"] = Vector2(0.0, 1.0)
	await create_timer(1.9).timeout
	main.test_stick["L"] = Vector2.ZERO
	check(await wait_shoe_at(30, 2.0) >= 0.0,
		"FP25: the shoe waits at the short line")
	var spot30: Vector3 = main.spot_pos(30, false)
	var hand_r30 := Vector3(spot30.x + 0.25, 0.85, spot30.z)
	check(await long_arm_grab(main, "R", hand_r30),
		"FP25: a squeeze from the short-line spot latches the peg shoe")
	check(main._grip_index() == 0 and main.grip_label.text == "TOE GRIP · FLIP",
		"FP25: the peg arrival holds the default (TOE after the round trip)")
	check(await drop_and_restock(main, "R"), "FP25: the peg shoe drops and restocks")
	main.test_hand_tf.erase("R")
	# Home again: the origin goes to the 40 ft LINE (the
	# FP7 (d) idiom) - a cam at the world origin reads as
	# standing at NO line (it is 0.914 m behind the foul
	# line, outside the follow's proximity), so an identity
	# teleport would leave the shoe stocked short.
	main.origin.global_transform = Transform3D(Basis.IDENTITY,
		Vector3(0.0, 0.0, main.FOUL_40_Z))
	check(await wait_shoe_at(40, 3.0) >= 0.0,
		"FP25: the shoe restocks at the standard end for the next section")
	# (k) Fix Pass 34: THE PEG EXCLUSION (Fix Pass 36
	# numbers: LONG_ARM_RADIUS 2.40 m, the 30 ft peg 3.20 m
	# from the 40 ft spot's right hand, 3.39 m from the
	# left - OUTSIDE the radius again) - in GAME play the
	# peg must NOT answer a far squeeze from the 40 ft
	# spot; only the game station's stocked pair may. Stage
	# it directly: the player shoe railed at the peg, mode
	# flipped to GAME without the gather (a real start_game
	# would collect the shoe to the shelf, destroying the
	# staged state), a fresh squeeze from the 40 ft spot
	# hand. Then - because distance alone would refuse the
	# spot squeeze now - stage the walked case too: a hand
	# INSIDE the radius beside the peg, still in GAME, so
	# the explicit exclusion alone carries that refusal.
	var peg_slot: Vector3 = main.rack_slot_tf(30, false, 0).origin
	# Staged as production keeps a RAILED shoe: frozen on
	# its slot (the funnel and the gather both freeze).
	main.shoe.freeze = true
	main.shoe.global_position = peg_slot
	main.shoe.linear_velocity = Vector3.ZERO
	main.shoe.angular_velocity = Vector3.ZERO
	await frames(3)
	check(main.shoe.global_position.distance_to(peg_slot) < 0.01,
		"FP36: the exclusion leg's staging holds - the shoe railed at the peg")
	main.mode = "GAME"
	check(main.grab_armed and main.state == "STAND",
		"FP36: the grab stands armed for the exclusion leg (so the refusal is the peg's, not the grab's)")
	main.test_hand_tf["R"] = Transform3D(Basis.IDENTITY, hand_r40)
	main.test_grip["R"] = 1.0
	await create_timer(0.6).timeout
	check(main.hop_phase == "" and not main.grab_state.latched
		and main.shoe.global_position.distance_to(peg_slot) < 0.01,
		"FP36: in GAME the peg pair refuses a far squeeze from the 40 ft spot (3.20 m - outside the 2.40 m radius, the exclusion behind it) (hop '%s', shoe at %s)"
		% [String(main.hop_phase), str(main.shoe.global_position)])
	main.test_grip["R"] = 0.0
	await create_timer(0.25).timeout
	# The walked case: the hand 1.50 m from the peg-stocked
	# shoe - well inside the radius - still in GAME.
	main.test_hand_tf["R"] = Transform3D(Basis.IDENTITY,
		peg_slot + Vector3(1.5, 0.065, 0.0))
	main.test_grip["R"] = 1.0
	await create_timer(0.6).timeout
	check(main.hop_phase == "" and not main.grab_state.latched
		and main.shoe.global_position.distance_to(peg_slot) < 0.01,
		"FP36: in GAME a within-radius squeeze beside the peg STILL refuses - the explicit exclusion alone carries it (hop '%s', shoe at %s)"
		% [String(main.hop_phase), str(main.shoe.global_position)])
	main.test_grip["R"] = 0.0
	main.test_hand_tf.erase("R")
	main.mode = "PRACTICE"
	main.shoe.global_position = main.rack_slot_tf(40, false, 0).origin
	main.shoe.linear_velocity = Vector3.ZERO
	main.shoe.freeze = true
	await frames(3)

	# --- Fix Pass 26: the full circuit - cross-grabs enter
	# the far family, the far grip throws its declaration, and
	# a far default survives a restart. ---
	# (a) A near CROSS-grab enters the far family at its MID:
	# the right hand reaches across the shoe to shank_left.
	main.test_hand_tf.erase("L")
	main.test_hand_tf.erase("R")
	var gfar26: Vector3 = main.shoe.zone_world_center("shank_left")
	main.test_hand_tf["R"] = Transform3D(Basis.IDENTITY, gfar26)
	main.test_grip["R"] = 1.0
	await frames(6)
	check(main.state == "HELD" and main.held_zone == "shank_left"
		and main._grip_index() == 5
		and main.grip_label.text == "FAR SHANK · MID · 1¼ TURN · REVERSE",
		"FP26: a right-hand cross-grab enters the far family at FAR · MID (got %s / '%s')"
		% [main.held_zone, main.grip_label.text])
	# (b) The far throw: the production release serves the far
	# grip's declared count - the FP21 (c) stream with the
	# spin sign flipped (the reverse family's direction).
	var line_z26: float = main.game_line_z()
	var target26: Vector3 = main.target_stake_pos()
	var rp26 := Vector3(0.25, 1.25, line_z26 + 0.35)
	var tf26: float = 1.15
	var vel26 := Vector3((target26.x - rp26.x) / tf26,
		(0.50 - rp26.y + 4.9 * tf26 * tf26) / tf26,
		(target26.z - rp26.z) / tf26)
	var om26 := Vector3(0.0, TAU * 1.25 / tf26, 0.0)
	var rel26: Transform3D = main.rel_tf
	var hand_pos26: Vector3 = rp26 - rel26.origin
	main.test_hand_tf["R"] = Transform3D(Basis.IDENTITY, hand_pos26)
	await frames(4)
	main.samples = build_stream(hand_pos26, Quaternion.IDENTITY, vel26, om26, 26)
	main._release_shoe(main.samples)
	main.grab_state.reset()
	main.test_grip["R"] = 0.0
	check(main.state == "FLYING", "FP26: the far grip throws through the production path")
	check(String(main.release_cache.get("grip_name", "")) == "FAR SHANK · MID"
		and absf(float(main.release_cache.get("grip_nominal", 0.0)) - 1.25) <= 0.001,
		"FP26: the release cache carries the far grip (got %s / %.3f)"
		% [String(main.release_cache.get("grip_name", "")), float(main.release_cache.get("grip_nominal", 0.0))])
	check(absf(float(main.release_cache.get("spin_applied_total", 0.0)) - 1.25) <= 0.15,
		"FP26: the thrown far grip lands with its declared count (applied %.2f rev, declared +1.25)"
		% float(main.release_cache.get("spin_applied_total", 0.0)))
	check(await wait_state("STAND", 12.0), "FP26: the far throw settles and returns")
	var last_throw26: Dictionary = {}
	var f26: FileAccess = FileAccess.open(rec_path, FileAccess.READ)
	if f26 != null:
		for line26: String in f26.get_as_text().split("\n", false):
			var parsed26: Variant = JSON.parse_string(line26)
			if parsed26 is Dictionary and String(parsed26.get("type", "")) == "throw":
				last_throw26 = parsed26
	check(String(last_throw26.get("grip_name", "")) == "FAR SHANK · MID",
		"FP26: the throw record carries the far grip_name (got %s)"
		% String(last_throw26.get("grip_name", "")))
	main.test_hand_tf.erase("R")
	# (c) The left hand's cross-grab mirrors: shank_right is
	# ITS far zone, and it enters the same far MID.
	var gfar26l: Vector3 = main.shoe.zone_world_center("shank_right")
	main.test_hand_tf["L"] = Transform3D(Basis.IDENTITY, gfar26l)
	main.test_grip["L"] = 1.0
	await frames(6)
	check(main.state == "HELD" and main.held_hand == "L" and main.held_zone == "shank_right"
		and main._grip_index() == 5
		and main.grip_label.text == "FAR SHANK · MID · 1¼ TURN · REVERSE",
		"FP26: a left-hand cross-grab enters the far family at FAR · MID (got %s / '%s')"
		% [main.held_zone, main.grip_label.text])
	check(await drop_and_restock(main, "L"), "FP26: the cross-grabbed shoe drops and restocks")
	main.test_hand_tf.erase("L")
	# (d) A FAR default across a restart: cycle a held shoe to
	# FAR · MID (the default follows), then a fresh instance
	# must long-arm its arrival onto the far zone.
	main.test_hand_tf["R"] = Transform3D(Basis.IDENTITY,
		main.shoe.zone_world_center("toe"))
	main.test_grip["R"] = 1.0
	await frames(6)
	check(main.state == "HELD", "FP26: the setup grab latches for the far default")
	for i26: int in 5:
		await pulse_hand_button("L", "A")
	check(main._grip_index() == 5 and main.default_grip == 5
		and main.controls_full_text().contains("DEFAULT GRIP: FAR SHANK · MID"),
		"FP26: cycling to FAR · MID makes it the default, and the board names it (got %d)" % main.default_grip)
	check(await drop_and_restock(main, "R"), "FP26: the far-default shoe drops and restocks")
	main.test_hand_tf.erase("R")
	var m4: Node = spawn_fresh_main(rec_b, set_path)
	await create_timer(0.3).timeout
	check(int(m4.default_grip) == 5,
		"FP26: the far default survives a restart (read %d)" % int(m4.default_grip))
	check(await long_arm_grab(m4, "R", hand_r40),
		"FP26: the restarted instance long-arms from the spot")
	check(m4.held_zone == "shank_left" and m4._grip_index() == 5
		and m4.grip_label.text == "FAR SHANK · MID · 1¼ TURN · REVERSE",
		"FP26: the restarted long-arm arrival seats on the FAR zone (got %s / '%s')"
		% [m4.held_zone, m4.grip_label.text])
	m4.test_grip["R"] = 0.0
	m4.test_hand_tf.erase("R")
	root.remove_child(m4)
	m4.free()
	await frames(3)
	# Walk the default home to TOE for the sections that
	# follow (the FP25 setup idiom).
	main.test_hand_tf["R"] = Transform3D(Basis.IDENTITY,
		main.shoe.zone_world_center("toe"))
	main.test_grip["R"] = 1.0
	await frames(6)
	var guard26: int = 0
	while main.default_grip != 0 and guard26 < 10:
		await pulse_hand_button("L", "A")
		guard26 += 1
	check(main.default_grip == 0 and main._grip_index() == 0,
		"FP26: the default is walked back to TOE after the far legs (got %d)" % main.default_grip)
	check(await drop_and_restock(main, "R"), "FP26: the restored shoe drops and restocks")
	main.test_hand_tf.erase("R")

	# --- Fix Pass 7: the shoe waits where you are ---
	# The defect: the home pedestal was set only at latch time from
	# the shoe's OWN position, and the shoe starts on the 40 ft
	# pedestal - so it re-homed there forever and the 30 ft
	# pedestal could never be stocked. Now the stocked shoe
	# follows the line the PLAYER is standing at.
	# (a) Walk (production stick input) from the standard end to
	# the short line, empty-handed: a shoe must be waiting there.
	main.test_stick["L"] = Vector2(0.0, 1.0)
	await create_timer(1.9).timeout
	main.test_stick["L"] = Vector2.ZERO
	var arrive_sec: float = await wait_shoe_at(30, 1.0)
	check(arrive_sec >= 0.0,
		"walk to the short line empty-handed: a shoe is waiting on the 30 ft pedestal (stocked %.2f s after arrival)" % arrive_sec)
	# (b) It is grabbable there, and a still-hand drop there comes
	# back to the short pedestal.
	var toe30a: Vector3 = main.shoe.zone_world_center("toe")
	main.test_hand_tf["R"] = Transform3D(Basis.IDENTITY, toe30a)
	main.test_grip["R"] = 1.0
	await frames(5)
	check(main.state == "HELD" and main.held_hold == "flip",
		"the relocated shoe grabs at the short pedestal (state %s)" % main.state)
	await wait_hand_still("R")
	main.test_grip["R"] = 0.0
	await frames(4)
	check(main.state == "DROPPED", "still-hand release at the short line drops (state %s)" % main.state)
	check(await wait_state("STAND", 3.0), "dropped shoe at the short line returns")
	check(main.shoe.global_position.distance_to(main.stand_tfs[30].origin) < 0.01,
		"dropped shoe restocks at the SHORT pedestal (at %s)" % str(main.shoe.global_position))
	# (c) Throw from the short line: the next shoe stocks at the
	# SHORT pedestal within the pass-3 turnaround budget, and the
	# throw record tags line_ft 30.
	main.test_grip["R"] = 1.0
	await frames(5)
	check(main.state == "HELD", "re-grab at the short pedestal after the drop cycle")
	var now30: float = float(Time.get_ticks_msec()) / 1000.0
	var samples30: Array = []
	var v30 := Vector3(0.3, 3.4, -4.2)
	var g30 := Vector3(0.0, -9.8, 0.0)
	var p30 := Vector3(0.25, 1.15, -2.75)
	var hz30: float = 90.0
	var dur30: float = 0.30
	for i: int in int(dur30 * hz30) + 1:
		var t30: float = float(i) / hz30
		samples30.append(ThrowMath.make_sample(now30 - dur30 + t30,
			p30 + v30 * t30 + 0.5 * g30 * t30 * t30, Quaternion.IDENTITY))
	main.samples = samples30
	main._release_shoe(samples30)
	main.grab_state.reset()
	main.test_grip["R"] = 0.0
	check(main.state == "FLYING", "release at the short line throws (state %s)" % main.state)
	# (d) A shoe in flight is NEVER relocated: walk the player back
	# to the standard end mid-flight - the flying shoe and its home
	# must be untouched (the return keys off the RELEASE line).
	main.origin.global_transform = Transform3D.IDENTITY
	await frames(6)
	check(main.state == "FLYING" and main.active_stand_line_ft == 30,
		"in-flight shoe is not relocated by the player walking away (state %s, home %d)"
		% [main.state, main.active_stand_line_ft])
	main.origin.global_transform = Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -3.962))
	var cycle30: float = await wait_rest_to_stand(14.0)
	check(cycle30 >= 0.0 and cycle30 <= 1.2,
		"short-line throw: rest -> next shoe grabbable in %.2f s (pass-3 budget)" % cycle30)
	check(main.shoe.global_position.distance_to(main.stand_tfs[30].origin) < 0.01,
		"short-line throw restocks at the SHORT pedestal (at %s)" % str(main.shoe.global_position))
	var f30: FileAccess = FileAccess.open(rec_path, FileAccess.READ)
	var last30: Dictionary = {}
	if f30 != null:
		for line30: String in f30.get_as_text().split("\n", false):
			var pj30: Variant = JSON.parse_string(line30)
			if pj30 is Dictionary and String(pj30.get("type", "")) == "throw":
				last30 = pj30
	check(int(last30.get("line_ft", -1)) == 30,
		"short-line throw records line_ft 30 (got %d)" % int(last30.get("line_ft", -1)))
	# (e) A HELD shoe is never relocated either: hold it, walk the
	# player to the standard end - the shoe stays in the hand, and
	# the home stays at the short line.
	main.test_grip["R"] = 1.0
	await frames(5)
	check(main.state == "HELD", "grabbed again at the short pedestal")
	main.origin.global_transform = Transform3D.IDENTITY
	await frames(10)
	check(main.state == "HELD" and main.active_stand_line_ft == 30
		and main.shoe.global_position.distance_to(main.stand_tfs[40].origin) > 0.5,
		"held shoe is never relocated (state %s, home %d)" % [main.state, main.active_stand_line_ft])
	main.origin.global_transform = Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -3.962))
	await wait_hand_still("R")
	main.test_grip["R"] = 0.0
	await frames(4)
	check(await wait_state("STAND", 3.0), "released shoe returns after the held test")
	check(main.shoe.global_position.distance_to(main.stand_tfs[30].origin) < 0.01,
		"back at his line, the dropped shoe restocks at the SHORT pedestal")
	# (f) Walk back to the standard end empty-handed: the shoe
	# re-stocks at the 40 ft pedestal.
	main.test_stick["L"] = Vector2(0.0, -1.0)
	await create_timer(1.6).timeout
	main.test_stick["L"] = Vector2.ZERO
	var back_sec: float = await wait_shoe_at(40, 1.0)
	check(back_sec >= 0.0,
		"walk back to the standard end: the shoe re-stocks at the 40 ft pedestal (%.2f s)" % back_sec)
	main.origin.global_transform = Transform3D.IDENTITY

	# --- The shoe returns to the pedestal it was grabbed from ---
	# Place it on the 30 ft pedestal (as a return would leave it),
	# grab it there, drop it still: it must come back to the SHORT
	# pedestal, not the standard one. Fix Pass 7 re-derivation: the
	# player's BODY stands at the short line too - stocking now
	# follows the player, so the old hand-only teleport would be
	# overruled by the restock watcher (in the headset the hand is
	# never 3 m from the body anyway).
	main.origin.global_transform = Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -3.962))
	main.shoe.global_transform = main.stand_tfs[30]
	await frames(2)
	var toe30: Vector3 = main.shoe.zone_world_center("toe")
	main.test_hand_tf["R"] = Transform3D(Basis.IDENTITY, toe30)
	main.test_grip["R"] = 1.0
	await frames(5)
	check(main.grab_state.latched and main.active_stand_line_ft == 30,
		"grabbing from the short pedestal homes the shoe to it (line %d)" % main.active_stand_line_ft)
	for i: int in 40:
		if float(main.hand_speed["R"]) < 0.3:
			break
		await process_frame
	main.test_grip["R"] = 0.0
	await frames(4)
	check(main.state == "DROPPED", "still-hand release at the short line drops (state %s)" % main.state)
	check(await wait_state("STAND", 3.0), "dropped shoe returns under the quick timing")
	var back_tf: Transform3D = main.stand_tfs[30]
	check(main.shoe.global_position.distance_to(back_tf.origin) < 0.01,
		"shoe returned to the 30 ft pedestal it was grabbed from (at %s)" % str(main.shoe.global_position))
	main.origin.global_transform = Transform3D.IDENTITY

	# --- Settle honesty regression (pass 3) ---
	# A shoe placed at a known TRUE REST transform (frozen, zero
	# velocity) and settled under the new quick timing must record
	# the same landing distance the old timing's measurement gives
	# on that rest transform - faster detection, same measurement.
	var rest_tf := Transform3D(Basis.IDENTITY, Vector3(0.25, 0.065, -11.0))
	var stake_at_rest := Vector3(0.0, rest_tf.origin.y, -12.192)
	var expected_dist: float = ThrowMath.nearest_distance_inches(
		rest_tf, stake_at_rest, Shoe.WIDTH * 0.5, Shoe.LENGTH * 0.5)
	main.release_cache = {
		"hand": "R", "zone": "toe", "hold": "flip", "slide_offset_m": 0.0,
		"line_ft": 40, "origin_pos": Vector3.ZERO,
		"head_yaw_deg": 0.0, "origin_yaw_deg": 0.0,
		"origin_pitch_deg": 0.0, "origin_roll_deg": 0.0,
		"samples": [], "release_pos": rest_tf.origin,
		"release_quat": Quaternion.IDENTITY,
		"velocity": Vector3.ZERO, "angular_velocity": Vector3.ZERO,
	}
	main.shoe.freeze = true
	main.shoe.global_transform = rest_tf
	main.has_contact = true
	main.first_contact_pos = rest_tf.origin
	main.state = "FLYING"
	main._fly_time = 1.0
	main._still_time = 0.0
	check(await wait_state("STAND", 3.0), "controlled rest settles and returns under the quick timing")
	var f2: FileAccess = FileAccess.open(rec_path, FileAccess.READ)
	var last_throw: Dictionary = {}
	if f2 != null:
		for line2: String in f2.get_as_text().split("\n", false):
			var p2: Variant = JSON.parse_string(line2)
			if p2 is Dictionary and String(p2.get("type", "")) == "throw":
				last_throw = p2
	check(not last_throw.is_empty()
		and absf(float(last_throw.get("landing_distance_in", -1.0)) - expected_dist) < 0.1,
		"quick settle records the true-rest distance (%.2f in vs expected %.2f in)"
		% [float(last_throw.get("landing_distance_in", -1.0)), expected_dist])
	var settle_arr: Array = last_throw.get("settle_pos", [])
	check(settle_arr.size() == 3
		and Vector3(float(settle_arr[0]), float(settle_arr[1]), float(settle_arr[2])).distance_to(rest_tf.origin) < 0.002,
		"quick settle records the rest position itself, not an earlier guess")

	# --- Fix Pass 8: a shoe must never ghost through the stake ---
	# Field report (Chris, 2026-11-02): a shoe went "right through
	# stake... think it's hollow". Audit: the stake collision is a
	# SOLID cylinder and the shoe's continuous CD is on - the hole
	# is step size vs a 25 mm target (a 9 m/s shoe steps ~15 cm;
	# the linear CCD cast cannot sweep the tumble). His throw
	# crossed ~9 cm off centre at 0.18 m height, mid-skip. These
	# guards pin the fix in place: the visual stays 1 in, the
	# collision core runs +3 mm, CCD stays on, and dead-centre
	# full-speed shots through the production path must CLANG.
	find_stake()
	check(stake_body != null, "pass 8: stake body found in the built scene")
	var stake_col_radius: float = -1.0
	var stake_vis_radius: float = -1.0
	if stake_body != null:
		for sub: Node in stake_body.get_children():
			if sub is CollisionShape3D and (sub as CollisionShape3D).shape is CylinderShape3D:
				stake_col_radius = ((sub as CollisionShape3D).shape as CylinderShape3D).radius
			if sub is MeshInstance3D and (sub as MeshInstance3D).mesh is CylinderMesh:
				stake_vis_radius = ((sub as MeshInstance3D).mesh as CylinderMesh).top_radius
	check(absf(stake_vis_radius - 0.0127) < 0.0005,
		"pass 8: stake VISUAL stays true 1 in steel (r %.4f m)" % stake_vis_radius)
	check(stake_col_radius > stake_vis_radius
		and stake_col_radius - stake_vis_radius <= 0.0035,
		"pass 8: stake COLLISION core runs a few mm fat, no more (r %.4f m, +%.1f mm)"
		% [stake_col_radius, (stake_col_radius - stake_vis_radius) * 1000.0])
	check(bool(main.shoe.continuous_cd),
		"pass 8: shoe continuous CD is on (Godot 4.7 bool shape cast)")
	main.shoe.body_entered.connect(_on_stake_test_body_entered)
	# (a) In flight at stake-top height, flat, dead centre, 9.2 m/s.
	var shot_a: Dictionary = await fire_at_stake(
		Vector3(0.0, 1.56, -7.6), Vector3(0.0, 0.0, -9.2), 0.0)
	check(bool(shot_a["fired"]) and bool(shot_a["contact"]),
		"pass 8 shot A (flight at stake-top height): the stake is HIT, not ghosted")
	check(bool(shot_a["contact"]) or float(shot_a["max_beyond"]) <= 0.12,
		"pass 8 shot A: centre never crosses to the far side untouched (deepest %.3f m)"
		% float(shot_a["max_beyond"]))
	# (b) In flight low in the exposed band, flat, dead centre.
	var shot_b: Dictionary = await fire_at_stake(
		Vector3(0.0, 1.38, -7.6), Vector3(0.0, 0.0, -9.2), 0.0)
	check(bool(shot_b["fired"]) and bool(shot_b["contact"]),
		"pass 8 shot B (flight low in the band): the stake is HIT, not ghosted")
	check(bool(shot_b["contact"]) or float(shot_b["max_beyond"]) <= 0.12,
		"pass 8 shot B: centre never crosses to the far side untouched (deepest %.3f m)"
		% float(shot_b["max_beyond"]))
	# (c) Ground-skimming: touches down inside the pit and skims
	# into the stake base, tumbling, dead centre. With damping
	# removed (pass 9) the shoe arrives livelier and can thread
	# the opening slowly, settling wrapped AROUND the stake with
	# no single registrable contact - a ringer, not a ghost.
	# Either evidence answers the check: a stake engagement
	# (solver or guard), or a final rest encircling the stake
	# (centre within 6 cm of the axis).
	# Fix Pass 23 amendment: the sand now EATS this arrival -
	# a full-speed pit touchdown is buried where it lands
	# (Chris's law: a shoe that lands in the pit stays in the
	# pit), so the skim dies in the sand short of the base
	# instead of reaching it. That outcome is the pass working,
	# not a ghost: the guard's teeth are the max_beyond check
	# below (unchanged - the centre must never cross untouched)
	# plus shots A/B/D pinning stake engagement in flight. So
	# a third evidence answers now: the shoe settles dead
	# inside the pit (on the lane axis, within its length).
	var shot_c: Dictionary = await fire_at_stake(
		Vector3(0.0, 0.75, -8.3), Vector3(0.0, -0.2, -9.6), -7.0)
	check(bool(shot_c["fired"]) and (bool(shot_c["contact"]) or float(shot_c["axis_dist"]) < 0.06
			or float(shot_c["axis_dist"]) <= 0.914),
		"pass 8 shot C (pit touchdown, skim into the base): the stake is HIT, not ghosted (or the shoe settles wrapped on it, or - Fix Pass 23 - dies in the sand inside the pit, axis dist %.3f m)"
		% float(shot_c["axis_dist"]))
	check(bool(shot_c["contact"]) or float(shot_c["max_beyond"]) <= 0.12,
		"pass 8 shot C: centre never crosses to the far side untouched (deepest %.3f m)"
		% float(shot_c["max_beyond"]))
	# (d) Chris's geometry: ~9 cm off centre, tumbling, crossing in
	# flight at band height - the graze that ghosted in the field.
	var shot_d: Dictionary = await fire_at_stake(
		Vector3(0.09, 1.55, -7.3), Vector3(0.0, 0.1, -9.3), -9.0)
	check(bool(shot_d["fired"]) and bool(shot_d["contact"]),
		"pass 8 shot D (the field graze, 9 cm off centre): the stake is HIT, not ghosted")
	check(bool(shot_d["contact"]) or float(shot_d["max_beyond"]) <= 0.12,
		"pass 8 shot D: centre never crosses to the far side untouched (deepest %.3f m)"
		% float(shot_d["max_beyond"]))
	# --- Fix Pass 9: the damping pin and the sweep guard ---
	# The technique audit found the shoe had silently inherited
	# the physics space's default 0.1 linear + angular damp:
	# spin bled ~10%/s in flight and throws landed ~1 m short of
	# their ballistic line. The shoe now pins both damps to zero
	# in REPLACE mode - assert it stays that way.
	check(main.shoe.linear_damp_mode == RigidBody3D.DAMP_MODE_REPLACE
		and main.shoe.angular_damp_mode == RigidBody3D.DAMP_MODE_REPLACE
		and is_zero_approx(main.shoe.linear_damp) and is_zero_approx(main.shoe.angular_damp),
		"pass 9: shoe damping pinned to zero in REPLACE mode (no silent space-default decay)")
	# The undamped shoe arrives faster and higher, and the solver
	# + CCD miss the flat dead-centre shot A outright (it crossed
	# 0.66 m past the stake untouched in the audit's traces). The
	# sweep guard is what engages it now: shot A above counted as
	# a hit through solver contact OR a guard save (see
	# fire_at_stake), and with the guard disabled the same shot
	# must ghost again (negative control).
	main.shoe.guard_enabled = false
	var shot_ctl: Dictionary = await fire_at_stake(
		Vector3(0.0, 1.56, -7.6), Vector3(0.0, 0.0, -9.2), 0.0)
	main.shoe.guard_enabled = true
	check(bool(shot_ctl["fired"]) and not bool(shot_ctl["contact"])
		and float(shot_ctl["max_beyond"]) > 0.12,
		"pass 9 control: guard disabled, shot A ghosts again (deepest %.3f m untouched) - the guard is the save"
		% float(shot_ctl["max_beyond"]))
	# ============ Backyard Game v1: win-rule probes ============
	# Deterministic, no throwing: the win is an inning-END rule.
	main.origin.global_transform = Transform3D.IDENTITY
	main.start_game()
	check(main.mode == "GAME" and main.phase == "P_TURN" and main.inning == 1,
		"game: A starts a game - inning 1, player throws first")
	check(main.score_label.text.contains("YOU 0 - 0 OPP"),
		"game: the scoreboard shows the score on its own big line")
	main.score_you = 20
	main.inning_results = [
		{"owner": "P", "dist_in": 2.0, "ringer": false},
		{"owner": "AI", "dist_in": 9.0, "ringer": false}]
	main._score_inning()
	check(main.score_you == 21 and main.phase == "OVER"
		and main.winner_text == "YOU WIN!",
		"game: reaching exactly 21 at an inning's end wins")
	main.start_game()
	main.score_you = 19
	main.inning_results = [{"owner": "P", "dist_in": 0.0, "ringer": true}]
	main._score_inning()
	check(main.score_you == 22 and main.phase == "OVER",
		"game: passing 21 wins too (no win-by-two)")
	main.start_game()
	main.inning_results = [
		{"owner": "P", "dist_in": 8.0, "ringer": false},
		{"owner": "AI", "dist_in": 9.0, "ringer": false}]
	main._score_inning()
	check(main.phase == "INSERT" and main.last_scorer == "",
		"game: a scoreless inning posts to the insert (FP20: tabulated on settle, no walk)")
	main._finish_inning_cycle()
	check(main.inning == 2 and main.inning_first == "AI",
		"game: after a scoreless inning the first throw alternates")
	# Fix Pass 19: the cycle does NOT re-seat the AI - there is
	# no other end. He is still in the one pitching-end box
	# (FP11/FP13 asserted his far-end box after a swap; that
	# end, and the swap, no longer exist).
	check(main.ai_pitcher.position.distance_to(
			AIPitcher.box_root(main.game_line_z())) < 0.05,
		"FP19: after the cycle the AI is still in its pitching-end box (at %s)"
		% str(main.ai_pitcher.position))
	check_ai_box()

	# ============ Fix Pass 20: rounds post themselves ============
	# Chris's FP19 verdict: "everything is working" - and his
	# flow order: "we dont wanna make walking down and back
	# mandatory. last shoe thrown in round, score is tabulated,
	# next round, shoes are ready to go. I can see an Insert
	# Cam depicting a closeup, with a nice little score
	# breakdown." FP20 deletes the walk-arrival triggers: the
	# round tabulates on settle + a beat, the insert cam shows
	# the pit closeup and the breakdown, A stocks the next
	# round. Walking still exists; it just does nothing.
	# (a) THE LINE BARRIER (FP20's clamp, re-derived by FP30):
	# while a round is live the player cannot get his HEAD'S
	# GROUND POSITION past the foul line. FP20 clamped the
	# ORIGIN at a plane 0.40 m past the line and Chris walked
	# through it in the headset - origin obedient, head leaned
	# over, "line is behind me." The barrier judges the head:
	# walk, lean and stride all stop at the line itself (a
	# 0.05 m epsilon), and retreat still works (the barrier is
	# on the movement result, not input). Walked on production
	# movement throughout - never teleported.
	var line20: float = main.game_line_z()
	var limit30: float = line20 - main.LINE_BARRIER_EPSILON
	main.origin.global_transform = Transform3D.IDENTITY
	# Upright head, directly over the origin: the FP20 walk.
	main.cam.transform = Transform3D(Basis.IDENTITY, Vector3(0.0, 1.62, 0.0))
	main.start_game()
	await walk_forward_for(3.0)
	check(main.cam.global_position.z >= limit30 - 0.001
		and main.cam.global_position.z <= limit30 + 0.03,
		"FP30 barrier: a live-round walk down the lane stops with the HEAD at the line (head z %.3f, limit %.3f)"
		% [main.cam.global_position.z, limit30])
	# The leaned walk - Chris's screenshot geometry, on foot:
	# head pitched ~80 deg down to look at his toes, its centre
	# 0.30 m ahead of the origin. Under FP20 this walk put the
	# ORIGIN 0.40 m past the line; now the head pins at the
	# limit and the origin never even reaches the line.
	main.cam.transform = Transform3D(
		Basis.from_euler(Vector3(deg_to_rad(-80.0), 0.0, 0.0)),
		Vector3(0.0, 1.45, -0.30))
	await walk_forward_for(3.0)
	check(main.cam.global_position.z >= limit30 - 0.001
		and main.cam.global_position.z <= limit30 + 0.03,
		"FP30 barrier: leaned forward looking down, the head still stops at the line (head z %.3f, limit %.3f)"
		% [main.cam.global_position.z, limit30])
	check(main.origin.global_position.z > line20,
		"FP30 barrier: the leaned walk's ORIGIN stays behind the line entirely (origin z %.3f, line %.3f) - FP20 let it 0.40 m past"
		% [main.origin.global_position.z, line20])
	main.test_stick["L"] = Vector2(0.0, -1.0)
	await create_timer(0.6).timeout
	main.test_stick["L"] = Vector2.ZERO
	await frames(3)
	check(main.cam.global_position.z > limit30 + 0.5,
		"FP30 barrier: walking BACKWARD off the line still works (head z %.3f)"
		% main.cam.global_position.z)
	main.cam.transform = Transform3D(Basis.IDENTITY, Vector3(0.0, 1.62, 0.0))
	check(main.phase == "P_TURN",
		"FP20 clamp: the round is still live and unthrown after the walk attempt")
	await pulse_button("B")
	check(main.mode == "PRACTICE", "FP20: B leaves the clamp-test game")
	# The manufactured round: the beat runs first (nothing
	# posted yet), then the round posts ITSELF with the
	# player never having moved from the line.
	manufacture_round()
	check(main.phase == "TABULATE" and main.score_opp == 0,
		"FP20: a thrown round enters the tabulation beat unposted (phase %s, opp %d)"
		% [String(main.phase), main.score_opp])
	check(await wait_phase("INSERT", 5.0),
		"FP20: the round posts itself after the beat - no walking (phase %s)"
		% String(main.phase))
	check(main.phase == "INSERT" and main.score_opp == 3
		and main.cam.global_position.z > -0.5,
		"FP20: the manufactured score posted with the player standing at the line (board %d-%d, cam z %.2f)"
		% [main.score_you, main.score_opp, main.cam.global_position.z])
	check(main.board_breakdown_up and main.board_breakdown_label.visible
		and not main.status_label.visible,
		"FP39: the round-end breakdown is up on the REAR BOARD at the round's end (the billboard is cam only)")
	# Fix Pass 38 (re-derives FP34's fixed-transform guard):
	# the billboard stands at ONE fixed transform, left of
	# the lane at halfway - no matter where the player
	# stands or looks. Fix Pass 39 keeps the placement and
	# the guard verbatim; only the display moved (to the
	# rear board, checked above).
	var bb38: Transform3D = main.billboard_transform()
	check(main.insert_root.visible
		and main.insert_root.global_transform.origin.distance_to(bb38.origin) < 0.001
		and main.insert_root.global_transform.basis.is_equal_approx(bb38.basis),
		"FP38: the billboard stands at its fixed transform (at %s)"
		% str(main.insert_root.global_position))
	check(main.insert_root.global_position.x < -3.3
		and main.insert_root.global_position.z < -6.1
		and main.insert_root.global_position.z > -7.0,
		"FP38: the billboard is LEFT of the lane at halfway - not centred over it, not in the player's face")
	var lines20: String = "\n".join(PackedStringArray(main.round_lines))
	check(lines20.contains("OPP 1: RINGER")
		and lines20.contains("YOU 1: NO SCORE (30.0 IN)")
		and lines20.contains("OPP RINGER STANDS: +3")
		and lines20.contains("ROUND: OPP +3")
		and lines20.contains("MATCH: YOU 0 - 3 OPP")
		and lines20.contains("NEXT ROUND"),
		"FP20: the breakdown carries shoes, arithmetic, totals, continue (%s)"
		% lines20.replace("\n", " | "))
	check(main.board_breakdown_label.text == lines20,
		"FP39: the scoreboard's breakdown block shows exactly the round's lines")
	check(main.ai_pitcher.position.distance_to(
			AIPitcher.box_root(main.game_line_z())) < 0.05,
		"FP20: the AI never left its box for the cycle (at %s)"
		% str(main.ai_pitcher.position))
	# (b) FREE MOVEMENT during the insert: he may stroll down
	# the lane while the breakdown is up - the clamp is off.
	await walk_forward_for(2.5)
	check(main.origin.global_position.z < line20 - 0.5,
		"FP20: during the insert the player walks PAST the line freely (z %.3f)"
		% main.origin.global_position.z)
	# (c) A-CONTINUE from beyond the line seats him back
	# behind it (yaw-only seat - origin pitch/roll stay 0)
	# and stocks the next round, scorer first.
	await pulse_button("A")
	var waited20: float = 0.0
	while String(main.phase) != "AI_TURN" and waited20 < 5.0:
		await create_timer(0.1).timeout
		waited20 += 0.1
	check(main.inning == 2 and main.phase == "AI_TURN",
		"FP20: A at the insert opens inning 2 with the scorer (the AI) first (inning %d, phase %s)"
		% [main.inning, String(main.phase)])
	check(main.origin.global_position.z >= limit30 - 0.001
		and main.cam.global_position.z > main.game_line_z(),
		"FP20: the A-continue seated him back behind the line (origin z %.3f, cam z %.3f)"
		% [main.origin.global_position.z, main.cam.global_position.z])
	check_origin_level("FP20: the A-continue seat-back leaves the origin level (pitch/roll 0)")
	check(not main.board_breakdown_up and not main.board_breakdown_label.visible
		and main.status_label.visible,
		"FP39: the continue dismisses the breakdown - the scoreboard is back to its running display")
	check(all_railed() and max_slot_error() < 0.01,
		"FP20: the continue stocks both pairs per owner on the stations (worst %.3f m)"
		% max_slot_error())
	# Fix Pass 36 - THE GATHER'S DESTINATION, named per
	# owner: the same gather routes the AI pair to the AI's
	# OWN station - the one in front of the fountain at
	# (-2.14, -1.50) - not merely "a station".
	check(main.ai_pair[0].global_position.distance_to(
			main.rack_slot_tf(40, true, 0).origin) < 0.01
		and main.ai_pair[1].global_position.distance_to(
			main.rack_slot_tf(40, true, 1).origin) < 0.01
		and main.rack_slot_tf(40, true, 0).origin.x < -2.0,
		"FP36: the game's gather routes the AI pair to ITS station in front of the fountain (-2.14) (at %s / %s)"
		% [str(main.ai_pair[0].global_position),
			str(main.ai_pair[1].global_position)])
	# Inning 2 (stocked by the seat-back continue above)
	# plays out from the line, end to end.
	var guard12: int = 0
	while main.phase != "TABULATE" and main.phase != "INSERT" \
			and main.phase != "OVER" and guard12 < 6:
		guard12 += 1
		if main.phase == "P_TURN":
			check(await scripted_game_throw(),
				"FP20: inning 2 accepts the player's throws after the insert cycle")
		elif main.phase == "AI_TURN":
			var waited12: float = 0.0
			while main.phase == "AI_TURN" and waited12 < 40.0:
				await create_timer(0.5).timeout
				waited12 += 0.5
			check(main.phase != "AI_TURN",
				"FP20: the AI plays its inning-2 turn after the insert cycle")
		else:
			break
	check((main.phase == "TABULATE" or main.phase == "INSERT")
		and main.inning == 2,
		"FP20: inning 2 is thrown and reaches its tabulation (inning %d, phase %s)"
		% [main.inning, String(main.phase)])
	# B during the beat leaves, as at any game phase.
	manufacture_round()
	await pulse_button("B")
	check(main.mode == "PRACTICE",
		"FP20: B during the tabulation beat returns to practice")

	# ============ Fix Pass 39: THE BROADCAST PASS ============
	# The billboard is CAM ONLY, the camera is a smart
	# closeup, a ringer replays itself in slow motion, and
	# the breakdown lives on the rear scoreboard - through
	# the production paths only (entry: practice).
	# (a) THE FEED RUNS HOT IN FLIGHT: a production grab +
	# constructed release (the scripted_shot idiom) drives
	# the pit-cam viewport to full frame rate while the
	# shoe flies.
	var bb_labels: int = 0
	for ch38: Node in main.insert_root.get_children():
		if ch38 is Label3D:
			bb_labels += 1
	check(main.insert_root.visible and bb_labels == 0
		and (main.insert_screen.mesh as QuadMesh).size == main.BILLBOARD_FEED_LIVE,
		"FP39: the billboard stands CAM ONLY - no text on it, the feed full-panel (it never hides)")
	main.test_hand_tf["R"] = Transform3D(Basis.IDENTITY,
		main.shoe.zone_world_center("toe"))
	main.test_grip["R"] = 1.0
	await frames(6)
	for i: int in 2:
		await physics_frame
	check(main.state == "HELD",
		"FP38: the practice grab holds the shoe for the policy throw")
	var fp38_line_z: float = main.game_line_z()
	var fp38_release := Vector3(0.25, 1.25, fp38_line_z + 0.35)
	var fp38_rel: Dictionary = AIPitcher.base_release(
		fp38_release, main.target_stake_pos())
	var fp38_vel: Vector3 = fp38_rel["vel"]
	var fp38_ang: Vector3 = fp38_rel["ang"]
	var fp38_rel_tf: Transform3D = Shoe.hold_transform("toe", "R")
	var fp38_basis: Basis = (fp38_rel["basis"] as Basis) * fp38_rel_tf.basis.inverse()
	main.test_hand_tf["R"] = Transform3D(fp38_basis,
		fp38_release - fp38_basis * fp38_rel_tf.origin)
	await frames(4)
	for i: int in 2:
		await physics_frame
	var fp38_samples: Array = []
	var fp38_axis: Vector3 = fp38_ang.normalized()
	var fp38_rate: float = fp38_ang.length()
	var fp38_now: float = float(Time.get_ticks_msec()) / 1000.0
	for i: int in 28:
		var fp38_t: float = float(i - 27) / 90.0
		fp38_samples.append(ThrowMath.make_sample(
			fp38_now + fp38_t,
			fp38_release + fp38_vel * fp38_t,
			Quaternion(fp38_axis, fp38_rate * fp38_t)))
	main.samples = fp38_samples
	var fp38_gov: bool = main.spin_governor_enabled
	main.spin_governor_enabled = false
	main._release_shoe(fp38_samples)
	main.spin_governor_enabled = fp38_gov
	main.grab_state.reset()
	main.test_grip["R"] = 0.0
	check(main.state == "FLYING", "FP38: the policy release flies")
	var fp38_hot: bool = false
	var fp38_fly_guard: float = 0.0
	while main.state == "FLYING" and fp38_fly_guard < 3.0:
		await physics_frame
		if main.insert_viewport.render_target_update_mode == SubViewport.UPDATE_ALWAYS:
			fp38_hot = true
		fp38_fly_guard += 1.0 / 60.0
	check(fp38_hot,
		"FP38: the pit-cam viewport runs at FULL RATE while a shoe is in flight")
	# The settle budget is the suite's AI-turn class (40 s):
	# a shoe plowing a long sand furrow at low speed resets
	# the stillness test while it creeps, and under a loaded
	# box the physics clock dilates against the wall clock -
	# the FP38 probe of this same throw settled in ~2 s on a
	# quiet pit, the suite's worked-over pit takes longer.
	# Settle, in the state machine's own word: the player's
	# shoe leaves FLYING (practice then RETURNS it to the
	# stand - its shoe_status only leaves FLYING at the end
	# of that return, so the status is not the settle
	# signal here; an earlier wording of this check read
	# the status and failed on a settled shoe).
	var fp38_land: float = 0.0
	while main.state == "FLYING" and fp38_land < 40.0:
		await create_timer(0.25).timeout
		fp38_land += 0.25
	check(main.state != "FLYING",
		"FP38: the policy throw settled (practice returns the shoe to the stand; %.1f s)" % fp38_land)
	# (b) IDLE LAZY: once the post-settle beat burns off
	# with the pit quiet, the viewport leaves full rate -
	# polled for the transition (the beat is physics time,
	# which dilates under load).
	var fp38_idle: float = 0.0
	while main.insert_viewport.render_target_update_mode == SubViewport.UPDATE_ALWAYS \
			and fp38_idle < 20.0:
		await create_timer(0.25).timeout
		fp38_idle += 0.25
	check(main.insert_viewport.render_target_update_mode != SubViewport.UPDATE_ALWAYS,
		"FP38: the idle pit-cam leaves full rate (lazy pulses only; %.1f s)" % fp38_idle)
	# (c) THE BREAKDOWN ON THE SCOREBOARD: a manufactured
	# round posts itself (the FP20 idiom) - settle -> the
	# breakdown stands on the REAR BOARD, and the billboard
	# stays cam only, full-panel, even at round end.
	manufacture_round()
	check(await wait_phase("INSERT", 5.0),
		"FP39: the manufactured round posts its breakdown")
	check(main.board_breakdown_up and main.board_breakdown_label.visible
		and main.board_breakdown_label.text.contains("OPP +3")
		and (main.insert_screen.mesh as QuadMesh).size == main.BILLBOARD_FEED_LIVE,
		"FP39: the breakdown stands on the scoreboard - and the billboard is still cam only")
	# (d) CONTINUE returns the board to its running display.
	await pulse_button("A")
	await frames(4)
	check(not main.board_breakdown_up and not main.board_breakdown_label.visible
		and main.status_label.visible,
		"FP39: A-continue returns the scoreboard to its running display")
	await pulse_button("B")
	check(main.mode == "PRACTICE",
		"FP39: B returns to practice for the sections below")
	# (e) THE RINGER REPLAY - through the real path: a
	# scripted production ringer (the calibrated shot),
	# settled by the game's own settle path, must offer
	# itself to the replay, play back on the pit-cam layer
	# at the slowed rate with the real shoe hidden from
	# the pit camera only, and restore the live view when
	# it ends. A dud must never replay.
	main.start_game()
	var rp_shoe: Shoe = main.shoe
	check(await scripted_shot("ringer"),
		"FP39 replay: the scripted ringer flies and settles")
	var rp_wait: float = 0.0
	while main.replay_state != "PLAYING" and rp_wait < 6.0:
		await create_timer(0.1).timeout
		rp_wait += 0.1
	check(main.replay_state == "PLAYING",
		"FP39 replay: a settled ringer starts its slow-mo replay by itself (state %s after %.1f s)"
		% [String(main.replay_state), rp_wait])
	check(main.replay_clone != null and main.replay_clone.visible,
		"FP39 replay: the clone shoe is on the pit")
	var clone_part: MeshInstance3D = main.replay_clone.parts["toe"]
	var real_part: MeshInstance3D = rp_shoe.parts["toe"]
	check(clone_part.layers == main.VIS_LAYER_PITCAM
		and real_part.layers == main.VIS_LAYER_MAIN_ONLY,
		"FP39 replay: the clone rides the pit-cam layer (2) and the real shoe hides from the pit camera only (4)")
	# The clone flies the RECORDED track at the slowed
	# rate: at replay clock t, the track position is
	# t * REPLAY_RATE * ticks, interpolated between the
	# recorded samples - the clone must sit on that point
	# (the harness reads both clocks in one breath).
	await create_timer(0.6).timeout
	var rp_track: Array = main.replay_track["shoe"]
	var rp_f: float = main.replay_t * main.REPLAY_RATE \
		* float(Engine.physics_ticks_per_second)
	var rp_i0: int = clampi(int(floor(rp_f)), 0, rp_track.size() - 2)
	var rp_expect_pos: Vector3 = (rp_track[rp_i0] as Transform3D).origin.lerp(
		(rp_track[rp_i0 + 1] as Transform3D).origin, rp_f - float(rp_i0))
	check(main.replay_clone.global_position.distance_to(rp_expect_pos) < 0.03,
		"FP39 replay: the clone sits on the recorded track at the slowed rate (track t %.2f, off by %.3f m)"
		% [rp_f, main.replay_clone.global_position.distance_to(rp_expect_pos)])
	check(main.insert_viewport.render_target_update_mode == SubViewport.UPDATE_ALWAYS,
		"FP39 replay: the feed runs at full rate while the replay plays")
	var rp_end: float = 0.0
	while main.replay_state != "IDLE" and rp_end < 12.0:
		await create_timer(0.2).timeout
		rp_end += 0.2
	check(main.replay_state == "IDLE" and not main.replay_clone.visible
		and real_part.layers == main.VIS_LAYER_WORLD,
		"FP39 replay: the replay ends and the live view is restored (real shoe back on both cameras)")
	# A dud settles and NO replay is offered. The dud's
	# settle passes the turn to the AI - freeze its
	# sampler NOW, in the same breath, or its own throw
	# (0.8 s delay) pre-empts the scripted one below.
	check(await scripted_shot("dud"),
		"FP39 replay: the follow-up dud flies and settles")
	main.ai_delay = 100000.0
	await create_timer(2.0).timeout
	check(main.replay_state == "IDLE" and main.replay_track.is_empty(),
		"FP39 replay: a non-ringer never replays")
	# (f) EITHER SIDE'S RINGER REPLAYS - and live wins: an
	# AI ringer starts its replay, then B (back to
	# practice - a round-end state change through the
	# production input poll) cuts it mid-flight.
	check(await wait_phase("AI_TURN", 10.0),
		"FP39 replay: the turn passes to the AI")
	check(await scripted_ai_throw("ringer"),
		"FP39 replay: the AI's scripted ringer settles")
	rp_wait = 0.0
	while main.replay_state != "PLAYING" and rp_wait < 6.0:
		await create_timer(0.1).timeout
		rp_wait += 0.1
	check(main.replay_state == "PLAYING",
		"FP39 replay: the AI's ringer replays too (a ringer is a ringer)")
	await pulse_button("B")
	await frames(4)
	check(main.mode == "PRACTICE" and main.replay_state == "IDLE"
		and not main.replay_clone.visible,
		"FP39 replay: B to practice cuts the replay - live always wins")

	# ============ Fix Pass 40: the camera follows the ARRIVAL ============
	# Chris's FP39 verdict: the cam is smooth with a high
	# frame rate - but it starts tracking the shoe too
	# soon, "swinging way left and going kind of wild
	# trying to get a shot". His law: the camera stays on
	# the pit until the shoe is well on its way; it
	# follows the ARRIVAL, never the release. Two scripted
	# production throws in practice - a straight line
	# drive and a hard pulled-LEFT throw - with the
	# camera's yaw sampled every physics frame against
	# the baseline: before the gate the drift must stay
	# within 1 degree (the targets ARE the baseline's);
	# across the whole flight the excursion stays in a
	# bounded arc - 8 deg for the line drive, 20 for the
	# pull (a stake-anchored look can lean toward a shoe
	# 3 m wide, but the stake never leaves the frame it
	# fills); after the gate the shoe must be inside the
	# frustum for the arrival. FP39's own desired yaw is
	# recomputed per sample from its formulas, so the
	# same flights report both passes' numbers.
	var f40_base_yaw: float = rad_to_deg(atan2(
		-(main.PITCAM_BASE_LOOK.x - main.PITCAM_BASE_POS.x),
		-(main.PITCAM_BASE_LOOK.z - main.PITCAM_BASE_POS.z)))
	for f40_kind in ["line", "pull"]:
		var f40_kind_s: String = String(f40_kind)
		# Start from a camera at home on the baseline and
		# a player at STAND (the previous lie hold burns
		# off, the camera eases home, the shoe restocks).
		var f40_home: float = 0.0
		while f40_home < 25.0:
			if String(main.state) == "STAND" \
					and main.pitcam_lie_left <= 0.0 \
					and absf(fp40_cam_yaw() - f40_base_yaw) < 0.5 \
					and absf(main.pitcam_fov - main.PITCAM_BASE_FOV) < 1.5:
				break
			await create_timer(0.25).timeout
			f40_home += 0.25
		check(String(main.state) == "STAND"
			and main.pitcam_lie_left <= 0.0
			and absf(fp40_cam_yaw() - f40_base_yaw) < 0.5,
			"FP40 (%s): the camera is home on the baseline before the throw (yaw %.2f, base %.2f)"
			% [f40_kind_s, fp40_cam_yaw(), f40_base_yaw])
		check(await fp40_release(f40_kind_s),
			"FP40 (%s): the scripted throw flies" % f40_kind_s)
		var f40_pre_max: float = 0.0
		var f40_pre_frames: int = 0
		var f40_yaw_min: float = fp40_cam_yaw()
		var f40_yaw_max: float = f40_yaw_min
		var f40_leg_min: float = fp40_legacy_yaw(main.shoe.global_position)
		var f40_leg_max: float = f40_leg_min
		var f40_engaged: bool = false
		var f40_framed: bool = false
		var f40_guard: float = 0.0
		while String(main.state) == "FLYING" and f40_guard < 20.0:
			await physics_frame
			f40_guard += 1.0 / 60.0
			var f40_yaw: float = fp40_cam_yaw()
			if not main.pitcam_gate_engaged:
				f40_pre_frames += 1
				f40_pre_max = maxf(f40_pre_max,
					absf(f40_yaw - f40_base_yaw))
			else:
				f40_engaged = true
			f40_yaw_min = minf(f40_yaw_min, f40_yaw)
			f40_yaw_max = maxf(f40_yaw_max, f40_yaw)
			var f40_leg: float = fp40_legacy_yaw(main.shoe.global_position)
			f40_leg_min = minf(f40_leg_min, f40_leg)
			f40_leg_max = maxf(f40_leg_max, f40_leg)
			if main.pitcam_gate_progress >= 0.85 \
					and main.insert_cam.is_position_in_frustum(
						main.shoe.global_position):
				f40_framed = true
		var f40_down: float = 0.0
		while String(main.shoe_status[main.shoe]) != "DOWN" \
				and f40_down < 15.0:
			await create_timer(0.2).timeout
			f40_down += 0.2
		check(f40_engaged,
			"FP40 (%s): the follow engaged once the shoe was well on its way (gate at %.2f of the run)"
			% [f40_kind_s, main.PITCAM_GATE_FRACTION])
		check(f40_pre_frames >= 20,
			"FP40 (%s): the gate had a real pre-gate phase to hold through (%d frames before engagement - a gate left latched by the shoe's last flight would show 0)"
			% [f40_kind_s, f40_pre_frames])
		check(f40_pre_max <= 1.0,
			"FP40 (%s): before the gate the camera HELD the pit (worst yaw drift %.2f deg of 1.0 allowed)"
			% [f40_kind_s, f40_pre_max])
		var f40_exc: float = f40_yaw_max - f40_yaw_min
		var f40_bound: float = 8.0 if f40_kind_s == "line" else 20.0
		check(f40_exc <= f40_bound,
			"FP40 (%s): the flight's yaw excursion stayed in its arc (%.2f deg of %.0f allowed; FP39's follow asked %.2f on the same flight)"
			% [f40_kind_s, f40_exc, f40_bound, f40_leg_max - f40_leg_min])
		check(f40_framed,
			"FP40 (%s): after the gate the shoe is in the frame for the arrival"
			% f40_kind_s)

	# ============ Fix Pass 41: MULTI-CAM SMART CUTS ============
	# Chris: "there could be multiple cams that it smart
	# cuts, depending. a cam right behind the pin, for
	# example." Three fixed cameras, one director: MAIN
	# holds until FP40's gate; at the gate the landing is
	# projected - on line cuts to PIN for the arrival,
	# wide stays on MAIN; a skid or a leaner cuts to SIDE
	# at the settle; the ringer replay runs the same
	# director over its recording. Asserted on the ACTIVE
	# CAMERA (main.pitcam_shot, the director's word, plus
	# the camera nodes' own current flags) through
	# scripted production throws in practice.
	# (a) ON LINE: the straight drive projects at the
	# stake - MAIN before the gate, PIN for the arrival.
	var f41_home: float = 0.0
	while f41_home < 25.0:
		if String(main.state) == "STAND" and main.pitcam_lie_left <= 0.0:
			break
		await create_timer(0.25).timeout
		f41_home += 0.25
	check(await fp40_release("line"),
		"FP41 (line): the scripted drive flies")
	var f41a_pin_early: bool = false
	var f41a_saw_pin: bool = false
	var f41a_pin_current: bool = false
	var f41a_last_fly: String = "MAIN"
	var f41a_guard: float = 0.0
	while String(main.state) == "FLYING" and f41a_guard < 20.0:
		await physics_frame
		f41a_guard += 1.0 / 60.0
		if not main.pitcam_gate_engaged:
			if main.pitcam_shot != "MAIN":
				f41a_pin_early = true
		elif main.pitcam_shot == "PIN":
			f41a_saw_pin = true
			if main.pin_cam.current and not main.insert_cam.current:
				f41a_pin_current = true
		f41a_last_fly = main.pitcam_shot
	check(not f41a_pin_early,
		"FP41 (line): no cut before the gate - MAIN holds the pit through the release")
	check(f41a_saw_pin and f41a_last_fly == "PIN",
		"FP41 (line): the director cut to the PIN cam for the on-line arrival (last flight shot %s)" % f41a_last_fly)
	check(f41a_pin_current,
		"FP41 (line): the pin camera node is the viewport's live camera during the arrival")
	var f41a_set: float = 0.0
	while String(main.state) == "FLYING" and f41a_set < 15.0:
		await create_timer(0.2).timeout
		f41a_set += 0.2
	check(main.dir_last_online,
		"FP41 (line): the gate projection called the drive ON LINE")
	# (b) WIDE: the hard pull projects 3 m left of the
	# pit - the director never leaves MAIN.
	var f41b_home: float = 0.0
	while f41b_home < 25.0:
		if String(main.state) == "STAND" and main.pitcam_lie_left <= 0.0:
			break
		await create_timer(0.25).timeout
		f41b_home += 0.25
	check(await fp40_release("pull"),
		"FP41 (pull): the scripted pull flies")
	var f41b_left_main: bool = false
	var f41b_guard: float = 0.0
	while String(main.state) == "FLYING" and f41b_guard < 20.0:
		await physics_frame
		f41b_guard += 1.0 / 60.0
		if main.pitcam_shot != "MAIN":
			f41b_left_main = true
	var f41b_set: float = 0.0
	while String(main.state) == "FLYING" and f41b_set < 15.0:
		await create_timer(0.2).timeout
		f41b_set += 0.2
	check(not f41b_left_main and main.pitcam_shot == "MAIN",
		"FP41 (pull): a wide throw stays on MAIN throughout (shot %s)" % main.pitcam_shot)
	check(not main.dir_last_online,
		"FP41 (pull): the gate projection called the pull WIDE")
	# (c) THE GROUND GAME: the plowing toss skids a
	# quarter metre through the sand - SIDE at the
	# settle, held for the lie.
	var f41c_home: float = 0.0
	while f41c_home < 25.0:
		if String(main.state) == "STAND" and main.pitcam_lie_left <= 0.0:
			break
		await create_timer(0.25).timeout
		f41c_home += 0.25
	check(await fp41_release_skid(),
		"FP41 (skid): the plowing toss flies")
	var f41c_set: float = 0.0
	while String(main.state) == "FLYING" and f41c_set < 15.0:
		await create_timer(0.2).timeout
		f41c_set += 0.2
	var f41c_side: bool = false
	var f41c_poll: float = 0.0
	while f41c_poll < 3.0:
		if main.pitcam_shot == "SIDE" and main.side_cam.current:
			f41c_side = true
			break
		await create_timer(0.1).timeout
		f41c_poll += 0.1
	check(main.dir_last_skid_m >= main.DIRECTOR_SKID_M,
		"FP41 (skid): the toss plowed - %.3f m after first sand contact (threshold %.2f)"
		% [main.dir_last_skid_m, main.DIRECTOR_SKID_M])
	check(f41c_side,
		"FP41 (skid): the director cut to the SIDE cam at the settle and holds it for the lie")
	# (d) THE REPLAY CUTS TOO: a production ringer's
	# slow-mo runs the director over its recording -
	# MAIN for the flight, PIN from the recorded gate.
	main.start_game()
	check(await scripted_shot("ringer"),
		"FP41 (replay): the scripted ringer flies and settles")
	var f41d_wait: float = 0.0
	while main.replay_state != "PLAYING" and f41d_wait < 6.0:
		await create_timer(0.1).timeout
		f41d_wait += 0.1
	check(main.replay_state == "PLAYING",
		"FP41 (replay): the ringer's replay is playing")
	var f41d_first: String = main.pitcam_shot
	var f41d_saw_pin: bool = false
	var f41d_guard: float = 0.0
	while main.replay_state == "PLAYING" and f41d_guard < 20.0:
		await physics_frame
		f41d_guard += 1.0 / 60.0
		if main.pitcam_shot == "PIN":
			f41d_saw_pin = true
	check(f41d_first == "MAIN",
		"FP41 (replay): the replay opens on MAIN (got %s)" % f41d_first)
	check(f41d_saw_pin,
		"FP41 (replay): the replay cut to PIN at the recorded gate for the arrival")
	var f41d_end: float = 0.0
	while main.replay_state != "IDLE" and f41d_end < 12.0:
		await create_timer(0.2).timeout
		f41d_end += 0.2
	check(main.replay_state == "IDLE" and main.pitcam_shot == "MAIN",
		"FP41 (replay): the replay ends back on MAIN (shot %s)" % main.pitcam_shot)
	await pulse_button("B")
	check(main.mode == "PRACTICE",
		"FP41: B returns to practice for the sections below")
	# (e) RESET: after the cuts above, a fresh flight
	# starts on MAIN and holds it to the gate - the
	# director re-arms with every release.
	var f41e_home: float = 0.0
	while f41e_home < 25.0:
		if String(main.state) == "STAND" and main.pitcam_lie_left <= 0.0:
			break
		await create_timer(0.25).timeout
		f41e_home += 0.25
	check(await fp40_release("line"),
		"FP41 (reset): the follow-up drive flies")
	var f41e_early: bool = false
	var f41e_guard: float = 0.0
	while String(main.state) == "FLYING" and f41e_guard < 20.0:
		await physics_frame
		f41e_guard += 1.0 / 60.0
		if not main.pitcam_gate_engaged and main.pitcam_shot != "MAIN":
			f41e_early = true
	check(not f41e_early,
		"FP41 (reset): a new flight re-arms the director on MAIN")

	# ============ Fix Pass 13: the scoring audit ============
	# Chris played a full game: "it scored all the points, I
	# got nothing." Two live hypotheses: an owner-attribution
	# flip from FP11's restock (his shoes literally scoring
	# for the AI), or an earned shutout (points need a shoe
	# inside 6 in - his median landing is ~4 ft, the AI's mean
	# is 3.7 in). These innings settle it through the
	# production paths only - scripted releases, real flight,
	# real settle, real scoring - with the settle records
	# themselves inspected as they land. (The rack geometry
	# itself is asserted per rack in check_rack above; the
	# AI's box in check_ai_box, called at boot and after the
	# FP11 swap probe.)
	main.ai_pitcher.speed_scale = 3.0
	main.origin.global_transform = Transform3D.IDENTITY
	# (i) Player ringer vs two AI duds -> YOU +3, with the
	# settle records read mid-inning, tag by tag.
	main.start_game()
	check(main.shoe.global_position.distance_to(
		main.rack_slot_tf(40, false, 0).origin) < 0.01,
		"FP13 audit: the game stocks the active shoe on slot 0 of the turned rack")
	main.test_hand_tf["R"] = Transform3D(Basis.IDENTITY,
		main.shoe.zone_world_center("toe"))
	await frames(6)
	for i: int in 2:
		await physics_frame
	check(main.candidate_zone == "toe",
		"FP13: from the stance, a reach acquires slot 0's toe zone at the new placement (got '%s')"
		% main.candidate_zone)
	main.test_hand_tf["R"] = Transform3D.IDENTITY
	check(await scripted_shot("ringer"),
		"FP13 audit (i): the player's scripted ringer flies and settles")
	check(main.inning_results.size() == 1
		and String(main.inning_results[0]["owner"]) == "P"
		and bool(main.inning_results[0]["ringer"]),
		"FP13 audit (i): the settled ringer is recorded under the PLAYER's tag")
	check(await scripted_shot("dud"),
		"FP13 audit (i): the player's second shoe (a dud) settles")
	check(main.inning_results.size() == 2
		and String(main.inning_results[1]["owner"]) == "P",
		"FP13 audit (i): the player's dud is recorded under the PLAYER's tag too")
	check(await wait_phase("AI_TURN", 10.0),
		"FP13 audit (i): the turn passes to the AI")
	check(await scripted_ai_throw("dud"),
		"FP13 audit (i): AI dud one settles")
	check(main.inning_results.size() == 3
		and String(main.inning_results[2]["owner"]) == "AI",
		"FP13 audit (i): the AI's dud is recorded under the AI's tag")
	# Fix Pass 34 - THE REAL-PATH SCOREBOARD PROOF: pose
	# the head facing the HOUSE and pitched DOWN before the
	# last shoe settles. The old gaze spawn would have
	# planted the board behind the player, face-down in the
	# patio; the fixed board must come up at its court
	# transform regardless - and this inning drives the
	# full production flow (throws, settle, tabulation
	# beat, posting) to get it there.
	var head_home34: Transform3D = main.cam.transform
	main.cam.transform = Transform3D(Basis.IDENTITY,
		Vector3(0.0, 1.62, -0.914)).looking_at(
			Vector3(0.0, 0.2, 3.0), Vector3.UP)
	check(await scripted_ai_throw("dud"),
		"FP13 audit (i): AI dud two settles")
	check(main.phase == "TABULATE" and main.score_you == 0,
		"FP20 audit (i): the thrown inning is NOT posted yet - the round posts itself after the beat (phase %s, board %d-%d)"
		% [String(main.phase), main.score_you, main.score_opp])
	check(await wait_phase("INSERT", 10.0) and main.score_you == 3
		and main.score_opp == 0
		and main.last_inning_text == "YOU +3 (RINGER)",
		"FP13 audit (i): player ringer vs two AI duds scores YOU +3, posted by the tabulation (board %d-%d, '%s')"
		% [main.score_you, main.score_opp, main.last_inning_text])
	var bb38b: Transform3D = main.billboard_transform()
	check(main.board_breakdown_up
		and main.insert_root.global_transform.origin.distance_to(bb38b.origin) < 0.001
		and main.insert_root.global_transform.basis.is_equal_approx(bb38b.basis),
		"FP39: with the head facing the house and pitched down at the settle, the breakdown still comes up on the rear board - and the billboard stands at its fixed transform, not in the player's face")
	main.cam.transform = head_home34
	# Fix Pass 39 re-derives the old all-four-shoes framing
	# audit: the broadcast camera is a CLOSEUP now - it
	# does not promise every dud in frame (the wide ones
	# sit ~2.5 m out); it promises the settled SUBJECT -
	# the last shoe down - framed tight with the stake as
	# its reference. Assert exactly that: the subject is
	# the camera's lie subject, it sits inside the
	# closeup's view, and the lens is at the lie fov.
	check(main.pitcam_lie_left > 0.0
		and main.insert_cam.is_position_in_frustum(main.pitcam_subject_pos),
		"FP39 audit (i): the broadcast camera's lie closeup frames the last settled shoe's lie")
	check(absf(main.insert_cam.fov - main.PITCAM_LIE_FOV) < 4.0,
		"FP39 audit (i): the camera holds the lie closeup's fov (%.1f, lie %.1f)"
		% [main.insert_cam.fov, main.PITCAM_LIE_FOV])
	# (ii) Player point shoe only -> YOU +1.
	main.start_game()
	check(await play_scripted_inning(["point", "dud"], ["dud", "dud"]),
		"FP13 audit (ii): the scripted inning plays out")
	check(await wait_phase("INSERT", 10.0) and main.score_you == 1
		and main.score_opp == 0
		and main.last_inning_text == "YOU +1",
		"FP13 audit (ii): a lone player point shoe scores YOU +1, posted by the tabulation (board %d-%d, '%s')"
		% [main.score_you, main.score_opp, main.last_inning_text])
	# (iv) Cross-check the other direction: an AI ringer
	# through the production swing path stands against the
	# player's point shoe - the AI's shoe credits the AI, and
	# the player's close shoe leaks nothing.
	main.start_game()
	check(await play_scripted_inning(["point", "dud"], ["ringer", "dud"]),
		"FP13 audit (iv): the cross-check inning plays out")
	check(await wait_phase("INSERT", 10.0) and main.score_you == 0
		and main.score_opp == 3
		and main.last_inning_text == "OPP +3 (OPP RINGER)",
		"FP13 audit (iv): AI ringer vs player point shoe scores OPP +3, player shut out, posted by the tabulation (board %d-%d, '%s')"
		% [main.score_you, main.score_opp, main.last_inning_text])
	# (iii) A scripted full game the PLAYER wins, hand-tracked:
	# ringer + dud vs dud + dud every inning = YOU +3 a round,
	# seven innings = 21-0, every inning posted by its own
	# tabulation and continued with A - a full game played
	# with NO walking at all (Fix Pass 20's rhythm; the
	# brief's no-walk full-game proof).
	main.start_game()
	var expect_you: int = 0
	var innings_ok: bool = true
	while main.phase != "OVER" and expect_you < 21:
		if not await play_scripted_inning(["ringer", "dud"], ["dud", "dud"]):
			innings_ok = false
			break
		expect_you += 3
		var waited_iii: float = 0.0
		while String(main.phase) != "INSERT" and String(main.phase) != "OVER" \
				and waited_iii < 10.0:
			await create_timer(0.2).timeout
			waited_iii += 0.2
		if String(main.phase) != "INSERT" and String(main.phase) != "OVER":
			innings_ok = false
			break
		if main.score_you != expect_you or main.score_opp != 0:
			innings_ok = false
			break
		if String(main.phase) == "OVER":
			break
		await pulse_button("A")
		if not await wait_phase("P_TURN", 10.0):
			innings_ok = false
			break
	check(innings_ok and main.phase == "OVER",
		"FP13 audit (iii): every scripted inning lands its hand-tracked +3 (final phase %s, inning %d)"
		% [String(main.phase), main.inning])
	check(main.score_you == 21 and main.score_opp == 0
		and main.winner_text == "YOU WIN!"
		and main.score_label.text.contains("YOU 21 - 0 OPP"),
		"FP13 audit (iii): the scripted full game ends YOU 21 - 0 OPP and the player wins ('%s')"
		% main.winner_text)
	main.ai_pitcher.speed_scale = 1.0

	# ============ Fix Pass 15: the tilt ============
	# Chris, in BOTH game sessions (the FP12-era game and the
	# FP14 session): "at some point, the entire view of the
	# game world slants downward like 10 degrees, total
	# vertigo inducer." The guilty path was the B-swap seat:
	# it multiplied by the inverse of the head's full local
	# rotation, so a head held pitched down at the pit when B
	# was tapped wrote its pitch into the origin's basis -
	# where it stayed, invisible at the seat instant itself
	# (the camera still read level), and slanting the whole
	# world the moment he straightened up. Pre-fix harness
	# reproduction through this very production path (head
	# pitched 12 deg at the tap): origin tilt 12.27 deg after
	# the swap; camera world tilt 12.26 deg once the head
	# straightened. The old FP12 smoke never saw it because
	# its head was never pitched.
	#
	# (0) NEGATIVE CONTROL, scene level: the old seat formula,
	# computed here from the same pitched head pose the
	# production seat is about to get, tilts by the head's
	# pitch - so this harness can see the fault class.
	pitch_head(12.0)
	var legacy_seat: Transform3D = Transform3D(Basis(Vector3.UP, PI),
		Vector3(0.05, 1.62, -0.55)) * main.cam.transform.inverse()
	check(tilt_of(legacy_seat.basis) > 11.0,
		"FP15 NC: the pre-FP15 seat formula tilts the origin by the head's pitch (%.2f deg)"
		% tilt_of(legacy_seat.basis))
	# (a) Turns at a held head pitch: the turn reads only the
	# camera's POSITION, never its orientation - the origin
	# cannot pitch, and the turn still turns at its rate.
	var yaw15a: float = atan2(main.origin.global_transform.basis.z.x,
		main.origin.global_transform.basis.z.z)
	main.test_stick["R"] = Vector2(1.0, 0.0)
	await create_timer(1.2).timeout
	main.test_stick["R"] = Vector2.ZERO
	await frames(3)
	check_origin_level("FP15: 1.2 s of full-stick turns with the head pitched 12 deg leaves the origin level")
	var yaw15b: float = atan2(main.origin.global_transform.basis.z.x,
		main.origin.global_transform.basis.z.z)
	check(absf(wrapf(yaw15b - yaw15a, -PI, PI)) > 0.5,
		"FP15: the turns still turned with the head pitched (%.2f rad)"
		% wrapf(yaw15b - yaw15a, -PI, PI))
	# (b) THE GUILTY PATH IS GONE (Fix Pass 19): the B-swap
	# seat was deleted with the two-pit game - nothing seats
	# the player anywhere any more, so no path can write a
	# pitched head into the origin. What B does now, with the
	# head pitched 12 deg at the tap: it just leaves the game.
	# (The seat's own checks retire with it; the guard (c) and
	# the walked cycle (d) carry the FP15 surface now.)
	manufacture_round()
	pitch_head(12.0)
	check(main.phase == "TABULATE", "FP20: the tabulation beat is running")
	await pulse_button("B")
	check(main.mode == "PRACTICE",
		"FP20: B with the head pitched just leaves the game - no seat exists to tilt")
	check_origin_level("FP20: B leaves a LEVEL origin, head pitched 12 deg")
	# (c) The guard: a tilt arriving by ANY path is stripped
	# within a physics frame and the repair counted; with the
	# guard off the same tilt PERSISTS (the negative control
	# that the guard is the stripper).
	var repairs0: int = main.origin_tilt_repairs
	var cur_yaw15: float = atan2(main.origin.global_transform.basis.z.x,
		main.origin.global_transform.basis.z.z)
	main.origin.global_transform = Transform3D(
		Basis.from_euler(Vector3(deg_to_rad(-9.0), cur_yaw15, deg_to_rad(1.5))),
		main.origin.global_position)
	await physics_frame
	await physics_frame
	check(tilt_of(main.origin.global_transform.basis) < 0.005
		and main.origin_tilt_repairs > repairs0,
		"FP15: the guard strips a foreign tilt within a frame and counts it (%d repairs)"
		% main.origin_tilt_repairs)
	main.tilt_guard_enabled = false
	main.origin.global_transform = Transform3D(
		Basis.from_euler(Vector3(deg_to_rad(-9.0), cur_yaw15, deg_to_rad(1.5))),
		main.origin.global_position)
	await physics_frame
	await physics_frame
	await physics_frame
	check(tilt_of(main.origin.global_transform.basis) > 5.0,
		"FP15 NC: with the guard off, a foreign tilt PERSISTS (%.2f deg)"
		% tilt_of(main.origin.global_transform.basis))
	main.tilt_guard_enabled = true
	await physics_frame
	await physics_frame
	check_origin_level("FP15: the guard heals it again when re-enabled")
	# (d) THE FP20 SEAT under a pitched head: the round posts
	# itself with the head pitched 13 deg; the player strolls
	# past the line during the insert (the walk reads only
	# the head's flat direction - pitch cannot tilt it), and
	# the A-continue seats him back behind the line with the
	# pitch still held. The seat writes yaw only, so the
	# origin stays level throughout - the FP15 surface in
	# FP20's shape.
	await wait_ai_quiet()
	manufacture_round()
	pitch_head(13.0)
	check(await wait_phase("INSERT", 10.0),
		"FP15/20: the round posts to the insert with the head pitched 13 deg")
	await walk_forward_for(2.5)
	check(main.origin.global_position.z < main.game_line_z() - 0.90,
		"FP15/20: the pitched-head stroll crosses the line freely during the insert (z %.2f)"
		% main.origin.global_position.z)
	check_origin_level("FP15/20: the stroll under a pitched head leaves the origin level")
	await pulse_button("A")
	check(main.phase == "AI_TURN"
		and main.cam.global_position.z > main.game_line_z(),
		"FP15/20: the A-continue seats the pitched-head player back behind the line")
	check_origin_level("FP15/20: the seat-back leaves the origin level, head pitched 13 deg")
	# (e) A FULL GAME with the head pitched 12 deg through
	# every round (the FP13 audit game's shape): level after
	# every operation and at game end. (Fix Pass 20: the walk
	# cycles are gone; the operations under a pitched head
	# are now the throws, the tabulation, the insert, and
	# the A-continue.)
	await wait_ai_quiet()
	main.origin.global_transform = Transform3D.IDENTITY
	pitch_head(12.0)
	main.start_game()
	var tilt_ok15: bool = true
	var guard15: int = 0
	while main.phase != "OVER" and guard15 < 10:
		guard15 += 1
		if not await play_scripted_inning(["ringer", "dud"], ["dud", "dud"]):
			tilt_ok15 = false
			break
		if tilt_of(main.origin.global_transform.basis) >= 0.005:
			tilt_ok15 = false
		var waited15: float = 0.0
		while String(main.phase) != "INSERT" and String(main.phase) != "OVER" \
				and waited15 < 10.0:
			await create_timer(0.2).timeout
			waited15 += 0.2
		if String(main.phase) != "INSERT" and String(main.phase) != "OVER":
			tilt_ok15 = false
			break
		if tilt_of(main.origin.global_transform.basis) >= 0.005:
			tilt_ok15 = false
		if String(main.phase) == "INSERT":
			await pulse_button("A")
			if not await wait_phase("P_TURN", 10.0):
				tilt_ok15 = false
				break
			if tilt_of(main.origin.global_transform.basis) >= 0.005:
				tilt_ok15 = false
	check(tilt_ok15 and main.phase == "OVER" and main.score_you == 21,
		"FP15/20: a full game, head pitched 12 deg through every round, stays level and ends 21-0")
	check_origin_level("FP15/20: origin level at game end")
	main.cam.transform = Transform3D.IDENTITY

	# ============ Backyard Game v1 / Fix Pass 20: a full game ============
	# Scripted player throws (production input path) + the AI's
	# own turns drive a complete game to a winner, ONE-WAY and
	# SETTLE-POSTED: every inning is thrown from the pitching
	# end, posts itself after the settle beat, and the next
	# inning starts on A at the insert. The player never
	# walks. He starts where a fresh game starts - standing
	# at the pitching end.
	main.origin.global_transform = Transform3D.IDENTITY
	main.start_game()
	var guard_innings: int = 0
	while main.phase != "OVER" and guard_innings < 40:
		guard_innings += 1
		var inning_no: int = main.inning
		var turn_guard: int = 0
		while main.phase != "TABULATE" and main.phase != "INSERT" \
				and main.phase != "OVER" and turn_guard < 6:
			turn_guard += 1
			if main.phase == "P_TURN":
				check(await scripted_game_throw(),
					"game: player throw flies and settles (inning %d)" % inning_no)
			elif main.phase == "AI_TURN":
				var waited_ai: float = 0.0
				while main.phase == "AI_TURN" and waited_ai < 40.0:
					await create_timer(0.5).timeout
					waited_ai += 0.5
				check(main.phase != "AI_TURN",
					"game: the AI's turn completes (inning %d)" % inning_no)
			else:
				break
		check(main.phase == "TABULATE" or main.phase == "INSERT"
			or main.phase == "OVER",
			"game: inning %d is thrown" % inning_no)
		if main.phase == "TABULATE" or main.phase == "INSERT":
			var waited_g: float = 0.0
			while String(main.phase) != "INSERT" and String(main.phase) != "OVER" \
					and waited_g < 10.0:
				await create_timer(0.2).timeout
				waited_g += 0.2
			check(main.phase == "INSERT" or main.phase == "OVER",
				"game: inning %d posts itself - no walk down, no walk back" % inning_no)
		if main.phase == "INSERT":
			await pulse_button("A")
			check(main.phase == "P_TURN" or main.phase == "AI_TURN",
				"game: A at the insert starts inning %d" % (inning_no + 1))
		check(main.phase != "TABULATE" and main.phase != "INSERT",
			"game: inning %d completes its settle-posted cycle" % inning_no)
	check(main.phase == "OVER",
		"game: a full game reaches a winner (final %d-%d in %d innings)"
		% [main.score_you, main.score_opp, main.inning])
	check(maxi(main.score_you, main.score_opp) >= 21,
		"game: the winner reached 21 or more")
	main.test_button["B"] = true
	await frames(4)
	main.test_button["B"] = false
	await frames(4)
	check(main.mode == "PRACTICE", "game: B at game over returns to practice")
	check(main.status_label.text.contains("THROWS:"),
		"game: the practice board readouts are back")
	check(main.state == "STAND"
		and main.shoe.global_position.distance_to(
			main.rack_slot_tf(main.active_stand_line_ft,
				false, main._pair_index_of(main.shoe)).origin) < 0.01,
		"game: practice after the game stocks the shoe on the rail as before")

	# ============ The hands pass: BASIC hands on the grip analog ============
	# The controller rep is a hand now, and its pose is the
	# grip analog made visible: open at rest, closing through
	# the squeeze, shut on the held shoe, opening again
	# through the un-squeeze that fires the release - Chris's
	# law of his own throwing ("the release is an
	# un-squeeze"). Driven through the production paths: the
	# test transports feed the same _grip_value / _hand_tf
	# the grab logic reads, and the wrap is asserted in hand
	# space, where Shoe.hold_transform seats every zone's
	# centre at the one grip anchor.
	var rep_r: Node3D = main.ctrl_rep["R"]
	var rep_l: Node3D = main.ctrl_rep["L"]
	check(rep_r.find_children("*", "Label3D", true, false).is_empty()
		and rep_l.find_children("*", "Label3D", true, false).is_empty(),
		"hands: the billboard L/R tags retired with the blocks")
	var joints_r: Dictionary = main.hand_joints["R"]
	var joints_l: Dictionary = main.hand_joints["L"]
	var fingers_r: Array = joints_r["fingers"]
	var fingers_l: Array = joints_l["fingers"]
	var mid_chain_r: Array = fingers_r[1]
	check(absf((fingers_r[0][0] as Node3D).position.x + 0.030) < 0.001
		and absf((fingers_l[0][0] as Node3D).position.x - 0.030) < 0.001,
		"hands: mirrored pair - the R index knuckle sits thumb-side at -X, the L at +X")
	# The analog alone, no grab: rest open, half squeeze half shut.
	main.test_grip["R"] = 0.0
	await frames(3)
	check(float(main.hand_curl_t["R"]) < 0.02
		and absf((mid_chain_r[0] as Node3D).rotation.x - deg_to_rad(-6.0)) < 0.01,
		"hands: at rest the hand stands OPEN (proximal at the open table's -6 deg)")
	main.test_grip["R"] = 0.5
	await frames(3)
	var t_mid: float = float(main.hand_curl_t["R"])
	check(t_mid > 0.4 and t_mid < 0.9,
		"hands: a half squeeze half closes the hand (blend %.2f)" % t_mid)
	# A production grab at the toe, through the test transport.
	for i: int in 120:
		await physics_frame
		if String(main.state) == "STAND":
			var home_tf2: Transform3D = main.stand_tfs[int(main.active_stand_line_ft)]
			if main.shoe.global_position.distance_to(home_tf2.origin) < 0.01:
				break
	main.origin.global_transform = Transform3D(Basis.IDENTITY,
		Vector3(0.0, 0.0, main.line_z_for_ft(int(main.active_stand_line_ft))))
	main.test_hand_tf["R"] = Transform3D(Basis.IDENTITY, main.shoe.zone_world_center("toe"))
	main.test_grip["R"] = 1.0
	await frames(6)
	check(main.state == "HELD" and main.held_zone == "toe",
		"hands: the production grab holds the shoe at the TOE grip")
	check(float(main.hand_curl_t["R"]) > 0.95,
		"hands: the hand is shut on the held shoe (blend %.2f)" % float(main.hand_curl_t["R"]))
	var rep_inv: Transform3D = rep_r.global_transform.affine_inverse()
	var anchor := Vector3(0.0, -0.018, 0.0)
	var bar_toe: Vector3 = main.test_hand_tf["R"].affine_inverse() * main.shoe.zone_world_center("toe")
	check(bar_toe.distance_to(anchor) < 0.002,
		"hands: the toe bar sits at the grip anchor in hand space")
	var mid_piv: Vector3 = rep_inv * (mid_chain_r[1] as Node3D).global_position
	var dist_piv: Vector3 = rep_inv * (mid_chain_r[2] as Node3D).global_position
	check(mid_piv.distance_to(bar_toe) < 0.032 and dist_piv.distance_to(bar_toe) < 0.032
		and dist_piv.y < bar_toe.y,
		"hands: the middle finger WRAPS the toe bar (mid joint %.1f mm, tip joint %.1f mm from the bar centre, tip joint under it)"
		% [mid_piv.distance_to(bar_toe) * 1000.0, dist_piv.distance_to(bar_toe) * 1000.0])
	# Cycle to the shank: the same closed hand must wrap the
	# shank bar at the same anchor.
	await pulse_button("A")
	check(main.held_zone == "shank_right",
		"hands: the grip cycles to the home shank (got '%s')" % main.held_zone)
	# The reference is the bar point the seat puts AT the
	# anchor: hold_transform seats the zone centre SHIFTED by
	# the stop's slide offset (the shank stops ride the slide
	# axis, Fix Pass 21), so at SHANK·TOE the zone's nominal
	# centre sits one slide offset (45 mm) down the bar from
	# the fingers. Measuring the joints against the nominal
	# centre failed this check deterministically (probe,
	# FP43 fix: bar-to-anchor 45.0 mm immediate AND after a
	# 30-frame settle - no race; the joints sit 25.0/28.7 mm
	# from the anchor itself, identical to the toe). The
	# standard is unchanged: the seated bar point within
	# 2 mm of the anchor, both joints within 32 mm of it,
	# tip joint under it.
	var z_shank: Dictionary = Shoe.zones()["shank_right"]
	var slid_centre: Vector3 = Vector3(z_shank["center"]) \
		+ Vector3(z_shank["slide_axis"]) * main.slide_offset
	var bar_shank: Vector3 = main.test_hand_tf["R"].affine_inverse() \
		* (main.shoe.global_transform * slid_centre)
	var mid_piv2: Vector3 = rep_inv * (mid_chain_r[1] as Node3D).global_position
	var dist_piv2: Vector3 = rep_inv * (mid_chain_r[2] as Node3D).global_position
	check(bar_shank.distance_to(anchor) < 0.002
		and mid_piv2.distance_to(bar_shank) < 0.032 and dist_piv2.distance_to(bar_shank) < 0.032
		and dist_piv2.y < bar_shank.y,
		"hands: the same closed hand WRAPS the shank bar at the anchor (mid joint %.1f mm, tip joint %.1f mm from the bar centre, tip joint under it)"
		% [mid_piv2.distance_to(bar_shank) * 1000.0, dist_piv2.distance_to(bar_shank) * 1000.0])
	# The un-squeeze shows BEFORE the release fires, then the
	# release fires and the hand rests open.
	main.test_grip["R"] = 0.45
	await frames(3)
	var t_open: float = float(main.hand_curl_t["R"])
	check(main.state == "HELD" and t_open > 0.15 and t_open < 0.65,
		"hands: the un-squeeze opens the hand while the shoe is still held (blend %.2f)" % t_open)
	main.test_grip["R"] = 0.0
	await frames(6)
	check(main.state != "HELD", "hands: the release fires as the grip lets go")
	check(float(main.hand_curl_t["R"]) < 0.02,
		"hands: the hand rests open after the release")

	# ============ Fix Pass 44: PROXIMITY scoring mode ============
	# The second scoring mode, designed 2026-11-07 and pulled
	# forward 2026-11-13 (Chris: "real horseshoe scoring with
	# fake horseshoe physics" is the mismatch - the loosened
	# throw needs the scoring that pays by distance). Probes:
	# the board and controls name the mode and its switch;
	# X alone in practice (empty hand) toggles, and ONLY that;
	# a game played in PROXIMITY end to end on staged results;
	# the mode persists across a restart. CLASSIC's own probes
	# all ran earlier in this suite, on the untouched path.
	check(await wait_state("STAND", 12.0),
		"FP44: the yard is at rest before the mode probes")
	if main.mode != "PRACTICE":
		main._enter_practice()
		await frames(4)
	check(main.scoring_mode == "CLASSIC"
		and main.status_label.text.contains("SCORING: CLASSIC"),
		"FP44: a first run is CLASSIC and the board's status block names it")
	check(main.controls_full_text().contains(
		"X BUTTON (EMPTY HAND) IN PRACTICE: CHANGE SCORING MODE"),
		"FP44: the controls list names the X scoring toggle")
	# X alone in practice, empty hand: the toggle.
	await pulse_hand_button("L", "A")
	check(main.scoring_mode == "PROXIMITY"
		and main.status_label.text.contains("SCORING: PROXIMITY"),
		"FP44: X in practice (empty hand) switches to PROXIMITY and the board names it")
	var set_f44: FileAccess = FileAccess.open(set_path, FileAccess.READ)
	var set_p44: Variant = JSON.parse_string(set_f44.get_as_text()) \
		if set_f44 != null else null
	check(set_p44 is Dictionary
		and String(set_p44.get("scoring_mode", "")) == "PROXIMITY",
		"FP44: PROXIMITY is persisted to the settings file")
	await pulse_hand_button("L", "A")
	check(main.scoring_mode == "CLASSIC",
		"FP44: X again switches back to CLASSIC")
	await pulse_hand_button("L", "A")
	check(main.scoring_mode == "PROXIMITY",
		"FP44: and X once more returns to PROXIMITY for the game probes")
	# The merged game A is intact: A (both channels read it)
	# starts the game, in the selected mode, without toggling.
	await pulse_button("A")
	check(main.mode == "GAME" and main.scoring_mode == "PROXIMITY",
		"FP44: A still starts the game, in the selected mode")
	# Both sides across 21 in one inning: the higher total wins.
	main.score_you = 18
	main.score_opp = 17
	main.inning_results = [
		{"owner": "P", "dist_in": 0.0, "ringer": true},
		{"owner": "P", "dist_in": 30.0, "ringer": false},
		{"owner": "AI", "dist_in": 10.0, "ringer": false},
		{"owner": "AI", "dist_in": 50.0, "ringer": false}]
	main._score_inning()
	check(main.score_you == 23 and main.score_opp == 20
		and main.phase == "OVER" and main.winner_text == "YOU WIN!",
		"FP44 game: both across 21, the higher total wins (got %d-%d, %s)"
		% [main.score_you, main.score_opp, main.phase])
	var rl44: String = "\n".join(PackedStringArray(main.round_lines))
	check(rl44.contains("SCORING: PROXIMITY")
		and rl44.contains("YOU 1: 0.0 IN = 4 PTS")
		and rl44.contains("YOU 2: 30.0 IN = 1 PTS")
		and rl44.contains("OPP 1: 10.0 IN = 3 PTS")
		and rl44.contains("OPP 2: 50.0 IN = 0 PTS")
		and rl44.contains("ROUND: YOU +5 - OPP +3")
		and rl44.contains("MATCH: YOU 23 - 20 OPP"),
		"FP44 game: the breakdown shows every shoe's distance and band points for both sides (%s)" % rl44)
	# Both across 21 LEVEL: another inning, and the tied
	# inning keeps the first-throw order.
	main.start_game()
	main.score_you = 20
	main.score_opp = 20
	main.inning_results = [
		{"owner": "P", "dist_in": 4.0, "ringer": false},
		{"owner": "AI", "dist_in": 4.0, "ringer": false}]
	main._score_inning()
	check(main.score_you == 24 and main.score_opp == 24
		and main.phase == "INSERT",
		"FP44 game: level totals across 21 play another inning (got %d-%d, %s)"
		% [main.score_you, main.score_opp, main.phase])
	main._finish_inning_cycle()
	check(main.inning == 2 and main.inning_first == "P",
		"FP44 game: a tied inning keeps the first-throw order (first %s)"
		% main.inning_first)
	# A decisive inning: the side that scored more throws
	# first next.
	main.start_game()
	main.inning_results = [
		{"owner": "P", "dist_in": 30.0, "ringer": false},
		{"owner": "P", "dist_in": 40.0, "ringer": false},
		{"owner": "AI", "dist_in": 4.0, "ringer": false},
		{"owner": "AI", "dist_in": 90.0, "ringer": false}]
	main._score_inning()
	check(main.phase == "INSERT" and main.last_scorer == "AI",
		"FP44 game: the AI outscored the inning 4-2 (scorer %s)" % main.last_scorer)
	main._finish_inning_cycle()
	check(main.inning_first == "AI",
		"FP44 game: the side that scored more throws first next (first %s)"
		% main.inning_first)
	# The toggle guard: X while HOLDING cycles the grip and
	# does NOT touch the mode.
	main._enter_practice()
	check(await wait_state("STAND", 12.0),
		"FP44: back at rest in practice for the guard probe")
	var toe_c44: Vector3 = main.shoe.zone_world_center("toe")
	main.test_hand_tf["R"] = Transform3D(Basis.IDENTITY, toe_c44)
	main.test_grip["R"] = 1.0
	await frames(6)
	check(main.state == "HELD" and main.held_zone == "toe",
		"FP44: the near grab latches for the toggle guard probe")
	await pulse_hand_button("L", "A")
	check(main.held_zone == "shank_right"
		and main.scoring_mode == "PROXIMITY",
		"FP44: X while holding cycles the grip and does NOT toggle (zone %s, mode %s)"
		% [main.held_zone, main.scoring_mode])
	check(await drop_and_restock(main, "R"),
		"FP44: the guard-probe shoe drops and restocks")
	main.test_hand_tf.erase("R")
	# Persistence round trip: a fresh instance boots in the
	# stored mode, board naming it.
	var rec44: String = "user://smoke44_throws.jsonl"
	if FileAccess.file_exists(rec44):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(rec44))
	var m44: Node = spawn_fresh_main(rec44, set_path)
	await create_timer(0.3).timeout
	check(m44.scoring_mode == "PROXIMITY"
		and m44.status_label.text.contains("SCORING: PROXIMITY"),
		"FP44: a restart boots in the stored mode and its board names it (mode %s)"
		% m44.scoring_mode)
	root.remove_child(m44)
	m44.free()
	await frames(3)
	# Leave the yard as the run found it: CLASSIC, persisted.
	main.set_scoring_mode("CLASSIC")
	check(main.scoring_mode == "CLASSIC",
		"FP44: the mode is restored to CLASSIC")

	main.origin.global_transform = Transform3D.IDENTITY
	DirAccess.remove_absolute(ProjectSettings.globalize_path(rec_path))

	print("---")
	if failures == 0:
		print("SMOKE: ALL %d CHECKS PASSED" % checks)
	else:
		print("SMOKE: %d of %d CHECKS FAILED" % [failures, checks])
	quit(1 if failures > 0 else 0)
