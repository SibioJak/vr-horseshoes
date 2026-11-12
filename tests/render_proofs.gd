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
##   proofs/board_breakdown.png - Fix Pass 39: the round-end
##     breakdown UP on the rear SCOREBOARD (the fresh look),
##     seen from the throwing line; board_from_foul_line.png
##     is the same board in its running state, same camera.
##   proofs/proof_billboard_feed.png - Fix Pass 39: the
##     billboard from the throwing spot at a settled lie -
##     the broadcast camera's closeup of shoe + stake on the
##     panel; the suite also samples the feed texture
##     across a staged flight and asserts it changes.
##   proofs/proof_billboard_flight.png - Fix Pass 39: the
##     billboard from the throwing spot MID-FLIGHT - the
##     camera's closeup follow, the shoe big in the panel.
##   proofs/proof_billboard_replay.png - Fix Pass 39: the
##     billboard mid-REPLAY - a settled ringer's slow-mo
##     clone flying the recorded track on the panel.
##   proofs/proof_billboard_pull.png - Fix Pass 40: a hard
##     pulled-LEFT throw's ARRIVAL closeup on the panel -
##     the shoe framed WITH the stake, the camera composed
##     on the pit instead of swung off after the shoe.
##   proofs/proof_pincam_arrival.png - Fix Pass 41: the
##     PIN CAM's own frame at an on-line arrival - the
##     shoe in the air coming at the lens, the stake big
##     in the foreground (the billboard feed itself,
##     saved from the pit viewport's texture).
##   proofs/proof_sidecam_skid.png - Fix Pass 41: the
##     SIDE CAM's frame of a plowing arrival's lie - the
##     furrow read in profile across the pit.
##   proofs/proof_sidecam_leaner.png - Fix Pass 41: the
##     SIDE CAM's frame of a leaner at rest against the
##     stake, in profile.
##   proofs/proof_billboard_plan.png - Fix Pass 38: the
##     billboard's placement from a high oblique - LEFT of
##     the lane at halfway, posts at the bed line, face
##     angled back at the throwing end, lane + berm clear.
##   proofs/perimeter_from_40.png - Stage A from the 40 ft line
##     at eye height: beds and stone framing the lane, the tree
##     line beyond the far fence.
##   proofs/perimeter_from_pit.png - Stage A from behind the
##     pit looking back: the planted yard behind the player.
##   proofs/bed_closeup.png - a right-hand bed at arm's length:
##     stones, shrubs, tufts, flower dots.
##   proofs/lookback_from_line.png - Stage B: the turn-around
##     from the pitching spot - patio, house rear, stations.
##   proofs/patio_close.png - Stage B: the patio dressed -
##     grill, table and chairs, door and pots.
##   proofs/gate_view.png - Stage B: THE GATE in the right
##     fence, the stepping-stone path arriving.
##   proofs/fountain_view.png - Stage B: the stacked-rock
##     fountain in its corner nook at the patio end of the
##     left bed (Fix Pass 29).
##   proofs/phineas_view.png - Stage B: Phineas Gage in the
##     corner pocket beside the far bed's west end, pan in
##     hand (Fix Pass 29).
##   proofs/sway_a.png / sway_b.png - the sway pair: one
##     designated background canopy against the sky, shot twice
##     ~6 s apart; the suite MEASURES the canopy's displacement
##     between the frames (see _canopy_centroid) and asserts it
##     moved a little - present, small, never a lurch.
##   proofs/time_cloudy.png / time_noon.png / time_dusk.png -
##     Stage B light: one camera at the throwing line, the
##     yard under the three times; the suite MEASURES mean
##     luminance (dusk darker than noon) and the cloudy/noon
##     overcast signature (Fix Pass 31: saturation down,
##     warmth near zero and cooler, luminance lower and
##     flatter than noon's).
##   proofs/dusk_fire.png - Stage B light: the look-back at
##     DUSK with the patio fire lit; the suite measures the
##     fire's neighbourhood brighter and warmer than the
##     frame around it.
##   proofs/birds_view.png - Stage B light: a forced bird
##     crossing parked mid-frame - dark two-wing silhouettes
##     against the sky, counted by the suite.
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


## Mean luminance over a strided sample of the frame -
## the Stage B light frames' darkness measure.
func mean_luminance(img: Image) -> float:
	var total: float = 0.0
	var n: int = 0
	for x: int in range(0, img.get_width(), 6):
		for y: int in range(0, img.get_height(), 6):
			var px: Color = img.get_pixel(x, y)
			total += px.r * 0.299 + px.g * 0.587 + px.b * 0.114
			n += 1
	return total / float(maxi(n, 1))


## Mean HSV saturation over the same strided sample - the
## overcast signature's desaturation measure (Fix Pass 31).
func mean_saturation(img: Image) -> float:
	var total: float = 0.0
	var n: int = 0
	for x: int in range(0, img.get_width(), 6):
		for y: int in range(0, img.get_height(), 6):
			var px: Color = img.get_pixel(x, y)
			var mx: float = maxf(maxf(px.r, px.g), px.b)
			var mn: float = minf(minf(px.r, px.g), px.b)
			total += 0.0 if mx <= 0.0 else (mx - mn) / mx
			n += 1
	return total / float(maxi(n, 1))


## The standard deviation of the frame's luminance - its
## contrast spread. An overcast frame is FLATTER: the same
## mean territory with a tighter spread (Fix Pass 31).
func luminance_sd(img: Image) -> float:
	var mean: float = mean_luminance(img)
	var total: float = 0.0
	var n: int = 0
	for x: int in range(0, img.get_width(), 6):
		for y: int in range(0, img.get_height(), 6):
			var px: Color = img.get_pixel(x, y)
			var lum: float = px.r * 0.299 + px.g * 0.587 + px.b * 0.114
			total += (lum - mean) * (lum - mean)
			n += 1
	return sqrt(total / float(maxi(n, 1)))


## Mean absolute per-channel difference between two frames
## of the same size - "these are not the same picture".
func mean_abs_diff(a: Image, b: Image) -> float:
	var total: float = 0.0
	var n: int = 0
	for x: int in range(0, a.get_width(), 6):
		for y: int in range(0, a.get_height(), 6):
			var pa: Color = a.get_pixel(x, y)
			var pb: Color = b.get_pixel(x, y)
			total += (absf(pa.r - pb.r) + absf(pa.g - pb.g)
				+ absf(pa.b - pb.b)) / 3.0
			n += 1
	return total / float(maxi(n, 1))


## (luminance, warmth) over a square region of the frame:
## warmth is mean red-minus-blue - firelight's signature.
func region_stats(img: Image, cx: int, cy: int, half: int) -> Vector2:
	var lum: float = 0.0
	var warm: float = 0.0
	var n: int = 0
	var x0: int = maxi(cx - half, 0)
	var x1: int = mini(cx + half, img.get_width() - 1)
	var y0: int = maxi(cy - half, 0)
	var y1: int = mini(cy + half, img.get_height() - 1)
	for x: int in range(x0, x1, 3):
		for y: int in range(y0, y1, 3):
			var px: Color = img.get_pixel(x, y)
			lum += px.r * 0.299 + px.g * 0.587 + px.b * 0.114
			warm += px.r - px.b
			n += 1
	if n == 0:
		return Vector2(-1.0, 0.0)
	return Vector2(lum / float(n), warm / float(n))


## Fix Pass 32 census helpers: bright-desaturated SPARK
## samples in a box around a screen point; pixels CHANGED
## vs a baseline frame in that box (the plume's presence,
## at any light level) with their mean warmth; and the mean
## absolute difference of two frames (the clean-air test).
func spark_px(img: Image, centre: Vector2) -> int:
	var n: int = 0
	for gx: int in range(maxi(0, int(centre.x) - 90), mini(img.get_width(), int(centre.x) + 90), 2):
		for gy: int in range(maxi(0, int(centre.y) - 90), mini(img.get_height(), int(centre.y) + 90), 2):
			var c: Color = img.get_pixel(gx, gy)
			var mx: float = maxf(c.r, maxf(c.g, c.b))
			var mn: float = minf(c.r, minf(c.g, c.b))
			if mn > 0.62 and (mx - mn) < 0.16:
				n += 1
	return n


func changed_px(a: Image, b: Image, centre: Vector2, thresh: float) -> int:
	var n: int = 0
	for gx: int in range(maxi(0, int(centre.x) - 90), mini(a.get_width(), int(centre.x) + 90), 2):
		for gy: int in range(maxi(0, int(centre.y) - 90), mini(a.get_height(), int(centre.y) + 90), 2):
			var ca: Color = a.get_pixel(gx, gy)
			var cb: Color = b.get_pixel(gx, gy)
			if absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b) > thresh:
				n += 1
	return n


