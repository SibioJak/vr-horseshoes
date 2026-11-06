extends SceneTree
## Pit-surface landing measurement (Backyard v2 Stage 1):
## three standard arrivals into the FAR pit, driven at REAL
## PACING (Engine.time_scale = 1.0), against whatever surface
## the pit is built with - run it before and after a surface
## change and compare. A fresh production Shoe (real parts,
## real physics material, real mass) is dropped/thrown at the
## real pit body in the real main scene; main never manages
## the extra shoe, so nothing but surface + shoe physics is
## measured. Per arrival it reports:
##   bounce_m - the shoe centre's rise during its first
##     airborne rebound after first pit contact (0 if it
##     never leaves the surface again)
##   rollout_m - horizontal distance from first pit contact
##     to the settled position
## Cases: A flat drop from 0.75 m over the stake; B flat
## skid at 3.5 m/s entering the pit; C a game-weight flip
## pitch (10.5 rad/s) from the home end, aimed 0.22 m left
## of the stake so the surface - not the stake - is measured.
## Run: godot --headless --path . --script tests/sand_measure.gd

const REPS: int = 3
const MAX_FRAMES: int = 900

var main: Node
var pit_bodies: Array = []
var label: String = "surface"
var _probe_shoe: Shoe = null
var _pit_contact_origin := Vector3.ZERO
var _pit_contact_seen: bool = false


func _initialize() -> void:
	_run()


## RigidBody3D exposes only get_contact_count() (probed via
## ClassDB) - collider identity comes from the body_entered
## signal, which Shoe's contact monitor already enables.
func _on_probe_body_entered(body: Node) -> void:
	if not _pit_contact_seen and pit_bodies.has(body):
		_pit_contact_seen = true
		_pit_contact_origin = _probe_shoe.global_position


func _find_pit_bodies() -> void:
	pit_bodies.clear()
	for child: Node in main.get_children():
		if child is StaticBody3D:
			# Fix Pass 23: the sand body carries the "sand"
			# group now (the shoe's absorption keys on it too),
			# and its centre moved when the body deepened - the
			# group is the stable identifier.
			if (child as StaticBody3D).is_in_group("sand"):
				pit_bodies.append(child)


func _run_case(shoe_node: Shoe, start_tf: Transform3D,
		vel: Vector3, ang: Vector3) -> Dictionary:
	_pit_contact_seen = false
	_pit_contact_origin = Vector3.ZERO
	shoe_node.freeze = true
	shoe_node.global_transform = start_tf
	shoe_node.linear_velocity = Vector3.ZERO
	shoe_node.angular_velocity = Vector3.ZERO
	await physics_frame
	await physics_frame
	shoe_node.linear_velocity = vel
	shoe_node.angular_velocity = ang
	shoe_node.freeze = false
	var contact_origin := Vector3.ZERO
	var have_contact: bool = false
	var rebound_apex: float = 0.0
	var airborne_after: bool = false
	var bounce_done: bool = false
	var bounce_m: float = 0.0
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
			continue
		if not bounce_done:
			if not touching and shoe_node.get_contact_count() == 0:
				airborne_after = true
				rebound_apex = maxf(rebound_apex, pos.y)
			elif touching and airborne_after:
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
	var rollout: float = 0.0
	if have_contact:
		rollout = Vector2(settled_pos.x - contact_origin.x,
			settled_pos.z - contact_origin.z).length()
	return {"contact": have_contact, "bounce_m": bounce_m,
		"rollout_m": rollout}


func _median(values: Array) -> float:
	var s: Array = values.duplicate()
	s.sort()
	return float(s[s.size() / 2])


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
	print("SAND MEASURE [%s]: time_scale %.1f, pit bodies found %d" % [
		label, Engine.time_scale, pit_bodies.size()])
	var shoe_node := Shoe.new()
	main.add_child(shoe_node)
	_probe_shoe = shoe_node
	shoe_node.body_entered.connect(_on_probe_body_entered)
	await physics_frame
	var stake_z: float = main.STAKE_POS.z
	var surface_y: float = main.STAKE_POS.y
	var cases: Array = [
		{"name": "A flat drop 0.75 m",
			"tf": Transform3D(Basis.IDENTITY,
				Vector3(0.0, surface_y + 0.0105 + 0.75, stake_z)),
			"vel": Vector3.ZERO, "ang": Vector3.ZERO},
		{"name": "B flat skid 3.5 m/s",
			"tf": Transform3D(Basis.IDENTITY,
				Vector3(0.0, surface_y + 0.025, stake_z + 0.80)),
			"vel": Vector3(0.0, 0.0, -3.5), "ang": Vector3.ZERO},
		{"name": "C flip pitch (stake offset)",
			"tf": Transform3D(Basis.IDENTITY,
				Vector3(0.22, 1.35, -1.2)),
			"vel": Vector3(0.0, 4.6, -9.6), "ang": Vector3(10.5, 0.0, 0.0)},
	]
	for case_def: Dictionary in cases:
		var bounces: Array = []
		var rollouts: Array = []
		var contacts: int = 0
		for rep: int in REPS:
			var res: Dictionary = await _run_case(shoe_node,
				case_def["tf"], case_def["vel"], case_def["ang"])
			if bool(res["contact"]):
				contacts += 1
				bounces.append(float(res["bounce_m"]))
				rollouts.append(float(res["rollout_m"]))
		if contacts > 0:
			print("SAND MEASURE [%s] %s: pit contacts %d/%d, bounce %.3f m, rollout %.3f m (bounces %s, rollouts %s)" % [
				label, String(case_def["name"]), contacts, REPS,
				_median(bounces), _median(rollouts),
				str(bounces), str(rollouts)])
		else:
			print("SAND MEASURE [%s] %s: NO pit contact in %d reps - case missed the pit" % [
				label, String(case_def["name"]), REPS])
	quit(0)
