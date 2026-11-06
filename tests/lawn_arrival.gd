extends SceneTree
## Arrival-condition LAWN measurement (Fix Pass 24): the
## companion to tests/sand_arrival.gd, same metric language,
## at REAL PACING (Engine.time_scale = 1.0). Chris's law: a
## shoe that lands on the grass between player and pit dies
## in the grass - it does not roll or bounce its way into
## the pit. His evidence (throws-17, 2026-11-06): a throw
## first-touched at z = -9.4, travelled 2.66 m and settled
## IN the pit 6 in from the stake, conducted there by the
## lawn. The ground body is a hard slab with grass numbers
## (friction 0.7, bounce 0.35) - the sand disease, one body
## over (Fix Pass 23 cured the sand; the lawn was out of
## that pass's scope).
## Classes:
##   SHORT  - the production flip release with the velocity
##     scaled down (a real throw with less on it - same
##     motion, same tumble). Chris's case: first contact
##     around z = -9.4, ~1.9 m short of the pit's front edge.
##   MIDWAY - a flat ballistic arrival solved onto the lane
##     at z ~ -6, halfway down (a lob scaled down arrives
##     steep and spears in; the flat skidder is the disease).
##   FRONT  - informational: a flat arrival first-touching
##     a body-length short of the sand (z ~ -11.1); how many
##     still finish in the sand is reported, not gated.
##   TUMBLE - staged, not thrown: the shoe starts on the
##     corner strip INSIDE the pit's 6 ft box zone, pitched
##     onto a corner, tumbling diagonally in through the
##     pit's open mouth. These must still finish in the
##     sand - a legal tumble-in is real horseshoes.
##   STRIP-IN / STRIP-OUT - the exemption exercised
##     directly: a roll staged on the one patch of lawn
##     exposed inside the box (the strip beyond the side
##     timber) vs the same roll on open lawn outside the
##     box. In-box the roll must travel as far with the
##     bleed on as with it off; outside, it must die.
## Every arrival also prints its contact-step line: the
## centre position and collider kinds on the first step the
## shoe itself reports a contact - the convention the
## absorption reads, and the position the box-zone
## exemption is judged by.
## --no-turf runs the control: the lawn bleed disabled on
## the probe shoe, everything else identical.
## Per arrival: first-contact z, travel after touchdown
## (horizontal, first contact to settled centre), and
## whether the settled centre lies inside the pit footprint.
## Run: godot --headless --path . --script tests/lawn_arrival.gd
##   [--label=pre|post]

const MAX_FRAMES: int = 900

var main: Node
var ground_body: StaticBody3D = null
var label: String = "run"
var _probe_shoe: Shoe = null
var _contact_origin := Vector3.ZERO
var _contact_seen: bool = false
var _contact_body_kind: String = ""
var _frame_contact_kind: String = ""
var _frame_contact_pos := Vector3.ZERO


func _initialize() -> void:
	_run()


func _on_probe_body_entered(body: Node) -> void:
	if not _contact_seen:
		_contact_seen = true
		_contact_origin = _probe_shoe.global_position
		if body.is_in_group("sand"):
			_contact_body_kind = "sand"
		elif body == ground_body:
			_contact_body_kind = "turf"
		else:
			_contact_body_kind = "other"


## The lawn is the one yard-wide static body (the sand, the
## timbers and the stations are all small). Identify it by
## its collision footprint so this rig runs identically on
## the pre-fix code (no group) and the post-fix code.
func _find_ground_body() -> void:
	ground_body = null
	for child: Node in main.get_children():
		if child is StaticBody3D:
			for sub: Node in (child as StaticBody3D).get_children():
				if sub is CollisionShape3D:
					var sh: Shape3D = (sub as CollisionShape3D).shape
					if sh is BoxShape3D and (sh as BoxShape3D).size.x >= 10.0:
						ground_body = child as StaticBody3D
						return


