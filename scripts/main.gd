extends Node3D

## VR Horseshoes - Backyard Game v1.
## The DE toss test grew a game in a ONE-PIT backyard (Fix
## Pass 19, the real backyard form): one timber sand pit,
## true foul lines at the pitching end, NHPA cancellation
## scoring to 21 against a visible AI club player, and a
## one-way inning rhythm - both pitchers throw from the line
## end, and when the last shoe settles the round tabulates
## itself and the INSERT CAM shows a live closeup of the pit
## with the score breakdown (Fix Pass 20: no mandatory walk
## down and back; walking is free, it just does nothing
## functional - though a live round clamps the player behind
## the foul line). The judged core is
## untouched and stays guarded by the suites: zone-snap grab
## + sticky slide (GrabState/Shoe), windowed release sampling
## (ThrowMath), the honest rigid-body shoe (zero damping,
## stake sweep guard), the JSONL recorder, standard
## twin-stick movement, and the in-world scoreboard. PRACTICE
## mode is the old test, exactly: free throwing with
## per-throw readouts.
##
## Rig binding is FIELD-CENSUS settled (VR Baseball Duel, same rig:
## Quest 3 + Virtual Desktop/VDXR + Godot 4.7): hands register as
## plain "left_hand"/"right_hand" with live data on the "default"
## pose. One XRController3D per hand, pose never overridden. Do not
## "fix" these names to /user/hand/... paths - no such trackers exist
## on this rig.

const STAKE_POS := Vector3(0.0, 0.0, -12.192) # the ONE pit's surface point (Fix Pass 19: sand at grade, y=0)
const STAKE_VISUAL_RADIUS: float = 0.0127 # the 1 in steel Chris sees
const STAKE_COLLISION_RADIUS: float = 0.0157 # visual + 3 mm (Fix Pass 8, see _build_pit)
const PIT_SIZE := Vector3(0.914, 0.05, 1.829) # 36 in x 72 in
# Fix Pass 19: TRUE foul lines at the pitching end - each stands
# 3 ft in front of where the pitching end's own stake would sit,
# so the 40 ft class pitches from the 37 ft line (z -0.914) and
# the 30 ft class from the 27 ft line (z -3.962). Before FP19
# the "40 ft line" sat ON the home stake's plane (z 0) and the
# short line a flat 9.144 m from the target - neither was a real
# foul line.
const FOUL_40_Z: float = -0.914 # the 37 ft line: 40 ft class
const FOUL_30_Z: float = -3.962 # the 27 ft line: 30 ft class
const STANCE_HALF_WIDTH: float = 0.85
const STANCE_HALF_DEPTH: float = 0.40
# Fix Pass 19 pitching spots: the player pitches from his side
# of the lane, the AI from the opposite side, ~1.6 m apart -
# real one-pit play, both pitchers at the line end. Each owner's
# station stands a reach-over outboard of his own spot.
const PLAYER_SPOT_X: float = 0.8
const AI_SPOT_X: float = -0.8
const STAND_SIDE_X: float = 1.22 # station slot 0 outboard of the owner's spot (FP11: 1.0 m; FP13: 1.22 m; FP19: measured from the spot)
const STAND_SHOE_Y: float = 0.785
const SLOT_STEP: float = 0.24 # pair slots along a rail stand (the rail runs down-lane since Fix Pass 13)
const PLAYER_PAIR_COLOR := Color(0.92, 0.75, 0.16) # yellow (photo feed)
const AI_PAIR_COLOR := Color(0.18, 0.36, 0.85) # blue (photo feed)
const WIN_SCORE: int = 21
const CANDIDATE_RADIUS: float = 0.14
const BOARD_POS := Vector3(-2.4, 0.0, -16.2) # Fix Pass 10: beyond the pit, left of the stake
const BOARD_YAW_DEG: float = 10.0 # face turned back at the pitching end
const THROW_MIN_SPEED: float = 0.9
const SAMPLE_KEEP_SEC: float = 0.40
const SETTLE_STILL_SEC: float = 0.25
const RETURN_WAIT_SEC: float = 0.20

var origin: XROrigin3D
var cam: XRCamera3D
var hand_ctrl: Dictionary = {} # "L"/"R" -> XRController3D
var ctrl_rep: Dictionary = {}
var xr_ok: bool = false
var head_tracking_ok: bool = false

var shoe: Shoe # the ACTIVE player shoe (the state machine drives this one)
var player_pair: Array = [] # Array[Shoe], yellow
var ai_pair: Array = [] # Array[Shoe], blue
var shoe_status: Dictionary = {} # Shoe -> "RAILED" | "HELD" | "FLYING" | "DOWN"
var stake_body_node: StaticBody3D = null # far stake (spawn wiring compat)
var stake_axis_a: Vector3 = Vector3.ZERO # far stake collision axis endpoints (world)
var stake_axis_b: Vector3 = Vector3.ZERO
var stakes: Dictionary = {} # "FAR"|"HOME" -> {body, axis_a, axis_b, pos}
var stand_tfs: Dictionary = {} # line_ft (30/40) -> PLAYER slot-0 transform at the pitching end (FP19: one end only)
var ai_stand_tfs: Dictionary = {} # 40 ft ONLY -> AI slot-0 transform at the pitching end (FP18: no AI practice points)
var stand_tf: Transform3D # the rail slot the ACTIVE shoe currently belongs to
var active_stand_line_ft: int = 40
var ai_pitcher: AIPitcher
var ai_rng := RandomNumberGenerator.new()
var board_root: Node3D
var board_slab_size := Vector3(3.0, 2.7, 0.05)
var title_label: Label3D
var status_label: Label3D
var controls_label: Label3D
var scenery_root: Node3D

var state: String = "STAND" # STAND, HELD, FLYING, DROPPED, RETURNING
var grab_state := GrabState.new()
var held_hand: String = ""
var held_zone: String = ""
var held_hold: String = ""
var rel_tf := Transform3D.IDENTITY
var slide_offset: float = 0.0
# Fix Pass 21: the grip cycle's in-world label - a small board-
# family tag that rides above the held shoe naming the grip
# position (ThrowMath.GRIP_POSITIONS). Visible only while a
# shoe is held; gone the instant it is released.
var grip_label: Label3D = null
# Fix Pass 22: a small second line under the grip name while
# a shoe is held - the cycle's discoverability lives on the
# label itself now that any A/X press cycles.
var grip_hint_label: Label3D = null
var candidate_hand: String = ""
var candidate_zone: String = ""

var samples: Array = [] # Dictionary samples for the held hand
var sample_hand: String = ""
# Fix Pass 14: the release is read at the grip's true let-go
# instant, interpolated between polls (see ThrowMath's sub-step
# section) - the flag exists so the bench can run the legacy grid
# read as the negative control.
var substep_release_enabled: bool = true
# Fix Pass 16: the finger-drag term (see ThrowMath.govern_spin)
# meters the release spin on the style axis toward the hold's
# regulation total; the flag is the bench's negative control.
var spin_governor_enabled: bool = true
var _grip_hist: Array = [] # recent {"t", "g"} readings for the latched hand
var _prev_hand_pos: Dictionary = {}
var _prev_hand_t: Dictionary = {}
var hand_speed: Dictionary = {"L": 0.0, "R": 0.0}

var throw_count: int = 0
var last_hold_text: String = "-"
var last_distance_in: float = -1.0
var last_flip_rev: float = 0.0
var last_turn_rev: float = 0.0
var last_ringer: bool = false

var recorder: ThrowRecorder
var recorder_path: String = "user://throws.jsonl"
var release_cache: Dictionary = {}
# Fix Pass 15: the origin's basis is level BY CONSTRUCTION (every
# reorientation is yaw-only - see Locomotion), and this guard is
# the belt behind the braces: any pitch/roll that reaches the
# origin by ANY path is stripped the same physics frame, and the
# repair is counted so a recurrence is visible, never silent.
# (tilt_guard_enabled exists for the smoke's negative control.)
var tilt_guard_enabled: bool = true
var origin_tilt_repairs: int = 0
var flip_rot: float = 0.0
var turn_rot: float = 0.0
var has_contact: bool = false
var first_contact_pos: Vector3 = Vector3.ZERO
var _fly_time: float = 0.0
var _still_time: float = 0.0
var _pos_still_time: float = 0.0 # positional stillness (leaner guard)
var _pos_anchor: Vector3 = Vector3.ZERO
var _wait_time: float = 0.0

# --- Backyard Game v1 state ---
# mode: "PRACTICE" (the old test) or "GAME". In GAME, phase runs
# the one-way loop: "P_TURN" -> "AI_TURN" (order set by
# inning_first) -> "TABULATE" (Fix Pass 20: all four shoes are
# down; a short beat runs, then the round posts itself and the
# insert cam appears) -> "INSERT" (the breakdown is up; A
# stocks the next inning) -> next inning, or "OVER" (the
# insert carries the final breakdown). The AI never leaves
# the pitching end.
var mode: String = "PRACTICE"
var phase: String = ""
var inning: int = 0
var score_you: int = 0
var score_opp: int = 0
var inning_first: String = "P" # who throws first this inning
var turn_side: String = "" # side currently throwing
var turn_throws_left: int = 0
var inning_results: Array = [] # settled {owner, dist_in, ringer} this inning
var last_inning_text: String = ""
var winner_text: String = ""
var grab_armed: bool = true # game phases disarm the grab (AI turn etc.)
var ai_flight: Dictionary = {} # Shoe -> flight tracking dict (AI throws)
var ai_throw_pending: bool = false # an AI swing is animating
var ai_wait_clear: float = 0.0
var _btn_prev: Dictionary = {"A": false, "B": false}

# Fix Pass 20: the insert cam - an in-world panel carrying a
# live closeup of the pit (a SubViewport sharing this world)
# plus the round's score breakdown, spawned in front of the
# player when a round tabulates and dismissed with A.
const ROUND_BEAT_SEC: float = 0.75 # settle -> tabulation beat
const INSERT_DIST_M: float = 2.0 # panel distance at spawn
var tabulate_left: float = -1.0 # TABULATE countdown (<0 idle)
var round_lines: Array = [] # the insert's breakdown lines
var insert_root: Node3D = null
var insert_viewport: SubViewport = null
var insert_cam: Camera3D = null
var insert_label: Label3D = null

# Test hooks (used by the headless suites / render proofs only).
var test_hand_tf: Dictionary = {}
var test_grip: Dictionary = {}
var test_trigger: Dictionary = {}
var test_stick: Dictionary = {}
var test_button: Dictionary = {} # "A"/"B" -> bool
var test_button_hand: Dictionary = {} # "L"/"R" -> {"A"/"B" -> bool} (Fix Pass 21 per-hand reads)
var debug_show_zones: bool = false


func _ready() -> void:
	recorder = ThrowRecorder.new(recorder_path)
	ai_rng.randomize()
	_init_stands()
	_build_world()
	_build_rig()
	_build_board()
	_build_grip_label()
	_build_insert()
	_spawn_shoes()
	_build_ai()
	head_tracking_ok = _head_tracking_ok()
	print("VR Horseshoes backyard game ready. xr_ok=", xr_ok, " head_tracking=", head_tracking_ok)
	_update_board()


