extends SceneTree

## Rendered-frame proofs (needs a real GL frame - run under Xvfb,
## NOT --headless):
##   xvfb-run -a -s "-screen 0 1280x800x24" \
##     ~/workspace/tools/godot/Godot_v4.7-stable_linux.x86_64 \
##     --path . --script tests/render_proofs.gd
##
## Feeds fake positional trackers under the FIELD-CENSUS names
## ("left_hand"/"right_hand", "default" pose - the Duel's settled
## binding) and saves:
##   proofs/court_view.png - the full court ON-AXIS (Fix Pass 18):
##     camera on the court centre line behind the pitching end,
##     level, looking straight down the lane - the ONE pit on the
##     axis at the far end under the board (Fix Pass 19), the
##     player's station near-right with its pair hanging face-on,
##     the AI in his box beside him at the 37 ft line, the
##     landscaped lane rows (Fix Pass 18), the dressed backyard
##     around it all (Fix Pass 10 scenery), board beyond the pit
##     at left.
##   proofs/board_closeup.png - the board face-on: every line of the
##     status + controls text on the slab and legible.
##   proofs/board_from_foul_line.png - from the 40 ft foul line at
##     standing eye height (Fix Pass 10): the board beyond-left of
##     the pit with its stat lines legible at ~16 m.
##   proofs/held_shoe.png  - the shoe latched in the right hand via a
##     real tracker grip input, grab-zone markers visible.
##   proofs/grip_label.png - the Fix Pass 21 grip label riding the
##     held shoe after a free-hand X cycle (SHANK · TOE).
##   proofs/grip_far.png - the Fix Pass 26 far hold: the circuit
##     walked across the shoe to FAR SHANK · MID, the label
##     naming the reverse grip and the shoe seated the other
##     way (opening flipped vs the home hold).
##   proofs/grip_far_heel.png - the Fix Pass 27 clamp proof:
##     one more cycle step to FAR SHANK · HEEL, the LONGEST
##     label in the set, at the same camera as grip_far.png -
##     the whole string inside the frame at the clamped size.
##   proofs/insert_view.png - the Fix Pass 20 insert cam UP at a
##     round's end: the live pit closeup (all four settled shoes
##     parked around the stake, one dud wide) over the round's
##     score breakdown, seen from the player's eye.
##   proofs/perimeter_from_40.png - Stage A from the 40 ft line
##     at eye height: beds and stone framing the lane, the tree
##     line beyond the far fence.
##   proofs/perimeter_from_pit.png - Stage A from behind the
##     pit looking back: the planted yard behind the player.
##   proofs/bed_closeup.png - a right-hand bed at arm's length:
##     stones, shrubs, tufts, flower dots.
##   proofs/sway_a.png / sway_b.png - the sway pair: one
##     designated background canopy against the sky, shot twice
##     ~6 s apart; the suite MEASURES the canopy's displacement
##     between the frames (see _canopy_centroid) and asserts it
##     moved a little - present, small, never a lurch.
## These prove the rendered path + input path work together; they do
## NOT prove headset feel. The XR interaction layer is only verified
## when Chris runs it in the headset.

var failures: int = 0
var checks: int = 0
var main: Node


func check(cond: bool, name: String) -> void:
	checks += 1
	if cond:
		print("PASS  ", name)
	else:
		failures += 1
		print("FAIL  ", name)


func feed_tracker(tracker_name: StringName, hand: int, tf: Transform3D) -> void:
	var t := XRPositionalTracker.new()
	t.name = tracker_name
	t.set_tracker_hand(hand)
	t.set_tracker_type(XRServer.TRACKER_CONTROLLER)
	XRServer.add_tracker(t)
	t.set_pose(&"default", tf, Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)


func move_tracker(tracker_name: StringName, tf: Transform3D) -> void:
	var t: XRPositionalTracker = XRServer.get_tracker(tracker_name) as XRPositionalTracker
	t.set_pose(&"default", tf, Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)