func _wait_settle(shoe_node: Shoe) -> Vector3:
	var still: int = 0
	var frame: int = 0
	var settled_pos: Vector3 = shoe_node.global_position
	while frame < MAX_FRAMES:
		await physics_frame
		frame += 1
		settled_pos = shoe_node.global_position
		if frame > 30:
			if shoe_node.linear_velocity.length() < 0.10 \
					and shoe_node.angular_velocity.length() < 0.30:
				still += 1
			else:
				still = 0
			if still > 18:
				break
	return settled_pos


## Poll for the first frame the shoe itself reports a
## contact: the centre position and collider kinds on the
## contact step - the same convention the shoe's absorption
## reads in _integrate_forces (body_entered's callback can
## lag a step behind it, which matters at the box line).
func _await_contact_frame(shoe_node: Shoe) -> void:
	_frame_contact_kind = ""
	_frame_contact_pos = Vector3.ZERO
	var guard: int = 0
	while guard < 600:
		await physics_frame
		guard += 1
		if shoe_node.get_contact_count() > 0:
			_frame_contact_pos = shoe_node.global_position
			var kinds: Array = []
			for obj: Node in shoe_node.get_colliding_bodies():
				if obj != null and obj.is_in_group("sand"):
					if not kinds.has("sand"):
						kinds.append("sand")
				elif obj == ground_body:
					if not kinds.has("turf"):
						kinds.append("turf")
				elif not kinds.has("other"):
					kinds.append("other")
			_frame_contact_kind = "/".join(PackedStringArray(kinds))
			return


func _run_thrown(shoe_node: Shoe, rel: Dictionary) -> Dictionary:
	_contact_seen = false
	_contact_origin = Vector3.ZERO
	shoe_node.freeze = true
	shoe_node.global_transform = Transform3D(rel["basis"], rel["pos"])
	shoe_node.linear_velocity = Vector3.ZERO
	shoe_node.angular_velocity = Vector3.ZERO
	await physics_frame
	await physics_frame
	shoe_node.linear_velocity = rel["vel"]
	shoe_node.angular_velocity = rel["ang"]
	shoe_node.freeze = false
	await _await_contact_frame(shoe_node)
	var settled_pos: Vector3 = await _wait_settle(shoe_node)
	shoe_node.freeze = true
	return _score(settled_pos)


func _run_staged(shoe_node: Shoe, from_pos: Vector3, vel: Vector3,
		ang: Vector3) -> Dictionary:
	_contact_seen = false
	_contact_origin = Vector3.ZERO
	shoe_node.freeze = true
	shoe_node.global_transform = Transform3D(Basis.IDENTITY, from_pos)
	shoe_node.linear_velocity = Vector3.ZERO
	shoe_node.angular_velocity = Vector3.ZERO
	await physics_frame
	await physics_frame
	shoe_node.linear_velocity = vel
	shoe_node.angular_velocity = ang
	shoe_node.freeze = false
	await _await_contact_frame(shoe_node)
	var settled_pos: Vector3 = await _wait_settle(shoe_node)
	shoe_node.freeze = true
	return _score(settled_pos)


func _score(settled_pos: Vector3) -> Dictionary:
	var travel: float = 0.0
	if _contact_seen:
		travel = Vector2(settled_pos.x - _contact_origin.x,
			settled_pos.z - _contact_origin.z).length()
	var in_pit: bool = absf(settled_pos.x) <= 0.457 \
		and absf(settled_pos.z - main.STAKE_POS.z) <= 0.914
	var fc_in_box: bool = absf(_frame_contact_pos.x - main.STAKE_POS.x) <= 0.914 \
		and absf(_frame_contact_pos.z - main.STAKE_POS.z) <= 0.914
	if _contact_seen:
		print("  arrival: fc (%s) z %.2f x %.2f, travel %.3f m, in pit %s | contact step: (%s) centre z %.2f x %.2f, in box %s" % [
			_contact_body_kind, _contact_origin.z, _contact_origin.x,
			travel, str(in_pit), _frame_contact_kind,
			_frame_contact_pos.z, _frame_contact_pos.x, str(fc_in_box)])
	return {"contact": _contact_seen,
		"fc_z": _contact_origin.z if _contact_seen else 0.0,
		"travel_m": travel, "in_pit": in_pit,
		"frame_kind": _frame_contact_kind, "fc_in_box": fc_in_box}


