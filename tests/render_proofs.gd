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
##   proofs/court_view.png - from the pitcher's head: pit + stake at
##     40 ft centre, shoe stand right, board legible left.
##   proofs/held_shoe.png  - the shoe latched in the right hand via a
##     real tracker grip input, grab-zone markers visible.
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

	# --- Proof A: court from the pitcher's view ---
	var cam_a := Camera3D.new()
	cam_a.fov = 85.0
	cam_a.position = Vector3(0.15, 1.62, 1.25)
	main.add_child(cam_a)
	cam_a.look_at(Vector3(-0.30, 0.35, -5.0), Vector3.UP)
	cam_a.current = true
	await settle(6)
	await snap(cam_a, "res://proofs/court_view.png")
	cam_a.queue_free()

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

	# --- Proof C: locomotion through the REAL tracker stick inputs ---
	# (the same "primary" action the headset's thumbsticks feed).
	set_stick(&"left_hand", Vector2(0.0, -1.0))
	await create_timer(1.0).timeout
	set_stick(&"left_hand", Vector2.ZERO)
	var walked: Vector3 = main.origin.global_position
	check(walked.z < -1.2 and walked.z > -2.8 and absf(walked.x) < 0.4,
		"tracker left stick walks the origin forward (~2 m in 1 s, got %s)" % str(walked))
	var head_before: Vector3 = main.cam.global_transform.basis * Vector3(0.0, 0.0, -1.0)
	set_stick(&"right_hand", Vector2(1.0, 0.0))
	await settle(6)
	set_stick(&"right_hand", Vector2.ZERO)
	var head_after: Vector3 = main.cam.global_transform.basis * Vector3(0.0, 0.0, -1.0)
	var turn_ang: float = rad_to_deg(Vector2(head_before.x, head_before.z).angle_to(
		Vector2(head_after.x, head_after.z)))
	check(absf(absf(turn_ang) - 30.0) < 2.0,
		"tracker right stick snaps the heading by 30 deg (got %.1f)" % turn_ang)
	check(main.origin.global_position.distance_to(walked) < 0.02,
		"tracker snap turn does not translate the origin (moved %.3f m)" % main.origin.global_position.distance_to(walked))

	DirAccess.remove_absolute(ProjectSettings.globalize_path(rec_path))
	print("---")
	if failures == 0:
		print("PROOFS: ALL %d CHECKS PASSED" % checks)
	else:
		print("PROOFS: %d of %d CHECKS FAILED" % [failures, checks])
	quit(1 if failures > 0 else 0)