func set_grip(tracker_name: StringName, value: float) -> void:
	var t: XRPositionalTracker = XRServer.get_tracker(tracker_name) as XRPositionalTracker
	t.set_input(&"grip", value)


func set_stick(tracker_name: StringName, value: Vector2) -> void:
	var t: XRPositionalTracker = XRServer.get_tracker(tracker_name) as XRPositionalTracker
	t.set_input(&"primary", value)


func set_button(tracker_name: StringName, action: StringName, pressed: bool) -> void:
	var t: XRPositionalTracker = XRServer.get_tracker(tracker_name) as XRPositionalTracker
	t.set_input(action, pressed)


func settle(phys: int = 6) -> void:
	for i: int in phys:
		await physics_frame
	for j: int in 3:
		await process_frame


func snap(cam: Camera3D, out_rel: String) -> void:
	await RenderingServer.frame_post_draw
	var img: Image = root.get_texture().get_image()
	var out_path: String = ProjectSettings.globalize_path(out_rel)
	var err: Error = img.save_png(out_path)
	check(err == OK, "screenshot saved to %s" % out_rel)
	var distinct: Dictionary = {}
	var step: int = 8
	for x: int in range(0, img.get_width(), step):
		for y: int in range(0, img.get_height(), step):
			distinct[img.get_pixel(x, y).to_rgba32()] = true
	check(distinct.size() > 25, "frame at %s is a real scene (%d sampled colors)" % [out_rel, distinct.size()])


## Like snap(), but hands back the frame for measurement.
func snap_image(out_rel: String) -> Image:
	await RenderingServer.frame_post_draw
	var img: Image = root.get_texture().get_image()
	var out_path: String = ProjectSettings.globalize_path(out_rel)
	var err: Error = img.save_png(out_path)
	check(err == OK, "screenshot saved to %s" % out_rel)
	return img


## The canopy's green run on one scanline: the run of
## canopy-green pixels (green dominant over blue and red -
## the sky behind is blue, the fence brown) that CONTAINS the
## image centre column, returned as (centroid_x, width), or
## (-1, 0) when no such run exists. The sway camera aims at
## the canopy's centre, so its run is the centre one; grass
## and beds sit far below the chosen scanline.
func canopy_centroid(img: Image, y: int) -> Vector2:
	var cx: int = img.get_width() / 2
	var run_start: int = -1
	var found := Vector2(-1.0, 0.0)
	for x: int in img.get_width():
		var px: Color = img.get_pixel(x, y)
		var green: bool = px.g > px.b + 0.03 and px.g >= px.r
		if green and run_start < 0:
			run_start = x
		elif not green and run_start >= 0:
			if run_start <= cx and x - 1 >= cx:
				found = Vector2(float(run_start) + float(x - run_start) * 0.5, float(x - run_start))
			run_start = -1
	if run_start >= 0 and run_start <= cx:
		found = Vector2(float(run_start) + float(img.get_width() - run_start) * 0.5,
			float(img.get_width() - run_start))
	return found


func _init() -> void:
	_run()


