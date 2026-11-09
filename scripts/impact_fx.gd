class_name ImpactFX
extends Node3D

## Impact dressing (Impact Dressing Pass): the plume (the
## moment), the divot (the residue), and the clang (the sound).
## Everything here rides events the game already knows: the
## shoe's surface-absorption episode start (Fix Pass 23/24 -
## kind, first-contact point, pre-impact velocity, impact
## strength) is forwarded by main, main's body_entered wiring
## names stake and shoe strikes, and the settle paths name
## ringers. No parallel detector, no physics contact: plumes
## and divots are pure visuals from pre-allocated pools (ZERO
## per-impact allocation), and sounds play from a pooled set of
## AudioStreamPlayer3D at the impact point.
##
## Pools: PLUME_SLOTS plume pairs (grain spray + dust puff),
## DIVOT_CAP ground marks (ring buffer, oldest recycled), and
## PLAYER_COUNT audio players (round-robin). Divots accumulate
## through a round and are raked clean by main at every restock
## (the _gather_to_rail funnel: round change, new game, back
## to practice) via clear_marks().

const KIND_SAND: int = 1 # mirrors Shoe.ABSORB_SAND
const KIND_TURF: int = 2 # mirrors Shoe.ABSORB_TURF

const PLUME_SLOTS: int = 6
const DIVOT_CAP: int = 24
const PLAYER_COUNT: int = 6

const STREAM_SAND_THUD: String = "res://assets/audio/sand_thud.ogg"
const STREAM_STAKE_CLANG: String = "res://assets/audio/stake_clang.ogg"
const STREAM_SHOE_CLINK: String = "res://assets/audio/shoe_clink.ogg"
const STREAM_RINGER_RING: String = "res://assets/audio/ringer_ring.ogg"

const SAND_SPRAY_COL := Color(0.82, 0.70, 0.50)
const SAND_PUFF_COL := Color(0.87, 0.79, 0.62, 0.38)
const TURF_SPRAY_COL := Color(0.45, 0.50, 0.30)
const TURF_PUFF_COL := Color(0.55, 0.58, 0.42, 0.30)
const SAND_DIVOT_COL := Color(0.52, 0.42, 0.29)
const TURF_DIVOT_COL := Color(0.32, 0.40, 0.22)

var _plumes: Array = [] # {root, spray, puff, spray_mat, puff_mat, spray_mesh_mat, puff_mesh_mat}
var _plume_next: int = 0
var _divots: Array = [] # {mi, mat}
var _divot_next: int = 0
var _divot_active: int = 0
var _players: Array = [] # AudioStreamPlayer3D
var _player_next: int = 0
var _streams: Dictionary = {}

## Test-facing records (tests cannot hear or see particles):
## every routed impact and every played sound, in order.
var impact_log: Array = []
var play_log: Array = []


static func stream_path_for_event(event: String) -> String:
	match event:
		"sand_thud":
			return STREAM_SAND_THUD
		"stake_clang":
			return STREAM_STAKE_CLANG
		"shoe_clink":
			return STREAM_SHOE_CLINK
		"ringer":
			return STREAM_RINGER_RING
	return ""


## Impact-scaled volume: a dead drop is a murmur, a game-speed
## arrival speaks up. Monotonic in strength for every event.
static func volume_db_for(event: String, strength: float) -> float:
	var s: float = clampf(strength, 0.0, 1.0)
	match event:
		"sand_thud":
			return lerpf(-17.0, -3.0, s)
		"stake_clang":
			return lerpf(-15.0, -2.0, s)
		"shoe_clink":
			return lerpf(-17.0, -4.0, s)
		"ringer":
			return -2.5
	return -12.0


static func pitch_for(event: String, strength: float) -> float:
	var s: float = clampf(strength, 0.0, 1.0)
	match event:
		"stake_clang", "shoe_clink":
			return lerpf(0.94, 1.05, s)
		"ringer":
			return 1.0
	return lerpf(0.92, 1.02, s)


## Divot radius (m) by surface and impact strength: sand takes
## a real dent, grass a lighter scuff.
static func divot_radius_for(kind: int, strength: float) -> float:
	var s: float = clampf(strength, 0.0, 1.0)
	if kind == KIND_SAND:
		return lerpf(0.085, 0.20, s)
	return lerpf(0.045, 0.10, s)


## Plume energy 0..1 by surface and impact strength: grass
## gets at most a faint scuff of sand's plume.
static func plume_scale_for(kind: int, strength: float) -> float:
	var s: float = clampf(strength, 0.0, 1.0)
	if kind == KIND_SAND:
		return lerpf(0.30, 1.0, s)
	return lerpf(0.10, 0.35, s)