func _sorted_stat(values: Array, frac: float) -> float:
	var s: Array = values.duplicate()
	s.sort()
	var idx: int = clampi(int(round(frac * float(s.size() - 1))), 0, s.size() - 1)
	return float(s[idx])


func _report(cls_name: String, rows: Array) -> void:
	var fcs: Array = []
	var travels: Array = []
	var pits: int = 0
	var violations: int = 0
	for r: Dictionary in rows:
		if bool(r["contact"]):
			fcs.append(float(r["fc_z"]))
			travels.append(float(r["travel_m"]))
			if bool(r["in_pit"]):
				pits += 1
				# The law's violation: a lawn-first contact from
				# outside the box that still settles in the pit.
				if String(r["frame_kind"]).contains("turf") \
						and not bool(r["fc_in_box"]):
					violations += 1
	if fcs.is_empty():
		print("LAWN ARRIVAL [%s] %s: NO contact in %d arrivals" % [
			label, cls_name, rows.size()])
		return
	print("LAWN ARRIVAL [%s] %s: arrivals %d, fc_z med %.2f min %.2f max %.2f, travel med %.3f max %.3f m, settled in pit %d, lawn-first violations %d" % [
		label, cls_name, rows.size(),
		_sorted_stat(fcs, 0.5), _sorted_stat(fcs, 0.0), _sorted_stat(fcs, 1.0),
		_sorted_stat(travels, 0.5), _sorted_stat(travels, 1.0), pits,
		violations])