func _mat(c: Color, emission: float = 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	if emission > 0.0:
		m.emission_enabled = true
		m.emission = c
		m.emission_energy_multiplier = emission
	return m


func _box(parent: Node, pos: Vector3, size: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.position = pos
	mi.material_override = mat
	parent.add_child(mi)
	return mi


func _cyl(parent: Node, pos: Vector3, radius: float, height: float, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = radius
	cm.bottom_radius = radius
	cm.height = height
	mi.mesh = cm
	mi.position = pos
	mi.material_override = mat
	parent.add_child(mi)
	return mi


func _static_box(pos: Vector3, size: Vector3, mat: Material, phys: PhysicsMaterial) -> StaticBody3D:
	var body := StaticBody3D.new()
	if phys != null:
		body.physics_material_override = phys
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat
	body.add_child(mi)
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = size
	cs.shape = bs
	body.add_child(cs)
	body.position = pos
	add_child(body)
	return body


static func line_z_for_ft(line_ft: int) -> float:
	return FOUL_30_Z if line_ft == 30 else FOUL_40_Z


## Which side of the lane an owner's station stands on, as a
## world-x sign: outboard of his pitching spot - the player's
## on his right (+x), the AI's on its left (-x). (Fix Pass 19:
## both owners pitch from the one pitching end, so the side no
## longer depends on a target end.)
static func station_side(is_ai: bool) -> float:
	return -1.0 if is_ai else 1.0


## The owner's nominal pitching spot at a foul line: the
## player on his side of the lane, the AI on the opposite
## side, ~1.6 m apart (Fix Pass 19).
static func spot_pos(line_ft: int, is_ai: bool) -> Vector3:
	return Vector3(AI_SPOT_X if is_ai else PLAYER_SPOT_X, 0.0,
		line_z_for_ft(line_ft))


static func make_rack_tf(line_ft: int, is_ai: bool) -> Transform3D:
	# Rack slot 0 (Fix Pass 11, Chris's field order): BESIDE the
	# stance at the foul line's own z - NOT behind the player -
	# facing him, so he reaches over and grabs a shoe without
	# turning around. (The FP3 pedestal rule - 0.5 m behind the
	# line, 0.75 m to the side - survived into v1 as slot 0 of
	# a shared rack; in game flow the rack sat directly behind
	# him and every grab meant a turn.)
	#
	# Fix Pass 13 (Chris, from the headset: "the horseshoe
	# holders need to be turned 90-degrees and moved further
	# from line"): the rack is TURNED and moved OUT. FP11 hung
	# the pair along a rail running across the court at 1.0 m,
	# faces angled down-lane; standing at his stance beside
	# that rack, Chris saw the shoes' edges and backs, one
	# behind the other. Now the rail runs DOWN-LANE beside the
	# stance and the pair steps down-lane along it (see
	# rack_slot_tf), so the hanging shoes present FACE-ON to
	# the player - the way the station in his photo feed faces
	# its viewer - and slot 0 sits further out at 1.22 m from
	# the stance centre, still a plain reach-over (outside the
	# stance box, |x| <= 0.85, no turn, no walk). The shoe
	# still HANGS on the rail by its toe bridge: plane
	# near-vertical, bridge up.
	#
	# Fix Pass 19: the stance the law is measured from is now
	# the owner's own pitching SPOT at the one pitching end
	# (the player at +0.8, the AI at -0.8 - see spot_pos), and
	# the travel direction is always down-lane (-z). Slot 0
	# sits 1.22 m outboard of the spot, at the line's own z;
	# the hang's yaw solve below is the FP13 one with travel
	# pinned to -1.
	#
	# The yaw is solved per rack (owner's side) so the face
	# normal (the hang basis applied to +Y) points across the
	# court at the stance with FP11's slight down-lane slant
	# kept: the old normal's horizontal parts were 0.847
	# across / 0.489 down-lane, so sin(yaw) takes 0.866 x side
	# and cos(yaw) takes -0.5 x travel - the same tipped hang,
	# turned to face him.
	var side: float = station_side(is_ai)
	var spot: Vector3 = spot_pos(line_ft, is_ai)
	var yaw: float = atan2(0.8660254 * side, 0.5)
	return Transform3D(
		Basis.from_euler(Vector3(deg_to_rad(-78.0), yaw, 0.0)),
		Vector3(spot.x + side * STAND_SIDE_X,
			STAND_SHOE_Y, spot.z))


## World transform of one slot on one owner's rack. Each rack
## holds ONLY its owner's pair (Fix Pass 11: v1 ran slots 0-3
## along ONE shared rack - both pairs on a single stand.
## Chris: "all the shoes spawn on one rack."). Slot 0 hangs
## at STAND_SIDE_X outboard of the owner's pitching spot;
## since Fix Pass 13 slot 1 steps one slot DOWN-LANE from it
## along the turned rail (toward the target stake - always
## -z since Fix Pass 19's one-way court), so both shoes hang
## clear of the stance box and the swing corridor.
func rack_slot_tf(line_ft: int, is_ai: bool, idx: int) -> Transform3D:
	var base: Transform3D
	if is_ai:
		base = ai_stand_tfs[line_ft]
	else:
		base = stand_tfs[line_ft]
	var step: float = float(idx) * SLOT_STEP * -1.0
	return Transform3D(base.basis, base.origin + Vector3(0.0, 0.0, step))


func _is_ai_shoe(shoe_node: Shoe) -> bool:
	return ai_pair.has(shoe_node)


func _pair_index_of(shoe_node: Shoe) -> int:
	var pi: int = player_pair.find(shoe_node)
	if pi >= 0:
		return pi
	return maxi(ai_pair.find(shoe_node), 0)


func _init_stands() -> void:
	stand_tfs = {40: make_rack_tf(40, false), 30: make_rack_tf(30, false)}
	# Fix Pass 18: the AI has NO practice stock points - it never
	# practices. Its pair stocks only at the 40 ft game station.
	# Any gather/restock that names a 30 ft line sends the AI
	# pair to the 40 ft station instead (see _gather_to_rail
	# and _restock_to_player_line).
	ai_stand_tfs = {40: make_rack_tf(40, true)}
	active_stand_line_ft = 40
	stand_tf = stand_tfs[active_stand_line_ft]


func _refresh_stand_tf() -> void:
	stand_tf = rack_slot_tf(active_stand_line_ft,
		false, _pair_index_of(shoe))


func _set_active_stand(line_ft: int) -> void:
	active_stand_line_ft = line_ft
	_refresh_stand_tf()


## "The shoe waits where you are" (Fix Pass 7, generalised in
## Backyard Game v1). While a shoe sits stocked (RAILED), its
## home follows the PLAYER: standing at a foul line relocates
## every stocked shoe to that line's stock point, pairs and
## all. Instant and silent: the shoes are frozen at rest, so
## this is a clean teleport, never a visible flight. Runs
## only in PRACTICE with the active shoe at rest (state
## STAND) - a held, flying or still-settling shoe is never
## touched, a game in progress places its own shoes, and at
## neither line nothing moves. Fix Pass 19 re-anchors it to
## the one pitching end: the pair homes to the station (the
## 37 ft line) or the peg post (the 27 ft line) by which line
## the player is pitching from.
##
## Defect history: before Fix Pass 7 the home was set ONLY at
## latch time, from the shoe's own position (_nearest_stand_line).
## The shoe starts on the 40 ft pedestal and could only reach a
## pedestal by being returned to the current home, so every
## latch re-homed it to the pedestal it was already sitting on -
## the 30 ft pedestal could become home only by being grabbed
## from, which required the shoe to already be there. It never
## was. Chris, in the headset: "the shorter distance podium
## doesn't spawn a horseshoe, very stingy."
func _restock_to_player_line() -> void:
	if mode != "PRACTICE" or state != "STAND":
		return
	var want_line: int = ThrowMath.standing_line_ft(cam.global_position, STAKE_POS)
	if want_line == 0 or want_line == active_stand_line_ft:
		return
	_set_active_stand(want_line)
	for s: Shoe in _all_shoes():
		if String(shoe_status[s]) == "RAILED":
			s.freeze = true
			# Fix Pass 18: the AI pair has no 30 ft home - it
			# waits at the 40 ft game station.
			var s_line: int = 40 if _is_ai_shoe(s) else want_line
			s.global_transform = rack_slot_tf(s_line,
				_is_ai_shoe(s), _pair_index_of(s))
			s.clear_highlights()


func _all_shoes() -> Array:
	var out: Array = []
	out.append_array(player_pair)
	out.append_array(ai_pair)
	return out


func _nearest_stand_line() -> int:
	var best_line: int = active_stand_line_ft
	var best_dist: float = INF
	for line_ft: int in [40, 30]:
		var tf: Transform3D = stand_tfs[line_ft]
		var d: float = shoe.global_position.distance_to(tf.origin)
		if d < best_dist:
			best_dist = d
			best_line = line_ft
	return best_line


## One owner's STATION (Backyard Game v1 photo feed; Backyard
## v2 Stage 1 rebuilds it as furniture in the "BUBBA" photo's
## family): a chunky stacked-timber body whose owner's pair
## hangs on the rail beam in front of its face, a top shelf
## with a bottle and a cup, generic roundel stickers on the
## face, a bottle opener on the pit-side end and the cleaning
## file hanging on the other end. The FUNCTION is the FP13
## rail stand's, untouched: slot 0 at base_pos, slot 1 one
## step down-lane, the pair presenting face-on to the stance;
## only the furniture around the slots changed. step_dir:
## the down-lane direction at this end (-1 toward the far
## stake, +1 toward the home stake); sx: the station's side
## sign (the body stands behind the slots, away from the
## stance; the shelf and face look back at the owner).
func _build_station(base_pos: Vector3, sx: float, step_dir: float) -> void:
	var timber := _mat(Color(0.52, 0.40, 0.26))
	var timber_alt := _mat(Color(0.46, 0.34, 0.22))
	var mid_z: float = base_pos.z + SLOT_STEP * 0.5 * step_dir
	var body_x: float = base_pos.x + 0.30 * sx
	# Stacked-timber body: five boards with a hand-stacked
	# whisper of z jitter, alternating weathered shades.
	for i: int in 5:
		var slab_mat: Material = timber if i % 2 == 0 else timber_alt
		_box(self, Vector3(body_x, 0.0935 + 0.187 * float(i),
			mid_z + (0.008 if i % 2 == 0 else -0.008)),
			Vector3(0.36, 0.187, 0.86), slab_mat)
	# Top shelf, overhanging the body toward the stance but
	# clearing the hanging pair's bridges below it.
	_box(self, Vector3(base_pos.x + 0.27 * sx, 0.96, mid_z),
		Vector3(0.50, 0.05, 0.96), _mat(Color(0.55, 0.43, 0.28)))
	# The rail beam the pair hangs on (the FP13 rail, in
	# timber), carried on two arms from the body's face.
	_box(self, Vector3(base_pos.x, 0.885, mid_z),
		Vector3(0.07, 0.07, SLOT_STEP + 0.30), timber_alt)
	for arm_z: float in [base_pos.z - 0.06 * step_dir,
			base_pos.z + (SLOT_STEP + 0.06) * step_dir]:
		_box(self, Vector3(base_pos.x + 0.09 * sx, 0.885, arm_z),
			Vector3(0.14, 0.05, 0.06), timber)
	# Shelf props: a bottle and a cup, backyard clutter.
	_cyl(self, Vector3(base_pos.x + 0.30 * sx, 1.065, mid_z - 0.28),
		0.032, 0.16, _mat(Color(0.13, 0.25, 0.16)))
	_cyl(self, Vector3(base_pos.x + 0.30 * sx, 1.18, mid_z - 0.28),
		0.011, 0.07, _mat(Color(0.13, 0.25, 0.16)))
	_cyl(self, Vector3(base_pos.x + 0.22 * sx, 1.03, mid_z + 0.30),
		0.040, 0.09, _mat(Color(0.62, 0.32, 0.22)))
	# Roundel stickers on the face (generic two-tone discs -
	# no brands), scattered like the photo's.
	var face_x: float = base_pos.x + 0.115 * sx
	var sticker_specs: Array = [
		[0.58, -0.24, Color(0.72, 0.22, 0.16), Color(0.92, 0.88, 0.78)],
		[0.63, 0.03, Color(0.16, 0.45, 0.48), Color(0.92, 0.88, 0.78)],
		[0.52, 0.27, Color(0.85, 0.62, 0.18), Color(0.25, 0.24, 0.24)],
	]
	for spec: Array in sticker_specs:
		var disc: MeshInstance3D = _cyl(self,
			Vector3(face_x, float(spec[0]), mid_z + float(spec[1])),
			0.045, 0.008, _mat(spec[2]))
		disc.rotation.z = PI * 0.5
		var inner: MeshInstance3D = _cyl(self,
			Vector3(face_x - 0.003 * sx, float(spec[0]), mid_z + float(spec[1])),
			0.026, 0.010, _mat(spec[3]))
		inner.rotation.z = PI * 0.5
	# Bottle opener on the pit-side end: a dark steel plate
	# with its lip, the BUBBA station's left-end detail.
	var end_z: float = mid_z + 0.43 * step_dir
	var steel := _mat(Color(0.23, 0.23, 0.25))
	_box(self, Vector3(body_x, 0.62, end_z + 0.008 * step_dir),
		Vector3(0.10, 0.13, 0.015), steel)
	_box(self, Vector3(body_x, 0.545, end_z + 0.016 * step_dir),
		Vector3(0.06, 0.03, 0.03), steel)
	# The cleaning file on the far end: black handle over a
	# long thin blade, hanging flat against the end boards.
	var file_z: float = mid_z - 0.43 * step_dir
	_box(self, Vector3(body_x, 0.72, file_z - 0.012 * step_dir),
		Vector3(0.035, 0.10, 0.02), _mat(Color(0.10, 0.10, 0.11)))
	_box(self, Vector3(body_x, 0.50, file_z - 0.006 * step_dir),
		Vector3(0.016, 0.32, 0.008), _mat(Color(0.55, 0.56, 0.58)))


## The player's PRACTICE home at a 30 ft line (Fix Pass 18,
## Chris's Stage 1 verdict: "get rid of the duplicate shelves
## along the side"). The FP7 rule still needs the pair to wait
## where the player stands at each short line, but a second
## shelf per line was furniture the court never earned: in its
## place stands ONE slim peg post - a single low timber post
## behind the slots with a peg reaching to each slot point,
## nothing else. The slot transforms (and so the hang, the
## grab, the restock) are the FP13 ones, untouched; only what
## STANDS at the practice point changed. base_pos/sx/step_dir
## carry the same meanings as in _build_station.
func _build_peg_post(base_pos: Vector3, sx: float, step_dir: float) -> void:
	var timber := _mat(Color(0.52, 0.40, 0.26))
	var timber_alt := _mat(Color(0.46, 0.34, 0.22))
	var mid_z: float = base_pos.z + SLOT_STEP * 0.5 * step_dir
	var post_x: float = base_pos.x + 0.24 * sx
	# The post: slim, square, just tall enough to carry the
	# pegs at rail height (0.885, the station rail's height).
	_box(self, Vector3(post_x, 0.465, mid_z),
		Vector3(0.09, 0.93, 0.09), timber)
	# One peg per slot, reaching from the post to the slot
	# point the shoe hangs on.
	for idx: int in 2:
		var slot_z: float = base_pos.z + SLOT_STEP * float(idx) * step_dir
		_box(self, Vector3(base_pos.x + 0.10 * sx, 0.885, slot_z),
			Vector3(0.28, 0.045, 0.05), timber_alt)


func _build_world() -> void:
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48.0, -24.0, 0.0)
	sun.light_energy = 1.1
	add_child(sun)
	var we := WorldEnvironment.new()
	var env := Environment.new()
	# Fix Pass 10: a real sky (procedural gradient + sun disc)
	# replaces the flat clear colour - one of the static references
	# the comfort dressing hangs on. Ambient stays the settled
	# colour source so the judged court lighting does not move.
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.22, 0.44, 0.78)
	sky_mat.sky_horizon_color = Color(0.72, 0.81, 0.90)
	sky_mat.sky_curve = 0.12
	sky_mat.ground_bottom_color = Color(0.18, 0.24, 0.16)
	sky_mat.ground_horizon_color = Color(0.72, 0.81, 0.90)
	sky_mat.ground_curve = 0.08
	sky_mat.sun_angle_max = 25.0
	var sky := Sky.new()
	sky.sky_material = sky_mat
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.75, 0.78, 0.72)
	env.ambient_light_energy = 0.7
	we.environment = env
	add_child(we)

	var ground_phys := PhysicsMaterial.new()
	ground_phys.friction = 0.7
	ground_phys.bounce = 0.35
	_static_box(Vector3(0.0, -0.05, -6.0), Vector3(40.0, 0.1, 48.0), _mat(Color(0.32, 0.52, 0.26)), ground_phys)

	# Fix Pass 19: ONE pit - the real backyard form (Chris's
	# call, verified against NHPA geometry): one timber sand
	# pit at the far end, a pitching end with true foul lines,
	# and one-way play. The two-pit build is gone from this
	# scene; _build_pit stays a reusable builder that takes a
	# stake position and a key, because the park venue will
	# need a two-pit court later.
	_build_pit(STAKE_POS, "FAR")

	# True foul lines, painted across the lane at the pitching
	# end only (Fix Pass 19): the 37 ft line for 40 ft play
	# and the 27 ft line for the 30 ft class. Before FP19 both
	# ends carried strips - the "40 ft" ones on the stakes'
	# own planes, passing through the pits.
	_box(self, Vector3(0.0, 0.006, FOUL_40_Z), Vector3(1.8, 0.012, 0.07), _mat(Color(0.92, 0.92, 0.90)))
	_box(self, Vector3(0.0, 0.006, FOUL_30_Z), Vector3(1.6, 0.012, 0.07), _mat(Color(0.92, 0.92, 0.90)))

	# The pitching end's furniture (Fix Pass 19): one BUBBA
	# station per owner flanking the pitching area at the
	# 37 ft line - the player's on his right, the AI's on its
	# left, each a reach-over outboard of its owner's pitching
	# spot (the FP13 law, translated to the spots) - and ONE
	# slim peg post at the 27 ft line for the player's
	# practice pair (the FP18 pattern). The far end has no
	# stations any more: nobody pitches from there.
	_build_station(stand_tfs[40].origin, station_side(false), -1.0)
	_build_station(ai_stand_tfs[40].origin, station_side(true), -1.0)
	_build_peg_post(stand_tfs[30].origin, station_side(false), -1.0)

	_build_scenery()