func _ready() -> void:
	_streams = {
		"sand_thud": preload(STREAM_SAND_THUD),
		"stake_clang": preload(STREAM_STAKE_CLANG),
		"shoe_clink": preload(STREAM_SHOE_CLINK),
		"ringer": preload(STREAM_RINGER_RING),
	}
	_build_plumes()
	_build_divots()
	_build_players()


func _build_particles(amount: int, lifetime: float, explosiveness: float,
		gravity: Vector3, spread: float, mesh: Mesh,
		mesh_mat: Material) -> Dictionary:
	var p := GPUParticles3D.new()
	p.amount = amount
	p.lifetime = lifetime
	p.one_shot = true
	p.explosiveness = explosiveness
	p.local_coords = false
	p.visibility_aabb = AABB(Vector3(-3, -3, -3), Vector3(6, 6, 6))
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3(0.0, 1.0, 0.55)
	pm.spread = spread
	pm.gravity = gravity
	pm.scale_min = 0.7
	pm.scale_max = 1.3
	p.process_material = pm
	p.draw_pass_1 = mesh
	p.material_override = mesh_mat
	return {"node": p, "mat": pm}


func _build_plumes() -> void:
	for i: int in PLUME_SLOTS:
		var root := Node3D.new()
		root.name = "Plume%d" % i
		add_child(root)
		# Grain spray: small dry-sand grains thrown forward.
		var spray_mesh := BoxMesh.new()
		spray_mesh.size = Vector3(0.02, 0.02, 0.02)
		var spray_mesh_mat := StandardMaterial3D.new()
		spray_mesh_mat.albedo_color = SAND_SPRAY_COL
		spray_mesh_mat.roughness = 1.0
		spray_mesh.material = spray_mesh_mat
		var spray: Dictionary = _build_particles(30, 0.75, 0.9,
			Vector3(0.0, -4.5, 0.0), 28.0, spray_mesh, spray_mesh_mat)
		root.add_child(spray["node"] as Node)
		# Dust puff: soft, slow, grows as it hangs.
		var puff_mesh := SphereMesh.new()
		puff_mesh.radius = 0.05
		puff_mesh.height = 0.10
		puff_mesh.radial_segments = 8
		puff_mesh.rings = 4
		var puff_mesh_mat := StandardMaterial3D.new()
		puff_mesh_mat.albedo_color = SAND_PUFF_COL
		puff_mesh_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		puff_mesh_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		puff_mesh.material = puff_mesh_mat
		var puff: Dictionary = _build_particles(10, 1.05, 0.6,
			Vector3(0.0, 0.35, 0.0), 55.0, puff_mesh, puff_mesh_mat)
		(puff["mat"] as ParticleProcessMaterial).direction = Vector3(0.0, 1.0, 0.15)
		root.add_child(puff["node"] as Node)
		_plumes.append({
			"root": root,
			"spray": spray["node"], "spray_pm": spray["mat"],
			"puff": puff["node"], "puff_pm": puff["mat"],
			"spray_mesh_mat": spray_mesh_mat, "puff_mesh_mat": puff_mesh_mat,
		})


func _build_divots() -> void:
	var geo := CylinderMesh.new()
	geo.top_radius = 1.0
	geo.bottom_radius = 1.0
	geo.height = 1.0
	geo.radial_segments = 24
	for i: int in DIVOT_CAP:
		var mat := StandardMaterial3D.new()
		mat.albedo_color = SAND_DIVOT_COL
		mat.roughness = 1.0
		mat.polygon_offset_enabled = true
		mat.polygon_offset_factor = -2.0
		var mi := MeshInstance3D.new()
		mi.name = "Divot%d" % i
		mi.mesh = geo
		mi.material_override = mat
		mi.visible = false
		add_child(mi)
		_divots.append({"mi": mi, "mat": mat})


func _build_players() -> void:
	for i: int in PLAYER_COUNT:
		var pl := AudioStreamPlayer3D.new()
		pl.name = "ImpactPlayer%d" % i
		pl.unit_size = 2.0
		pl.max_distance = 40.0
		add_child(pl)
		_players.append(pl)


## One surface first-contact, forwarded from the shoe's
## absorption episode via main: plume + divot, logged. The
## caller (main) owns the in-flight gate and the thud routing.
func surface_impact(kind: int, pos: Vector3, vel: Vector3, strength: float) -> void:
	var flat := Vector3(vel.x, 0.0, vel.z)
	var dir: Vector3 = flat.normalized() if flat.length() > 0.1 else Vector3(0.0, 0.0, -1.0)
	_fire_plume(kind, pos, dir, strength)
	_stamp_divot(kind, pos, dir, strength)
	impact_log.append({"kind": kind, "strength": strength,
		"pos": pos, "radius": divot_radius_for(kind, strength)})
	if impact_log.size() > 96:
		impact_log.pop_front()