## The production flip solved for a different aim point and
## flight time (the sand rig's construction): cross the
## target's plane at 0.22 m, one full revolution, phase
## 59 deg. A flat, fast solve aimed down the lane produces
## the skidding arrival a velocity-scaled lob cannot - the
## lob arrives steep and spears in; Chris's disease is the
## flat one that hits and runs.
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
	_find_ground_body()
	print("LAWN ARRIVAL [%s]: time_scale %.1f, ground body found %s" % [
		label, Engine.time_scale, str(ground_body != null)])
	var shoe_node := Shoe.new()
	main.add_child(shoe_node)
	main._wire_guard(shoe_node, "FAR")
	if "--no-turf" in OS.get_cmdline_user_args():
		# Pre-fix equivalent on fixed code: the lawn bleed
		# off, everything else identical (the sand's stays on).
		shoe_node.turf_absorb_enabled = false
		print("LAWN ARRIVAL [%s]: turf absorption DISABLED (control)" % label)
	_probe_shoe = shoe_node
	shoe_node.body_entered.connect(_on_probe_body_entered)
	await physics_frame
	var from_pos: Vector3 = AIPitcher.release_base_pos(main.game_line_z())
	# SHORT: the production release with the velocity scaled
	# down - a real throw with less on it (Chris's case).
	var short_rows: Array = []
	for rep: int in 2:
		for f: float in [0.95, 0.93, 0.905, 0.88]:
			var rel: Dictionary = AIPitcher.base_release(
				from_pos, main.STAKE_POS)
			rel["vel"] = (rel["vel"] as Vector3) * f
			short_rows.append(await _run_thrown(shoe_node, rel))
			shoe_node.global_transform = Transform3D(Basis.IDENTITY,
				Vector3(3.0, 0.4, -6.0))
	_report("SHORT", short_rows)
	# MIDWAY + FRONT: flat ballistic arrivals solved onto
	# aim points down the lane (the crossing point sits
	# 0.22 m up; first contact lands a stride past it).
	var ballistic_classes: Array = [
		{"name": "MIDWAY", "aim_z": -6.6, "t": 0.68,
			"aim_xs": [-0.25, 0.0, 0.25]},
		{"name": "FRONT", "aim_z": -11.25, "t": 1.30,
			"aim_xs": [-0.15, 0.15]},
	]
	for class_def: Dictionary in ballistic_classes:
		var rows: Array = []
		for rep: int in 2:
			for ax: float in class_def["aim_xs"]:
				var aim := Vector3(main.STAKE_POS.x + ax,
					main.STAKE_POS.y, float(class_def["aim_z"]))
				var rel: Dictionary = _ballistic(
					from_pos, aim, float(class_def["t"]))
				rel["vel"] = (rel["vel"] as Vector3) * (0.99 if rep == 0 else 1.01)
				rows.append(await _run_thrown(shoe_node, rel))
				shoe_node.global_transform = Transform3D(Basis.IDENTITY,
					Vector3(3.0, 0.4, -6.0))
		_report(String(class_def["name"]), rows)
	# TUMBLE: staged in-box tumble-ins. The only lawn inside
	# the box a shoe can cross is the corner strip (the side
	# timbers guard the flanks): the shoe arrives over the
	# strip just inside the box's front edge with real energy,
	# pitched onto a corner, tumbling diagonally in through
	# the pit's open mouth toward the sand's front corner.
	# TUMBLE-OUT is the same arrival staged a step farther
	# out, first contact beyond the box's front edge - the
	# contrast that proves the exemption is the zone, not
	# the staging.
	var tumble_rows: Array = []
	var tumble_out_rows: Array = []
	for side: float in [1.0, -1.0]:
		for rep: int in 2:
			for variant: int in 2:
				var start_z: float = main.STAKE_POS.z + (0.86 if variant == 0 else 1.14)
				var tumble_basis := Basis(Vector3(0.0, 0.0, 1.0), 0.6 * side) \
					* Basis(Vector3(1.0, 0.0, 0.0), 0.5)
				_contact_seen = false
				_contact_origin = Vector3.ZERO
				shoe_node.freeze = true
				shoe_node.global_transform = Transform3D(tumble_basis,
					Vector3(0.82 * side, 0.30, start_z))
				shoe_node.linear_velocity = Vector3.ZERO
				shoe_node.angular_velocity = Vector3.ZERO
				await physics_frame
				await physics_frame
				shoe_node.linear_velocity = Vector3(
					-2.8 * side, -0.5, -0.8)
				shoe_node.angular_velocity = Vector3(6.0, 0.0, 12.0 * side)
				shoe_node.freeze = false
				await _await_contact_frame(shoe_node)
				var tumble_settled: Vector3 = await _wait_settle(shoe_node)
				shoe_node.freeze = true
				if variant == 0:
					tumble_rows.append(_score(tumble_settled))
				else:
					tumble_out_rows.append(_score(tumble_settled))
				shoe_node.global_transform = Transform3D(Basis.IDENTITY,
					Vector3(3.0, 0.4, -6.0))
	_report("TUMBLE", tumble_rows)
	_report("TUMBLE-OUT", tumble_out_rows)
	# STRIP: the exemption exercised directly. Inside the
	# box the only exposed lawn is the strip beyond the side
	# timber's outer face (|x| 0.697..0.914): the shoe is set
	# rolling on it toward the timber. In-box (STRIP-IN) the
	# roll is exempt and must still reach the timber (~0.12 m)
	# exactly as it does with the bleed off; the same roll a
	# step outside the box (STRIP-OUT, open lawn in front of
	# the pit's corner) must die on the grass.
	for variant: int in 2:
		var strip_rows: Array = []
		for side: float in [1.0, -1.0]:
			for rep: int in 2:
				var strip_z: float = main.STAKE_POS.z if variant == 0 \
					else main.STAKE_POS.z + 1.29
				var res: Dictionary = await _run_staged(shoe_node,
					Vector3(0.82 * side, 0.05, strip_z),
					Vector3(-1.6 * side, -0.1, 0.0),
					Vector3(0.0, 0.0, 11.0 * side))
				strip_rows.append(res)
				shoe_node.global_transform = Transform3D(Basis.IDENTITY,
					Vector3(3.0, 0.4, -6.0))
		_report("STRIP-IN" if variant == 0 else "STRIP-OUT", strip_rows)
	quit(0)