## One pit + stake (Backyard Game v1's builder, kept
## reusable for the park's two-pit court: it takes a stake
## position and a key, and builds the whole judged
## construction - sand, timber frame, the 1 in stake on its
## leaning pivot, the +3 mm collision core (Fix Pass 8) and
## the sweep-guard axis the shoe reads (Fix Pass 9). The
## key names the end: "FAR" leans the stake toward +z and
## opens the pit's front to +z (the pitching side); a second
## pit built with the mirrored key would lean and open the
## other way.
func _build_pit(stake_pos: Vector3, key: String) -> void:
	# Sand pit (Backyard v2 Stage 1, Chris's timber-pit photo):
	# sand digs and dies - no bounce at all, full friction taken
	# rough so the combined value stays 1.0 against the shoe,
	# absorbent on top. Measured against the old clay (friction
	# 1.0, bounce 0.04) with tests/sand_measure.gd at real
	# pacing; the numbers are in the pass report. The pit BODY
	# keeps the judged clay box's exact footprint - the
	# scoring area (36x72 in) and the stake do not move.
	# Fix Pass 19: the body SINKS so its top sits at grade
	# (2 mm proud, only to keep its face off the ground's) -
	# a shoe sliding in off the grass meets no lip anywhere,
	# the front included (see the threshold below).
	var sand_phys := PhysicsMaterial.new()
	sand_phys.friction = 1.0
	sand_phys.rough = true
	sand_phys.bounce = 0.0
	sand_phys.absorbent = true
	var pit_pos := Vector3(stake_pos.x, stake_pos.y - 0.023, stake_pos.z)
	var sand_mat := StandardMaterial3D.new()
	sand_mat.albedo_color = Color(0.76, 0.66, 0.47)
	sand_mat.roughness = 1.0
	_static_box(pit_pos, PIT_SIZE, sand_mat, sand_phys)
	# The box zone's apron (Fix Pass 19): regulation puts the
	# pit inside a 6 ft x 6 ft pitcher's box with platforms
	# flanking it LEVEL with the pit top. Here that whole zone
	# is one flat sheet of worn apron at grade - standing
	# beside this pit reads as standing on the ground, because
	# it is the ground. (It replaces Stage 1's big spilled-sand
	# surround, which read as part of the pit and put the
	# "standing in a pit" feeling under the player's feet at
	# the old home end.)
	_box(self, Vector3(stake_pos.x, 0.004, stake_pos.z),
		Vector3(1.83, 0.008, 1.83), _mat(Color(0.60, 0.57, 0.38)))
	# Timber frame, SUNK TO GRADE (Fix Pass 19): two courses
	# of weathered railroad ties on the pit border, the lower
	# course buried (its top at grade), one course standing
	# above it - the frame reads as edging set into the
	# ground, not a planter box. Inner faces flush with the
	# scoring footprint; no gameplay dimension moves. The
	# sides and the back carry COLLISION (a shoe hitting the
	# back timber and stopping is real); the front - the
	# pitcher-facing side - has NO board across (Chris's
	# explicit order): only a low threshold whose top is at
	# sand level, visual only, so arrivals slide in unimpeded
	# in physics as well as looks.
	var front_sign: float = 1.0 if key == "FAR" else -1.0
	var tie_dark := _mat(Color(0.33, 0.26, 0.19))
	var tie_grey := _mat(Color(0.41, 0.35, 0.28))
	var tie_w: float = 0.24
	var tie_h: float = 0.14
	var side_x: float = PIT_SIZE.x * 0.5 + tie_w * 0.5
	var end_z: float = PIT_SIZE.z * 0.5 + tie_w * 0.5
	# Side ties: the buried course is underground and unseen -
	# only the standing course is built, as a static body so
	# its mesh and its collision are the same timber.
	for sx: float in [-1.0, 1.0]:
		var side_body: StaticBody3D = _static_box(
			Vector3(sx * side_x, tie_h * 0.5, stake_pos.z),
			Vector3(tie_w, tie_h, PIT_SIZE.z + tie_w * 2.0),
			tie_grey if sx < 0.0 else tie_dark, null)
		# Hand-laid, not machined: a whisper of yaw.
		side_body.rotation.y = 0.006 if sx < 0.0 else -0.005
	# Back tie: same construction, across the pit's far end.
	_static_box(Vector3(0.0, tie_h * 0.5,
			stake_pos.z - front_sign * end_z),
		Vector3(PIT_SIZE.x, tie_h, tie_w), tie_dark, null)
	# The front threshold: a flat board sunk to sand level
	# across the pit's mouth - an edge line in the grass,
	# nothing for a shoe to hit.
	_box(self, Vector3(0.0, -0.028, stake_pos.z + front_sign * end_z),
		Vector3(PIT_SIZE.x, 0.06, tie_w), tie_grey)

	# Stake: 1 in steel, top 14.5 in above the pit, leaning ~8 deg
	# toward the pitcher who throws at it. The far stake leans
	# toward +z (its pitcher stands at z > stake); the home stake
	# mirrors, leaning toward -z. Pivot at the pit surface.
	var lean: float = 8.0 if key == "FAR" else -8.0
	var stake_pivot := Node3D.new()
	stake_pivot.position = stake_pos
	stake_pivot.rotation_degrees = Vector3(lean, 0.0, 0.0)
	add_child(stake_pivot)
	var stake_body := StaticBody3D.new()
	stake_pivot.add_child(stake_body)
	var smi := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = STAKE_VISUAL_RADIUS
	cyl.bottom_radius = STAKE_VISUAL_RADIUS
	cyl.height = 0.62
	smi.mesh = cyl
	smi.position = Vector3(0.0, 0.058, 0.0)
	smi.material_override = _mat(Color(0.55, 0.57, 0.62))
	stake_body.add_child(smi)
	# Fix Pass 8 - the stake is NOT hollow, and never was: the
	# collision shape is a solid CylinderShape3D, audited in code
	# and at runtime. The hole is step size: at 60 Hz a 9 m/s shoe
	# travels ~15 cm per physics step past a 25 mm target, and the
	# shoe's shape-cast CCD sweeps its LINEAR motion only - it
	# cannot sweep the tumble. Chris's one ghost in 88 throws
	# (2026-11-02) crossed ~9 cm off centre at 0.18 m height,
	# mid-skip after a touchdown: exactly the phase a step or a
	# linear cast can slip. The collision core therefore runs
	# +3 mm fat (the mesh stays a true 1 in) - enough to close
	# graze-phase gaps, small enough to stay inside the visual
	# contact tolerance of a 21-27 mm thick shoe, so no honest
	# near-miss gets stolen. Scoring geometry (ringer window,
	# landing distance) still measures against the true 1 in
	# stake; only contact wears the extra 3 mm.
	var scs := CollisionShape3D.new()
	var scyl := CylinderShape3D.new()
	scyl.radius = STAKE_COLLISION_RADIUS
	scyl.height = 0.62
	scs.shape = scyl
	scs.position = Vector3(0.0, 0.058, 0.0)
	stake_body.add_child(scs)
	# Fix Pass 9: even the fat core + CCD does not stop a fast
	# FLAT shoe in the upper band (measured ghosts at centre
	# heights 0.21-0.34, sub-step graze windows the cast misses).
	# The shoe therefore carries a sweep guard against the stake
	# it is thrown at (see shoe.gd): at every release the shoe is
	# handed the target stake's body and axis endpoints. They are
	# registered here, per stake.
	var axis_a: Vector3 = stake_pivot.global_transform * Vector3(0.0, 0.058 - 0.31, 0.0)
	var axis_b: Vector3 = stake_pivot.global_transform * Vector3(0.0, 0.058 + 0.31, 0.0)
	stakes[key] = {"body": stake_body, "axis_a": axis_a, "axis_b": axis_b, "pos": stake_pos}
	if key == "FAR":
		stake_body_node = stake_body
		stake_axis_a = axis_a
		stake_axis_b = axis_b


## The stake being thrown at - since Fix Pass 19 there is
## exactly one, at the far end of the one-way court.
func target_stake_key() -> String:
	return "FAR"


func target_stake_pos() -> Vector3:
	return STAKE_POS


