class_name SandSurface
extends MeshInstance3D

## Fix Pass 37, Layer 2 - THE PIT KEEPS THE DENT: one pit's
## sand as a deformable VISUAL surface. A heightfield grid
## over the pit footprint (CELL ~4 cm: 24 x 47 verts, ~2.1k
## tris - trivial for the Quest, and it is rebuilt only when
## a stamp lands). A punch-in stamps a crater with a raised
## lip (displaced sand goes somewhere); a shoe plowing
## through the sand stamps a furrow along its travel. Marks
## persist through the round and are raked flat at the same
## restock funnel that clears the decal divots (main's
## _gather_to_rail).
##
## VISUAL ONLY, by law: no collision shape, nothing in the
## physics or scoring path reads this mesh - arrivals stay
## on the FP23 body + absorption path, so a shoe never rides
## its own dent. The dent depth and the Layer 1 sink depth
## come from the SAME impact stamp (Shoe.sink_depth_for_
## strength), so a settled shoe sits IN its crater.
##
## The stake guard: stamp strength fades to zero inside
## STAKE_GUARD_IN of the stake axis and is full beyond
## STAKE_GUARD_OUT, so no crater ever swallows the stake's
## base.

const CELL: float = 0.04
const MAX_DEPTH: float = 0.045 # deepest bowl floor, m below the plane
const MAX_LIP: float = 0.020 # highest rim, m above the plane
const STAKE_GUARD_IN: float = 0.10
const STAKE_GUARD_OUT: float = 0.22
const LIP_REACH: float = 1.7 # lip ring lives at 1.0..1.7 crater radii

var _size := Vector2.ZERO # footprint (x, z), m
var _stake_xz := Vector2.ZERO
var _cols: int = 0
var _rows: int = 0
var _heights := PackedFloat32Array()
var _base_verts := PackedVector3Array() # grid, y = 0
var _uvs := PackedVector2Array()
var _indices := PackedInt32Array()
var stamp_count: int = 0 # test surface: stamps applied since the rake


## Build the flat surface. `centre` is the pit centre with
## y = the sand plane (the physics top face); the mesh is
## unrotated and axis-aligned, like the pit itself.
func build(centre: Vector3, size: Vector2, stake_xz: Vector2,
		mat: Material) -> void:
	position = centre
	_size = size
	_stake_xz = stake_xz
	_cols = int(round(size.x / CELL)) + 1
	_rows = int(round(size.y / CELL)) + 1
	_heights.resize(_cols * _rows)
	_base_verts.resize(_cols * _rows)
	_uvs.resize(_cols * _rows)
	for r: int in _rows:
		for c: int in _cols:
			var i: int = r * _cols + c
			var lx: float = -size.x * 0.5 + size.x * float(c) / float(_cols - 1)
			var lz: float = -size.y * 0.5 + size.y * float(r) / float(_rows - 1)
			_base_verts[i] = Vector3(lx, 0.0, lz)
			_uvs[i] = Vector2(float(c) / float(_cols - 1),
				float(r) / float(_rows - 1))
	_indices.clear()
	# Winding: Godot front faces are CLOCKWISE from the
	# viewing side. (The first FP37 build had these counter-
	# clockwise - the surface was culled from above and the
	# pit rendered as lawn. The render proofs' pixel samples
	# caught what every data-level check could not.)
	for r2: int in _rows - 1:
		for c2: int in _cols - 1:
			var a: int = r2 * _cols + c2
			var b: int = a + 1
			var d: int = a + _cols
			var e: int = d + 1
			_indices.append_array([a, b, d, b, e, d])
	material_override = mat
	_rebuild()


func top_y() -> float:
	return global_position.y


## Is this world point over the pit footprint (the sand
## plane's own rect, no margin)?
func contains_xz(p: Vector3) -> bool:
	return absf(p.x - global_position.x) <= _size.x * 0.5 \
		and absf(p.z - global_position.z) <= _size.y * 0.5


## Stamp strength at a world point: full away from the
## stake, fading to nothing at its base.
func _guard_factor(wx: float, wz: float) -> float:
	var d: float = Vector2(wx - _stake_xz.x, wz - _stake_xz.y).length()
	return clampf((d - STAKE_GUARD_IN) / (STAKE_GUARD_OUT - STAKE_GUARD_IN),
		0.0, 1.0)


## A punch-in: a smooth bowl of `depth` at `world_pos`, with
## the displaced sand raised as a lip ring around it.
func stamp_crater(world_pos: Vector3, radius: float, depth: float) -> void:
	if depth <= 0.0 or radius <= 0.0:
		return
	stamp_count += 1
	var reach: float = radius * LIP_REACH
	var cx: float = world_pos.x - global_position.x
	var cz: float = world_pos.z - global_position.z
	var c0: int = maxi(0, int(floor((cx - reach + _size.x * 0.5) / CELL)))
	var c1: int = mini(_cols - 1, int(ceil((cx + reach + _size.x * 0.5) / CELL)))
	var r0: int = maxi(0, int(floor((cz - reach + _size.y * 0.5) / CELL)))
	var r1: int = mini(_rows - 1, int(ceil((cz + reach + _size.y * 0.5) / CELL)))
	for r: int in range(r0, r1 + 1):
		for c: int in range(c0, c1 + 1):
			var i: int = r * _cols + c
			var v: Vector3 = _base_verts[i]
			var dist: float = Vector2(v.x - cx, v.z - cz).length()
			if dist > reach:
				continue
			var g: float = _guard_factor(global_position.x + v.x,
				global_position.z + v.z)
			if g <= 0.0:
				continue
			var d01: float = dist / radius
			var h: float = _heights[i]
			if d01 < 1.0:
				var bowl: float = 0.5 + 0.5 * cos(d01 * PI)
				h -= depth * bowl * g
			else:
				var lip_t: float = (d01 - 1.0) / (LIP_REACH - 1.0)
				h += depth * 0.38 * sin(lip_t * PI) * g
			_heights[i] = clampf(h, -MAX_DEPTH, MAX_LIP)
	_rebuild()


