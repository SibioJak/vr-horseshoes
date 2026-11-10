extends SceneTree
## Arrival-condition sand measurement (Fix Pass 23): tumbling
## shoes pitched at the pit with real 40 ft flip arrival energy,
## at REAL PACING (Engine.time_scale = 1.0). The old
## tests/sand_measure.gd flat drops cannot see the failure this
## suite exists for - a tumbling arrival whose leading corner
## grabs the sand and vaults - so here every arrival is a real
## AIPitcher.base_release flip from the real release point,
## aimed at points inside the pit but off the stake (the
## surface, not the stake, is what is measured).
## Per arrival, in sand_measure's metric language:
##   bounce_m - the shoe centre's rise during its first
##     airborne rebound after first pit contact (0 if it never
##     leaves the surface again)
##   rise_m - the brief's own metric: the peak rebound height
##     of the shoe centre after first sand contact, measured
##     as the highest centre point reached after the impact
##     squash (the centre's first local minimum) minus that
##     minimum. A tumbling shoe can pinwheel - centre rising
##     as it vaults over a grabbed corner - without ever
##     being fully airborne, which bounce_m cannot see.
##   travel_m - horizontal distance from first pit contact to
##     the settled position
##   left_pit - the settled centre lies outside the pit
##     footprint although the first contact was inside it (the
##     comedic ejection; the pass target is zero)
## Two classes: GAME (the production flip profile) and HARD
## (the same target solved with a 1.19 s flight instead of
## 1.40 s - a flatter, hotter arrival on the same aim point).
## Run: godot --headless --path . --script tests/sand_arrival.gd
##   [--label=pre|post]

const MAX_FRAMES: int = 900

var main: Node
var pit_bodies: Array = []
var label: String = "run"
var _probe_shoe: Shoe = null
var _pit_contact_origin := Vector3.ZERO
var _pit_contact_seen: bool = false


func _initialize() -> void:
	_run()


func _on_probe_body_entered(body: Node) -> void:
	if not _pit_contact_seen and pit_bodies.has(body):
		_pit_contact_seen = true
		_pit_contact_origin = _probe_shoe.global_position


## The sand body is the one absorbent body in the scene (its
## physics material is the giveaway before Fix Pass 23) and a
## member of the "sand" group after it - accept either.
func _find_pit_bodies() -> void:
	pit_bodies.clear()
	for child: Node in main.get_children():
		if child is StaticBody3D:
			var sb := child as StaticBody3D
			var is_sand: bool = sb.is_in_group("sand")
			if not is_sand and sb.physics_material_override != null:
				is_sand = sb.physics_material_override.absorbent
			if is_sand and absf(sb.position.x - main.STAKE_POS.x) < 0.01 \
					and absf(sb.position.z - main.STAKE_POS.z) < 0.01:
				pit_bodies.append(sb)