## Fix Pass 10 scenery / comfort dressing: the first sketch of the
## backyard. Chris gets queasy moving in the bare test court - his
## diagnosis: "lack of anything in background, no objects, flat
## plane." Everything here is a STATIC VISUAL REFERENCE at some
## distance (mow stripes underfoot, fence at the yard edge, trees
## and a shed mid/far, sky + clouds above); nothing collides,
## nothing moves, and the judged court surfaces - pit, lines,
## racks, stake - are untouched. Placement keeps the court
## apron (|x| <= 2.3, z -14.8..1.6) bare of stripes and keeps the
## board sightline from both foul lines clear; the smoke suite
## asserts the sightline clearance so dressing can never creep
## in front of the board.
func _build_scenery() -> void:
	scenery_root = Node3D.new()
	scenery_root.name = "Scenery"
	add_child(scenery_root)

	# --- Mow stripes: light bands laid over the base green,
	# running down the yard (away from the pitcher), skipping the
	# court apron. Thin visual-only boxes, no collision.
	var stripes := Node3D.new()
	stripes.name = "Stripes"
	scenery_root.add_child(stripes)
	var stripe_mat := _mat(Color(0.40, 0.60, 0.30))
	var band_w: float = 1.4
	var band_i: int = 0
	var band_x: float = -19.6 + band_w * 0.5
	while band_x < 19.6:
		if band_i % 2 == 0:
			if absf(band_x) < 3.0:
				# Band crosses the apron: two stubs, behind the
				# foul lines and beyond the pit.
				_box(stripes, Vector3(band_x, 0.002, 9.8), Vector3(band_w, 0.004, 16.4), stripe_mat)
				_box(stripes, Vector3(band_x, 0.002, -22.4), Vector3(band_w, 0.004, 15.2), stripe_mat)
			else:
				_box(stripes, Vector3(band_x, 0.002, -6.0), Vector3(band_w, 0.004, 48.0), stripe_mat)
		band_i += 1
		band_x += band_w

	# --- Perimeter fence: vertical wooden slats + two rails per
	# run, at the yard edge (x +/-13, z -20 / +7) - the backyard
	# fence from Chris's photo feed. One shared slat mesh.
	var fence := Node3D.new()
	fence.name = "Fence"
	scenery_root.add_child(fence)
	var slat_mesh := BoxMesh.new()
	slat_mesh.size = Vector3(0.24, 1.75, 0.03)
	var wood_a := _mat(Color(0.52, 0.40, 0.26))
	var wood_b := _mat(Color(0.47, 0.36, 0.23))
	var rail_mat := _mat(Color(0.44, 0.33, 0.21))
	var post_mesh := BoxMesh.new()
	post_mesh.size = Vector3(0.12, 1.85, 0.12)
	# Runs: [start, end] pairs along the rectangle.
	var runs: Array = [
		[Vector2(-13.0, -20.0), Vector2(13.0, -20.0)],
		[Vector2(-13.0, 7.0), Vector2(13.0, 7.0)],
		[Vector2(-13.0, -20.0), Vector2(-13.0, 7.0)],
		[Vector2(13.0, -20.0), Vector2(13.0, 7.0)],
	]
	for run: Array in runs:
		var a: Vector2 = run[0]
		var b: Vector2 = run[1]
		var run_len: float = a.distance_to(b)
		var dir2: Vector2 = (b - a) / run_len
		var yaw: float = atan2(dir2.x, dir2.y) + PI * 0.5
		var n_slats: int = int(run_len / 0.275)
		for s: int in n_slats:
			var c2: Vector2 = a + dir2 * (0.14 + float(s) * 0.275)
			var slat := MeshInstance3D.new()
			slat.mesh = slat_mesh
			slat.material_override = wood_a if s % 2 == 0 else wood_b
			slat.position = Vector3(c2.x, 0.875, c2.y)
			slat.rotation_degrees = Vector3(0.0, rad_to_deg(yaw), 0.0)
			fence.add_child(slat)
		for rail_y: float in [0.50, 1.35]:
			var rail := MeshInstance3D.new()
			var rail_mesh := BoxMesh.new()
			rail_mesh.size = Vector3(run_len, 0.09, 0.04)
			rail.mesh = rail_mesh
			rail.material_override = rail_mat
			var mid2: Vector2 = (a + b) * 0.5
			rail.position = Vector3(mid2.x, rail_y, mid2.y)
			rail.rotation_degrees = Vector3(0.0, rad_to_deg(yaw), 0.0)
			fence.add_child(rail)
		var n_posts: int = int(run_len / 3.25)
		for p: int in range(n_posts + 1):
			var c2: Vector2 = a + dir2 * (float(p) * run_len / float(n_posts))
			var post := MeshInstance3D.new()
			post.mesh = post_mesh
			post.material_override = rail_mat
			post.position = Vector3(c2.x, 0.925, c2.y)
			fence.add_child(post)

	# --- Trees: trunk + canopy masses at varied distances.
	var trunk_mat := _mat(Color(0.35, 0.25, 0.16))
	var leaf_a := _mat(Color(0.22, 0.42, 0.18))
	var leaf_b := _mat(Color(0.27, 0.48, 0.21))
	var tree_spots: Array = [
		[Vector3(-8.5, 0.0, -19.5), 1.15],
		[Vector3(7.0, 0.0, -19.0), 1.0],
		[Vector3(-11.5, 0.0, -9.0), 1.25],
		[Vector3(11.0, 0.0, -5.0), 0.95],
		[Vector3(-7.5, 0.0, 4.5), 1.05],
		[Vector3(12.0, 0.0, 3.0), 1.2],
	]
	var tree_i: int = 0
	for spot: Array in tree_spots:
		tree_i += 1
		var tp: Vector3 = spot[0]
		var sc: float = spot[1]
		var tree := Node3D.new()
		tree.name = "Tree%d" % tree_i
		tree.position = tp
		scenery_root.add_child(tree)
		var trunk := MeshInstance3D.new()
		var trunk_mesh := CylinderMesh.new()
		trunk_mesh.top_radius = 0.14 * sc
		trunk_mesh.bottom_radius = 0.22 * sc
		trunk_mesh.height = 2.2 * sc
		trunk.mesh = trunk_mesh
		trunk.material_override = trunk_mat
		trunk.position = Vector3(0.0, 1.1 * sc, 0.0)
		tree.add_child(trunk)
		var blobs: Array = [
			[Vector3(0.0, 3.1, 0.0) * sc, 1.6],
			[Vector3(0.85, 2.55, 0.3) * sc, 1.1],
			[Vector3(-0.8, 2.65, -0.35) * sc, 1.05],
		]
		var blob_i: int = 0
		for blob: Array in blobs:
			blob_i += 1
			var bp2: Vector3 = blob[0]
			var br: float = float(blob[1]) * sc
			var can := MeshInstance3D.new()
			var sm := SphereMesh.new()
			sm.radius = br
			sm.height = br * 2.0
			sm.radial_segments = 12
			sm.rings = 8
			can.mesh = sm
			can.material_override = leaf_a if blob_i % 2 == 1 else leaf_b
			can.position = bp2
			tree.add_child(can)

	# --- Shed: simple box body + pitched roof + door, off to the
	# right beyond the pit (Chris's photo feed has the white shed).
	var shed := Node3D.new()
	shed.name = "Shed"
	shed.position = Vector3(9.5, 0.0, -13.0)
	shed.rotation_degrees = Vector3(0.0, -12.0, 0.0)
	scenery_root.add_child(shed)
	var shed_mat := _mat(Color(0.62, 0.64, 0.66))
	_box(shed, Vector3(0.0, 1.075, 0.0), Vector3(2.8, 2.15, 2.1), shed_mat)
	var roof_mat := _mat(Color(0.30, 0.28, 0.28))
	var roof_l := _box(shed, Vector3(-0.72, 2.42, 0.0), Vector3(1.75, 0.07, 2.4), roof_mat)
	roof_l.rotation_degrees = Vector3(0.0, 0.0, 38.0)
	var roof_r := _box(shed, Vector3(0.72, 2.42, 0.0), Vector3(1.75, 0.07, 2.4), roof_mat)
	roof_r.rotation_degrees = Vector3(0.0, 0.0, -38.0)
	_box(shed, Vector3(0.0, 0.95, 1.06), Vector3(0.8, 1.5, 0.04), _mat(Color(0.45, 0.47, 0.50)))

	# --- Clouds: flattened bright puffs, unshaded, high and far.
	var clouds := Node3D.new()
	clouds.name = "Clouds"
	scenery_root.add_child(clouds)
	var cloud_mat := StandardMaterial3D.new()
	cloud_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	cloud_mat.albedo_color = Color(0.97, 0.98, 1.0)
	var cloud_spots: Array = [
		[Vector3(-14.0, 30.0, -34.0), Vector3(7.0, 1.1, 3.5)],
		[Vector3(6.0, 34.0, -28.0), Vector3(9.0, 1.4, 4.0)],
		[Vector3(16.0, 28.0, -12.0), Vector3(6.0, 1.0, 3.0)],
		[Vector3(-20.0, 32.0, -2.0), Vector3(8.0, 1.2, 3.6)],
		[Vector3(2.0, 36.0, -44.0), Vector3(11.0, 1.6, 4.5)],
		[Vector3(12.0, 30.0, 10.0), Vector3(6.5, 1.0, 3.2)],
	]
	for cspot: Array in cloud_spots:
		var cp: Vector3 = cspot[0]
		var cs2: Vector3 = cspot[1]
		var puff := MeshInstance3D.new()
		var pm := SphereMesh.new()
		pm.radius = 1.0
		pm.height = 2.0
		pm.radial_segments = 12
		pm.rings = 8
		puff.mesh = pm
		puff.material_override = cloud_mat
		puff.position = cp
		puff.scale = cs2
		clouds.add_child(puff)

	# --- Landscaped lane rows (Fix Pass 18, Chris's Stage 1
	# verdict): where the deleted practice shelves lined the
	# lane now runs a landscaped row down EACH side - a low,
	# smooth grass berm (crest ~0.26 m) with shrubs dotted
	# along it in the tree palette. The rows sit outside the
	# lane, clear of the stances and swing space (inner toe at
	# |x| 1.5), and run between the ends without touching
	# either pit's sand surround. Visual only, like all the
	# dressing; two shared shrub meshes and the tree materials
	# keep the poly and material count down.
	var lane_rows := Node3D.new()
	lane_rows.name = "LaneRows"
	scenery_root.add_child(lane_rows)
	var berm_mesh := SphereMesh.new()
	berm_mesh.radius = 1.0
	berm_mesh.height = 2.0
	berm_mesh.radial_segments = 20
	berm_mesh.rings = 10
	var berm_mat := _mat(Color(0.37, 0.57, 0.28))
	var shrub_mesh_a := SphereMesh.new()
	shrub_mesh_a.radius = 0.30
	shrub_mesh_a.height = 0.60
	shrub_mesh_a.radial_segments = 10
	shrub_mesh_a.rings = 6
	var shrub_mesh_b := SphereMesh.new()
	shrub_mesh_b.radius = 0.22
	shrub_mesh_b.height = 0.44
	shrub_mesh_b.radial_segments = 10
	shrub_mesh_b.rings = 6
	var shrub_mats: Array = [leaf_a, leaf_b, leaf_a,
		_mat(Color(0.48, 0.54, 0.34))]
	var shrub_z: Array = [-2.3, -3.05, -3.8, -4.6, -5.35, -6.1,
		-6.9, -7.65, -8.4, -9.2, -9.9]
	var shrub_jx: Array = [0.10, -0.12, 0.05, -0.06, 0.13, -0.10,
		0.0, 0.08, -0.13, 0.06, -0.04]
	var shrub_sxz: Array = [1.0, 0.9, 1.12, 0.95]
	for sx: float in [-1.0, 1.0]:
		var row := Node3D.new()
		row.name = "RowL" if sx < 0.0 else "RowR"
		lane_rows.add_child(row)
		var berm := MeshInstance3D.new()
		berm.name = "Berm"
		berm.mesh = berm_mesh
		berm.material_override = berm_mat
		berm.position = Vector3(sx * 2.05, 0.0, -6.05)
		berm.scale = Vector3(0.55, 0.26, 4.15)
		row.add_child(berm)
		var phase: int = 0 if sx > 0.0 else 5
		for i: int in shrub_z.size():
			var shrub := MeshInstance3D.new()
			shrub.name = "Shrub"
			var big: bool = i % 2 == 0
			shrub.mesh = shrub_mesh_a if big else shrub_mesh_b
			var smat: Material = shrub_mats[i % shrub_mats.size()]
			shrub.material_override = smat
			var jx: float = float(shrub_jx[(i + phase) % shrub_jx.size()])
			var sxz: float = float(shrub_sxz[i % shrub_sxz.size()])
			shrub.position = Vector3(sx * (2.05 + jx),
				0.39 if big else 0.35, float(shrub_z[i]))
			shrub.scale = Vector3(sxz, 0.8 if big else 0.85, sxz)
			row.add_child(shrub)


func _build_rig() -> void:
	origin = XROrigin3D.new()
	origin.name = "Origin"
	add_child(origin)
	cam = XRCamera3D.new()
	origin.add_child(cam)
	var xr_interface: XRInterface = XRServer.find_interface("OpenXR")
	if xr_interface != null and xr_interface.is_initialized():
		get_viewport().use_xr = true
		xr_ok = true
	else:
		var fallback := Camera3D.new()
		fallback.position = Vector3(0.0, 1.55, 1.15)
		add_child(fallback)
		fallback.look_at(Vector3(0.0, 0.35, -5.5), Vector3.UP)
		fallback.current = true
	for hand: String in ["L", "R"]:
		var tracker_name: StringName = &"left_hand" if hand == "L" else &"right_hand"
		var c := XRController3D.new()
		c.tracker = tracker_name
		origin.add_child(c)
		hand_ctrl[hand] = c
		_build_controller_rep(c, hand)


func _build_controller_rep(ctrl: XRController3D, hand: String) -> void:
	var rep := Node3D.new()
	rep.name = "ControllerRep" + hand
	ctrl.add_child(rep)
	ctrl_rep[hand] = rep
	var accent: Color = Color(0.25, 0.85, 1.0) if hand == "L" else Color(1.0, 0.55, 0.2)
	var body := MeshInstance3D.new()
	var body_mesh := BoxMesh.new()
	body_mesh.size = Vector3(0.038, 0.026, 0.105)
	body.mesh = body_mesh
	body.material_override = _mat(Color(0.72, 0.74, 0.78))
	body.position = Vector3(0.0, -0.005, 0.005)
	body.rotation_degrees = Vector3(-18.0, 0.0, 0.0)
	rep.add_child(body)
	var band := MeshInstance3D.new()
	var band_mesh := BoxMesh.new()
	band_mesh.size = Vector3(0.040, 0.010, 0.024)
	band.mesh = band_mesh
	band.material_override = _mat(accent, 1.2)
	band.position = Vector3(0.0, 0.006, -0.018)
	band.rotation_degrees = Vector3(-18.0, 0.0, 0.0)
	rep.add_child(band)
	var tag := Label3D.new()
	tag.text = hand
	tag.font_size = 64
	tag.pixel_size = 0.0009
	tag.modulate = accent
	tag.outline_size = 8
	tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	tag.position = Vector3(0.0, 0.045, 0.0)
	rep.add_child(tag)


func _head_tracking_ok() -> bool:
	var t: XRPositionalTracker = XRServer.get_tracker(&"head") as XRPositionalTracker
	if t == null:
		return false
	var pose: XRPose = t.get_pose(&"default")
	if pose == null:
		return false
	return pose.has_tracking_data


func _build_board() -> void:
	board_root = Node3D.new()
	# Fix Pass 10 placement (Chris's order): BEYOND the pit, LEFT
	# of the stake from the pitcher's viewpoint, face turned back
	# at the pitching end - after a throw he reads the results
	# where he is already looking, instead of turning around to a
	# board by the foul line. Pass 2 put the FP1 board front-left
	# of the spot after pass 1's yaw sign pointed its face AWAY
	# from the player (he had been reading its back); the smoke
	# suite's facing assertion survives from that lesson and now
	# guards THIS spot. The board is scoreboard-sized (3 m wide,
	# slab top 3.2 m) because the stat lines must read from
	# 13-16 m: ~0.21 m capitals, with the controls list in smaller
	# type below for the one close-up read. Label Y positions are
	# laid out on the font's TRUE line pitch (get_height = 1.375x
	# font_size for the fallback font - a first cut that assumed
	# 1.0x overlapped title into status in the close-up proof).
	board_root.position = BOARD_POS
	board_root.rotation_degrees = Vector3(0.0, BOARD_YAW_DEG, 0.0)
	add_child(board_root)
	var wood := _mat(Color(0.30, 0.21, 0.12))
	_box(board_root, Vector3(-1.38, 1.75, -0.03), Vector3(0.09, 3.50, 0.09), wood)
	_box(board_root, Vector3(1.38, 1.75, -0.03), Vector3(0.09, 3.50, 0.09), wood)
	_box(board_root, Vector3(0.0, 1.85, -0.02), board_slab_size, wood)
	title_label = Label3D.new()
	title_label.text = "HORSESHOES - BACKYARD"
	title_label.font_size = 56
	title_label.pixel_size = 0.0026
	title_label.modulate = Color(1.0, 0.93, 0.75)
	title_label.outline_size = 10
	title_label.outline_modulate = Color(0.1, 0.07, 0.03)
	title_label.position = Vector3(0.0, 3.04, 0.01)
	board_root.add_child(title_label)
	# Backyard Game v1: the status block grows to 7 worst-case
	# lines (game score/turn/result/prompt joins the practice
	# readouts), so the status font steps down a size (58/0.0029,
	# ~0.17 m capitals - still distance-legible) and the controls
	# block steps down with it. The smoke suite's slab-fit guard
	# measures both blocks at their new worst cases.
	status_label = Label3D.new()
	status_label.font_size = 58
	status_label.pixel_size = 0.0029
	status_label.modulate = Color(0.95, 0.97, 0.90)
	status_label.outline_size = 8
	status_label.outline_modulate = Color(0.1, 0.07, 0.03)
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status_label.position = Vector3(0.0, 2.06, 0.01)
	board_root.add_child(status_label)
	controls_label = Label3D.new()
	controls_label.text = "CONTROLS\nGRAB: squeeze a glinting part of the shoe\ntoe = FLIP hold - side = TURN hold\nSLIDE: Grip + trigger: slide grip along shoe\nlet go of trigger to lock the new grip\nA / X WHILE HOLDING A SHOE: CHANGE GRIP\nTHROW: swing and open the hand\nDROP: open hand while still\nLeft stick: move\nRight stick: turn\n30 FT LINE: up the court - learning distance\nA BUTTON (EMPTY HAND): start game / next round / play again\nB BUTTON: back to practice (in a game)\nRECENTER: menu long-press - seated/standing ok"
	controls_label.font_size = 30
	controls_label.pixel_size = 0.00095
	controls_label.line_spacing = 1.0
	controls_label.modulate = Color(0.88, 0.90, 0.82)
	controls_label.outline_size = 6
	controls_label.outline_modulate = Color(0.1, 0.07, 0.03)
	controls_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	controls_label.position = Vector3(0.0, 0.79, 0.01)
	board_root.add_child(controls_label)