func _run() -> void:
	root.size = Vector2i(1280, 720)
	var rec_path: String = "user://proof_throws.jsonl"
	if FileAccess.file_exists(rec_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(rec_path))
	var ps: PackedScene = load("res://main.tscn")
	main = ps.instantiate()
	main.recorder_path = rec_path
	root.add_child(main)
	await create_timer(0.4).timeout
	check(main != null, "main scene instantiated")

	# Standing player at the foul line, hands low at the sides.
	var r_tf := Transform3D(Basis.from_euler(Vector3(deg_to_rad(-15.0), 0.0, 0.0)), Vector3(0.28, 1.05, 0.05))
	var l_tf := Transform3D(Basis.from_euler(Vector3(deg_to_rad(-15.0), 0.0, 0.0)), Vector3(-0.28, 1.05, 0.05))
	feed_tracker(&"right_hand", XRPositionalTracker.TRACKER_HAND_RIGHT, r_tf)
	feed_tracker(&"left_hand", XRPositionalTracker.TRACKER_HAND_LEFT, l_tf)
	await settle(10)
	check(main.hand_ctrl["R"].get_is_active(), "fed right tracker drives the R controller")
	check(main.hand_ctrl["L"].get_is_active(), "fed left tracker drives the L controller")
	for h: String in ["L", "R"]:
		var rep: Node3D = main.ctrl_rep[h]
		check(rep.visible, "controller rep visible while tracked (%s)" % h)

	# --- Proof A: the FULL court, ON-AXIS (Fix Pass 18) ---
	# The camera stands ON the court centre line behind the
	# pitching end, level, looking straight down the lane, so
	# the one pit sits on the axis in frame. The FP13
	# three-quarter framing (off-axis at (3.1, 3.3, 5.6), yawed
	# across the lane) composed a lie in the two-pit days: in
	# Chris's annotated copy the two pits read as offset into
	# different lanes, while the FP18 audit measured every pit
	# element's centre at x = 0.0000 in the world. The honest
	# proof stands where the axis is visible: the player's
	# station near-right with its pair face-on, the AI in his
	# box beside him at the line, the landscaped rows lining
	# the lane, the pit and the board beyond it.
	var cam_a := Camera3D.new()
	cam_a.fov = 55.0
	cam_a.position = Vector3(0.0, 2.9, 5.4)
	main.add_child(cam_a)
	cam_a.look_at(Vector3(0.0, 0.0, -6.098), Vector3.UP)
	cam_a.current = true
	await settle(6)
	await snap(cam_a, "res://proofs/court_view.png")
	cam_a.queue_free()

	# --- Proof A3: the STAGE A perimeter (Stage 2) ---
	# From the 40 ft line at standing eye height, down-court:
	# the beds and their stone frame the lane, and the tree
	# line stands beyond the far fence behind the pit.
	var cam_p := Camera3D.new()
	cam_p.fov = 55.0
	cam_p.position = Vector3(0.8, 1.62, 0.6)
	main.add_child(cam_p)
	cam_p.look_at(Vector3(0.0, 0.4, -12.192), Vector3.UP)
	cam_p.current = true
	await settle(6)
	await snap(cam_p, "res://proofs/perimeter_from_40.png")
	# From behind the pit, looking back the way the player
	# came: lane rows, beds, both stations, and the tree line
	# over the pitching end.
	cam_p.position = Vector3(0.0, 1.7, -15.0)
	cam_p.look_at(Vector3(0.0, 0.9, 3.0), Vector3.UP)
	await settle(6)
	await snap(cam_p, "res://proofs/perimeter_from_pit.png")
	# A bed close-up: stone edge, tufts, shrubs and flower
	# dots in the right-hand bed, mid-lane.
	cam_p.position = Vector3(2.1, 0.75, -4.4)
	cam_p.look_at(Vector3(3.9, 0.10, -6.6), Vector3.UP)
	await settle(6)
	await snap(cam_p, "res://proofs/bed_closeup.png")
	cam_p.queue_free()

	# --- Proof A4: the sway pair (Stage A) ---
	# BGTree3 - the big far tree at (-5, -22.8), canopy centre
	# ~(-5, 5.9) - framed against the sky and shot twice ~6 s
	# apart. The canopy run on a mid-canopy scanline must MOVE
	# between frames, a little: at this distance (8.6 m, fov
	# 55, 1280 wide) a pixel is ~7.0 mm, and the shader leans
	# the crown a degree or two - single-digit to low-double-
	# digit pixels, never a lurch, never a statue.
	var cam_s := Camera3D.new()
	cam_s.fov = 55.0
	cam_s.position = Vector3(-5.0, 5.4, -14.2)
	main.add_child(cam_s)
	cam_s.look_at(Vector3(-5.0, 5.9, -22.8), Vector3.UP)
	cam_s.current = true
	await settle(6)
	var sway_img_a: Image = await snap_image("res://proofs/sway_a.png")
	await create_timer(6.0).timeout
	var sway_img_b: Image = await snap_image("res://proofs/sway_b.png")
	cam_s.queue_free()
	var scan_y: int = int(float(sway_img_a.get_height()) * 0.45)
	var run_a: Vector2 = canopy_centroid(sway_img_a, scan_y)
	var run_b: Vector2 = canopy_centroid(sway_img_b, scan_y)
	check(run_a.x >= 0.0 and run_b.x >= 0.0,
		"sway pair: the designated canopy fills the frame centre in both shots (runs %.0f / %.0f px wide)"
		% [run_a.y, run_b.y])
	if run_a.x >= 0.0 and run_b.x >= 0.0:
		var shift_px: float = absf(run_b.x - run_a.x)
		var m_per_px: float = 2.0 * 8.61 * tan(deg_to_rad(27.5)) / 1280.0
		check(shift_px >= 1.0 and shift_px <= 30.0,
			"sway pair: canopy displaced %.1f px = %.3f m in ~6 s - moving, and small"
			% [shift_px, shift_px * m_per_px])

	# --- Proof A2: board close-up, MID-GAME (Backyard Game v1) ---
	# Seed a game in progress, so the board renders its game
	# status block (score, inning, turn, last-inning result) -
	# the values are proof dressing only, no throw is recorded.
	main.mode = "GAME"
	main.phase = "P_TURN"
	main.score_you = 9
	main.score_opp = 7
	main.inning = 4
	main.turn_side = "P"
	main.turn_throws_left = 1
	main.last_inning_text = "YOU +3"
	main.throw_count = 13
	main.last_hold_text = "FLIP (TOE)"
	main.last_distance_in = 3.2
	main.last_flip_rev = 1.01
	main.last_turn_rev = 0.0
	main.last_ringer = false
	main._update_board()
	var face_dir: Vector3 = main.board_root.global_transform.basis.z
	face_dir.y = 0.0
	face_dir = face_dir.normalized()
	var board_center: Vector3 = main.board_root.global_transform * Vector3(0.0, 1.85, 0.0)
	var cam_close := Camera3D.new()
	cam_close.fov = 55.0
	cam_close.position = board_center + face_dir * 4.2
	main.add_child(cam_close)
	cam_close.look_at(board_center, Vector3.UP)
	cam_close.current = true
	await settle(4)
	await snap(cam_close, "res://proofs/board_closeup.png")
	cam_close.queue_free()

	# --- Proof D: the board from the 40 ft foul line (Fix Pass 10) ---
	# Standing eye height behind the line, looking where the
	# pitcher looks after a throw: the stat lines must read at
	# this distance (~16 m) - that is the whole point of the move.
	var cam_d := Camera3D.new()
	cam_d.fov = 70.0
	# Fix Pass 19: at the player's own spot - his side of the
	# true 37 ft line, at his stance depth behind it.
	cam_d.position = Vector3(0.8, 1.62, -0.364)
	main.add_child(cam_d)
	cam_d.look_at(board_center, Vector3.UP)
	cam_d.current = true
	var foul_dist: float = cam_d.position.distance_to(main.board_root.global_position)
	check(foul_dist > 15.0 and foul_dist < 17.5,
		"foul-line proof really is at board-reading distance (%.1f m)" % foul_dist)
	await settle(4)
	await snap(cam_d, "res://proofs/board_from_foul_line.png")
	cam_d.queue_free()

	# --- Proof E: the insert cam UP at a round's end (Fix Pass 20) ---
	# A manufactured round ends the way a real one does: the
	# tabulation raises the insert - live pit closeup over the
	# score breakdown. The four shoes are parked settled around
	# the stake (one dud wide, the framing stress case), and
	# every one of them must sit inside the closeup's view: a
	# framed-but-empty closeup is a fail.
	main.start_game()
	var park_spots: Array = [
		Vector3(0.10, 0.05, -12.10), Vector3(0.55, 0.05, -11.95),
		Vector3(-0.35, 0.05, -12.45), Vector3(2.30, 0.05, -12.30)]
	var park_i: int = 0
	for raw_e: Variant in main._all_shoes():
		var shoe_e: Node3D = raw_e
		shoe_e.freeze = true
		shoe_e.global_position = park_spots[park_i]
		main.shoe_status[shoe_e] = "DOWN"
		park_i += 1
	main.inning_results = [
		{"owner": "P", "dist_in": 2.0, "ringer": false},
		{"owner": "P", "dist_in": 9.0, "ringer": false},
		{"owner": "AI", "dist_in": 4.0, "ringer": false},
		{"owner": "AI", "dist_in": 90.0, "ringer": false}]
	main._score_inning()
	await settle(6)
	check(main.phase == "INSERT" and main.insert_root.visible,
		"insert cam is UP at the round's end")
	var framed_e: bool = true
	for raw_f: Variant in main._all_shoes():
		var shoe_f: Node3D = raw_f
		if not main.insert_cam.is_position_in_frustum(shoe_f.global_position):
			framed_e = false
	check(framed_e,
		"insert closeup frames ALL FOUR settled shoes (dud at 2.3 m included)")
	var lines_e: String = "\n".join(PackedStringArray(main.round_lines))
	check(lines_e.contains("YOU 1: 2.0 IN")
		and lines_e.contains("YOUR CLOSEST SHOE SCORES: +1")
		and lines_e.contains("MATCH: YOU 1 - 0 OPP"),
		"insert carries the round's breakdown")
	var cam_e := Camera3D.new()
	cam_e.fov = 60.0
	cam_e.position = Vector3(0.0, 1.05, 0.35)
	main.add_child(cam_e)
	cam_e.look_at(main.insert_root.global_position, Vector3.UP)
	cam_e.current = true
	await settle(4)
	await snap(cam_e, "res://proofs/insert_view.png")
	cam_e.queue_free()
	# Back to practice for the proofs that follow.
	main._enter_practice()
	await settle(4)

	# --- Proof B: grab the shoe through the tracker grip input ---
	var toe_c: Vector3 = main.shoe.zone_world_center("toe")
	move_tracker(&"right_hand", Transform3D(Basis.IDENTITY, toe_c))
	await settle(6)
	check(main.candidate_zone == "toe", "right hand at the toe acquires the toe zone (got '%s')" % main.candidate_zone)
	set_grip(&"right_hand", 1.0)
	await settle(8)
	check(main.grab_state.latched, "tracker grip input latches the grab (both-orders path: zone first)")
	check(main.state == "HELD", "shoe HELD after tracker grab")
	check(main.held_hold == "flip", "toe grab through tracker input gives FLIP hold")
	var hand_pos: Vector3 = main.hand_ctrl["R"].global_position
	check(main.shoe.global_position.distance_to(hand_pos) < 0.30,
		"held shoe sits at the hand (%.3f m)" % main.shoe.global_position.distance_to(hand_pos))
	main.debug_show_zones = true
	await settle(3)
	var marker: MeshInstance3D = main.shoe.zone_markers["toe"]
	check(marker.visible, "grab-zone markers visible for the held proof")
	var shoe_pos: Vector3 = main.shoe.global_position
	var cam_b := Camera3D.new()
	cam_b.fov = 70.0
	cam_b.position = shoe_pos + Vector3(0.42, 0.30, 0.48)
	main.add_child(cam_b)
	cam_b.look_at(shoe_pos, Vector3.UP)
	cam_b.current = true
	await settle(4)
	await snap(cam_b, "res://proofs/held_shoe.png")
	cam_b.queue_free()

	# --- Proof B2: the grip label rides the held shoe (Fix Pass 21) ---
	# The toe grab above starts at TOE GRIP; the label must be
	# up, naming it. Then the FREE (left) hand's face button -
	# fed through the real tracker input, the same ax_button the
	# headset's X feeds - walks the grip to SHANK · TOE and the
	# label follows.
	check(main.grip_label.visible and main.grip_label.text == "TOE GRIP · FLIP",
		"grip label rides the held shoe naming TOE GRIP (got '%s', visible %s)"
		% [main.grip_label.text, str(main.grip_label.visible)])
	set_button(&"left_hand", &"ax_button", true)
	await settle(5)
	set_button(&"left_hand", &"ax_button", false)
	await settle(5)
	check(main._grip_index() == 1 and main.grip_label.text == "SHANK · TOE · 1⅛ TURN",
		"free-hand X through the tracker input cycles the grip; the label follows (got '%s')"
		% main.grip_label.text)
	# Carry the held shoe out into open space for the shot: at
	# the station the turn hold's edge-on shoe is a sliver lost
	# against the timber; at arm's length over the lawn the
	# label and the shoe it rides read clean.
	move_tracker(&"right_hand", Transform3D(Basis.IDENTITY, Vector3(0.25, 1.25, -0.55)))
	await settle(8)
	var shoe_pos2: Vector3 = main.shoe.global_position
	var cam_b2 := Camera3D.new()
	cam_b2.fov = 70.0
	cam_b2.position = shoe_pos2 + Vector3(0.45, 0.25, 0.62)
	main.add_child(cam_b2)
	cam_b2.look_at(shoe_pos2 + Vector3(0.0, 0.05, 0.0), Vector3.UP)
	cam_b2.current = true
	await settle(4)
	await snap(cam_b2, "res://proofs/grip_label.png")
	cam_b2.queue_free()

	# --- Proof B3: the FAR hold (Fix Pass 26) ---
	# Four more X presses through the same tracker input walk
	# the circuit across the shoe to FAR SHANK · MID. The far
	# hold must seat as the reverse setup: with the tracker
	# hand at identity basis, the home hold's opening points
	# -X (Proof B2's seat); the far hold's must point +X -
	# flipped, not the same pose on a different anchor.
	for i26: int in 4:
		set_button(&"left_hand", &"ax_button", true)
		await settle(5)
		set_button(&"left_hand", &"ax_button", false)
		await settle(5)
	check(main._grip_index() == 5 and main.held_zone == "shank_left"
		and main.grip_label.text == "FAR SHANK · MID · 1¼ TURN · REVERSE",
		"the circuit crosses to FAR SHANK · MID on the far zone (got idx %d / %s / '%s')"
		% [main._grip_index(), main.held_zone, main.grip_label.text])
	var open_far: Vector3 = main.shoe.global_transform.basis * Vector3(0.0, 0.0, 1.0)
	check(open_far.x > 0.9,
		"the far hold seats as the reverse setup - opening flipped to +X (got %s)" % str(open_far))
	var shoe_pos3: Vector3 = main.shoe.global_position
	var cam_b3 := Camera3D.new()
	cam_b3.fov = 70.0
	cam_b3.position = shoe_pos3 + Vector3(0.45, 0.25, 0.62)
	main.add_child(cam_b3)
	cam_b3.look_at(shoe_pos3 + Vector3(0.0, 0.05, 0.0), Vector3.UP)
	cam_b3.current = true
	await settle(4)
	await snap(cam_b3, "res://proofs/grip_far.png")
	cam_b3.queue_free()

	# --- Proof B4: the longest label at the clamped size ---
	# (Fix Pass 27). One more X press walks to FAR SHANK ·
	# HEEL - the longest string the label can ever show. The
	# FP26 shot above filled Chris's headset view with the
	# MID string at the old size (0.768 m wide for HEEL); the
	# clamped label must carry the whole HEEL string at the
	# same camera, and its measured width must sit inside the
	# ~0.50 m cap (font metrics, the standing method).
	set_button(&"left_hand", &"ax_button", true)
	await settle(5)
	set_button(&"left_hand", &"ax_button", false)
	await settle(5)
	check(main._grip_index() == 6
		and main.grip_label.text == "FAR SHANK · HEEL · 1⅜ TURN · REVERSE",
		"the circuit walks on to FAR SHANK · HEEL, the longest label (got idx %d / '%s')"
		% [main._grip_index(), main.grip_label.text])
	var fb27p: Font = ThemeDB.fallback_font
	var w27p: float = fb27p.get_string_size(main.grip_label.text,
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, main.grip_label.font_size).x * main.grip_label.pixel_size
	check(w27p <= 0.50,
		"FP27: the longest grip label measures inside the clamp (%.3f m <= 0.50 m)" % w27p)
	var shoe_pos4: Vector3 = main.shoe.global_position
	var cam_b4 := Camera3D.new()
	cam_b4.fov = 70.0
	cam_b4.position = shoe_pos4 + Vector3(0.45, 0.25, 0.62)
	main.add_child(cam_b4)
	cam_b4.look_at(shoe_pos4 + Vector3(0.0, 0.05, 0.0), Vector3.UP)
	cam_b4.current = true
	await settle(4)
	await snap(cam_b4, "res://proofs/grip_far_heel.png")
	cam_b4.queue_free()

	# --- Proof C: locomotion through the REAL tracker stick inputs ---
	# (the same "primary" action the headset's thumbsticks feed).
	# Pass-6 STANDARD mapping: left_hand stick walks (forward push
	# reads y=+1 on Chris's rig, the FP4 field correction),
	# right_hand stick X turns smoothly (FP5 math).
	set_stick(&"left_hand", Vector2(0.0, 1.0))
	await create_timer(1.0).timeout
	set_stick(&"left_hand", Vector2.ZERO)
	var walked: Vector3 = main.origin.global_position
	check(walked.z < -1.2 and walked.z > -2.8 and absf(walked.x) < 0.4,
		"tracker left stick walks the origin forward (~2 m in 1 s, got %s)" % str(walked))
	# Smooth turn through the real tracker input: hold the right
	# stick over, sampling the camera heading every ~0.1 s. The
	# measured rate must be ~100 deg/s (asserted on rate - timer
	# pacing varies under Xvfb), no step anywhere near the old
	# 30 deg snap, origin untranslated.
	var last_head: Vector3 = main.cam.global_transform.basis * Vector3(0.0, 0.0, -1.0)
	var p_max_step: float = 0.0
	var p_total: float = 0.0
	set_stick(&"right_hand", Vector2(1.0, 0.0))
	var p_t0: int = Time.get_ticks_msec()
	for i: int in 5:
		await create_timer(0.1).timeout
		var h_now2: Vector3 = main.cam.global_transform.basis * Vector3(0.0, 0.0, -1.0)
		var p_step: float = absf(rad_to_deg(Vector2(last_head.x, last_head.z).angle_to(
			Vector2(h_now2.x, h_now2.z))))
		p_max_step = maxf(p_max_step, p_step)
		p_total += p_step
		last_head = h_now2
	set_stick(&"right_hand", Vector2.ZERO)
	var p_secs: float = float(Time.get_ticks_msec() - p_t0) / 1000.0
	var p_rate: float = p_total / maxf(p_secs, 0.001)
	check(p_rate > 70.0 and p_rate < 130.0,
		"tracker right stick turns smoothly at ~100 deg/s (got %.0f deg/s over %.2f s)" % [p_rate, p_secs])
	check(p_max_step < 24.0,
		"tracker turning has NO STEP: largest sampled heading change %.1f deg (snap was 30 at once)" % p_max_step)
	check(main.origin.global_position.distance_to(walked) < 0.02,
		"tracker smooth turn does not translate the origin (moved %.3f m)" % main.origin.global_position.distance_to(walked))

	DirAccess.remove_absolute(ProjectSettings.globalize_path(rec_path))
	print("---")
	if failures == 0:
		print("PROOFS: ALL %d CHECKS PASSED" % checks)
	else:
		print("PROOFS: %d of %d CHECKS FAILED" % [failures, checks])
	quit(1 if failures > 0 else 0)
