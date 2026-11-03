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
## sightline segment (40 ft foul line spot -> board centre, XZ).
func sightline_dist(p: Vector3) -> float:
	var a := Vector2(0.0, 0.0)
	var b := Vector2(main.BOARD_POS.x, main.BOARD_POS.z)
	var q := Vector2(p.x, p.z)
	var ab: Vector2 = b - a
	var t: float = clampf((q - a).dot(ab) / ab.length_squared(), 0.0, 1.0)
	return (a + ab * t).distance_to(q)


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
	main._release_shoe(samples)
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
	var travel: float = -1.0 if main.target_far else 1.0
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
	main._release_shoe(main.samples)
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


func _run() -> void:
	var rec_path: String = "user://smoke_throws.jsonl"
	if FileAccess.file_exists(rec_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(rec_path))
	var ps: PackedScene = load("res://main.tscn")
	main = ps.instantiate()
	main.recorder_path = rec_path
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
	check(main.status_label != null and main.controls_label != null, "board labels exist")
	check(main.controls_label.text.contains("GRAB") and main.controls_label.text.contains("THROW")
		and main.controls_label.text.contains("SLIDE") and main.controls_label.text.contains("RECENTER"),
		"board lists every control (grab/slide/throw/recenter)")
	check(main.controls_label.text.contains("Left stick: move")
		and main.controls_label.text.contains("Right stick: turn"),
		"board lists the pass-6 standard stick controls (left moves, right turns)")
	check(main.controls_label.text.contains("30 FT LINE"),
		"board notes the 30 ft short line (pass 3)")
	check(main.controls_label.text.contains("A BUTTON")
		and main.controls_label.text.contains("B BUTTON"),
		"board lists the game buttons (A start/play again, B swap/practice) - standing rule: every accepted command is listed")
	check(main.status_label.text.contains("THROWS: 0"), "board starts at zero throws")

	# --- Backyard Game v1: full court, pairs, the opponent ---
	check(main.stakes.size() == 2, "two stakes built, one per end (%d)" % main.stakes.size())
	var sp_far: Vector3 = main.stakes["FAR"]["pos"]
	var sp_home: Vector3 = main.stakes["HOME"]["pos"]
	check(absf(sp_far.distance_to(sp_home) - 12.192) < 0.001,
		"the two stakes stand exactly 12.192 m apart (%.3f)" % sp_far.distance_to(sp_home))
	check(absf(main.line_z_for_ft_at(40, true)) < 0.001
		and absf(main.line_z_for_ft_at(30, true) + 3.048) < 0.001
		and absf(main.line_z_for_ft_at(40, false) + 12.192) < 0.001
		and absf(main.line_z_for_ft_at(30, false) + 9.144) < 0.001,
		"foul lines mirror at both ends (0 / -3.048 / -9.144 / -12.192)")
	check(main.player_pair.size() == 2 and main.ai_pair.size() == 2,
		"two pairs of shoes: the player's and the AI's")
	for s: Shoe in main._all_shoes():
		var want_slot: Transform3D = main.slot_tf(true, 40, main._slot_of(s))
		check(s.global_position.distance_to(want_slot.origin) < 0.01,
			"shoe hangs on its rail slot at boot (slot %d)" % main._slot_of(s))
		check(String(main.shoe_status[s]) == "RAILED", "boot shoe is stocked (RAILED)")
	check(main.player_pair[0].tint == main.PLAYER_PAIR_COLOR
		and main.ai_pair[0].tint == main.AI_PAIR_COLOR,
		"pairs wear their colours: yellow player, blue AI")
	var slot0_pos: Vector3 = main.slot_tf(true, 40, 0).origin
	var rail_pieces: int = 0
	for child: Node in main.get_children():
		if child is MeshInstance3D and (child as MeshInstance3D).global_position.distance_to(slot0_pos) < 1.0:
			rail_pieces += 1
	check(rail_pieces >= 4,
		"rail stand furniture (posts, rail, shelf) stands at the home 40 ft stock point (%d pieces)" % rail_pieces)
	check(main.ai_pitcher != null and main.ai_pitcher.is_inside_tree(),
		"the AI opponent character stands at the home end")

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
	# Every label's rendered text block must fit ON the slab
	# (font metrics, not eyeballs): this is the standing guard
	# that no line can silently outgrow the board again.
	var fb_font: Font = ThemeDB.fallback_font
	for lbl: Label3D in [main.title_label, main.status_label, main.controls_label]:
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
		check(w_max <= main.board_slab_size.x - 0.08 and h_tot <= main.board_slab_size.y - 0.08,
			"board label '%s...' fits the slab (%.2f x %.2f m on %.1f x %.1f)"
			% [text_lines[0], w_max, h_tot, main.board_slab_size.x, main.board_slab_size.y])
	# The boot text never exercises the widest line the board can
	# show - measure the worst-case status blocks with the label's
	# own font. Backyard Game v1 re-derived them: the status font
	# stepped down (58 / 0.0029) because a game status runs to
	# SEVEN lines where practice ran to six, and the longest
	# honest lines grew ("LAST INNING: ... (RINGER)",
	# "B: SWAP ENDS - OR WALK THERE"). Both modes are measured.
	var worst_cases: Array = [
		"THROWS: 999\nHOLD: TURN (SHANK_RIGHT)\nLAST: 123.4 IN\nFLIP: -1.24 REV\nTURN: -1.24 REV\nRINGER!\nA: START GAME",
		"YOU 99 - 99 OPP\nINNING 99 - YOUR THROW 2 OF 2\nLAST: 123.4 IN\nFLIP: -1.24 REV\nTURN: -1.24 REV\nLAST INNING: YOU +6 (RINGER)\nB: SWAP ENDS - OR WALK THERE",
	]
	for worst: String in worst_cases:
		var w_lines: PackedStringArray = worst.split("\n")
		var w_worst: float = 0.0
		for ln2: String in w_lines:
			w_worst = maxf(w_worst, fb_font.get_string_size(ln2, HORIZONTAL_ALIGNMENT_LEFT, -1.0, main.status_label.font_size).x * main.status_label.pixel_size)
		var h_worst: float = float(w_lines.size()) * fb_font.get_height(main.status_label.font_size) * main.status_label.pixel_size \
			+ float(w_lines.size() - 1) * main.status_label.line_spacing * main.status_label.pixel_size
		check(w_worst <= main.board_slab_size.x - 0.08 and h_worst <= main.board_slab_size.y - 0.08,
			"worst-case status block fits the slab (%.2f x %.2f m)" % [w_worst, h_worst])

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
	var sky_ok: bool = false
	for child: Node in main.get_children():
		if child is WorldEnvironment:
			sky_ok = (child as WorldEnvironment).environment.background_mode == Environment.BG_SKY
	check(sky_ok, "a real sky replaces the flat clear colour")

	# --- Rail stands clear of the stance boxes (pass-3 checks,
	# re-derived for Backyard Game v1) ---
	# FP2 measured the stand from the SPAWN point (0.61 m) and called
	# it fine; Chris's photo showed it sitting on the foul line where
	# his stance goes. The permanent assertion measures against
	# the STANCE BOX at each line: |x| <= 0.85, line z +/- 0.40.
	# A stand must sit outside that box, behind its line, and
	# within ~0.9 m reach of a player standing at the line.
	# V1 re-derivation: pedestals retired for rail stands, but the
	# rail's FIRST slot hangs exactly where the pedestal top put
	# the shoe - the placement Chris judged - so these checks now
	# read the rail's slot-0 transforms, and a mirrored set covers
	# the far end's stands (x flips sign, "behind" flips with it).
	check(main.stand_tfs.size() == 2, "two home-end stands exist, one per foul line (%d)" % main.stand_tfs.size())
	for line_ft: int in [40, 30]:
		var ptf: Transform3D = main.stand_tfs[line_ft]
		var pp: Vector3 = ptf.origin
		var line_z: float = main.line_z_for_ft(line_ft)
		var in_stance: bool = absf(pp.x) <= main.STANCE_HALF_WIDTH \
			and absf(pp.z - line_z) <= main.STANCE_HALF_DEPTH
		check(not in_stance,
			"%d ft stand is OUTSIDE the stance box (at %s, line z %.3f)" % [line_ft, str(pp), line_z])
		check(pp.z - line_z > 0.40 and pp.z - line_z < 0.60,
			"%d ft stand sits ~0.5 m BEHIND its line (%.2f m)" % [line_ft, pp.z - line_z])
		check(pp.x > 0.60 and pp.x < 0.90,
			"%d ft stand sits ~0.75 m to the side (x %.2f)" % [line_ft, pp.x])
		var reach: float = Vector2(pp.x, pp.z).distance_to(Vector2(0.0, line_z))
		check(reach <= 0.92,
			"%d ft stand is within reach of the line (%.2f m from line centre)" % [line_ft, reach])
	check(main.active_stand_line_ft == 40, "the shoe starts homed to the 40 ft stand")
	check(main.stand_tfs_far.size() == 2, "two far-end stands exist, mirrored (%d)" % main.stand_tfs_far.size())
	for line_ft2: int in [40, 30]:
		var ptf2: Transform3D = main.stand_tfs_far[line_ft2]
		var pp2: Vector3 = ptf2.origin
		var line_z2: float = main.line_z_for_ft_at(line_ft2, false)
		var in_stance2: bool = absf(pp2.x) <= main.STANCE_HALF_WIDTH \
			and absf(pp2.z - line_z2) <= main.STANCE_HALF_DEPTH
		check(not in_stance2,
			"far %d ft stand is OUTSIDE the stance box (at %s, line z %.3f)" % [line_ft2, str(pp2), line_z2])
		check(pp2.z - line_z2 < -0.40 and pp2.z - line_z2 > -0.60,
			"far %d ft stand sits ~0.5 m BEHIND its line (%.2f m)" % [line_ft2, pp2.z - line_z2])
		check(pp2.x < -0.60 and pp2.x > -0.90,
			"far %d ft stand sits ~0.75 m to the side (x %.2f)" % [line_ft2, pp2.x])
		var reach2: float = Vector2(pp2.x, pp2.z).distance_to(Vector2(0.0, line_z2))
		check(reach2 <= 0.92,
			"far %d ft stand is within reach of the line (%.2f m from line centre)" % [line_ft2, reach2])

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
	check(main.shoe.global_position.distance_to(shoe_pos_before) < 0.02,
		"shoe stays put in the world while sliding (moved %.3f m)" % main.shoe.global_position.distance_to(shoe_pos_before))
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

	# --- Fix Pass 7: the shoe waits where you are ---
	# The defect: the home pedestal was set only at latch time from
	# the shoe's OWN position, and the shoe starts on the 40 ft
	# pedestal - so it re-homed there forever and the 30 ft
	# pedestal could never be stocked. Now the stocked shoe
	# follows the line the PLAYER is standing at.
	# (a) Walk (production stick input) from the standard end to
	# the short line, empty-handed: a shoe must be waiting there.
	main.test_stick["L"] = Vector2(0.0, 1.0)
	await create_timer(1.55).timeout
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
	main.origin.global_transform = Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -3.048))
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
	main.origin.global_transform = Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -3.048))
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
	main.origin.global_transform = Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -3.048))
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
	var shot_c: Dictionary = await fire_at_stake(
		Vector3(0.0, 0.75, -8.3), Vector3(0.0, -0.2, -9.6), -7.0)
	check(bool(shot_c["fired"]) and (bool(shot_c["contact"]) or float(shot_c["axis_dist"]) < 0.06),
		"pass 8 shot C (pit touchdown, skim into the base): the stake is HIT, not ghosted (or the shoe settles wrapped on it, axis dist %.3f m)"
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
	check(main.status_label.text.contains("YOU 0 - 0 OPP"),
		"game: the board shows the score")
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
	check(main.phase == "SWAP" and main.last_scorer == "",
		"game: a scoreless inning goes to the swap prompt")
	main._complete_swap(true)
	check(main.inning == 2 and main.inning_first == "AI",
		"game: after a scoreless inning the first throw alternates")

	# ============ Backyard Game v1: a full game ============
	# Scripted player throws (production input path) + the AI's
	# own turns drive a complete game to a winner. End swaps
	# alternate between the B button and walking there.
	main.start_game()
	var saw_far_target: bool = false
	var swap_methods: Array = []
	var guard_innings: int = 0
	while main.phase != "OVER" and guard_innings < 40:
		guard_innings += 1
		if main.phase == "SWAP":
			if main.inning % 2 == 1:
				main.test_button["B"] = true
				await frames(4)
				main.test_button["B"] = false
				await frames(4)
				swap_methods.append("button")
			else:
				var spot_z: float = 0.55 if not main.target_far else -12.742
				var yaw2: float = 0.0 if not main.target_far else PI
				var want_cam := Transform3D(Basis(Vector3.UP, yaw2),
					Vector3(0.0, 1.6, spot_z))
				main.origin.global_transform = want_cam * main.cam.transform.inverse()
				await frames(6)
				swap_methods.append("walk")
			check(main.phase != "SWAP",
				"game: end swap completed (%s)" % String(swap_methods[swap_methods.size() - 1]))
		if not main.target_far:
			saw_far_target = true
		# Play out the inning in whichever order the first-throw
		# rule dictates: turns alternate within the inning.
		var inning_no: int = main.inning
		var turn_guard: int = 0
		while main.phase != "SWAP" and main.phase != "OVER" and turn_guard < 6:
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
		check(main.phase == "SWAP" or main.phase == "OVER",
			"game: inning %d completes" % inning_no)
	check(main.phase == "OVER",
		"game: a full game reaches a winner (final %d-%d in %d innings)"
		% [main.score_you, main.score_opp, main.inning])
	check(maxi(main.score_you, main.score_opp) >= 21,
		"game: the winner reached 21 or more")
	check(saw_far_target, "game: innings alternate ends (home-stake innings happened)")
	check(swap_methods.has("button") and swap_methods.has("walk"),
		"game: end swaps worked by button AND by walking %s" % str(swap_methods))
	main.test_button["B"] = true
	await frames(4)
	main.test_button["B"] = false
	await frames(4)
	check(main.mode == "PRACTICE", "game: B at game over returns to practice")
	check(main.status_label.text.contains("THROWS:"),
		"game: the practice board readouts are back")
	check(main.state == "STAND"
		and main.shoe.global_position.distance_to(
			main.slot_tf(main.stock_target_far, main.active_stand_line_ft,
				main._slot_of(main.shoe)).origin) < 0.01,
		"game: practice after the game stocks the shoe on the rail as before")

	main.origin.global_transform = Transform3D.IDENTITY
	DirAccess.remove_absolute(ProjectSettings.globalize_path(rec_path))

	print("---")
	if failures == 0:
		print("SMOKE: ALL %d CHECKS PASSED" % checks)
	else:
		print("SMOKE: %d of %d CHECKS FAILED" % [failures, checks])
	quit(1 if failures > 0 else 0)