func _update_board() -> void:
	if status_label == null:
		return
	var dist_text: String = "-"
	var flip_text: String = "-"
	var turn_text: String = "-"
	if last_distance_in >= 0.0:
		dist_text = "%.1f IN" % last_distance_in
		# Fix Pass 10 rotation readout (Chris approved): the same
		# flip_rot / turn_rot numbers the recorder writes to
		# throws.jsonl for this throw, so he can watch his turn
		# attempts actually turn (or not) from where he stands.
		flip_text = "%.2f REV" % last_flip_rev
		turn_text = "%.2f REV" % last_turn_rev
	var lines: Array = []
	if mode == "PRACTICE":
		lines = [
			"THROWS: %d" % throw_count,
			"HOLD: %s" % last_hold_text,
			"LAST: %s" % dist_text,
			"FLIP: %s" % flip_text,
			"TURN: %s" % turn_text,
		]
		if last_ringer:
			lines.append("RINGER!")
		lines.append("A: START GAME")
	elif phase == "OVER":
		lines = [
			"YOU %d - %d OPP" % [score_you, score_opp],
			winner_text,
			"FINAL - %d INNINGS" % inning,
			"A: PLAY AGAIN",
			"B: PRACTICE",
		]
	elif phase == "TABULATE":
		# Fix Pass 20: both sides have thrown and all four
		# shoes are down; the round is posting itself (the
		# insert cam is about to show the breakdown).
		lines = [
			"YOU %d - %d OPP" % [score_you, score_opp],
			"ROUND %d THROWN" % inning,
			"LAST: %s" % dist_text,
			"FLIP: %s" % flip_text,
			"TURN: %s" % turn_text,
		]
		if last_ringer:
			lines.append("RINGER!")
	elif phase == "INSERT":
		lines = [
			"YOU %d - %d OPP" % [score_you, score_opp],
			"ROUND %d DONE" % inning,
			"LAST INNING: %s" % last_inning_text,
			"A: NEXT ROUND",
		]
	else:
		var turn_text2: String = "YOUR THROW %d OF 2" % (3 - turn_throws_left) \
			if turn_side == "P" else "OPP THROWING"
		lines = [
			"YOU %d - %d OPP" % [score_you, score_opp],
			"INNING %d - %s" % [inning, turn_text2],
			"LAST: %s" % dist_text,
			"FLIP: %s" % flip_text,
			"TURN: %s" % turn_text,
			"LAST INNING: %s" % (last_inning_text if last_inning_text != "" else "-"),
		]
		if last_ringer:
			lines.append("RINGER!")
	status_label.text = "\n".join(PackedStringArray(lines))


## Point one shoe's stake sweep guard at a stake (Fix Pass 9's
## guard, generalised): called at spawn and again at EVERY
## release, since either stake can now be the target.
func _wire_guard(shoe_node: Shoe, stake_key: String) -> void:
	var st: Dictionary = stakes[stake_key]
	shoe_node.guard_axis_a = st["axis_a"]
	shoe_node.guard_axis_b = st["axis_b"]
	shoe_node.guard_radius = STAKE_COLLISION_RADIUS
	shoe_node.guard_body = st["body"]
	# guard_enabled is NOT set here: it is enabled once at spawn
	# and left alone after, so the Fix Pass 9 negative control
	# (guard deliberately disabled) survives a release.


func _make_shoe(pair_color: Color) -> Shoe:
	var s := Shoe.new()
	add_child(s)
	s.apply_tint(pair_color)
	_wire_guard(s, "FAR")
	s.guard_enabled = true
	s.freeze = true
	s.body_entered.connect(_on_any_shoe_body_entered.bind(s))
	shoe_status[s] = "RAILED"
	return s

## Four shoes: the player's yellow pair and the AI's blue pair,
## each stocked on its OWN rack at the home end's 40 ft line at
## boot (practice). The active shoe is the player's first; the
## state machine drives it exactly as the single test shoe was
## driven.
func _spawn_shoes() -> void:
	player_pair = [_make_shoe(PLAYER_PAIR_COLOR), _make_shoe(PLAYER_PAIR_COLOR)]
	ai_pair = [_make_shoe(AI_PAIR_COLOR), _make_shoe(AI_PAIR_COLOR)]
	shoe = player_pair[0]
	for s: Shoe in _all_shoes():
		s.global_transform = rack_slot_tf(40, _is_ai_shoe(s), _pair_index_of(s))
	state = "STAND"


func _build_ai() -> void:
	ai_pitcher = AIPitcher.new()
	ai_pitcher.name = "AIPitcher"
	add_child(ai_pitcher)
	ai_pitcher.place_at(FOUL_40_Z)


# --- Hand access (test overrides first, then the real controllers) ---

func _hand_tf(hand: String) -> Transform3D:
	if test_hand_tf.has(hand):
		var tf: Transform3D = test_hand_tf[hand]
		return tf
	var c: XRController3D = hand_ctrl[hand]
	return c.global_transform


func _grip_value(hand: String) -> float:
	if test_grip.has(hand):
		return float(test_grip[hand])
	var c: XRController3D = hand_ctrl[hand]
	var v: Variant = c.get_input(&"grip")
	if v == null:
		return 0.0
	return float(v)


func _trigger_value(hand: String) -> float:
	if test_trigger.has(hand):
		return float(test_trigger[hand])
	var c: XRController3D = hand_ctrl[hand]
	var v: Variant = c.get_input(&"trigger")
	if v == null:
		return 0.0
	return float(v)


func _stick_value(hand: String) -> Vector2:
	if test_stick.has(hand):
		var tv: Vector2 = test_stick[hand]
		return tv
	var c: XRController3D = hand_ctrl[hand]
	return c.get_vector2(&"primary")


## Game buttons (Backyard Game v1): A/X = start game / next
## round / play again, B/Y = back to practice - the board
## lists both. Either hand counts. Fix Pass 19: B lost the
## end-swap (the one-way court has no other end) - in a game,
## at any phase, B returns to practice; in practice B does
## nothing. Fix Pass 20: A at the insert dismisses it and
## stocks the next round.
## Fix Pass 22 (Chris, from the headset: "not sure how you
## implemented change grip, cant find it. Just make it A or
## X for now."): the per-hand free-hand rule of Fix Pass 21
## is REPLACED. On any A-press or X-press - either hand,
## holding or free - if a shoe is currently held, the press
## cycles THAT shoe's grip and is spent; the game A never
## fires under a held shoe. With no shoe held, a press is
## the game A exactly as before, and X alone does nothing.
## B is never the cycle. The A/X channel is the single
## ax_button action both controllers share (A on the right
## controller, X on the left), read here as "A".
func _hand_button_down(hand: String, btn: String) -> bool:
	if test_button_hand.has(hand):
		var per: Dictionary = test_button_hand[hand]
		if per.has(btn):
			return bool(per[btn])
	if test_button.has(btn):
		return bool(test_button[btn])
	var c: XRController3D = hand_ctrl[hand]
	if c == null:
		return false
	var action: StringName = &"ax_button" if btn == "A" else &"by_button"
	return c.is_button_pressed(action)


func _button_down(btn: String) -> bool:
	return _hand_button_down("L", btn) or _hand_button_down("R", btn)


func _poll_buttons() -> void:
	var ax_now: bool = _button_down("A")
	var b_now: bool = _button_down("B")
	var ax_edge: bool = ax_now and not bool(_btn_prev["A"])
	var b_edge: bool = b_now and not bool(_btn_prev["B"])
	_btn_prev["A"] = ax_now
	_btn_prev["B"] = b_now
	if ax_edge:
		if state == "HELD":
			_cycle_grip()
		elif mode == "PRACTICE" and state == "STAND":
			start_game()
		elif mode == "GAME" and phase == "INSERT":
			_continue_round()
		elif mode == "GAME" and phase == "OVER":
			start_game()
	if b_edge and mode == "GAME":
		_enter_practice()


## Fix Pass 21: the grip position the held shoe currently
## declares - from the zone under the hand and the settled
## slide offset (ThrowMath.grip_index_for). The label names
## it; the cycle advances from it; the release serves it.
func _grip_index() -> int:
	if held_zone == "":
		return 0
	var z: Dictionary = Shoe.zones()[held_zone]
	return ThrowMath.grip_index_for(held_zone, slide_offset, float(z["slide_max"]))


func _refresh_grip_label() -> void:
	if grip_label == null:
		return
	var p: Dictionary = ThrowMath.grip_position(_grip_index())
	grip_label.text = String(p["label"])


func _build_grip_label() -> void:
	grip_label = Label3D.new()
	grip_label.name = "GripLabel"
	grip_label.font_size = 48
	grip_label.pixel_size = 0.00085
	grip_label.modulate = Color(1.0, 0.93, 0.75)
	grip_label.outline_size = 8
	grip_label.outline_modulate = Color(0.1, 0.07, 0.03)
	grip_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	grip_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	grip_label.no_depth_test = true
	grip_label.visible = false
	add_child(grip_label)
	# Fix Pass 22: the hint line rides under the grip name
	# (a child of the name label, so it shares the label's
	# visibility exactly: shown whenever a shoe is held,
	# gone at release).
	grip_hint_label = Label3D.new()
	grip_hint_label.name = "GripHintLabel"
	grip_hint_label.font_size = 30
	grip_hint_label.pixel_size = 0.00085
	grip_hint_label.modulate = Color(1.0, 0.93, 0.75, 0.85)
	grip_hint_label.outline_size = 6
	grip_hint_label.outline_modulate = Color(0.1, 0.07, 0.03)
	grip_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	grip_hint_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	grip_hint_label.no_depth_test = true
	grip_hint_label.text = "A/X - CHANGE GRIP"
	grip_hint_label.position = Vector3(0.0, -0.062, 0.0)
	grip_label.add_child(grip_hint_label)


## Fix Pass 21: one tap of the free hand's face button walks
## the grip to the next named position around the shoe
## (TOE GRIP -> SHANK · TOE -> SHANK · MID -> SHANK · HEEL ->
## TOE GRIP ...). The shoe re-seats in the hand at the new
## position's hold pose - zone plus the stop's slide offset -
## with a haptic tick from the zone tick's family, deepened
## per stop. Entering the shank family from the toe takes the
## shank on the holding hand's own side (the per-hand mirrored
## turn setups Shoe.hold_transform builds); moving within the
## shank family keeps the grabbed shank.
func _cycle_grip() -> void:
	if state != "HELD" or held_hand == "" or shoe == null:
		return
	if grab_state.sliding or grab_state.slide_mode:
		return # mid-slide the shoe is frozen; the slide owns it
	var idx: int = (_grip_index() + 1) % ThrowMath.grip_position_count()
	var pos: Dictionary = ThrowMath.grip_position(idx)
	var zone: String = held_zone
	if String(pos["hold"]) == "flip":
		zone = "toe"
	elif held_zone == "toe":
		zone = "shank_right" if held_hand == "R" else "shank_left"
	var z: Dictionary = Shoe.zones()[zone]
	slide_offset = ThrowMath.grip_slide_offset(idx, float(z["slide_max"]))
	if zone != held_zone:
		shoe.clear_highlights()
		held_zone = zone
		held_hold = String(z["hold"])
		shoe.set_highlight(zone, true)
	rel_tf = Shoe.hold_transform(zone, held_hand, slide_offset)
	shoe.global_transform = _hand_tf(held_hand) * rel_tf
	var c: XRController3D = hand_ctrl[held_hand]
	if c != null:
		c.trigger_haptic_pulse(&"haptic", 0.0, 0.30 + 0.10 * float(idx),
			0.03 + 0.012 * float(idx), 0.0)
	_refresh_grip_label()
	recorder.log_record({
		"type": "grab", "event": "grip_cycle", "hand": held_hand, "zone": held_zone,
		"grip": String(pos["name"]), "slide_offset_m": slide_offset,
		"ts": Time.get_datetime_string_from_system(),
	})


func _track_hand_speed(hand: String) -> void:
	var now: float = float(Time.get_ticks_msec()) / 1000.0
	var pos: Vector3 = _hand_tf(hand).origin
	if _prev_hand_t.has(hand):
		var dt: float = now - float(_prev_hand_t[hand])
		if dt > 0.0005:
			# Bench note (Backyard Game v1): the divisor is
			# floored at a 240 Hz tick. On the headset frames
			# arrive at a steady ~90 Hz so the floor never
			# engages; in headless runs an iteration can
			# collapse to ~1 ms and ordinary hand motion then
			# reads as a multi-m/s wave, randomly tripping the
			# slide/throw speed gates (the slide stays-put
			# check flaked on the untouched FP10 base for this
			# reason). The release estimator's windowed fit
			# does not read this speed.
			var prev: Vector3 = _prev_hand_pos[hand]
			var inst: float = (pos - prev).length() / maxf(dt, 1.0 / 240.0)
			hand_speed[hand] = lerpf(float(hand_speed[hand]), inst, 0.45)
	_prev_hand_pos[hand] = pos
	_prev_hand_t[hand] = now


# --- Sampling ---

func _add_sample() -> void:
	if held_hand == "":
		return
	var now: float = float(Time.get_ticks_msec()) / 1000.0
	if not samples.is_empty():
		var last: Dictionary = samples[samples.size() - 1]
		if now - float(last["t"]) < 0.004:
			return
	var tf: Transform3D = _hand_tf(held_hand)
	samples.append(ThrowMath.make_sample(now, tf.origin, tf.basis.get_rotation_quaternion(), origin.global_position))
	while samples.size() > 2:
		var first: Dictionary = samples[0]
		if now - float(first["t"]) <= SAMPLE_KEEP_SEC:
			break
		samples.pop_front()


# --- Grab processing (render rate) ---