## A skid: a shallow trough of `depth` along the segment
## a -> b (world), `width` across, round-capped at the ends
## by the point-segment distance itself.
func stamp_furrow(a: Vector3, b: Vector3, width: float, depth: float) -> void:
	if depth <= 0.0 or width <= 0.0:
		return
	stamp_count += 1
	var half: float = width * 0.5
	var ax: float = a.x - global_position.x
	var az: float = a.z - global_position.z
	var bx: float = b.x - global_position.x
	var bz: float = b.z - global_position.z
	var minx: float = minf(ax, bx) - half
	var maxx: float = maxf(ax, bx) + half
	var minz: float = minf(az, bz) - half
	var maxz: float = maxf(az, bz) + half
	var c0: int = maxi(0, int(floor((minx + _size.x * 0.5) / CELL)))
	var c1: int = mini(_cols - 1, int(ceil((maxx + _size.x * 0.5) / CELL)))
	var r0: int = maxi(0, int(floor((minz + _size.y * 0.5) / CELL)))
	var r1: int = mini(_rows - 1, int(ceil((maxz + _size.y * 0.5) / CELL)))
	var ab := Vector2(bx - ax, bz - az)
	var ab_len2: float = ab.length_squared()
	for r: int in range(r0, r1 + 1):
		for c: int in range(c0, c1 + 1):
			var i: int = r * _cols + c
			var v: Vector3 = _base_verts[i]
			var t: float = 0.0
			if ab_len2 > 0.000001:
				t = clampf(Vector2(v.x - ax, v.z - az).dot(ab) / ab_len2,
					0.0, 1.0)
			var near := Vector2(ax + ab.x * t, az + ab.y * t)
			var dist: float = Vector2(v.x - near.x, v.z - near.y).length()
			if dist > half:
				continue
			var g: float = _guard_factor(global_position.x + v.x,
				global_position.z + v.z)
			if g <= 0.0:
				continue
			var fall: float = 0.5 + 0.5 * cos(dist / half * PI)
			_heights[i] = clampf(_heights[i] - depth * fall * g,
				-MAX_DEPTH, MAX_LIP)
	_rebuild()


## The rake: every mark gone, the pit reads clean.
func rake() -> void:
	_heights.fill(0.0)
	stamp_count = 0
	_rebuild()


## Dent depth (m, positive = below the plane) at a world
## point, sampled at the nearest vertex. Test surface.
## (Samples on the grid's true spacing - size / (n - 1) -
## not the nominal CELL the counts were rounded from.)
func depth_at(world_pos: Vector3) -> float:
	var c: int = clampi(int(round((world_pos.x - global_position.x
		+ _size.x * 0.5) / (_size.x / float(_cols - 1)))), 0, _cols - 1)
	var r: int = clampi(int(round((world_pos.z - global_position.z
		+ _size.y * 0.5) / (_size.y / float(_rows - 1)))), 0, _rows - 1)
	return -_heights[r * _cols + c]


## Largest mark in the pit, either way (m). Test surface.
func max_abs_height() -> float:
	var m: float = 0.0
	for h: float in _heights:
		m = maxf(m, absf(h))
	return m


## {verts, tris} - the report's cost line.
func grid_stats() -> Dictionary:
	return {"verts": _cols * _rows, "tris": _indices.size() / 3,
		"cols": _cols, "rows": _rows}


func _rebuild() -> void:
	var verts := PackedVector3Array()
	verts.resize(_base_verts.size())
	var normals := PackedVector3Array()
	normals.resize(_base_verts.size())
	var colors := PackedColorArray()
	colors.resize(_base_verts.size())
	for r: int in _rows:
		for c: int in _cols:
			var i: int = r * _cols + c
			verts[i] = Vector3(_base_verts[i].x, _heights[i], _base_verts[i].z)
			# Central-difference normal from the heightfield:
			# smooth shading for free, no SurfaceTool pass.
			var hl: float = _heights[r * _cols + maxi(c - 1, 0)]
			var hr: float = _heights[r * _cols + mini(c + 1, _cols - 1)]
			var hu: float = _heights[maxi(r - 1, 0) * _cols + c]
			var hd: float = _heights[mini(r + 1, _rows - 1) * _cols + c]
			normals[i] = Vector3(-(hr - hl) / (2.0 * CELL), 1.0,
				-(hd - hu) / (2.0 * CELL)).normalized()
			# Disturbed-sand tint (the material reads vertex
			# colour as albedo): a hollow sits in its own
			# shade, a lip of fresh-piled sand catches the
			# light. Without it a smooth 14 mm bowl is nearly
			# invisible in flat noon light - the dent must
			# READ, that is the layer's whole point.
			var h: float = _heights[i]
			var shade: float = 1.0
			if h < 0.0:
				shade = 1.0 - 0.38 * clampf(-h / MAX_DEPTH, 0.0, 1.0)
			elif h > 0.0:
				shade = 1.0 + 0.12 * clampf(h / MAX_LIP, 0.0, 1.0)
			colors[i] = Color(shade, shade, shade)
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = _uvs
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = _indices
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh = am