func changed_warmth(a: Image, b: Image, centre: Vector2, thresh: float) -> float:
	var warm: float = 0.0
	var n: int = 0
	for gx: int in range(maxi(0, int(centre.x) - 90), mini(a.get_width(), int(centre.x) + 90), 2):
		for gy: int in range(maxi(0, int(centre.y) - 90), mini(a.get_height(), int(centre.y) + 90), 2):
			var ca: Color = a.get_pixel(gx, gy)
			var cb: Color = b.get_pixel(gx, gy)
			if absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b) > thresh:
				warm += ca.r - ca.b
				n += 1
	if n == 0:
		return 0.0
	return warm / float(n)


func region_mean_diff(a: Image, b: Image, centre: Vector2, half: int) -> float:
	var total: float = 0.0
	var n: int = 0
	for gx: int in range(maxi(0, int(centre.x) - half), mini(a.get_width(), int(centre.x) + half), 2):
		for gy: int in range(maxi(0, int(centre.y) - half), mini(a.get_height(), int(centre.y) + half), 2):
			var ca: Color = a.get_pixel(gx, gy)
			var cb: Color = b.get_pixel(gx, gy)
			total += absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b)
			n += 1
	if n == 0:
		return 1.0
	return total / float(n) / 3.0


## The whole frame's (luminance, warmth), strided.
func frame_stats(img: Image) -> Vector2:
	var lum: float = 0.0
	var warm: float = 0.0
	var n: int = 0
	for x: int in range(0, img.get_width(), 6):
		for y: int in range(0, img.get_height(), 6):
			var px: Color = img.get_pixel(x, y)
			lum += px.r * 0.299 + px.g * 0.587 + px.b * 0.114
			warm += px.r - px.b
			n += 1
	return Vector2(lum / float(maxi(n, 1)), warm / float(maxi(n, 1)))


func _init() -> void:
	_run()