func _find_candidate() -> void:
	candidate_hand = ""
	candidate_zone = ""
	if state != "STAND" or not grab_armed:
		return
	var best_dist: float = CANDIDATE_RADIUS
	for hand: String in ["L", "R"]:
		var hp: Vector3 = _hand_tf(hand).origin
		for zone: String in Shoe.zones().keys():
			var d: float = hp.distance_to(shoe.zone_world_center(zone))
			if d < best_dist:
				best_dist = d
				candidate_hand = hand
				candidate_zone = zone


## Thumbstick locomotion (Fix Pass 2; STANDARD twin-stick scheme
## restored in Fix Pass 6 at Chris's field order: the LEFT stick
## walks, the RIGHT stick turns - the two are read independently
## and applied in the same frame so they blend into a curved
## path). Runs BEFORE sampling/grab so every hand transform this
## frame already includes the new origin. Walk is head-relative and
## direct; the smooth turn rotates the origin about the camera so
## turning never translates the player.
func _process_locomotion(delta: float) -> void:
	if delta <= 0.0:
		return
	var ls: Vector2 = _stick_value("L")
	var disp: Vector3 = Locomotion.walk_displacement(ls, cam.global_transform.basis, delta)
	if disp != Vector3.ZERO:
		origin.global_position = Locomotion.clamp_origin(origin.global_position + disp)
	var rs: Vector2 = _stick_value("R")
	var ang: float = Locomotion.turn_angle(rs.x, delta)
	if not is_zero_approx(ang):
		origin.global_transform = Locomotion.rotate_about(
			origin.global_transform, cam.global_position, deg_to_rad(ang))
	# Fix Pass 20: the LINE CLAMP (game mode, round live -
	# see _round_live). A position clamp on the movement
	# RESULT, not a new input rule: turning, walking backward
	# or sideways and blending stay exactly as Fix Pass 6
	# left them; only forward progress past the plane stops.
	# The plane sits the stance box's stride allowance
	# (0.40 m) past the 37 ft game line - the player can
	# stride AT the line, he cannot walk down the lane while
	# a round is live.
	if _round_live():
		var p: Vector3 = origin.global_position
		var plane: float = game_line_z() - STANCE_HALF_DEPTH
		if p.z < plane:
			p.z = plane
			origin.global_position = p


## Fix Pass 20: a game round is LIVE from its first stock
## until it tabulates and the insert appears (phases P_TURN,
## AI_TURN, TABULATE). While the insert is up, while the
## game is over, and in practice, movement is free.
func _round_live() -> bool:
	return mode == "GAME" and (phase == "P_TURN" \
		or phase == "AI_TURN" or phase == "TABULATE")


## Fix Pass 20: is the player past the game line's clamp
## plane (down the lane where a live round would not let
## him be)?
func _past_line() -> bool:
	return origin.global_position.z < game_line_z() - STANCE_HALF_DEPTH


## Seat the player back behind the game line (Fix Pass 20,
## on Fix Pass 15's seat construction): the camera lands
## 0.55 m behind the 37 ft line at his own x, facing the
## pit, via Locomotion.seat_transform - yaw only, level by
## construction, the head's pitch never read, so the FP15
## tilt cannot recur on this path. Used when a round starts
## (game start, or A-continue from the insert) with the
## player down the lane.
func _seat_behind_line() -> void:
	var cam_pos: Vector3 = cam.global_position
	var want := Vector3(cam_pos.x, cam_pos.y, game_line_z() + 0.55)
	origin.global_transform = Locomotion.seat_transform(
		cam.transform, want, 0.0)


func _process(_delta: float) -> void:
	_process_locomotion(_delta)
	_poll_buttons()
	_track_hand_speed("L")
	_track_hand_speed("R")
	if state == "HELD":
		_add_sample()
	_process_grab()
	if state == "HELD" and not grab_state.sliding:
		shoe.global_transform = _hand_tf(held_hand) * rel_tf
	shoe.set_markers_visible(debug_show_zones and (state == "STAND" or state == "HELD"))
	# Fix Pass 21: the grip label rides above the held shoe and
	# is gone the instant the shoe leaves the hand.
	if grip_label != null:
		if state == "HELD" and shoe != null:
			grip_label.visible = true
			grip_label.global_position = shoe.global_position + Vector3(0.0, 0.14, 0.0)
		else:
			grip_label.visible = false


func _process_grab() -> void:
	var prev_zone: String = candidate_zone
	_find_candidate()
	if candidate_zone != prev_zone:
		shoe.clear_highlights()
		if candidate_zone != "" and state == "STAND":
			shoe.set_highlight(candidate_zone, true)
			var c: XRController3D = hand_ctrl[candidate_hand]
			if c != null:
				c.trigger_haptic_pulse(&"haptic", 0.0, 0.35, 0.04, 0.0)
			recorder.log_record({
				"type": "grab", "event": "zone_acquired",
				"hand": candidate_hand, "zone": candidate_zone,
				"ts": Time.get_datetime_string_from_system(),
			})
	var in_hand: String = ""
	var in_zone: String = ""
	var in_grip: float = 0.0
	var in_speed: float = 0.0
	var in_trigger: float = 0.0
	if grab_state.latched:
		in_hand = held_hand
		in_zone = held_zone
		in_grip = _grip_value(held_hand)
		in_speed = float(hand_speed[held_hand])
		in_trigger = _trigger_value(held_hand)
		# Fix Pass 14: keep the grip stream (same clock as the
		# hand samples) so a release can be located BETWEEN polls.
		_grip_hist.append({"t": float(Time.get_ticks_msec()) / 1000.0, "g": in_grip})
		while _grip_hist.size() > 6:
			_grip_hist.pop_front()
	elif candidate_hand != "":
		in_hand = candidate_hand
		in_zone = candidate_zone
		in_grip = _grip_value(candidate_hand)
		in_speed = float(hand_speed[candidate_hand])
		in_trigger = _trigger_value(candidate_hand)
	var ev: String = grab_state.update(in_hand, in_zone, in_grip, in_speed, in_trigger)
	match ev:
		"latch":
			_do_latch(in_hand, in_zone)
		"slide_start":
			pass # shoe simply stops following; slide resolves at lock
		"slide_end":
			_do_slide_end()
		"release":
			_do_release()


func _do_latch(hand: String, zone: String) -> void:
	# Home starts as the pedestal the shoe was just grabbed from.
	# It does not stay glued there: a throw re-homes to the line
	# it was released from (see _settle_throw), a drop returns
	# here, and while the shoe sits stocked the home follows the
	# line the player is standing at (Fix Pass 7). Practice only:
	# a game places its shoes itself, and stand_tf was set when
	# the shoe was activated.
	if mode == "PRACTICE":
		_set_active_stand(_nearest_stand_line())
	shoe_status[shoe] = "HELD"
	held_hand = hand
	held_zone = zone
	var z: Dictionary = Shoe.zones()[zone]
	held_hold = String(z["hold"])
	slide_offset = 0.0
	rel_tf = Shoe.hold_transform(zone, hand)
	shoe.freeze = true
	shoe.global_transform = _hand_tf(hand) * rel_tf
	state = "HELD"
	samples.clear()
	_grip_hist.clear()
	sample_hand = hand
	shoe.set_highlight(zone, true)
	recorder.log_record({
		"type": "grab", "event": "latch", "hand": hand, "zone": zone,
		"hold": held_hold, "ts": Time.get_datetime_string_from_system(),
	})
	_refresh_grip_label()


func _do_slide_end() -> void:
	var hand_tf: Transform3D = _hand_tf(held_hand)
	var z: Dictionary = Shoe.zones()[held_zone]
	var axis: Vector3 = z["slide_axis"]
	var smax: float = float(z["slide_max"])
	var center: Vector3 = z["center"]
	var anchor_local: Vector3 = shoe.global_transform.affine_inverse() * hand_tf.origin
	var off: float = (anchor_local - center).dot(axis)
	var clamped: float = clampf(off, -smax, smax)
	if not is_equal_approx(off, clamped):
		var shift_local: Vector3 = axis * (off - clamped)
		shoe.global_position += shoe.global_transform.basis * shift_local
	slide_offset = clamped
	rel_tf = hand_tf.affine_inverse() * shoe.global_transform
	recorder.log_record({
		"type": "grab", "event": "slide", "hand": held_hand, "zone": held_zone,
		"slide_offset_m": clamped, "ts": Time.get_datetime_string_from_system(),
	})
	# Fix Pass 21: a settled slide may have crossed into another
	# stop's neighbourhood - the label follows the nearest stop.
	_refresh_grip_label()


func _do_release() -> void:
	# Fix Pass 14: locate the true let-go instant between the last
	# two grip polls - the previous reading above the let-go
	# threshold, this one at or below it - and hand it to the
	# release. Degenerate history (a grab released inside a single
	# poll gap, the flag off) leaves t_star negative and the
	# release falls back to the legacy grid read.
	var t_star: float = -1.0
	var timing: Dictionary = {}
	if substep_release_enabled and _grip_hist.size() >= 2:
		var prev: Dictionary = _grip_hist[_grip_hist.size() - 2]
		var cur: Dictionary = _grip_hist[_grip_hist.size() - 1]
		var tp: float = float(prev["t"])
		var tc: float = float(cur["t"])
		var gp: float = float(prev["g"])
		var gc: float = float(cur["g"])
		if gp > GrabState.GRIP_OFF and gc <= GrabState.GRIP_OFF and tc > tp:
			t_star = ThrowMath.release_crossing_time(tp, gp, tc, gc, GrabState.GRIP_OFF)
			timing = {
				"offset_ms": (t_star - tp) * 1000.0,
				"grip_bracket": [gp, gc],
			}
	_release_shoe(samples, t_star, timing)


## The throw itself. Release position/orientation are the shoe's
## CURRENT transform (cached by the follow code at the release event);
## velocity/angular velocity come from the windowed fit over the
## sample buffer - never a single-frame delta, never recomputed later.
## Fix Pass 14: when t_star names the interpolated let-go instant
## and the sample buffer actually covers it, position, orientation,
## velocity and spin are ALL read at t_star from the fitted motion;
## otherwise the legacy grid read runs unchanged (direct callers -
## the suites, the technique audit - take that path).
func _release_shoe(release_samples: Array, t_star: float = -1.0, timing: Dictionary = {}) -> void:
	var use_sub: bool = false
	if substep_release_enabled and t_star >= 0.0 and release_samples.size() >= 2:
		var t_first: float = float(release_samples[0]["t"])
		var last_smp: Dictionary = release_samples[release_samples.size() - 1]
		var t_last: float = float(last_smp["t"])
		# Coverage: t_star must sit inside the recorded motion
		# (a hair past the last sample is fine - the fit window
		# itself reads 30 ms past its anchor by design).
		if t_star >= t_first - 0.002 and t_star <= t_last + 0.020:
			use_sub = true
	var evaluated: Dictionary = ThrowMath.evaluate_release_at(
		release_samples, origin.global_transform.basis, t_star, use_sub)
	var vel: Vector3 = evaluated["vel"]
	var ang: Vector3 = evaluated["ang"]
	var speed: float = vel.length()
	var release_tf: Transform3D = shoe.global_transform
	if use_sub:
		var hand_pos: Vector3 = ThrowMath.position_at_time(release_samples, t_star)
		var hand_quat: Quaternion = ThrowMath.orientation_at_time(release_samples, t_star)
		release_tf = Transform3D(Basis(hand_quat), hand_pos) * rel_tf
	var hand_was: String = held_hand
	var zone_was: String = held_zone
	var hold_was: String = held_hold
	var slide_was: float = slide_offset
	# Fix Pass 21: the grip position held at release - its
	# declared count is what the governor serves.
	var zone_data: Dictionary = Shoe.zones()[zone_was]
	var grip_was: Dictionary = ThrowMath.grip_position(
		ThrowMath.grip_index_for(zone_was, slide_was, float(zone_data["slide_max"])))
	# Fix Pass 16: the finger-drag term. The estimator's spin is
	# kept verbatim for the record's estimator evidence; what
	# flies is the governed spin (style axis pulled toward the
	# hold's regulation total - see ThrowMath.govern_spin).
	# Player path only: the AI's release is computed exact and
	# never passes through here.
	var est_ang: Vector3 = ang
	var spin_ev: Dictionary = ThrowMath.govern_spin(
		ang, release_tf, vel, hold_was, target_stake_pos(),
		spin_governor_enabled, float(grip_was["nominal"]))
	ang = spin_ev["ang"]
	held_hand = ""
	sample_hand = ""
	shoe.clear_highlights()
	if speed >= THROW_MIN_SPEED:
		var tilt_pr: Vector2 = _origin_pitch_roll()
		release_cache = {
			"hand": hand_was, "zone": zone_was, "hold": hold_was,
			# Fix Pass 21: the grip that declared this throw.
			"grip_name": String(grip_was["name"]),
			"grip_nominal": float(grip_was["nominal"]),
			"slide_offset_m": slide_was,
			"line_ft": ThrowMath.line_ft_for_release(release_tf.origin, target_stake_pos()),
			"origin_pos": origin.global_position,
			# Stance evidence, captured at the release moment: where
			# the HEAD faced vs how the whole RIG was yawed (stick
			# turns or a crooked recenter). Their difference separates
			# "he turned his head" from "the rig was rotated".
			"head_yaw_deg": ThrowMath.yaw_deg(-cam.global_transform.basis.z),
			"origin_yaw_deg": ThrowMath.yaw_deg(-origin.global_transform.basis.z),
			# Fix Pass 15 diagnostic: the origin's pitch/roll at
			# the release instant (see _origin_pitch_roll).
			"origin_pitch_deg": tilt_pr.x,
			"origin_roll_deg": tilt_pr.y,
			"samples": release_samples.duplicate(true),
			"release_pos": release_tf.origin,
			"release_quat": release_tf.basis.get_rotation_quaternion(),
			"velocity": vel, "angular_velocity": ang,
			# Fix Pass 16 evidence: the estimator's raw spin and
			# the drag term's account of itself (signed totals
			# about the style axis, in revolutions). Fix Pass 17:
			# the totals are counted HAND-TO-STAKE - revolutions
			# over the flight to the target stake's plane, per
			# Smith (1946) - not over the flight to the ground.
			"estimator_angular_velocity": est_ang,
			"spin_hand_total": float(spin_ev["hand_total"]),
			"spin_applied_total": float(spin_ev["applied_total"]),
			"spin_nominal": float(spin_ev["nominal"]),
			# Fix Pass 14 evidence for the record: which read
			# produced this release, where inside its poll step
			# the let-go instant fell, and the grip readings
			# that bracket it.
			"release_timing": "substep" if use_sub else "grid",
			"substep_offset_ms": float(timing.get("offset_ms", 0.0)) if use_sub else 0.0,
			"grip_bracket": timing.get("grip_bracket", []) if use_sub else [],
		}
		flip_rot = 0.0
		turn_rot = 0.0
		has_contact = false
		_fly_time = 0.0
		_still_time = 0.0
		_pos_still_time = 0.0
		_pos_anchor = shoe.global_position
		state = "FLYING"
		shoe_status[shoe] = "FLYING"
		_wire_guard(shoe, target_stake_key())
		shoe.reset_stake_guard()
		shoe.freeze = false
		shoe.global_transform = release_tf
		shoe.linear_velocity = vel
		shoe.angular_velocity = ang
	else:
		state = "DROPPED"
		_still_time = 0.0
		_wait_time = 0.0
		shoe.freeze = false
		shoe.global_transform = release_tf
		shoe.linear_velocity = Vector3.ZERO
		shoe.angular_velocity = Vector3.ZERO
		recorder.log_record({
			"type": "grab", "event": "drop", "hand": hand_was, "zone": zone_was,
			"release_speed_mps": speed, "ts": Time.get_datetime_string_from_system(),
		})