func _run_arrival(shoe_node: Shoe, rel: Dictionary) -> Dictionary:
	_pit_contact_seen = false
	_pit_contact_origin = Vector3.ZERO
	# Fix Pass 37: a faithful release resets the guard AND
	# the absorption/flight-stamp state, exactly as main's
	# release paths do (reset_stake_guard) - without it the
	# flight's sand stamp bleeds across arrivals.
	shoe_node.reset_stake_guard()
	shoe_node.freeze = true
	shoe_node.global_transform = Transform3D(rel["basis"], rel["pos"])
	shoe_node.linear_velocity = Vector3.ZERO
	shoe_node.angular_velocity = Vector3.ZERO
	await physics_frame
	await physics_frame
	shoe_node.linear_velocity = rel["vel"]
	shoe_node.angular_velocity = rel["ang"]
	shoe_node.freeze = false
	var contact_origin := Vector3.ZERO
	var have_contact: bool = false
	var contact_in_pit: bool = false
	var rebound_apex: float = 0.0
	var airborne_after: bool = false
	var bounce_done: bool = false
	var bounce_m: float = 0.0
	var squash_min: float = INF
	var squash_frames: int = 0
	var rise_peak: float = 0.0
	var still: int = 0
	var settled_pos: Vector3 = shoe_node.global_position
	var frame: int = 0
	while frame < MAX_FRAMES:
		await physics_frame
		frame += 1
		var pos: Vector3 = shoe_node.global_position
		var touching: bool = shoe_node.get_contact_count() > 0
		if not have_contact:
			if _pit_contact_seen:
				have_contact = true
				contact_origin = _pit_contact_origin
				contact_in_pit = absf(contact_origin.x) <= 0.457 \
					and absf(contact_origin.z - main.STAKE_POS.z) <= 0.914
			continue
		# Rise tracking: the squash is the centre's minimum in
		# the first ~0.2 s after contact; the rebound is how
		# high the centre climbs after that minimum.
		if squash_frames < 12:
			squash_frames += 1
			squash_min = minf(squash_min, pos.y)
		else:
			rise_peak = maxf(rise_peak, pos.y)
		if not bounce_done:
			if not touching:
				airborne_after = true
				rebound_apex = maxf(rebound_apex, pos.y)
			elif airborne_after:
				bounce_m = maxf(0.0, rebound_apex - contact_origin.y)
				bounce_done = true
		if frame > 30:
			if shoe_node.linear_velocity.length() < 0.10 \
					and shoe_node.angular_velocity.length() < 0.30:
				still += 1
			else:
				still = 0
			if still > 18:
				settled_pos = pos
				break
		settled_pos = pos
	shoe_node.freeze = true
	if have_contact and not bounce_done:
		bounce_m = 0.0
	var travel: float = 0.0
	var left_pit: bool = false
	var rise_m: float = 0.0
	if have_contact:
		travel = Vector2(settled_pos.x - contact_origin.x,
			settled_pos.z - contact_origin.z).length()
		left_pit = contact_in_pit and (absf(settled_pos.x) > 0.457 \
			or absf(settled_pos.z - main.STAKE_POS.z) > 0.914)
		if squash_min < INF and rise_peak > 0.0:
			rise_m = maxf(0.0, rise_peak - squash_min)
	# Fix Pass 37: run the production sink (main's settle
	# helper) and read the law's number - how far the shoe's
	# lowest point ends below the sand plane (0.002). on_sand
	# marks a rest ON the sand itself (not perched on the
	# stake, a frame, or out on the lawn), read before sinking.
	var pen: float = -1.0
	var on_sand: bool = false
	var fstr: float = shoe_node.flight_sand_strength()
	if have_contact:
		var low0: float = shoe_node.lowest_point_y()
		on_sand = main._sand_surface_at(settled_pos) != null \
			and low0 >= 0.002 - 0.006 and low0 <= 0.002 + 0.008
		main._sink_settled_shoe(shoe_node)
		pen = 0.002 - shoe_node.lowest_point_y()
	return {"contact": have_contact, "bounce_m": bounce_m,
		"rise_m": rise_m, "travel_m": travel, "left_pit": left_pit,
		"pen_m": pen, "strength": fstr, "on_sand": on_sand,
		"settled": settled_pos}


func _sorted_stat(values: Array, frac: float) -> float:
	var s: Array = values.duplicate()
	s.sort()
	var idx: int = clampi(int(round(frac * float(s.size() - 1))), 0, s.size() - 1)
	return float(s[idx])


## The production flip solved for a different flight time
## (the HARD class): same construction as AIPitcher.base_release
## - cross the target's plane at 0.22 m, one full revolution,
## phase 59 deg - over T seconds instead of FLIGHT_T.
func _ballistic(from_pos: Vector3, target: Vector3, t: float) -> Dictionary:
	var vel := Vector3(
		(target.x - from_pos.x) / t,
		(0.22 - from_pos.y + 0.5 * 9.8 * t * t) / t,
		(target.z - from_pos.z) / t)
	var flat := Vector3(target.x - from_pos.x, 0.0, target.z - from_pos.z)
	var yaw_basis := Basis(Vector3.UP, atan2(-flat.x, -flat.z))
	var basis: Basis = yaw_basis * Basis(Vector3(1.0, 0.0, 0.0), deg_to_rad(59.0)) \
		* Basis(Vector3.UP, PI)
	var ang: Vector3 = yaw_basis * Vector3(TAU / t, 0.0, 0.0)
	return {"pos": from_pos, "basis": basis, "vel": vel, "ang": ang}