func _run() -> void:
	root.size = Vector2i(1280, 720)
	var rec_path: String = "user://proof_throws.jsonl"
	if FileAccess.file_exists(rec_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(rec_path))
	# Stage B light: the settings file is redirected too, so
	# the run starts from a first run - NOON, the accepted
	# look - whatever the player's own file holds.
	var set_path_p: String = "user://proof_settings.json"
	if FileAccess.file_exists(set_path_p):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(set_path_p))
	var ps: PackedScene = load("res://main.tscn")
	main = ps.instantiate()
	main.recorder_path = rec_path
	main.settings_path = set_path_p
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
	# the lane, the pit and the board beyond it. Stage B: the
	# stations stand on the PATIO behind the line now, and
	# the house's rear wall stands where this camera used to
	# sit - it shoots from over the patio instead.
	var cam_a := Camera3D.new()
	cam_a.fov = 55.0
	cam_a.position = Vector3(0.0, 2.9, 3.1)
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

	# --- Proof B: the YARD PASS frames (Stage B) ---
	# The look-back from behind the pitching spot: the
	# player turns around and the patio is there - house
	# rear, both stations on the slab, the grill and table.
	var cam_y := Camera3D.new()
	cam_y.fov = 55.0
	cam_y.position = Vector3(0.8, 1.62, -1.5)
	main.add_child(cam_y)
	cam_y.look_at(Vector3(0.2, 0.8, 5.0), Vector3.UP)
	cam_y.current = true
	await settle(6)
	await snap(cam_y, "res://proofs/lookback_from_line.png")
	# The patio close: pavers underfoot, grill, table and
	# chairs, the back door and its pots.
	cam_y.position = Vector3(0.2, 1.45, 1.1)
	cam_y.look_at(Vector3(2.2, 0.7, 4.6), Vector3.UP)
	await settle(6)
	await snap(cam_y, "res://proofs/patio_close.png")
	# The gate from inside the yard, ON the stepping-stone
	# path's axis, the path arriving across the bed gap at
	# the frame's feet - the approach frame (Fix Pass 29:
	# no tree trunk stands in this view any more).
	cam_y.position = Vector3(9.8, 1.5, -6.0)
	cam_y.look_at(Vector3(13.0, 1.0, -6.0), Vector3.UP)
	await settle(6)
	await snap(cam_y, "res://proofs/gate_view.png")
	# The fountain in its corner nook at the patio end of
	# the left bed (Fix Pass 29), the bed run behind it.
	cam_y.position = Vector3(-2.35, 1.30, 0.35)
	cam_y.look_at(Vector3(-3.75, 0.30, -1.55), Vector3.UP)
	await settle(6)
	await snap(cam_y, "res://proofs/fountain_view.png")
	# Phineas in his corner pocket beside the far bed's
	# west end: hat, beard, pan, watching (Fix Pass 29).
	cam_y.position = Vector3(-3.10, 1.50, -12.55)
	cam_y.look_at(Vector3(-5.40, 1.05, -14.78), Vector3.UP)
	await settle(6)
	await snap(cam_y, "res://proofs/phineas_view.png")
	cam_y.queue_free()

	# --- Proof B0: Stage B light - three times, the fire, the birds ---
	# One camera at the throwing line (the perimeter framing)
	# under CLOUDY, NOON and DUSK in turn. The suite
	# MEASURES: dusk darker than noon overall; and CLOUDY's
	# overcast signature against noon from the SAME camera
	# (Fix Pass 31): saturation clearly down, warmth near
	# zero and cooler than noon's, luminance somewhat lower
	# and its spread flatter.
	var cam_t := Camera3D.new()
	cam_t.fov = 55.0
	cam_t.position = Vector3(0.8, 1.62, 0.6)
	main.add_child(cam_t)
	cam_t.look_at(Vector3(0.0, 0.4, -12.192), Vector3.UP)
	cam_t.current = true
	main.set_time_of_day("CLOUDY")
	await settle(6)
	var img_cloudy: Image = await snap_image("res://proofs/time_cloudy.png")
	main.set_time_of_day("NOON")
	await settle(6)
	var img_noon: Image = await snap_image("res://proofs/time_noon.png")
	main.set_time_of_day("DUSK")
	await settle(6)
	var img_dusk: Image = await snap_image("res://proofs/time_dusk.png")
	var lum_cloudy: float = mean_luminance(img_cloudy)
	var lum_noon: float = mean_luminance(img_noon)
	var lum_dusk: float = mean_luminance(img_dusk)
	check(lum_dusk < lum_noon * 0.85,
		"Stage B light: dusk is measurably darker than noon (mean luminance %.3f vs %.3f)"
		% [lum_dusk, lum_noon])
	var cloudy_stats: Vector2 = frame_stats(img_cloudy)
	var noon_stats: Vector2 = frame_stats(img_noon)
	var sat_cloudy: float = mean_saturation(img_cloudy)
	var sat_noon: float = mean_saturation(img_noon)
	var sd_cloudy: float = luminance_sd(img_cloudy)
	var sd_noon: float = luminance_sd(img_noon)
	check(sat_cloudy < sat_noon - 0.03,
		"Fix Pass 31: cloudy desaturates the yard (mean saturation %.3f vs noon %.3f)"
		% [sat_cloudy, sat_noon])
	check(absf(cloudy_stats.y) <= 0.045 and cloudy_stats.y < noon_stats.y - 0.003,
		"Fix Pass 31: cloudy's warmth sits near zero and cooler than noon (r-b %.3f vs %.3f)"
		% [cloudy_stats.y, noon_stats.y])
	check(lum_cloudy < lum_noon * 0.97 and lum_cloudy > lum_noon * 0.75,
		"Fix Pass 31: cloudy is somewhat dimmer than noon, not dark (luminance %.3f vs %.3f)"
		% [lum_cloudy, lum_noon])
	check(sd_cloudy < sd_noon * 0.95,
		"Fix Pass 31: cloudy flattens the frame (luminance spread %.3f vs noon %.3f)"
		% [sd_cloudy, sd_noon])
	cam_t.queue_free()
	# The look-back at DUSK, the fire lit: the pit's
	# neighbourhood - around its projected position - must
	# measure brighter and warmer than the frame around it.
	var cam_f := Camera3D.new()
	cam_f.fov = 55.0
	cam_f.position = Vector3(0.8, 1.62, -1.5)
	main.add_child(cam_f)
	cam_f.look_at(Vector3(0.2, 0.8, 5.0), Vector3.UP)
	cam_f.current = true
	await settle(6)
	check(main.fire_is_lit(), "Stage B light: the fire is lit for its frame")
	var img_fire: Image = await snap_image("res://proofs/dusk_fire.png")
	var fire_px: Vector2 = cam_f.unproject_position(Vector3(-2.30, 0.45, 1.90))
	var fire_region: Vector2 = region_stats(img_fire,
		int(fire_px.x), int(fire_px.y), 30)
	var fire_frame: Vector2 = frame_stats(img_fire)
	check(fire_region.x > fire_frame.x
		and fire_region.y > fire_frame.y + 0.03,
		"Stage B light: the fire's neighbourhood is brighter and warmer than the dusk frame around it (lum %.3f vs %.3f, warmth %.3f vs %.3f)"
		% [fire_region.x, fire_frame.x, fire_region.y, fire_frame.y])
	cam_f.queue_free()
	# A forced crossing parked across the sky camera: dark
	# two-wing silhouettes, counted. The flock is turned to
	# cross the frame (wings spread to the camera) - the
	# mover's travel direction is a test transport detail.
	main.debug_force_bird_crossing()
	main.bird_dir = Vector3(0.0, 0.0, -1.0)
	main.bird_root.rotation.y = PI * 0.5
	main.bird_root.position = Vector3(0.5, 15.0, -6.0)
	var cam_sky := Camera3D.new()
	cam_sky.fov = 55.0
	cam_sky.position = Vector3(0.8, 1.62, 0.6)
	main.add_child(cam_sky)
	cam_sky.look_at(Vector3(0.5, 13.2, -8.0), Vector3.UP)
	cam_sky.current = true
	await settle(3)
	var img_birds: Image = await snap_image("res://proofs/birds_view.png")
	var dark_px: int = 0
	for bx: int in range(0, img_birds.get_width(), 2):
		for by: int in range(0, img_birds.get_height(), 2):
			var bpx: Color = img_birds.get_pixel(bx, by)
			if bpx.r < 0.16 and bpx.g < 0.16 and bpx.b < 0.16:
				dark_px += 1
	check(dark_px > 20,
		"Stage B light: the flock crosses as dark silhouettes against the sky (%d dark samples)"
		% dark_px)
	cam_sky.queue_free()
	main.set_time_of_day("NOON")
	await settle(4)

	# --- Impact Dressing: plume mid-flight; FP37: dents ---
	# One camera over the pit. The plume is fired through
	# the FX debug hook and caught within its ~1 s life; the
	# pit's marks are then staged as real dents (the decal
	# divots retired in FP37) and raked away by the funnel.
	var cam_i := Camera3D.new()
	cam_i.fov = 55.0
	cam_i.position = Vector3(1.7, 1.6, -10.4)
	main.add_child(cam_i)
	cam_i.look_at(Vector3(0.0, 0.0, -12.192), Vector3.UP)
	cam_i.current = true
	await settle(4)
	main.fx.debug_fire_plume(ImpactFX.KIND_SAND,
		Vector3(0.1, 0.03, -11.95), Vector3(0.0, 0.0, -1.0), 1.0)
	await settle(2)
	var img_plume: Image = await snap_image("res://proofs/plume_mid.png")
	var plume_px: Vector2 = cam_i.unproject_position(Vector3(0.1, 0.25, -12.15))
	var grain_px: int = 0
	for gx: int in range(maxi(0, int(plume_px.x) - 90), mini(img_plume.get_width(), int(plume_px.x) + 90), 2):
		for gy: int in range(maxi(0, int(plume_px.y) - 90), mini(img_plume.get_height(), int(plume_px.y) + 90), 2):
			var gpx: Color = img_plume.get_pixel(gx, gy)
			if gpx.r > 0.55 and gpx.g > 0.42 and gpx.b < 0.68 and gpx.r > gpx.b + 0.08:
				grain_px += 1
	check(grain_px > 12,
		"Impact Dressing: the plume reads as dry-sand grains in flight (%d samples)" % grain_px)
	# Fix Pass 37: the pit's marks are real DENTS now. A
	# punch-in and a skid staged through main's production
	# stamp hooks, a buried-vs-on-top rest pair through its
	# production sink, then the rake. The plume above gets
	# its ~1 s life to die first, so the frames show the
	# MARKS, not the moment (the old divot section's rule).
	await create_timer(1.4).timeout
	await settle(2)
	var crater_pos := Vector3(0.18, 0.03, -12.30)
	main.debug_sand_crater(crater_pos, 0.95)
	await settle(2)
	check(main.sand_surface().depth_at(crater_pos) > 0.008,
		"Sand depth (FP37): a staged punch-in dents the pit (%.4f m)"
			% main.sand_surface().depth_at(crater_pos))
	var img_crater: Image = await snap_image("res://proofs/sand_crater.png")
	var cr_px: Vector2 = cam_i.unproject_position(crater_pos)
	main.debug_sand_furrow(Vector3(-0.32, 0.03, -11.80),
		Vector3(0.28, 0.03, -12.02), 1.0)
	await settle(2)
	check(main.sand_surface().depth_at(Vector3(-0.02, 0.03, -11.91)) > 0.003,
		"Sand depth (FP37): a staged skid plows its furrow (%.4f m)"
			% main.sand_surface().depth_at(Vector3(-0.02, 0.03, -11.91)))
	await snap_image("res://proofs/sand_furrow.png")
	# The rest pair: a full-strength stamp buries its shoe;
	# a soft one leaves its shoe on top. Both staged frozen
	# through main's production sink path.
	var rest_pair: Array = []
	var rest_specs: Array = [
		[Vector3(0.22, 0.02, -12.45), 0.5, 1.0],
		[Vector3(-0.24, 0.02, -11.90), -0.4, 0.1],
	]
	for rs: Array in rest_specs:
		var rshoe := Shoe.new()
		main.add_child(rshoe)
		rshoe.freeze = true
		rshoe.global_transform = Transform3D(
			Basis(Vector3.UP, float(rs[1])), rs[0])
		rshoe.debug_set_flight_sand_strength(float(rs[2]))
		rest_pair.append(rshoe)
	await settle(2)
	var sunk_hard: float = main._sink_settled_shoe(rest_pair[0])
	var sunk_soft: float = main._sink_settled_shoe(rest_pair[1])
	check(sunk_hard > 0.014 and sunk_soft < 0.002,
		"Sand depth (FP37): the hard arrival sinks %.4f m, the soft one %.4f m"
			% [sunk_hard, sunk_soft])
	await settle(2)
	await snap_image("res://proofs/sand_rest.png")
	for rshoe2: Variant in rest_pair:
		(rshoe2 as Shoe).queue_free()
	main._gather_to_rail(40)
	await settle(4)
	check(main.sand_surface().max_abs_height() < 0.0001,
		"Sand depth (FP37): the restock rake flattens every dent")
	var img_raked: Image = await snap_image("res://proofs/sand_raked.png")
	check(region_mean_diff(img_crater, img_raked, cr_px, 20) > 0.01,
		"Sand depth (FP37): the crater visibly reads against the same sand raked flat (diff %.3f)"
			% region_mean_diff(img_crater, img_raked, cr_px, 20))
	cam_i.queue_free()

	# --- Fix Pass 32: the plume at DUSK, dense frames ---
	# Chris's failing condition, staged: a full-strength burst
	# over the pit at dusk, frames across its life plus the
	# +2 s clean-air frame. Sparks = bright DESATURATED pixels
	# (the unshaded puff's signature); the fix must add none
	# beyond the static scene's own, the burst must still read
	# as sand, and at +2 s the air must be empty.
	main.set_time_of_day("DUSK")
	var cam_fp := Camera3D.new()
	cam_fp.fov = 55.0
	cam_fp.position = Vector3(1.7, 1.6, -10.4)
	main.add_child(cam_fp)
	cam_fp.look_at(Vector3(0.0, 0.0, -12.192), Vector3.UP)
	cam_fp.current = true
	await settle(4)
	var p_px: Vector2 = cam_fp.unproject_position(Vector3(0.1, 0.25, -12.15))
	var img_pbase: Image = await snap_image("res://proofs/plume_dusk_base.png")
	var spark_base: int = spark_px(img_pbase, p_px)
	main.fx.debug_fire_plume(ImpactFX.KIND_SAND,
		Vector3(0.1, 0.03, -11.95), Vector3(0.0, 0.0, -1.0), 1.0)
	await create_timer(0.30).timeout
	var img_pb1: Image = await snap_image("res://proofs/plume_dusk_1.png")
	await create_timer(0.45).timeout
	var img_pb2: Image = await snap_image("res://proofs/plume_dusk_2.png")
	await create_timer(0.45).timeout
	var img_pb3: Image = await snap_image("res://proofs/plume_dusk_3.png")
	# The burst must be VISIBLE in the sequence (llvmpipe's
	# slow frames land where they land - the best frame is
	# the evidence) and what shows must be warm sand, not
	# white sparks.
	# Fix Pass 37 recalibration: the visibility census counts
	# at a 0.15 delta, not 0.24. The burst is unchanged, but
	# its backdrop is - FP37 made the pit floor the sand's
	# true bright tan (the deformable surface), replacing
	# the darker apron sheet that used to cover it, so
	# sand grains over sand differ by less per pixel than
	# sand over apron did. (The spark and warmth censuses
	# below keep their 0.24 threshold untouched.)
	var burst_best: int = maxi(changed_px(img_pb1, img_pbase, p_px, 0.15),
		maxi(changed_px(img_pb2, img_pbase, p_px, 0.15),
			changed_px(img_pb3, img_pbase, p_px, 0.15)))
	check(burst_best > 100,
		"Fix Pass 32: at dusk the burst is plainly visible over the pit (%d changed samples)"
		% burst_best)
	var burst_warm: float = maxf(changed_warmth(img_pb1, img_pbase, p_px, 0.24),
		maxf(changed_warmth(img_pb2, img_pbase, p_px, 0.24),
			changed_warmth(img_pb3, img_pbase, p_px, 0.24)))
	check(burst_warm > 0.02,
		"Fix Pass 32: the burst's changed pixels are WARM sand (mean r-b %.3f)" % burst_warm)
	check(spark_px(img_pb1, p_px) <= spark_base,
		"Fix Pass 32: the burst adds NO spark-white pixels at dusk (%d over baseline %d)"
		% [spark_px(img_pb1, p_px), spark_base])
	check(spark_px(img_pb2, p_px) <= spark_base,
		"Fix Pass 32: mid-burst, still no spark-white pixels (%d over baseline %d)"
		% [spark_px(img_pb2, p_px), spark_base])
	check(spark_px(img_pb3, p_px) <= spark_base,
		"Fix Pass 32: late burst, still no spark-white pixels (%d over baseline %d)"
		% [spark_px(img_pb3, p_px), spark_base])
	# +2 s after the landing: nothing emitting, clean air
	# (no pixel in the box changed beyond the scene's own
	# slow dusk drift).
	await create_timer(1.4).timeout
	await settle(2)
	check(not main.fx.debug_any_plume_emitting(),
		"Fix Pass 32: at +2 s no plume slot is still emitting")
	var img_pclean: Image = await snap_image("res://proofs/plume_dusk_clean.png")
	var clean_diff: float = region_mean_diff(img_pclean, img_pbase, p_px, 90)
	check(changed_px(img_pclean, img_pbase, p_px, 0.33) <= 4 and clean_diff < 0.02,
		"Fix Pass 32: at +2 s the pit air is clean (%d strong-changed samples, mean diff %.4f)"
		% [changed_px(img_pclean, img_pbase, p_px, 0.33), clean_diff])
	cam_fp.queue_free()
	main.set_time_of_day("NOON")
	await settle(4)

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
	var board_center: Vector3 = main.board_root.global_transform * Vector3(0.0, 2.0, 0.0)
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

	# --- Proof E: the round-end breakdown UP on the rear ---
	# SCOREBOARD (Fix Pass 39; Fix Pass 20's insert proof,
	# re-homed by FP38 to the billboard, now on the board
	# it always belonged on). A manufactured round ends the
	# way a real one does: the tabulation puts the
	# breakdown on the rear board. The four shoes are
	# parked settled around the stake.
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
	check(main.phase == "INSERT" and main.board_breakdown_up
		and main.board_breakdown_label.visible
		and not main.status_label.visible,
		"the round-end breakdown is UP on the rear scoreboard at the round's end")
	var lines_e: String = "\n".join(PackedStringArray(main.round_lines))
	check(main.board_breakdown_label.text == lines_e
		and lines_e.contains("YOU 1: 2.0 IN")
		and lines_e.contains("YOUR CLOSEST SHOE SCORES: +1")
		and lines_e.contains("MATCH: YOU 1 - 0 OPP"),
		"the scoreboard carries the round's breakdown")
	# Fix Pass 39 re-derives the old all-four-shoes framing
	# audit for the CLOSEUP camera: at baseline the stake
	# and the shoe lying at it fill the panel - both must
	# sit inside the closeup's view (the wide dud at 2.3 m
	# is out of frame BY DESIGN now - the camera is a
	# closeup, and the lie is its subject).
	check(main.insert_cam.is_position_in_frustum(main.STAKE_POS + Vector3(0.0, 0.1, 0.0))
		and main.insert_cam.is_position_in_frustum(park_spots[0]),
		"the pit closeup frames the stake and the shoe lying at it")
	# The judging frame: from the THROWING LINE, the way
	# the player reads it - the fresh-look scoreboard
	# beyond the pit with the breakdown up.
	var cam_e := Camera3D.new()
	cam_e.fov = 55.0
	cam_e.position = Vector3(0.8, 1.62, -0.364)
	main.add_child(cam_e)
	cam_e.look_at(board_center, Vector3.UP)
	cam_e.current = true
	await settle(4)
	await snap(cam_e, "res://proofs/board_breakdown.png")
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
	# The hands pass carries the held shoe out into open space
	# for this frame (the same move Proof B2 makes for its own
	# shot): at the station the hand now occludes the shoe from
	# the old close offset, and from farther back the station
	# top slab occludes both. The subject is unchanged - the
	# held shoe, in the hand, markers up.
	move_tracker(&"right_hand", Transform3D(Basis.IDENTITY, Vector3(0.25, 1.25, -0.55)))
	await settle(6)
	var shoe_pos: Vector3 = main.shoe.global_position
	var cam_b := Camera3D.new()
	cam_b.fov = 70.0
	cam_b.position = shoe_pos + Vector3(0.30, 0.22, 0.44)
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

	# --- Proof H: THE HANDS (the hands pass) ---
	# BASIC hands where the placeholder blocks stood, judged
	# from the PLAYER'S OWN EYE - a camera at the head's spot
	# looking down at the hands, the view Chris gets. Three
	# frames: both hands OPEN at rest; the right hand CLOSED
	# on a held shoe at the TOE grip; the same hand closed at
	# the SHANK grip. The wrap must read on both holds, and
	# the thumbs must sit on the correct sides (R thumb on
	# the frame-left of the right hand, palm down).
	set_grip(&"right_hand", 0.0)
	var rest_wait: float = 0.0
	while main.state != "STAND" and rest_wait < 20.0:
		await create_timer(0.25).timeout
		rest_wait += 0.25
	check(main.state == "STAND", "hands proofs: the dropped shoe restocked for the hand frames")
	var open_basis := Basis.from_euler(Vector3(deg_to_rad(-18.0), 0.0, 0.0))
	move_tracker(&"right_hand", Transform3D(open_basis, Vector3(0.23, 1.04, -0.34)))
	move_tracker(&"left_hand", Transform3D(open_basis, Vector3(-0.23, 1.04, -0.34)))
	set_grip(&"left_hand", 0.0)
	await settle(8)
	check(float(main.hand_curl_t["R"]) < 0.02 and float(main.hand_curl_t["L"]) < 0.02,
		"hands proofs: both hands stand OPEN at rest")
	var cam_h := Camera3D.new()
	cam_h.fov = 60.0
	cam_h.position = Vector3(0.0, 1.54, -0.02)
	main.add_child(cam_h)
	cam_h.look_at(Vector3(0.0, 1.01, -0.36), Vector3.UP)
	cam_h.current = true
	await settle(4)
	await snap(cam_h, "res://proofs/hands_open.png")
	cam_h.queue_free()
	# The toe grab through the tracker path (Proof B's idiom),
	# then the hand carried out to the open-lawn spot Proof B2
	# composed for, and the eye put where the player's head
	# rides relative to a held hand: above and behind it.
	move_tracker(&"right_hand", Transform3D(Basis.IDENTITY, main.shoe.zone_world_center("toe")))
	await settle(6)
	check(main.candidate_zone == "toe", "hands proofs: the right hand acquires the toe zone")
	set_grip(&"right_hand", 1.0)
	await settle(8)
	check(main.state == "HELD" and main.held_zone == "toe",
		"hands proofs: the toe grab holds through the tracker input")
	move_tracker(&"right_hand", Transform3D(Basis.IDENTITY, Vector3(0.25, 1.25, -0.55)))
	await settle(8)
	var hand_pos_h: Vector3 = main.hand_ctrl["R"].global_position
	var cam_h2 := Camera3D.new()
	cam_h2.fov = 62.0
	cam_h2.position = hand_pos_h + Vector3(0.16, 0.33, 0.42)
	main.add_child(cam_h2)
	cam_h2.look_at(hand_pos_h + Vector3(0.0, -0.03, -0.02), Vector3.UP)
	cam_h2.current = true
	await settle(4)
	await snap(cam_h2, "res://proofs/hands_toe.png")
	# One X press cycles TOE -> SHANK - TOE (the home shank);
	# the same closed hand, the same eye.
	set_button(&"left_hand", &"ax_button", true)
	await settle(5)
	set_button(&"left_hand", &"ax_button", false)
	await settle(5)
	check(main.held_zone == "shank_right",
		"hands proofs: the grip cycles to the home shank (got '%s')" % main.held_zone)
	await settle(4)
	await snap(cam_h2, "res://proofs/hands_shank.png")
	cam_h2.queue_free()
	set_grip(&"right_hand", 0.0)
	await settle(8)

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

	# --- Proof F36a: THE SHELF on the player's OWN side ---
	# (Fix Pass 36, the Shelf War Treaty. FP35 built the
	# two corner stations at the fountain's latitude but
	# assigned each to the owner across the lane; Chris's
	# verdict: "Player shelf is on wrong side. AI shelf is
	# on wrong side. switch em." So: the player's shelf on
	# HIS side (+x), the AI's station on its side (-x), IN
	# FRONT OF THE FOUNTAIN - the fountain directly behind
	# the AI's station now.)
	var shelf_slot: Vector3 = main.rack_slot_tf(40, false, 0).origin
	check(shelf_slot.distance_to(main.SHELF_SLOT0) < 0.01,
		"FP36 proofs: the player's game shoes stock at his shelf slot")
	var ai_slot: Vector3 = main.rack_slot_tf(40, true, 0).origin
	check(ai_slot.distance_to(main.AI_SLOT0) < 0.01,
		"FP36 proofs: the AI's game shoes stock at its station slot")
	check(shelf_slot.x > 0.0 and ai_slot.x < 0.0,
		"FP36 proofs: OWNERSHIP - the player's shelf stands on HIS side (+x), the AI's on its side (-x)")
	check(absf(ai_slot.z - main.STAGE_B_FOUNTAIN_POS.z) < 0.01
		and ai_slot.x > main.STAGE_B_FOUNTAIN_POS.x,
		"FP36 proofs: the AI station stands in front of the fountain, at its latitude - the fountain behind IT now")
	check(absf(ai_slot.x + shelf_slot.x) < 0.01
		and absf(ai_slot.z - shelf_slot.z) < 0.01,
		"FP36 proofs: the two stations mirror across the lane axis")
	# The stocked pairs themselves, per owner: each pair
	# hangs at its own station wearing its owner's colour -
	# the fact the plan frame below has to SHOW. Stage it
	# through the production gather (the Impact Dressing
	# section's idiom) so the pairs stand stocked whatever
	# the earlier proofs left lying around.
	main._gather_to_rail(40)
	await settle(4)
	for pi: int in 2:
		var pshoe: Shoe = main.player_pair[pi]
		check(pshoe.global_position.distance_to(
				main.rack_slot_tf(40, false, pi).origin) < 0.01
			and pshoe.tint == main.PLAYER_PAIR_COLOR,
			"FP36 proofs: the player's yellow shoe %d hangs at HIS shelf (+2.14)" % pi)
		var ashoe: Shoe = main.ai_pair[pi]
		check(ashoe.global_position.distance_to(
				main.rack_slot_tf(40, true, pi).origin) < 0.01
			and ashoe.tint == main.AI_PAIR_COLOR,
			"FP36 proofs: the AI's blue shoe %d hangs at ITS station (-2.14, in front of the fountain)" % pi)
	var cam_f36a := Camera3D.new()
	cam_f36a.fov = 55.0
	cam_f36a.position = Vector3(0.2, 1.5, -0.4)
	main.add_child(cam_f36a)
	cam_f36a.look_at(Vector3(shelf_slot.x, 0.8, shelf_slot.z), Vector3.UP)
	cam_f36a.current = true
	await settle(6)
	await snap(cam_f36a, "res://proofs/proof_shelf.png")
	# The glance: standing at the spot, head turned along
	# the shelf's own bearing (66 deg off the pit axis) -
	# a glance RIGHT now, to his own side.
	cam_f36a.position = Vector3(0.8, 1.62, -0.914)
	cam_f36a.fov = 70.0
	cam_f36a.look_at(Vector3(shelf_slot.x, 0.85, shelf_slot.z), Vector3.UP)
	await settle(4)
	await snap(cam_f36a, "res://proofs/proof_shelf_glance.png")
	cam_f36a.queue_free()

	# --- Proof F36b: THE PLAN - both stations, OWNED ---
	# High oblique from the house side (a straight-down
	# plan hid FP35's pairs under the top shelves - two
	# boxes, no owners; that gap is part of why this pass
	# exists): the player's shelf on the RIGHT of frame
	# with his YELLOW pair hanging on it, the AI's station
	# on the LEFT with its BLUE pair, the fountain directly
	# behind the AI's station, the patio's two front
	# corners between them.
	var cam_f36b := Camera3D.new()
	cam_f36b.fov = 50.0
	cam_f36b.position = Vector3(0.0, 9.5, 3.4)
	main.add_child(cam_f36b)
	cam_f36b.look_at(Vector3(0.0, 0.0, -1.55), Vector3.UP)
	cam_f36b.current = true
	await settle(6)
	await snap(cam_f36b, "res://proofs/proof_stations_plan.png")
	cam_f36b.queue_free()

	# --- Proof F36c: THE AI'S STATION from the AI's spot ---
	# The mirrored glance: from the AI's throwing spot, its
	# station abeam outboard on ITS OWN side, the fountain
	# directly behind it.
	var cam_f36c := Camera3D.new()
	cam_f36c.fov = 70.0
	cam_f36c.position = Vector3(-0.8, 1.62, -0.914)
	main.add_child(cam_f36c)
	cam_f36c.look_at(Vector3(ai_slot.x, 0.85, ai_slot.z), Vector3.UP)
	cam_f36c.current = true
	await settle(4)
	await snap(cam_f36c, "res://proofs/proof_ai_shelf.png")
	cam_f36c.queue_free()

	# --- Proof F39a: THE BILLBOARD'S LIVE FEED, from the ---
	# throwing spot (Fix Pass 38's proof, re-derived by
	# Fix Pass 39: the panel is CAM ONLY now, and the
	# camera behind it is the smart closeup - the suite
	# samples the feed texture across a staged flight and
	# asserts the pit picture changes, snaps the follow
	# mid-flight, and snaps the held lie closeup after the
	# settle. A frozen panel is a fail.)
	main._enter_practice()
	await settle(4)
	check(main.insert_root.visible
		and (main.insert_screen.mesh as QuadMesh).size == main.BILLBOARD_FEED_LIVE
		and main.insert_root.global_transform.origin.distance_to(
			main.billboard_transform().origin) < 0.001
		and main.insert_root.global_transform.basis.is_equal_approx(
			main.billboard_transform().basis),
		"FP39 proofs: the billboard stands at its fixed transform, cam only, feed full-panel")
	# A subject for the feed: one player shoe parked at the
	# stake, its lie the thing the feed exists to show.
	var feed_shoe: Shoe = main.player_pair[0]
	feed_shoe.freeze = true
	feed_shoe.global_position = Vector3(0.18, 0.06, -12.05)
	main.shoe_status[feed_shoe] = "DOWN"
	await settle(40) # idle pulses (0.5 s cadence) refresh the feed
	var feed_idle: Image = main.insert_viewport.get_texture().get_image()
	check(mean_luminance(feed_idle) > 0.02,
		"FP38 proofs: the idle feed has a picture - the lazy pulse renders (mean luminance %.3f)" % mean_luminance(feed_idle))
	# A staged flight INTO the pit (the F34c idiom): while
	# it flies the feed runs hot; after it lands the pit
	# holds two shoes where it held one.
	var fly_shoe: Shoe = main.ai_pair[1]
	var fstart := Vector3(-1.6, 1.1, -9.4)
	# Arced to land right-of-stake in the pit, clear of the
	# parked shoe - the feed's changed region is the whole
	# arrived shoe, not a nudge of the parked one.
	var fvel := Vector3(2.5, 2.93, -3.72)
	fly_shoe.freeze = false
	fly_shoe.sleeping = false
	fly_shoe.global_transform = Transform3D(Basis.IDENTITY, fstart)
	fly_shoe.linear_velocity = fvel
	fly_shoe.angular_velocity = Vector3(-6.0, 0.0, 0.0)
	main.shoe_status[fly_shoe] = "FLYING"
	main.ai_flight[fly_shoe] = {
		"fly_time": 0.0, "still_time": 0.0,
		"pos_still": 0.0, "pos_anchor": fstart,
		"flip": 0.0, "turn": 0.0,
		"has_contact": false, "first_contact_pos": Vector3.ZERO,
		"release": {"basis": Basis.IDENTITY, "pos": fstart,
			"vel": fvel, "ang": Vector3(-6.0, 0.0, 0.0)},
		"line_ft": 40,
	}
	# The production release path's recorder call, so the
	# settle engages the camera's lie hold like a real
	# throw's (and the flight is on the record).
	main._pitcam_begin_record(fly_shoe)
	# The judging camera stands at the throwing spot from
	# here: it snaps the follow mid-flight and the lie
	# after the settle.
	var cam_f39a := Camera3D.new()
	cam_f39a.fov = 55.0
	cam_f39a.position = Vector3(0.8, 1.62, -0.914)
	main.add_child(cam_f39a)
	cam_f39a.look_at(main.billboard_transform().origin, Vector3.UP)
	cam_f39a.current = true
	var feed_mid: Image = null
	var flight_snapped: bool = false
	var ft0: int = Time.get_ticks_msec()
	while Time.get_ticks_msec() - ft0 < 5000:
		await process_frame
		if feed_mid == null and Time.get_ticks_msec() - ft0 > 400:
			feed_mid = main.insert_viewport.get_texture().get_image()
		# Proof (a): MID-FLIGHT, the shoe closing on the pit
		# - the panel must show the camera's closeup follow.
		if not flight_snapped and main.ai_flight.has(fly_shoe) \
				and fly_shoe.global_position.distance_to(main.STAKE_POS) < 2.6:
			flight_snapped = true
			await snap(cam_f39a, "res://proofs/proof_billboard_flight.png")
		if feed_mid != null and not main.ai_flight.has(fly_shoe):
			break
	check(flight_snapped,
		"FP39 proofs: the mid-flight follow frame was caught (shoe inside 2.6 m of the stake)")
	await settle(10)
	var feed_landed: Image = main.insert_viewport.get_texture().get_image()
	check(feed_mid != null and not main.ai_flight.has(fly_shoe),
		"FP38 proofs: the staged flight flew and settled in the pit")
	if feed_mid != null:
		# The diff runs at stride 2 over the whole frame:
		# idle -> landed must show the arrived shoe (and,
		# Fix Pass 39, the camera's own move to the lie
		# closeup), mid -> landed its fall.
		var diff_idle: int = 0
		var diff_mid: int = 0
		for gx: int in range(0, 1024, 2):
			for gy: int in range(0, 512, 2):
				var cl: Color = feed_landed.get_pixel(gx, gy)
				var ci: Color = feed_idle.get_pixel(gx, gy)
				if absf(ci.r - cl.r) + absf(ci.g - cl.g) + absf(ci.b - cl.b) > 0.25:
					diff_idle += 1
				var cm: Color = feed_mid.get_pixel(gx, gy)
				if absf(cm.r - cl.r) + absf(cm.g - cl.g) + absf(cm.b - cl.b) > 0.25:
					diff_mid += 1
		check(diff_idle > 60 and diff_mid > 25,
			"FP39 proofs: the billboard feed texture UPDATES across a shoe's flight (idle->landed %d, mid->landed %d changed samples)" % [diff_idle, diff_mid])
	# Proof (b): the settled LIE - let the camera finish
	# easing into its lie closeup (the subject is the
	# staged shoe, down in the pit beside the parked one),
	# then the judging frame from the throwing spot: the
	# billboard at its bearing, the closeup of shoe +
	# stake on its face.
	await settle(45)
	check(main.pitcam_subject_pos.distance_to(fly_shoe.global_position) < 0.05
		and main.insert_cam.is_position_in_frustum(fly_shoe.global_position)
		and absf(main.insert_cam.fov - main.PITCAM_LIE_FOV) < 4.0,
		"FP39 proofs: after the settle the camera holds the lie closeup (fov %.1f)"
		% main.insert_cam.fov)
	await snap(cam_f39a, "res://proofs/proof_billboard_feed.png")
	cam_f39a.queue_free()

	# --- Proof F40: THE PULLED-LEFT ARRIVAL (Fix Pass 40) ---
	# A full-court throw from the production release point,
	# aimed 3.0 m LEFT of the stake through the calibrated
	# profile (the F39a staging idiom with base_release):
	# the throw that sent FP39's camera swinging way left.
	# Under the gate the camera holds the pit until the
	# shoe is well on its way, and the arrival closeup
	# frames the wide lie WITH the stake - composed, not
	# swung off. The judging frame is the billboard from
	# the throwing spot once the lie hold has eased in.
	var pull_shoe: Shoe = main.ai_pair[0]
	var pstart := Vector3(0.25, 1.25, -0.564)
	var prel: Dictionary = AIPitcher.base_release(
		pstart, main.STAKE_POS + Vector3(-3.0, 0.0, 0.0))
	var pvel: Vector3 = prel["vel"]
	var pang: Vector3 = prel["ang"]
	pull_shoe.freeze = false
	pull_shoe.sleeping = false
	pull_shoe.global_transform = Transform3D(prel["basis"] as Basis, pstart)
	pull_shoe.linear_velocity = pvel
	pull_shoe.angular_velocity = pang
	main.shoe_status[pull_shoe] = "FLYING"
	main.ai_flight[pull_shoe] = {
		"fly_time": 0.0, "still_time": 0.0,
		"pos_still": 0.0, "pos_anchor": pstart,
		"flip": 0.0, "turn": 0.0,
		"has_contact": false, "first_contact_pos": Vector3.ZERO,
		"release": {"basis": prel["basis"], "pos": pstart,
			"vel": pvel, "ang": pang},
		"line_ft": 40,
	}
	main._pitcam_begin_record(pull_shoe)
	var pull_gated: bool = false
	var pt0: int = Time.get_ticks_msec()
	while Time.get_ticks_msec() - pt0 < 9000:
		await process_frame
		if main.pitcam_gate_engaged:
			pull_gated = true
		if not main.ai_flight.has(pull_shoe):
			break
	check(pull_gated and not main.ai_flight.has(pull_shoe),
		"FP40 proofs: the pulled-left throw flew, settled, and the follow's gate engaged on the way (engaged %s, still flying %s)"
		% [str(pull_gated), str(main.ai_flight.has(pull_shoe))])
	await settle(45)
	check(main.pitcam_subject_pos.distance_to(pull_shoe.global_position) < 0.05
		and main.insert_cam.is_position_in_frustum(pull_shoe.global_position)
		and main.insert_cam.is_position_in_frustum(main.STAKE_POS + Vector3(0.0, 0.3, 0.0))
		and absf(main.insert_cam.fov - main.PITCAM_LIE_FOV) < 4.0,
		"FP40 proofs: the pulled shoe's arrival closeup frames the lie WITH the stake (fov %.1f, lie at %s)"
		% [main.insert_cam.fov, str(pull_shoe.global_position)])
	var cam_f40 := Camera3D.new()
	cam_f40.fov = 55.0
	cam_f40.position = Vector3(0.8, 1.62, -0.914)
	main.add_child(cam_f40)
	cam_f40.look_at(main.billboard_transform().origin, Vector3.UP)
	cam_f40.current = true
	await settle(4)
	await snap(cam_f40, "res://proofs/proof_billboard_pull.png")
	cam_f40.queue_free()

	# --- Proof F41a: THE PIN CAM ARRIVAL (Fix Pass 41) ---
	# A full-court drive at the stake through the
	# calibrated profile (the F40 staging idiom): the
	# director holds MAIN to the gate, projects the
	# landing on line, and cuts to the fixed camera
	# behind the stake. The committed frame is the feed
	# itself at the arrival, grabbed from the viewport
	# texture the moment the shoe closes inside 3.4 m -
	# the texture lags the physics by a render frame at
	# most, so the shoe reads in the air, coming at the
	# lens, the stake big in the foreground.
	var pin_shoe: Shoe = main.ai_pair[0]
	var pin_start := Vector3(0.25, 1.25, -0.564)
	# Aimed 0.35 m right of the stake: still dead on line
	# for the director (0.85 m band), but the shoe crosses
	# the pin frame BESIDE the post instead of hiding
	# behind its silhouette on the way in.
	var pin_rel: Dictionary = AIPitcher.base_release(
		pin_start, main.target_stake_pos() + Vector3(0.35, 0.0, 0.0))
	var pin_vel: Vector3 = pin_rel["vel"]
	var pin_ang: Vector3 = pin_rel["ang"]
	pin_shoe.freeze = false
	pin_shoe.sleeping = false
	pin_shoe.global_transform = Transform3D(pin_rel["basis"] as Basis, pin_start)
	pin_shoe.linear_velocity = pin_vel
	pin_shoe.angular_velocity = pin_ang
	main.shoe_status[pin_shoe] = "FLYING"
	main.ai_flight[pin_shoe] = {
		"fly_time": 0.0, "still_time": 0.0,
		"pos_still": 0.0, "pos_anchor": pin_start,
		"flip": 0.0, "turn": 0.0,
		"has_contact": false, "first_contact_pos": Vector3.ZERO,
		"release": {"basis": pin_rel["basis"], "pos": pin_start,
			"vel": pin_vel, "ang": pin_ang},
		"line_ft": 40,
	}
	main._pitcam_begin_record(pin_shoe)
	var pin_saw: bool = false
	var pin_grabbed: bool = false
	var pt41: int = Time.get_ticks_msec()
	while Time.get_ticks_msec() - pt41 < 9000:
		await physics_frame
		if main.pitcam_shot == "PIN":
			pin_saw = true
			if main.ai_flight.has(pin_shoe) \
					and pin_shoe.global_position.distance_to(main.STAKE_POS) < 3.4:
				# Sync to a completed render before reading
				# the texture back: under box load the last
				# physics frame's render can lag the shoe
				# by metres, and the earlier unsynced grabs
				# caught the feed well behind the flight.
				await RenderingServer.frame_post_draw
				var pimg: Image = main.insert_viewport.get_texture().get_image()
				pimg.save_png("res://proofs/proof_pincam_arrival.png")
				pin_grabbed = true
				break
		if not main.ai_flight.has(pin_shoe):
			break
	check(pin_saw and pin_grabbed,
		"FP41 proofs: the director cut to the PIN cam and the arrival frame was grabbed (cut %s, frame %s)"
		% [str(pin_saw), str(pin_grabbed)])
	var pt41b: int = Time.get_ticks_msec()
	while main.ai_flight.has(pin_shoe) and Time.get_ticks_msec() - pt41b < 9000:
		await physics_frame
	check(not main.ai_flight.has(pin_shoe),
		"FP41 proofs: the pin-cam drive settled in the pit")

	# --- Proof F41b: THE SIDE CAM SKID (Fix Pass 41) ---
	# The design probe's plowing toss (staged at the
	# pit, the F39a idiom): it lands at the pit's front
	# and plows a quarter metre through the sand. The
	# director cuts to the SIDE cam at the settle; the
	# committed frame is the feed during the lie hold -
	# the furrow read in profile.
	var skid_shoe: Shoe = main.ai_pair[1]
	var sk_start := Vector3(0.10, 0.80, -8.20)
	var sk_vel := Vector3(0.20, 0.80, -6.80)
	var sk_ang := Vector3(-9.0, 0.0, 0.0)
	skid_shoe.freeze = false
	skid_shoe.sleeping = false
	skid_shoe.global_transform = Transform3D(Basis.IDENTITY, sk_start)
	skid_shoe.linear_velocity = sk_vel
	skid_shoe.angular_velocity = sk_ang
	main.shoe_status[skid_shoe] = "FLYING"
	main.ai_flight[skid_shoe] = {
		"fly_time": 0.0, "still_time": 0.0,
		"pos_still": 0.0, "pos_anchor": sk_start,
		"flip": 0.0, "turn": 0.0,
		"has_contact": false, "first_contact_pos": Vector3.ZERO,
		"release": {"basis": Basis.IDENTITY, "pos": sk_start,
			"vel": sk_vel, "ang": sk_ang},
		"line_ft": 40,
	}
	main._pitcam_begin_record(skid_shoe)
	var st41: int = Time.get_ticks_msec()
	while main.ai_flight.has(skid_shoe) and Time.get_ticks_msec() - st41 < 9000:
		await physics_frame
	await settle(30)
	check(not main.ai_flight.has(skid_shoe)
		and main.dir_last_skid_m >= main.DIRECTOR_SKID_M
		and main.pitcam_shot == "SIDE",
		"FP41 proofs: the plow settled as a skid (%.3f m) and the SIDE cam holds its lie (shot %s)"
		% [main.dir_last_skid_m, main.pitcam_shot])
	var simg: Image = main.insert_viewport.get_texture().get_image()
	simg.save_png("res://proofs/proof_sidecam_skid.png")
	check(mean_luminance(simg) > 0.02,
		"FP41 proofs: the side-cam skid frame is a real picture (mean luminance %.3f)" % mean_luminance(simg))

	# --- Proof F41c: THE LEANER (Fix Pass 41) ---
	# The probe's staged leaner: a shoe tipped in against
	# the stake from a short drop beside it (the parked
	# shoes from the earlier proofs are moved off the
	# stake first). It settles through the production AI
	# settle path; the director names it a leaner and
	# cuts to SIDE for the profile read.
	feed_shoe.global_position = Vector3(1.9, 0.06, -10.4)
	pin_shoe.freeze = true
	pin_shoe.global_position = Vector3(2.2, 0.06, -10.8)
	main.shoe_status[pin_shoe] = "DOWN"
	var lean_shoe: Shoe = main.ai_pair[0]
	var ln_start := Vector3(0.13, 0.50, -12.19)
	var ln_vel := Vector3(-0.30, -0.20, 0.0)
	var ln_ang := Vector3(0.0, 0.0, 2.0)
	lean_shoe.freeze = false
	lean_shoe.sleeping = false
	lean_shoe.global_transform = Transform3D(Basis.IDENTITY, ln_start)
	lean_shoe.linear_velocity = ln_vel
	lean_shoe.angular_velocity = ln_ang
	main.shoe_status[lean_shoe] = "FLYING"
	main.ai_flight[lean_shoe] = {
		"fly_time": 0.0, "still_time": 0.0,
		"pos_still": 0.0, "pos_anchor": ln_start,
		"flip": 0.0, "turn": 0.0,
		"has_contact": false, "first_contact_pos": Vector3.ZERO,
		"release": {"basis": Basis.IDENTITY, "pos": ln_start,
			"vel": ln_vel, "ang": ln_ang},
		"line_ft": 40,
	}
	main._pitcam_begin_record(lean_shoe)
	var lt41: int = Time.get_ticks_msec()
	while main.ai_flight.has(lean_shoe) and Time.get_ticks_msec() - lt41 < 9000:
		await physics_frame
	await settle(30)
	check(not main.ai_flight.has(lean_shoe)
		and main.dir_last_leaner and main.pitcam_shot == "SIDE",
		"FP41 proofs: the dropped shoe settled as a LEANER and the SIDE cam holds it (shot %s)"
		% main.pitcam_shot)
	var limg: Image = main.insert_viewport.get_texture().get_image()
	limg.save_png("res://proofs/proof_sidecam_leaner.png")
	check(mean_luminance(limg) > 0.02,
		"FP41 proofs: the side-cam leaner frame is a real picture (mean luminance %.3f)" % mean_luminance(limg))

	# --- Proof F38b: THE BILLBOARD'S PLACEMENT ---
	# High oblique from the house side: the billboard LEFT
	# of the lane at halfway, its posts at the bed line,
	# its face angled back at the throwing end; the lane,
	# the berm and the pit run clear beside it.
	var cam_f38b := Camera3D.new()
	cam_f38b.fov = 50.0
	cam_f38b.position = Vector3(2.6, 6.8, -0.6)
	main.add_child(cam_f38b)
	cam_f38b.look_at(Vector3(-2.9, 0.4, -7.4), Vector3.UP)
	cam_f38b.current = true
	await settle(6)
	await snap(cam_f38b, "res://proofs/proof_billboard_plan.png")
	cam_f38b.queue_free()

	# --- Proof F38c: THE BILLBOARD IS SOLID ---
	# A staged flight straight at the panel (the F34c
	# idiom): the shoe must strike it, knock with the wood
	# voice through the FP34 contact path, and stay on the
	# lane side - never pass through. Sampled on physics
	# frames: at 7 m/s a process-frame sample could step
	# over the contact.
	var strike_shoe: Shoe = main.ai_pair[0]
	var bb_tf: Transform3D = main.billboard_transform()
	var bb_n: Vector3 = bb_tf.basis.z.normalized()
	var log0: int = main.fx.play_log.size()
	var sstart := Vector3(0.5, 2.5, -6.55)
	var svel := Vector3(-6.2, 1.35, 0.0)
	strike_shoe.freeze = false
	strike_shoe.sleeping = false
	strike_shoe.global_transform = Transform3D(Basis.IDENTITY, sstart)
	strike_shoe.linear_velocity = svel
	strike_shoe.angular_velocity = Vector3(0.0, 0.0, 3.0)
	main.shoe_status[strike_shoe] = "FLYING"
	main.ai_flight[strike_shoe] = {
		"fly_time": 0.0, "still_time": 0.0,
		"pos_still": 0.0, "pos_anchor": sstart,
		"flip": 0.0, "turn": 0.0,
		"has_contact": false, "first_contact_pos": Vector3.ZERO,
		"release": {"basis": Basis.IDENTITY, "pos": sstart,
			"vel": svel, "ang": Vector3(0.0, 0.0, 3.0)},
		"line_ft": 40,
	}
	var min_plane: float = 1e9
	var bounced: bool = false
	var st0: int = Time.get_ticks_msec()
	while Time.get_ticks_msec() - st0 < 6000:
		await physics_frame
		var sd: float = (strike_shoe.global_position - bb_tf.origin).dot(bb_n)
		min_plane = minf(min_plane, sd)
		# The bounce reads on the panel's own axis: the
		# face's normal points mostly down-lane (+z), so a
		# -x flight deflects along the normal rather than
		# reversing in x. Inbound v.n ~ -2.5; a bounce sends
		# it positive.
		if strike_shoe.linear_velocity.dot(bb_n) > 0.3:
			bounced = true
		if not main.ai_flight.has(strike_shoe) and Time.get_ticks_msec() - st0 > 800:
			break
	check(min_plane > -0.05,
		"FP38 proofs: the struck shoe never passed through the panel (closest plane approach %.2f m)" % min_plane)
	check(bounced,
		"FP38 proofs: the shoe BOUNCED off the billboard (velocity along the face normal reversed)")
	var knocked: bool = false
	for i: int in range(log0, main.fx.play_log.size()):
		var e: Dictionary = main.fx.play_log[i]
		if String(e["event"]) == "wood_knock":
			knocked = true
	check(knocked,
		"FP38 proofs: the billboard strike played the WOOD KNOCK through the FP34 contact path")
	check(not main.ai_flight.has(strike_shoe),
		"FP38 proofs: the struck shoe settled back on the lane side")

	# --- Proof F39b: THE RINGER REPLAY (Fix Pass 39) ---
	# A production ringer in practice (the smoke suite's
	# idiom: grab the stocked shoe, pose the hand on the
	# solved release, let go through _release_shoe): the
	# settle offers the flight to the replay, and the panel
	# must show the clone flying it in slow motion. The
	# outer camera wears the player's own cull mask, so in
	# this frame the clone exists ONLY on the billboard -
	# exactly what the headset shows.
	main._enter_practice()
	await settle(4)
	main.test_hand_tf["R"] = Transform3D(Basis.IDENTITY,
		main.shoe.zone_world_center("toe"))
	main.test_grip["R"] = 1.0
	await settle(6)
	for i39: int in 2:
		await physics_frame
	check(main.state == "HELD", "FP39 proofs: the replay proof's grab holds the shoe")
	var rp_line_z: float = main.game_line_z()
	var rp_release := Vector3(0.25, 1.25, rp_line_z + 0.35)
	var rp_rel: Dictionary = AIPitcher.base_release(
		rp_release, main.target_stake_pos())
	var rp_vel: Vector3 = rp_rel["vel"]
	var rp_ang: Vector3 = rp_rel["ang"]
	var rp_rel_tf: Transform3D = Shoe.hold_transform("toe", "R")
	var rp_basis: Basis = (rp_rel["basis"] as Basis) * rp_rel_tf.basis.inverse()
	main.test_hand_tf["R"] = Transform3D(rp_basis,
		rp_release - rp_basis * rp_rel_tf.origin)
	await settle(4)
	for i39b: int in 2:
		await physics_frame
	var rp_samples: Array = []
	var rp_axis: Vector3 = rp_ang.normalized()
	var rp_rate: float = rp_ang.length()
	var rp_now: float = float(Time.get_ticks_msec()) / 1000.0
	for i39c: int in 28:
		var rp_t: float = float(i39c - 27) / 90.0
		rp_samples.append(ThrowMath.make_sample(
			rp_now + rp_t,
			rp_release + rp_vel * rp_t,
			Quaternion(rp_axis, rp_rate * rp_t)))
	main.samples = rp_samples
	var rp_gov: bool = main.spin_governor_enabled
	main.spin_governor_enabled = false
	main._release_shoe(rp_samples)
	main.spin_governor_enabled = rp_gov
	main.grab_state.reset()
	main.test_grip["R"] = 0.0
	check(main.state == "FLYING", "FP39 proofs: the replay proof's ringer flies")
	var rp_wait39: float = 0.0
	while main.replay_state != "PLAYING" and rp_wait39 < 15.0:
		await create_timer(0.15).timeout
		rp_wait39 += 0.15
	check(main.replay_state == "PLAYING" and main.replay_clone != null
		and main.replay_clone.visible,
		"FP39 proofs: the settled ringer's slow-mo replay is playing on the billboard (state %s)"
		% String(main.replay_state))
	var cam_f39b := Camera3D.new()
	cam_f39b.fov = 55.0
	cam_f39b.cull_mask = main.VIS_LAYER_WORLD | main.VIS_LAYER_MAIN_ONLY
	cam_f39b.position = Vector3(0.8, 1.62, -0.914)
	main.add_child(cam_f39b)
	cam_f39b.look_at(main.billboard_transform().origin, Vector3.UP)
	cam_f39b.current = true
	await settle(4)
	await snap(cam_f39b, "res://proofs/proof_billboard_replay.png")
	cam_f39b.queue_free()
	var rp_end39: float = 0.0
	while main.replay_state != "IDLE" and rp_end39 < 12.0:
		await create_timer(0.2).timeout
		rp_end39 += 0.2
	check(main.replay_state == "IDLE" and not main.replay_clone.visible,
		"FP39 proofs: the replay ends and the live view is restored")

	# --- Proof F34c: A PLANT BENDS (Fix Pass 34) ---
	# A staged AI-pair flight straight through a left-bed
	# shrub: standing frame, a dense burst across the hit,
	# the peak, and the recovered frame. The flight is a
	# real RigidBody flight registered the production way;
	# the bend comes from the production flight watch.
	var bidx: int = -1
	var bground := Vector3.ZERO
	for i: int in main.landscape_plant_points.size():
		var pp: Dictionary = main.landscape_plant_points[i]
		var g: Vector3 = pp["ground"]
		if float(pp["flex"]) == 1.0 and float(pp["r"]) >= 0.24 \
				and g.x < -2.5 and g.z > -8.5 and g.z < -5.0:
			bidx = i
			bground = g
			break
	check(bidx >= 0, "FP34 proofs: a staging shrub was found in the left bed")
	if bidx >= 0:
		# A smaller frame for the burst section: the dense
		# frames need render rate, and software GL at
		# 1280x720 only manages ~2 fps here.
		root.size = Vector2i(640, 360)
		await settle(4)
		var cam_f34c := Camera3D.new()
		cam_f34c.fov = 42.0
		cam_f34c.position = bground + Vector3(-1.55, 0.5, 1.15)
		main.add_child(cam_f34c)
		cam_f34c.look_at(bground + Vector3(0.0, 0.42, 0.0), Vector3.UP)
		cam_f34c.current = true
		await settle(6)
		await snap(cam_f34c, "res://proofs/proof_bend_standing.png")
		var bs: Shoe = main.ai_pair[1]
		var bstart: Vector3 = bground + Vector3(-1.7, 0.52, 0.0)
		var bvel := Vector3(6.5, 0.4, 0.0)
		bs.freeze = false
		bs.sleeping = false
		bs.global_transform = Transform3D(Basis.IDENTITY, bstart)
		bs.linear_velocity = bvel
		bs.angular_velocity = Vector3(0.0, 0.0, -9.0)
		main.shoe_status[bs] = "FLYING"
		main.ai_flight[bs] = {
			"fly_time": 0.0, "still_time": 0.0,
			"pos_still": 0.0, "pos_anchor": bstart,
			"flip": 0.0, "turn": 0.0,
			"has_contact": false, "first_contact_pos": Vector3.ZERO,
			"release": {"basis": Basis.IDENTITY, "pos": bstart,
				"vel": bvel, "ang": Vector3(0.0, 0.0, -9.0)},
			"line_ft": 40,
		}
		var bend_t0: int = Time.get_ticks_msec()
		var burst_i: int = 0
		var peak_ang: float = 0.0
		var peak_snapped: bool = false
		while Time.get_ticks_msec() - bend_t0 < 2400:
			await process_frame
			var ang: float = absf(main.debug_plant_bend_angle(bidx))
			peak_ang = maxf(peak_ang, ang)
			var el: float = float(Time.get_ticks_msec() - bend_t0) / 1000.0
			if el >= float(burst_i) * 0.1 and burst_i < 24:
				await snap_image("res://proofs/proof_bend_%02d.png" % burst_i)
				burst_i += 1
			if ang > 0.18 and not peak_snapped:
				peak_snapped = true
				await snap_image("res://proofs/proof_bend_peak.png")
		check(peak_ang > 0.15,
			"FP34 proofs: the struck shrub visibly bent (peak %.2f rad)" % peak_ang)
		var rec_t: int = 0
		while main.debug_active_bends() > 0 and rec_t < 40:
			await create_timer(0.1).timeout
			rec_t += 1
		await settle(4)
		await snap(cam_f34c, "res://proofs/proof_bend_recovered.png")
		check(main.debug_active_bends() == 0,
			"FP34 proofs: the shrub sprang back and the spring went idle")
		cam_f34c.queue_free()

	DirAccess.remove_absolute(ProjectSettings.globalize_path(rec_path))
	print("---")
	if failures == 0:
		print("PROOFS: ALL %d CHECKS PASSED" % checks)
	else:
		print("PROOFS: %d of %d CHECKS FAILED" % [failures, checks])
	quit(1 if failures > 0 else 0)