# --- Flight / settle ---

func _on_any_shoe_body_entered(_body: Node, shoe_node: Shoe) -> void:
	if shoe_node == shoe:
		if state == "FLYING" and not has_contact:
			has_contact = true
			first_contact_pos = shoe.global_position
	elif ai_flight.has(shoe_node):
		var fl: Dictionary = ai_flight[shoe_node]
		if not bool(fl["has_contact"]):
			fl["has_contact"] = true
			fl["first_contact_pos"] = shoe_node.global_position


func _physics_process(delta: float) -> void:
	_guard_origin_level()
	_restock_to_player_line()
	if state == "HELD":
		_add_sample()
		if not grab_state.sliding:
			shoe.global_transform = _hand_tf(held_hand) * rel_tf
	match state:
		"FLYING":
			_fly_time += delta
			var av: Vector3 = shoe.angular_velocity
			var x_axis: Vector3 = shoe.global_transform.basis.x.normalized()
			flip_rot += av.dot(x_axis) * delta / TAU
			turn_rot += av.y * delta / TAU
			if _fly_time > 0.6:
				if shoe.linear_velocity.length() < 0.10 and shoe.angular_velocity.length() < 0.30:
					_still_time += delta
				else:
					_still_time = 0.0
				# Leaner guard (Backyard Game v1): a shoe can come
				# to rest LEANING on the stake, gently rocking -
				# linear velocity ~0 but angular velocity spiking
				# past the still threshold forever, so the velocity
				# test never settles it and (in a game) the inning
				# hangs. Positional stillness is the robust signal:
				# a shoe that has not moved 2 cm in a full second
				# is down, wherever it is resting.
				if shoe.global_position.distance_to(_pos_anchor) < 0.02:
					_pos_still_time += delta
				else:
					_pos_still_time = 0.0
					_pos_anchor = shoe.global_position
				if _still_time > SETTLE_STILL_SEC or _pos_still_time > 1.0:
					_settle_throw()
			if shoe.global_position.length() > 40.0 or shoe.global_position.y < -2.0:
				_settle_throw()
		"DROPPED":
			if shoe.linear_velocity.length() < 0.10 and shoe.angular_velocity.length() < 0.30:
				_still_time += delta
			else:
				_still_time = 0.0
			if _still_time > SETTLE_STILL_SEC:
				state = "RETURNING"
				_wait_time = 0.0
		"RETURNING":
			_wait_time += delta
			if _wait_time > RETURN_WAIT_SEC:
				_return_to_stand()
	_track_ai_flights(delta)
	if mode == "GAME" and phase == "TABULATE":
		# Fix Pass 20: the round posts ITSELF. All four shoes
		# are down (the settle paths routed here through
		# _begin_tabulate), a short beat runs, then the inning
		# tabulates and the insert cam appears. No player
		# movement is required at any point - the FP19
		# walk-arrival triggers are deleted; walking down is
		# still physically possible and does nothing.
		tabulate_left -= delta
		if tabulate_left <= 0.0:
			tabulate_left = -1.0
			_score_inning()


func _settle_throw() -> void:
	if state != "FLYING":
		return
	var tsp: Vector3 = target_stake_pos()
	var stake_at_shoe := Vector3(tsp.x, shoe.global_position.y, tsp.z)
	var dist_in: float = ThrowMath.nearest_distance_inches(
		shoe.global_transform, stake_at_shoe, Shoe.WIDTH * 0.5, Shoe.LENGTH * 0.5)
	var ringer: bool = ThrowMath.is_ringer(
		shoe.global_transform, stake_at_shoe,
		Shoe.RINGER_INNER_HALF, Shoe.RINGER_Z_MIN, Shoe.RINGER_Z_MAX)
	throw_count += 1
	last_hold_text = "%s (%s)" % [String(release_cache["hold"]).to_upper(), String(release_cache["zone"]).to_upper()]
	last_distance_in = dist_in
	last_flip_rev = flip_rot
	last_turn_rev = turn_rot
	last_ringer = ringer
	_update_board()
	var vel: Vector3 = release_cache["velocity"]
	var ang: Vector3 = release_cache["angular_velocity"]
	var origin_at_release: Vector3 = release_cache["origin_pos"]
	var rp: Vector3 = release_cache["release_pos"]
	var rq: Quaternion = release_cache["release_quat"]
	var samples_copy: Array = release_cache["samples"]
	recorder.log_record({
		"type": "throw",
		"ts": Time.get_datetime_string_from_system(),
		"throw_index": throw_count,
		"hand": String(release_cache["hand"]),
		"hold": String(release_cache["hold"]),
		"zone": String(release_cache["zone"]),
		# Fix Pass 21: the grip that declared this throw and its count.
		"grip_name": String(release_cache.get("grip_name", "")),
		"grip_nominal": float(release_cache.get("grip_nominal", 0.0)),
		"slide_offset_m": float(release_cache["slide_offset_m"]),
		"line_ft": int(release_cache["line_ft"]),
		"origin_release_pos": ThrowRecorder.vec3_arr(origin_at_release),
		"head_yaw_deg": float(release_cache["head_yaw_deg"]),
		"origin_yaw_deg": float(release_cache["origin_yaw_deg"]),
		"origin_pitch_deg": float(release_cache.get("origin_pitch_deg", 0.0)),
		"origin_roll_deg": float(release_cache.get("origin_roll_deg", 0.0)),
		"samples": ThrowRecorder.sample_arr(samples_copy),
		"release_pos": ThrowRecorder.vec3_arr(rp),
		"release_quat": ThrowRecorder.quat_arr(rq),
		"release_velocity": ThrowRecorder.vec3_arr(vel),
		"release_angular_velocity": ThrowRecorder.vec3_arr(ang),
		"release_timing": String(release_cache.get("release_timing", "grid")),
		"substep_offset_ms": float(release_cache.get("substep_offset_ms", 0.0)),
		"grip_bracket": release_cache.get("grip_bracket", []),
		"spin_hand_total": float(release_cache.get("spin_hand_total", 0.0)),
		"spin_applied_total": float(release_cache.get("spin_applied_total", 0.0)),
		"spin_nominal": float(release_cache.get("spin_nominal", 0.0)),
		"first_contact_pos": ThrowRecorder.vec3_arr(first_contact_pos) if has_contact else [],
		"settle_pos": ThrowRecorder.vec3_arr(shoe.global_position),
		"settle_quat": ThrowRecorder.quat_arr(shoe.global_transform.basis.get_rotation_quaternion()),
		"landing_distance_in": dist_in,
		"ringer": ringer,
		"flip_rotations": flip_rot,
		"turn_rotations": turn_rot,
	})
	if mode == "GAME":
		# A game shoe STAYS DOWN: it is evidence for the inning's
		# scoring. Frozen where it settled; the turn advances.
		shoe_status[shoe] = "DOWN"
		shoe.freeze = true
		inning_results.append({"owner": "P", "dist_in": dist_in, "ringer": ringer})
		state = "STAND"
		_on_turn_shoe_settled("P")
		return
	# The next shoe stocks where the throw was made from (Fix
	# Pass 7): home follows the release's own line classification,
	# so the return below lands directly on the throwing line's
	# pedestal instead of whichever pedestal the shoe was grabbed
	# from (a shoe grabbed at 40 and pitched from 30 restocks at 30).
	_set_active_stand(int(release_cache["line_ft"]))
	state = "RETURNING"
	_wait_time = 0.0 # no linger: rhythm matters (Fix Pass 3)


func _return_to_stand() -> void:
	shoe.freeze = true
	shoe.global_transform = stand_tf
	shoe.clear_highlights()
	shoe_status[shoe] = "RAILED"
	has_contact = false
	release_cache.clear()
	state = "STAND"


# ============================================================
# Backyard Game v1: practice <-> game, innings, the AI turn,
# scoring, end swaps. The judged toss machinery above is the
# only way a shoe ever flies; this layer just deals the shoes.
# ============================================================

var last_scorer: String = "" # side that scored the last inning


func game_line_z() -> float:
	return line_z_for_ft(40)


## Clean reset: every shoe frozen onto its rail slot at the
## given stock point, the player's first shoe active.
func _gather_to_rail(line_ft: int) -> void:
	for s: Shoe in _all_shoes():
		s.freeze = true
		# Fix Pass 18: an AI shoe gathers to the 40 ft game
		# station whatever line is requested - it has no
		# practice stock point to gather to.
		var s_line: int = 40 if _is_ai_shoe(s) else line_ft
		s.global_transform = rack_slot_tf(s_line,
			_is_ai_shoe(s), _pair_index_of(s))
		s.clear_highlights()
		shoe_status[s] = "RAILED"
	active_stand_line_ft = line_ft
	shoe = player_pair[0]
	_refresh_stand_tf()
	grab_state.reset()
	has_contact = false
	release_cache.clear()
	ai_flight.clear()
	ai_throw_pending = false
	# A swing already animating keeps its callbacks: with the
	# pending shoe cleared, its release call lands on the
	# null guard in _ai_release_now and does nothing.
	ai_pending_shoe = null
	ai_pending_release = {}
	state = "STAND"


func start_game() -> void:
	_hide_insert()
	# Fix Pass 20: a game can be started from down the lane
	# (practice is free-form) - the first round is live the
	# moment it stocks, so seat him behind the line first
	# rather than let the line clamp snap him back.
	if _past_line():
		_seat_behind_line()
	tabulate_left = -1.0
	mode = "GAME"
	score_you = 0
	score_opp = 0
	inning = 1
	inning_first = "P"
	last_scorer = ""
	last_inning_text = ""
	winner_text = ""
	inning_results.clear()
	_gather_to_rail(40)
	ai_pitcher.place_at(game_line_z())
	_begin_turn("P")
	_update_board()


func _enter_practice() -> void:
	_hide_insert()
	tabulate_left = -1.0
	mode = "PRACTICE"
	phase = ""
	inning = 0
	inning_results.clear()
	# Stock the pairs at the line the player is standing at
	# (the FP7 rule decides; default to wherever stock
	# already lives).
	var lf: int = ThrowMath.standing_line_ft(cam.global_position, STAKE_POS)
	if lf != 0:
		_gather_to_rail(lf)
	else:
		_gather_to_rail(active_stand_line_ft)
	grab_armed = true
	ai_pitcher.place_at(game_line_z())
	_update_board()


func _activate_next_player_shoe() -> bool:
	for s: Shoe in player_pair:
		if String(shoe_status[s]) == "RAILED":
			shoe = s
			_refresh_stand_tf()
			state = "STAND"
			return true
	return false


func _begin_turn(side: String) -> void:
	turn_side = side
	turn_throws_left = 2
	phase = "P_TURN" if side == "P" else "AI_TURN"
	if side == "P":
		grab_armed = true
		_activate_next_player_shoe()
	else:
		grab_armed = false
		ai_delay = 0.8
	_update_board()


## Called by both settle paths (player + AI) once per game shoe.
func _on_turn_shoe_settled(side: String) -> void:
	if mode != "GAME":
		return
	turn_throws_left -= 1
	_update_board()
	if turn_throws_left > 0:
		if side == "P":
			_activate_next_player_shoe()
		else:
			ai_delay = 0.6
		return
	if turn_side == inning_first:
		_begin_turn("AI" if turn_side == "P" else "P")
	else:
		_begin_tabulate()


## Both sides have thrown (Fix Pass 20): all four shoes are
## DOWN - the settle paths brought us here - so the round
## tabulates itself after a short beat and the insert cam
## shows the result. (Fix Pass 19 made the player walk down
## to post the score and walk back to stock the next round;
## Chris, 2026-11-04: "we dont wanna make walking down and
## back mandatory. last shoe thrown in round, score is
## tabulated, next round, shoes are ready to go.")
func _begin_tabulate() -> void:
	phase = "TABULATE"
	tabulate_left = ROUND_BEAT_SEC
	grab_armed = false
	_update_board()


func _score_inning() -> void:
	var res: Dictionary = Scoring.score_inning(inning_results)
	score_you += int(res["points_p"])
	score_opp += int(res["points_ai"])
	last_scorer = String(res["scorer"])
	last_inning_text = String(res["summary"])
	var over: bool = score_you >= WIN_SCORE or score_opp >= WIN_SCORE
	if over:
		winner_text = "YOU WIN!" if score_you > score_opp else "OPP WINS"
	# Fix Pass 20: the insert's breakdown is built HERE, from
	# the same settled results the scorer just read - per-shoe
	# lines, the cancellation arithmetic in plain words, the
	# round's points and the running totals (the final
	# breakdown and winner line at game end).
	round_lines = _build_round_lines(res, over)
	inning_results.clear()
	grab_armed = false
	phase = "OVER" if over else "INSERT"
	_update_board()
	_show_insert()