func _run() -> void:
	Engine.time_scale = 1.0
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--label="):
			label = arg.trim_prefix("--label=")
	var packed: PackedScene = load("res://main.tscn")
	main = packed.instantiate()
	root.add_child(main)
	await process_frame
	await physics_frame
	await physics_frame
	_find_pit_bodies()
	print("SAND ARRIVAL [%s]: time_scale %.1f, pit bodies found %d" % [
		label, Engine.time_scale, pit_bodies.size()])
	var shoe_node := Shoe.new()
	main.add_child(shoe_node)
	_probe_shoe = shoe_node
	shoe_node.body_entered.connect(_on_probe_body_entered)
	await physics_frame
	var from_pos: Vector3 = AIPitcher.release_base_pos(main.game_line_z())
	# Aim points inside the pit, off the stake, in (x, z)
	# offsets from the stake.
	var offsets: Array = [
		Vector2(0.25, 0.30), Vector2(-0.25, 0.30),
		Vector2(0.25, -0.30), Vector2(-0.25, -0.30),
		Vector2(0.0, 0.55), Vector2(0.0, -0.55),
		Vector2(0.30, 0.0), Vector2(-0.30, 0.0),
	]
	var speed_jitter: Array = [1.0, 0.985, 1.015]
	var classes: Array = [
		{"name": "GAME", "flight_t": 1.40, "reps": 3},
		{"name": "HARD", "flight_t": 1.19, "reps": 2},
	]
	var pen_med: Dictionary = {}
	for class_def: Dictionary in classes:
		var bounces: Array = []
		var rises: Array = []
		var travels: Array = []
		var pens: Array = []
		var strs: Array = []
		var contacts: int = 0
		var ejections: int = 0
		var total: int = 0
		for rep: int in int(class_def["reps"]):
			for oi: int in offsets.size():
				var off: Vector2 = offsets[oi]
				var aim := Vector3(main.STAKE_POS.x + off.x,
					main.STAKE_POS.y, main.STAKE_POS.z + off.y)
				var rel: Dictionary
				if float(class_def["flight_t"]) >= AIPitcher.FLIGHT_T:
					rel = AIPitcher.base_release(from_pos, aim)
				else:
					rel = _ballistic(from_pos, aim, float(class_def["flight_t"]))
				var vel: Vector3 = rel["vel"]
				rel["vel"] = vel * float(speed_jitter[rep % speed_jitter.size()])
				var res: Dictionary = await _run_arrival(shoe_node, rel)
				total += 1
				if bool(res["contact"]):
					contacts += 1
					bounces.append(float(res["bounce_m"]))
					rises.append(float(res["rise_m"]))
					travels.append(float(res["travel_m"]))
					if bool(res["on_sand"]):
						pens.append(float(res["pen_m"]))
						strs.append(float(res["strength"]))
					if bool(res["left_pit"]):
						ejections += 1
				# Park the shoe clear of the lane for the next one.
				shoe_node.global_transform = Transform3D(Basis.IDENTITY,
					Vector3(3.0, 0.4, -6.0))
		if contacts > 0:
			var pen_line: String = "pen n/a"
			if not pens.is_empty():
				pen_med[String(class_def["name"])] = _sorted_stat(pens, 0.5)
				pen_line = "pen med %.4f (n %d, strength med %.2f)" % [
					_sorted_stat(pens, 0.5), pens.size(),
					_sorted_stat(strs, 0.5)]
			print("SAND ARRIVAL [%s] %s: arrivals %d, pit contacts %d, bounce med %.3f p90 %.3f max %.3f m, rise med %.3f p90 %.3f max %.3f m, travel med %.3f p90 %.3f max %.3f m, ejections %d, %s" % [
				label, String(class_def["name"]), total, contacts,
				_sorted_stat(bounces, 0.5), _sorted_stat(bounces, 0.9),
				_sorted_stat(bounces, 1.0),
				_sorted_stat(rises, 0.5), _sorted_stat(rises, 0.9),
				_sorted_stat(rises, 1.0),
				_sorted_stat(travels, 0.5), _sorted_stat(travels, 0.9),
				_sorted_stat(travels, 1.0), ejections, pen_line])
		else:
			print("SAND ARRIVAL [%s] %s: NO pit contact in %d arrivals" % [
				label, String(class_def["name"]), total])
	# Fix Pass 37 - THE LAW'S OWN CLASSES: arrivals kept by
	# the sand stamp they actually recorded (the FP23 impact
	# strength of their first sand episode). A direct pit
	# strike saturates the stamp, so SOFT arrivals are
	# stake-struck drops (aimed at the iron, energy shed on
	# it) and MED are grazes and clips from the same lane -
	# the arrivals real play produces at the soft end.
	var pen_classes: Array = [
		{"name": "SOFT", "lo": 0.0, "hi": 0.35, "aims": [
			{"aim": Vector3(main.STAKE_POS.x, main.STAKE_POS.y,
				main.STAKE_POS.z), "t": 1.22, "jx": 0.05, "jz": 0.12},
		]},
		# MED arrivals: real play makes them by deflection
		# (stake grazes shed either ~all or ~nothing - too
		# binary to sample), so the rig makes them the other
		# honest way: a shorter flight from midway, whose
		# arrival speed at the sand IS mid-band (0.35..0.75
		# of the strength scale = 5.1..8.1 m/s). The class
		# measures the sand's answer to a mid-strength
		# impact, which is the law's question. A back-timber
		# clip family rides along for variety.
		{"name": "MED", "lo": 0.35, "hi": 0.75, "aims": [
			{"from": Vector3(from_pos.x, from_pos.y, -6.67),
				"aim": Vector3(main.STAKE_POS.x + 0.15, main.STAKE_POS.y,
					main.STAKE_POS.z + 0.20),
				"t": 0.90, "jx": 0.08, "jz": 0.15},
			{"from": Vector3(from_pos.x, from_pos.y, -6.67),
				"aim": Vector3(main.STAKE_POS.x - 0.10, main.STAKE_POS.y,
					main.STAKE_POS.z - 0.25),
				"t": 0.97, "jx": 0.08, "jz": 0.15},
			{"aim": Vector3(main.STAKE_POS.x, main.STAKE_POS.y,
				main.STAKE_POS.z - 0.86), "t": 1.22, "jx": 0.25, "jz": 0.10},
		]},
	]
	var rng := RandomNumberGenerator.new()
	rng.seed = 37037
	for pc: Dictionary in pen_classes:
		var pens2: Array = []
		var strs2: Array = []
		var attempts: int = 0
		while pens2.size() < 8 and attempts < 48:
			attempts += 1
			var fam: Dictionary = (pc["aims"] as Array)[attempts % (pc["aims"] as Array).size()]
			var aim2: Vector3 = fam["aim"]
			aim2.x += rng.randf_range(-float(fam["jx"]), float(fam["jx"]))
			aim2.z += rng.randf_range(-float(fam["jz"]), float(fam["jz"]))
			var from2: Vector3 = fam["from"] if fam.has("from") else from_pos
			var rel2: Dictionary = _ballistic(from2, aim2, float(fam["t"]))
			var res2: Dictionary = await _run_arrival(shoe_node, rel2)
			shoe_node.global_transform = Transform3D(Basis.IDENTITY,
				Vector3(3.0, 0.4, -6.0))
			if not bool(res2["contact"]) or not bool(res2["on_sand"]):
				continue
			var st2: float = float(res2["strength"])
			if st2 < float(pc["lo"]) or st2 >= float(pc["hi"]):
				continue
			pens2.append(float(res2["pen_m"]))
			strs2.append(st2)
		if pens2.is_empty():
			print("SAND PEN [%s] %s: NO arrivals kept in %d attempts" % [
				label, String(pc["name"]), attempts])
		else:
			pen_med[String(pc["name"])] = _sorted_stat(pens2, 0.5)
			print("SAND PEN [%s] %s: kept %d of %d attempts, strength med %.2f, penetration med %.4f m min %.4f max %.4f" % [
				label, String(pc["name"]), pens2.size(), attempts,
				_sorted_stat(strs2, 0.5), _sorted_stat(pens2, 0.5),
				_sorted_stat(pens2, 0.0), _sorted_stat(pens2, 1.0)])
	print("SAND PEN [%s] SUMMARY: SOFT med %s / MED med %s / HARD med %s - the law wants SOFT < MED < HARD" % [
		label,
		("%.4f m" % float(pen_med["SOFT"])) if pen_med.has("SOFT") else "n/a",
		("%.4f m" % float(pen_med["MED"])) if pen_med.has("MED") else "n/a",
		("%.4f m" % float(pen_med["HARD"])) if pen_med.has("HARD") else "n/a"])
	quit(0)