func _fire_plume(kind: int, pos: Vector3, dir: Vector3, strength: float) -> void:
	var slot: Dictionary = _plumes[_plume_next]
	_plume_next = (_plume_next + 1) % PLUME_SLOTS
	var root: Node3D = slot["root"]
	root.global_position = pos + Vector3(0.0, 0.02, 0.0)
	root.rotation = Vector3(0.0, atan2(dir.x, dir.z), 0.0)
	var energy: float = plume_scale_for(kind, strength)
	var spray_pm: ParticleProcessMaterial = slot["spray_pm"]
	spray_pm.initial_velocity_min = lerpf(0.9, 2.8, energy)
	spray_pm.initial_velocity_max = lerpf(1.4, 4.2, energy)
	var puff_pm: ParticleProcessMaterial = slot["puff_pm"]
	puff_pm.initial_velocity_min = lerpf(0.15, 0.45, energy)
	puff_pm.initial_velocity_max = lerpf(0.30, 0.80, energy)
	var spray_mat: StandardMaterial3D = slot["spray_mesh_mat"]
	var puff_mat: StandardMaterial3D = slot["puff_mesh_mat"]
	if kind == KIND_SAND:
		spray_mat.albedo_color = SAND_SPRAY_COL
		puff_mat.albedo_color = SAND_PUFF_COL
	else:
		spray_mat.albedo_color = TURF_SPRAY_COL
		puff_mat.albedo_color = TURF_PUFF_COL
	(slot["spray"] as GPUParticles3D).restart()
	(slot["puff"] as GPUParticles3D).restart()


func _stamp_divot(kind: int, pos: Vector3, dir: Vector3, strength: float) -> void:
	var slot: Dictionary = _divots[_divot_next]
	var idx: int = _divot_next
	_divot_next = (_divot_next + 1) % DIVOT_CAP
	_divot_active = mini(_divot_active + 1, DIVOT_CAP)
	var r: float = divot_radius_for(kind, strength)
	var mi: MeshInstance3D = slot["mi"]
	var mat: StandardMaterial3D = slot["mat"]
	mat.albedo_color = SAND_DIVOT_COL if kind == KIND_SAND else TURF_DIVOT_COL
	mi.scale = Vector3(r, 0.0035, r * (1.0 + 0.7 * clampf(strength, 0.0, 1.0)))
	mi.global_position = pos + Vector3(0.0, 0.004 + float(idx) * 0.00035, 0.0)
	mi.rotation = Vector3(0.0, atan2(dir.x, dir.z), 0.0)
	mi.visible = true


## The rake: every mark gone, the pit reads clean.
func clear_marks() -> void:
	for slot: Dictionary in _divots:
		(slot["mi"] as MeshInstance3D).visible = false
	_divot_active = 0
	_divot_next = 0


func divot_count() -> int:
	return _divot_active


func plume_slots() -> int:
	return _plumes.size()


func player_count() -> int:
	return _players.size()


## Play one routed sound at a point in the world, from the
## pool, impact-scaled. Every play is logged for the suites.
func play_event(event: String, pos: Vector3, strength: float) -> void:
	var path: String = stream_path_for_event(event)
	if path == "" or not _streams.has(event):
		return
	var pl: AudioStreamPlayer3D = _players[_player_next]
	_player_next = (_player_next + 1) % PLAYER_COUNT
	pl.stream = _streams[event]
	pl.global_position = pos
	pl.volume_db = volume_db_for(event, strength)
	pl.pitch_scale = pitch_for(event, strength)
	pl.play()
	play_log.append({"event": event, "stream": path,
		"volume_db": pl.volume_db, "pitch": pl.pitch_scale, "pos": pos})
	if play_log.size() > 96:
		play_log.pop_front()


## Test/proof hooks: stage the full dressing for one impact
## (plume + divot + the surface's sound) without a throw, and
## a plume alone caught mid-flight for the proof frame.
func debug_surface_impact(kind: int, pos: Vector3, vel: Vector3, strength: float) -> void:
	surface_impact(kind, pos, vel, strength)
	if kind == KIND_SAND:
		play_event("sand_thud", pos, strength)


func debug_fire_plume(kind: int, pos: Vector3, dir: Vector3, strength: float) -> void:
	var flat := Vector3(dir.x, 0.0, dir.z)
	var d: Vector3 = flat.normalized() if flat.length() > 0.1 else Vector3(0.0, 0.0, -1.0)
	_fire_plume(kind, pos, d, strength)