## The insert's text for one tabulated round (Fix Pass 20):
## a header, one line per shoe, the arithmetic in plain
## words, the round and match lines, and the continue
## control the panel names on its own face.
func _build_round_lines(res: Dictionary, over: bool) -> Array:
	var lines: Array = []
	if over:
		lines.append("FINAL - %s" % winner_text)
	else:
		lines.append("ROUND %d" % inning)
	lines.append_array(Scoring.shoe_lines(inning_results))
	lines.append_array(Scoring.explain_lines(inning_results, res))
	if int(res["points_p"]) > 0:
		lines.append("ROUND: YOU +%d" % int(res["points_p"]))
	elif int(res["points_ai"]) > 0:
		lines.append("ROUND: OPP +%d" % int(res["points_ai"]))
	else:
		lines.append("ROUND: NO SCORE")
	lines.append("MATCH: YOU %d - %d OPP" % [score_you, score_opp])
	lines.append("A - PLAY AGAIN" if over else "A - NEXT ROUND")
	return lines


## A at the insert (Fix Pass 20): dismiss it and stock the
## next round. If the player strolled down to the pit while
## the insert was up (movement is free then), he is first
## seated back behind the line (Fix Pass 15's yaw-only seat
## - level by construction) so the new round starts legal;
## the line clamp then holds him there while it is live.
func _continue_round() -> void:
	if phase != "INSERT":
		return
	if _past_line():
		_seat_behind_line()
	_finish_inning_cycle()


## Dismiss the insert, gather the shoes to the pitching
## end's stations, and start the next inning with whoever
## scored (NHPA custom; scoreless innings alternate the
## first throw). The AI never moved - it lives at this end.
func _finish_inning_cycle() -> void:
	if phase != "INSERT":
		return
	_hide_insert()
	inning += 1
	if last_scorer != "":
		inning_first = last_scorer
	else:
		inning_first = "AI" if inning_first == "P" else "P"
	_gather_to_rail(40)
	_begin_turn(inning_first)
	_update_board()


## Build the insert cam panel (Fix Pass 20): a board-family
## wooden slab carrying a LIVE pit closeup over the round's
## breakdown text. The closeup is a SubViewport sharing this
## world, fed by its own camera parked above and behind the
## pit looking down at the stake (framed so all four settled
## shoes sit in the shot - the suites assert exactly that).
## The viewport renders only while the panel is up. Built
## once, hidden, positioned at each showing.
func _build_insert() -> void:
	insert_root = Node3D.new()
	insert_root.name = "InsertCam"
	add_child(insert_root)
	var wood := _mat(Color(0.30, 0.21, 0.12))
	_box(insert_root, Vector3(0.0, 0.0, -0.03), Vector3(1.52, 1.34, 0.05), wood)
	insert_viewport = SubViewport.new()
	insert_viewport.name = "InsertViewport"
	insert_viewport.size = Vector2i(1024, 512)
	insert_viewport.world_3d = get_world_3d()
	insert_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	insert_root.add_child(insert_viewport)
	insert_cam = Camera3D.new()
	insert_cam.name = "InsertCamera"
	insert_viewport.add_child(insert_cam)
	insert_cam.position = Vector3(0.0, 2.4, -10.0)
	insert_cam.fov = 55.0
	insert_cam.look_at(Vector3(0.0, 0.05, STAKE_POS.z), Vector3.UP)
	insert_cam.current = true
	var quad := MeshInstance3D.new()
	quad.name = "InsertScreen"
	var qm := QuadMesh.new()
	qm.size = Vector2(1.36, 0.68)
	quad.mesh = qm
	var qmat := StandardMaterial3D.new()
	qmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	qmat.albedo_texture = insert_viewport.get_texture()
	quad.material_override = qmat
	quad.position = Vector3(0.0, 0.28, 0.001)
	insert_root.add_child(quad)
	insert_label = Label3D.new()
	insert_label.font_size = 48
	insert_label.pixel_size = 0.00062
	insert_label.modulate = Color(0.95, 0.97, 0.90)
	insert_label.outline_size = 5
	insert_label.outline_modulate = Color(0.1, 0.07, 0.03)
	insert_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	insert_label.position = Vector3(0.0, -0.40, 0.0025)
	insert_root.add_child(insert_label)
	insert_root.visible = false


## Raise the insert (Fix Pass 20): spawned head-relative -
## INSERT_DIST_M ahead of where the player is looking,
## slightly below eye level - then WORLD-LOCKED. It never
## follows the head after spawn, so he can look around it,
## walk around it, or stroll down to the pit while it is
## up; it appears identically whether he stayed at the line
## or wandered. The spawn basis is yaw-only by construction
## (the look target shares the panel's height), the FP15
## discipline: no head pitch can be written into the world.
func _show_insert() -> void:
	if insert_root == null:
		return
	insert_label.text = "\n".join(PackedStringArray(round_lines))
	var cam_pos: Vector3 = cam.global_position
	var fwd := Vector3(-cam.global_transform.basis.z.x, 0.0,
		-cam.global_transform.basis.z.z)
	if fwd.length() < 0.01:
		fwd = Vector3(0.0, 0.0, -1.0)
	fwd = fwd.normalized()
	var pos: Vector3 = cam_pos + fwd * INSERT_DIST_M
	pos.y = clampf(cam_pos.y - 0.12, 0.9, 1.75)
	insert_root.global_transform = Transform3D(Basis(), pos).looking_at(
		pos + fwd, Vector3.UP)
	insert_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	insert_root.visible = true


func _hide_insert() -> void:
	if insert_root == null:
		return
	insert_root.visible = false
	insert_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_update_board()


## Fix Pass 15 self-healing guard, run every physics frame:
## if the origin's basis carries ANY pitch/roll, strip it on
## the spot (position and heading kept) and count the repair.
## Level is already the construction everywhere - this exists
## so a vertigo fault can never PERSIST because one path was
## missed, the way the B-swap seat's tilt used to.
func _guard_origin_level() -> void:
	if not tilt_guard_enabled:
		return
	var tf: Transform3D = origin.global_transform
	if Locomotion.tilt_deg(tf.basis) > 0.01:
		origin.global_transform = Locomotion.level_transform(tf)
		origin_tilt_repairs += 1


## The origin's pitch/roll in degrees, 2 dp, for the throw
## record (Fix Pass 15): pitch = the forward axis' height
## (nose-up positive), roll = the right axis' height. On a
## level rig both read 0.00; any recurrence of the slant is
## on the record at the release instant, next to head_yaw /
## origin_yaw, instead of living only in the player's stomach.
func _origin_pitch_roll() -> Vector2:
	var b: Basis = origin.global_transform.basis
	return Vector2(
		snappedf(rad_to_deg(asin(clampf(-b.z.y, -1.0, 1.0))), 0.01),
		snappedf(rad_to_deg(asin(clampf(b.x.y, -1.0, 1.0))), 0.01))


## The lane the AI is about to throw down: the corridor between
## the foul line and the target stake. The AI holds its throw
## while the player stands in it.
func _player_in_lane() -> bool:
	var cp: Vector3 = cam.global_position
	if absf(cp.x) > 1.3:
		return false
	var lz: float = game_line_z()
	var tz: float = target_stake_pos().z
	return cp.z > minf(lz, tz) + 0.15 and cp.z < maxf(lz, tz) - 0.15


var ai_delay: float = -1.0 # seconds until the AI's next throw; <0 idle
var ai_pending_shoe: Shoe = null
var ai_pending_release: Dictionary = {}


func _ai_next_throw() -> void:
	if mode != "GAME" or phase != "AI_TURN" or ai_throw_pending:
		return
	if _player_in_lane():
		ai_delay = 0.35 # hold: the player is in the lane
		return
	var next_shoe: Shoe = null
	for s: Shoe in ai_pair:
		if String(shoe_status[s]) == "RAILED":
			next_shoe = s
			break
	if next_shoe == null:
		return
	ai_pitcher.place_at(game_line_z())
	var from_pos: Vector3 = AIPitcher.release_base_pos(game_line_z())
	var rel: Dictionary = AIPitcher.sample_release(ai_rng, from_pos, target_stake_pos())
	ai_pending_shoe = next_shoe
	ai_pending_release = rel
	ai_throw_pending = true
	shoe_status[next_shoe] = "HELD"
	next_shoe.freeze = true
	ai_pitcher.play_throw(next_shoe, rel, _ai_release_now, _ai_swing_done)


func _ai_release_now() -> void:
	var s: Shoe = ai_pending_shoe
	if s == null:
		return
	var rel: Dictionary = ai_pending_release
	_wire_guard(s, target_stake_key())
	s.reset_stake_guard()
	s.freeze = false
	s.global_transform = Transform3D(rel["basis"], rel["pos"])
	s.linear_velocity = rel["vel"]
	s.angular_velocity = rel["ang"]
	shoe_status[s] = "FLYING"
	ai_flight[s] = {
		"fly_time": 0.0, "still_time": 0.0,
		"pos_still": 0.0, "pos_anchor": rel["pos"],
		"flip": 0.0, "turn": 0.0,
		"has_contact": false, "first_contact_pos": Vector3.ZERO,
		"release": rel,
		"line_ft": ThrowMath.line_ft_for_release(rel["pos"], target_stake_pos()),
	}


func _ai_swing_done() -> void:
	ai_throw_pending = false
	ai_pending_shoe = null


## AI flight tracking: the same settle discipline as the
## player's shoe (0.6 s minimum flight, rest thresholds, the
## same rotation accounting for the record).
func _track_ai_flights(delta: float) -> void:
	if ai_delay > 0.0:
		ai_delay -= delta
		if ai_delay <= 0.0:
			_ai_next_throw()
	if ai_flight.is_empty():
		return
	var done: Array = []
	for s: Shoe in ai_flight.keys():
		var fl: Dictionary = ai_flight[s]
		fl["fly_time"] = float(fl["fly_time"]) + delta
		var av: Vector3 = s.angular_velocity
		var x_axis: Vector3 = s.global_transform.basis.x.normalized()
		fl["flip"] = float(fl["flip"]) + av.dot(x_axis) * delta / TAU
		fl["turn"] = float(fl["turn"]) + av.y * delta / TAU
		if float(fl["fly_time"]) > 0.6:
			if s.linear_velocity.length() < 0.10 and s.angular_velocity.length() < 0.30:
				fl["still_time"] = float(fl["still_time"]) + delta
			else:
				fl["still_time"] = 0.0
			# Same leaner guard as the player's shoe: positional
			# stillness settles a shoe rocking against the stake.
			if s.global_position.distance_to(fl["pos_anchor"]) < 0.02:
				fl["pos_still"] = float(fl["pos_still"]) + delta
			else:
				fl["pos_still"] = 0.0
				fl["pos_anchor"] = s.global_position
			if float(fl["still_time"]) > SETTLE_STILL_SEC or float(fl["pos_still"]) > 1.0:
				done.append(s)
		if s.global_position.length() > 40.0 or s.global_position.y < -2.0:
			done.append(s)
	for s2: Shoe in done:
		_settle_ai_shoe(s2)


func _settle_ai_shoe(s: Shoe) -> void:
	if not ai_flight.has(s):
		return
	var fl: Dictionary = ai_flight[s]
	ai_flight.erase(s)
	var tsp: Vector3 = target_stake_pos()
	var stake_at_shoe := Vector3(tsp.x, s.global_position.y, tsp.z)
	var dist_in: float = ThrowMath.nearest_distance_inches(
		s.global_transform, stake_at_shoe, Shoe.WIDTH * 0.5, Shoe.LENGTH * 0.5)
	var ringer: bool = ThrowMath.is_ringer(
		s.global_transform, stake_at_shoe,
		Shoe.RINGER_INNER_HALF, Shoe.RINGER_Z_MIN, Shoe.RINGER_Z_MAX)
	s.freeze = true
	shoe_status[s] = "DOWN"
	throw_count += 1
	last_hold_text = "FLIP (TOE)"
	last_distance_in = dist_in
	last_flip_rev = float(fl["flip"])
	last_turn_rev = float(fl["turn"])
	last_ringer = ringer
	_update_board()
	var rel: Dictionary = fl["release"]
	var ai_tilt_pr: Vector2 = _origin_pitch_roll()
	recorder.log_record({
		"type": "throw",
		"ts": Time.get_datetime_string_from_system(),
		"throw_index": throw_count,
		"hand": "AI",
		"hold": "flip",
		"zone": "toe",
		# The AI's computed release is a toe-grip flip by
		# construction (see AIPitcher) - the same declaration
		# its zone/hold fields already make.
		"grip_name": "TOE GRIP",
		"grip_nominal": 1.0,
		"slide_offset_m": 0.0,
		"line_ft": int(fl["line_ft"]),
		"origin_release_pos": ThrowRecorder.vec3_arr(origin.global_position),
		"head_yaw_deg": ThrowMath.yaw_deg(-cam.global_transform.basis.z),
		"origin_yaw_deg": ThrowMath.yaw_deg(-origin.global_transform.basis.z),
		"origin_pitch_deg": ai_tilt_pr.x,
		"origin_roll_deg": ai_tilt_pr.y,
		"samples": [],
		"release_pos": ThrowRecorder.vec3_arr(rel["pos"]),
		"release_quat": ThrowRecorder.quat_arr(
			(rel["basis"] as Basis).get_rotation_quaternion()),
		"release_velocity": ThrowRecorder.vec3_arr(rel["vel"]),
		"release_angular_velocity": ThrowRecorder.vec3_arr(rel["ang"]),
		# The AI's release is computed, exact by construction -
		# no grip stream exists to interpolate.
		"release_timing": "ai_exact",
		"substep_offset_ms": 0.0,
		"grip_bracket": [],
		"first_contact_pos": ThrowRecorder.vec3_arr(fl["first_contact_pos"]) if bool(fl["has_contact"]) else [],
		"settle_pos": ThrowRecorder.vec3_arr(s.global_position),
		"settle_quat": ThrowRecorder.quat_arr(s.global_transform.basis.get_rotation_quaternion()),
		"landing_distance_in": dist_in,
		"ringer": ringer,
		"flip_rotations": float(fl["flip"]),
		"turn_rotations": float(fl["turn"]),
	})
	inning_results.append({"owner": "AI", "dist_in": dist_in, "ringer": ringer})
	_on_turn_shoe_settled("AI")
