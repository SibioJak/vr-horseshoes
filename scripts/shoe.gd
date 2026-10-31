class_name Shoe
extends RigidBody3D

## The horseshoe: a RigidBody3D built from three box parts (toe bridge
## + two shanks) plus heel calks, with one collision box per main part.
## Local frame: origin at shoe centre, shoe lying flat in XZ, toe
## (closed end) toward -Z, open end / heels toward +Z, +Y up.
##
## Grab zones live here, once, as data: the runtime proximity test,
## the part highlight, the hold transforms and the permanent zone
## audit in the test suite all read the same definitions.

const LENGTH: float = 0.1937 # 7 5/8 in
const WIDTH: float = 0.1842 # 7 1/4 in
const OPENING: float = 0.0889 # 3 1/2 in
const BAR: float = 0.0270 # bar thickness (toe/shank width)
const HEIGHT: float = 0.0210 # bar height
const MASS_KG: float = 1.13 # 2.5 lb

# Ringer inner window (stake centre, shoe-local): opening minus the
# 1 in stake, toe inner edge to just past the heel tips.
const RINGER_INNER_HALF: float = 0.0310
const RINGER_Z_MIN: float = -0.0580
const RINGER_Z_MAX: float = 0.1060

var parts: Dictionary = {} # zone name -> MeshInstance3D
var zone_markers: Dictionary = {} # zone name -> MeshInstance3D (proof/debug)
var _base_mats: Dictionary = {}
var _hi_mats: Dictionary = {}


static func zones() -> Dictionary:
	return {
		"toe": {
			"center": Vector3(0.0, 0.0, -0.0834),
			"extents": Vector3(0.120, 0.034, 0.030),
			"hold": "flip",
			"slide_axis": Vector3(1.0, 0.0, 0.0),
			"slide_max": 0.022,
		},
		"shank_left": {
			"center": Vector3(-0.0786, 0.0, 0.0068),
			"extents": Vector3(0.030, 0.034, 0.120),
			"hold": "turn",
			"slide_axis": Vector3(0.0, 0.0, 1.0),
			"slide_max": 0.045,
		},
		"shank_right": {
			"center": Vector3(0.0786, 0.0, 0.0068),
			"extents": Vector3(0.030, 0.034, 0.120),
			"hold": "turn",
			"slide_axis": Vector3(0.0, 0.0, 1.0),
			"slide_max": 0.045,
		},
	}


static func zone_aabb(zone: String) -> AABB:
	var z: Dictionary = zones()[zone]
	var c: Vector3 = z["center"]
	var e: Vector3 = z["extents"]
	return AABB(c - e * 0.5, e)


## The defined hold for a zone: shoe transform relative to the hand
## (shoe_global = hand_global * this). The anchor is the zone centre,
## so the grabbed part of the shoe sits in the fingers.
static func hold_transform(zone: String, hand: String) -> Transform3D:
	var z: Dictionary = zones()[zone]
	var center: Vector3 = z["center"]
	var basis: Basis
	if String(z["hold"]) == "flip":
		# Toe in the fingers, shoe flat, open end forward (hand -Z):
		# rotate PI about Y so shoe +Z (open) points along hand -Z.
		basis = Basis.from_euler(Vector3(0.0, PI, 0.0))
	else:
		# Shank in the fingers, shoe flat, opening to the side away
		# from the palm: right hand -> opening to the left (the
		# right-handed 1 1/4 turn setup), left hand mirrored.
		var yaw: float = -PI * 0.5 if hand == "R" else PI * 0.5
		basis = Basis.from_euler(Vector3(0.0, yaw, 0.0))
	var origin: Vector3 = basis * (-center) + Vector3(0.0, -0.018, 0.0)
	return Transform3D(basis, origin)


func _ready() -> void:
	mass = MASS_KG
	var phys := PhysicsMaterial.new()
	phys.friction = 0.9
	phys.bounce = 0.12
	physics_material_override = phys
	contact_monitor = true
	max_contacts_reported = 6
	continuous_cd = true
	_build_part("toe", Vector3(WIDTH, HEIGHT, BAR), Vector3(0.0, 0.0, -LENGTH * 0.5 + BAR * 0.5), 0.0)
	_build_part("shank_left", Vector3(BAR, HEIGHT, LENGTH - BAR), Vector3(-WIDTH * 0.5 + BAR * 0.5, 0.0, BAR * 0.5), 0.0)
	_build_part("shank_right", Vector3(BAR, HEIGHT, LENGTH - BAR), Vector3(WIDTH * 0.5 - BAR * 0.5, 0.0, BAR * 0.5), 0.0)
	# Heel calks: small angled blocks at the open tips (not grab zones).
	_build_calk(Vector3(-WIDTH * 0.5 + BAR * 0.5, 0.002, LENGTH * 0.5 - 0.012), -0.35)
	_build_calk(Vector3(WIDTH * 0.5 - BAR * 0.5, 0.002, LENGTH * 0.5 - 0.012), 0.35)
	_build_markers()


func _steel_mat(hi: bool) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	if hi:
		m.albedo_color = Color(1.0, 0.62, 0.15)
		m.emission_enabled = true
		m.emission = Color(1.0, 0.5, 0.1)
		m.emission_energy_multiplier = 1.6
	else:
		m.albedo_color = Color(0.36, 0.38, 0.42)
		m.metallic = 0.85
		m.roughness = 0.42
	return m


func _build_part(zone: String, size: Vector3, pos: Vector3, _unused: float) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.position = pos
	add_child(mi)
	parts[zone] = mi
	_base_mats[zone] = _steel_mat(false)
	_hi_mats[zone] = _steel_mat(true)
	mi.material_override = _base_mats[zone]
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = size
	cs.shape = bs
	cs.position = pos
	add_child(cs)


func _build_calk(pos: Vector3, yaw: float) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(BAR, HEIGHT * 1.25, 0.030)
	mi.mesh = bm
	mi.position = pos
	mi.rotation.y = yaw
	mi.material_override = _steel_mat(false)
	add_child(mi)


func _build_markers() -> void:
	var zs: Dictionary = zones()
	for zone: String in zs.keys():
		var z: Dictionary = zs[zone]
		var c: Vector3 = z["center"]
		var mi := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = 0.011
		sm.height = 0.022
		mi.mesh = sm
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.albedo_color = Color(1.0, 0.85, 0.2, 0.55)
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mi.material_override = m
		mi.position = c + Vector3(0.0, 0.026, 0.0)
		mi.visible = false
		add_child(mi)
		zone_markers[zone] = mi


func set_highlight(zone: String, on: bool) -> void:
	if zone == "":
		return
	var mi: MeshInstance3D = parts[zone]
	mi.material_override = _hi_mats[zone] if on else _base_mats[zone]


func clear_highlights() -> void:
	for zone: String in parts.keys():
		set_highlight(zone, false)


func set_markers_visible(on: bool) -> void:
	for zone: String in zone_markers.keys():
		var mi: MeshInstance3D = zone_markers[zone]
		mi.visible = on


## World-space centre of a grab zone.
func zone_world_center(zone: String) -> Vector3:
	var z: Dictionary = zones()[zone]
	var c: Vector3 = z["center"]
	return global_transform * c
