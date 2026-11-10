extends SceneTree

## Measured-level audio rig (Fix Pass 32): the impact dressing's
## routing tests all passed while the player heard NOTHING - a
## routing assertion is not proof of sound. This rig measures
## what a listener actually gets: the real main scene, a real
## game (production grab/release for the player, production
## play_throw for the AI), an AudioEffectCapture on the Master
## bus, and the listener camera placed first at the throwing
## line (~11.4 m from the pit) and then ringside (~1.3 m).
## Every number below is a bus level in dBFS from a genuine
## shoe landing through the production throw/contact path -
## never a direct call into the sound router. (Two labelled
## CALIBRATION plays at the end isolate the attenuation chain
## itself; they are not conviction evidence.)
## Run: godot --headless --path . --script tests/audio_measure.gd
## Exit code is the failure count's sign: 0 = every measured
## level inside its band, 1 = at least one outside.
##
## Fix Pass 33 windows: the same standard for the two sounds
## Chris's FP32 field test found missing - a SHORT player
## throw (the production release at 90% velocity) lands on
## the LAWN and must sound the grass thud at the line, and a
## player throw aimed onto the pit's side tie must KNOCK.
## Both are genuine production landings, measured the same
## way; a routing-only assertion does not ship.

var failures: int = 0
var main: Node
var cam: Camera3D
var cap: AudioEffectCapture

var _watching: bool = false
var _win_peak: float = 0.0
var _win_energy: float = 0.0
var _win_frames: int = 0
var _playing_seen: Array = []


func check(cond: bool, name: String) -> void:
	if cond:
		print("PASS  ", name)
	else:
		failures += 1
		print("FAIL  ", name)


func frames(n: int) -> void:
	for i: int in n:
		await process_frame


func _db(lin: float) -> float:
	return 20.0 * log(maxf(lin, 1e-7)) / log(10.0)


func _initialize() -> void:
	_run()


# --- Capture window (drains the Master-bus capture effect on
# every process frame while armed; records peak/RMS and any
# pool player actually seen in the playing state) ---

func _watch_start() -> void:
	cap.clear_buffer()
	_win_peak = 0.0
	_win_energy = 0.0
	_win_frames = 0
	_playing_seen.clear()
	_watching = true
	_watch_loop()


func _watch_loop() -> void:
	while _watching:
		var avail: int = cap.get_frames_available()
		if avail > 0:
			var buf: PackedVector2Array = cap.get_buffer(avail)
			for s: Vector2 in buf:
				var a: float = maxf(absf(s.x), absf(s.y))
				_win_peak = maxf(_win_peak, a)
				_win_energy += s.x * s.x + s.y * s.y
				_win_frames += 1
		if main != null and main.fx != null:
			for pl: Variant in main.fx._players:
				var apl := pl as AudioStreamPlayer3D
				if apl != null and apl.playing and apl.stream != null:
					var seen: String = apl.stream.resource_path
					if not _playing_seen.has(seen):
						_playing_seen.append(seen)
		await process_frame


func _watch_stop() -> Dictionary:
	_watching = false
	await process_frame
	await process_frame
	var rms: float = 0.0
	if _win_frames > 0:
		rms = sqrt(_win_energy / (2.0 * float(_win_frames)))
	return {"peak_db": _db(_win_peak), "rms_db": _db(rms),
		"playing": _playing_seen.duplicate()}


# --- Production throw drivers (the smoke suite's own shapes:
# build_stream + scripted_game_throw verbatim in pattern, the
# AI driver is smoke's scripted_ai_throw with a chosen aim) ---

func build_stream(hand_pos: Vector3, q_hand: Quaternion, vel: Vector3,
		omega: Vector3, seed_val: int) -> Array:
	var hz: float = 90.0
	var steps: int = 30
	var accel: Vector3 = vel.normalized() * 20.0
	var axis: Vector3 = omega.normalized()
	var rate: float = omega.length()
	var now: float = float(Time.get_ticks_msec()) / 1000.0
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val
	var out: Array = []
	for i: int in steps + 1:
		var tau: float = float(steps - i) / hz
		var pos: Vector3 = hand_pos - vel * tau + 0.5 * accel * tau * tau
		pos += Vector3(rng.randf_range(-0.002, 0.002),
			rng.randf_range(-0.002, 0.002), rng.randf_range(-0.002, 0.002))
		var q: Quaternion = Quaternion(axis, -rate * tau) * q_hand
		out.append(ThrowMath.make_sample(now - tau, pos, q))
	return out


func player_throw(aim_off: Vector3 = Vector3.ZERO, vel_scale: float = 1.0) -> bool:
	if String(main.state) != "STAND":
		return false
	var thrown_shoe: Shoe = main.shoe
	var line_z: float = main.game_line_z()
	var target: Vector3 = main.target_stake_pos() + aim_off
	var release_pos := Vector3(0.25, 1.25, line_z + 0.35)
	var t_f: float = 1.15
	var vel := Vector3((target.x - release_pos.x) / t_f,
		(0.50 - release_pos.y + 4.9 * t_f * t_f) / t_f,
		(target.z - release_pos.z) / t_f) * vel_scale
	var omega := Vector3(TAU / t_f, 0.0, 0.0)
	main.test_hand_tf["R"] = Transform3D(Basis.IDENTITY,
		thrown_shoe.zone_world_center("toe"))
	main.test_grip["R"] = 1.0
	await frames(6)
	for i: int in 2:
		await physics_frame
	if String(main.state) != "HELD":
		# Fix Pass 33 rig hygiene: a failed grab must not
		# leave the test hand squeezed and parked at the
		# shoe - the residue latches the grab the moment the
		# player's turn comes round (the wedge that silently
		# ate this rig's out-of-turn attempts in FP32's flow,
		# and any later window that needs the player).
		main.test_grip["R"] = 0.0
		main.grab_state.reset()
		return false
	var rel_tf: Transform3D = Shoe.hold_transform("toe", "R")
	var hand_pos: Vector3 = release_pos - rel_tf.origin
	main.test_hand_tf["R"] = Transform3D(Basis.IDENTITY, hand_pos)
	await frames(4)
	for i: int in 2:
		await physics_frame
	main.samples = build_stream(hand_pos, Quaternion.IDENTITY, vel, omega, 777)
	var gov_was: bool = main.spin_governor_enabled
	main.spin_governor_enabled = false
	main._release_shoe(main.samples)
	main.spin_governor_enabled = gov_was
	main.grab_state.reset()
	main.test_grip["R"] = 0.0
	if String(main.state) != "FLYING":
		return false
	var waited: float = 0.0
	while waited < 12.0:
		if String(main.shoe_status[thrown_shoe]) == "DOWN":
			return true
		await create_timer(0.2).timeout
		waited += 0.2
	return false


func ai_throw(aim_off: Vector3) -> bool:
	if String(main.phase) != "AI_TURN" or main.ai_throw_pending:
		return false
	main.ai_delay = 100000.0
	var next_shoe: Shoe = null
	for s: Shoe in main.ai_pair:
		if String(main.shoe_status[s]) == "RAILED":
			next_shoe = s
			break
	if next_shoe == null:
		return false
	main.ai_pitcher.place_at(main.game_line_z())
	var from_pos: Vector3 = AIPitcher.release_base_pos(main.game_line_z())
	var aim: Vector3 = main.target_stake_pos() + aim_off
	var rel: Dictionary = AIPitcher.base_release(from_pos, aim)
	main.ai_pending_shoe = next_shoe
	main.ai_pending_release = rel
	main.ai_throw_pending = true
	main.shoe_status[next_shoe] = "HELD"
	next_shoe.freeze = true
	main.ai_pitcher.play_throw(next_shoe, rel,
		main._ai_release_now, main._ai_swing_done)
	var waited: float = 0.0
	while waited < 20.0:
		if String(main.shoe_status[next_shoe]) == "DOWN":
			return true
		await create_timer(0.2).timeout
		waited += 0.2
	return false


func wait_phase(want: String, timeout_sec: float) -> bool:
	var waited: float = 0.0
	while waited < timeout_sec:
		if String(main.phase) == want:
			return true
		await create_timer(0.2).timeout
		waited += 0.2
	return String(main.phase) == want


func new_log_entries(from_idx: int) -> Array:
	var out: Array = []
	var log_arr: Array = main.fx.play_log
	for i: int in range(from_idx, log_arr.size()):
		out.append(log_arr[i])
	return out


func report_window(label: String, res: Dictionary, entries: Array,
		listener_pos: Vector3) -> void:
	var evs: Array = []
	for e: Variant in entries:
		var d: Dictionary = e
		var dist: float = listener_pos.distance_to(d["pos"])
		evs.append("%s vol=%.1f dB @ %.1f m" % [String(d["event"]),
			float(d["volume_db"]), dist])
	print("MEASURE %s: bus peak %.1f dBFS, rms %.1f dBFS | events: %s | playing seen: %s"
		% [label, float(res["peak_db"]), float(res["rms_db"]),
			", ".join(evs) if evs.size() > 0 else "(none)",
			", ".join(res["playing"]) if res["playing"].size() > 0 else "(none)"])


func _run() -> void:
	# Boot the real scene with redirected user files (smoke's
	# hygiene: never touch the player's real settings/throws).
	var rec_path: String = "user://audio_measure_throws.jsonl"
	if FileAccess.file_exists(rec_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(rec_path))
	var set_path: String = "user://audio_measure_settings.json"
	if FileAccess.file_exists(set_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(set_path))
	var ps: PackedScene = load("res://main.tscn")
	main = ps.instantiate()
	main.recorder_path = rec_path
	main.settings_path = set_path
	root.add_child(main)
	await create_timer(0.3).timeout

	cap = AudioEffectCapture.new()
	cap.buffer_length = 2.0
	AudioServer.add_bus_effect(0, cap)

	cam = Camera3D.new()
	root.add_child(cam)
	var stake: Vector3 = main.STAKE_POS
	var line_pos := Vector3(0.0, 1.6, -0.914)
	var pit_pos := Vector3(0.0, 1.0, stake.z + 1.0)
	cam.global_position = line_pos
	cam.look_at(stake + Vector3(0.0, 0.3, 0.0))
	cam.current = true
	await frames(5)
	print("LISTENER line->stake distance: %.2f m; ringside->stake: %.2f m"
		% [line_pos.distance_to(stake), pit_pos.distance_to(stake)])

	main.start_game()
	await frames(5)

	# --- Window 1: a full inning's landings heard from the line.
	_watch_start()
	var log0: int = main.fx.play_log.size()
	var ok1: bool = await player_throw()
	var ok2: bool = await player_throw()
	var phase_ok: bool = await wait_phase("AI_TURN", 15.0)
	var ok3: bool = await ai_throw(Vector3(0.28, 0.0, 0.05))
	var res1: Dictionary = await _watch_stop()
	print("flow: player throws ", ok1, "/", ok2, " phase ", phase_ok, " ai ", ok3)
	report_window("THUD-CLASS @ LINE (inning landings)", res1,
		new_log_entries(log0), line_pos)
	check(ok1 and ok2 and ok3, "production throws completed (player x2, AI sand)")
	check(float(res1["peak_db"]) > -22.0,
		"line: inning landings peak above -22 dBFS (got %.1f)" % float(res1["peak_db"]))

	# --- Window 2: the AI's second shoe heard ringside
	# (~1.4 m). Starts the instant throw 1 settles (no gap for
	# the game's own scheduler to steal the landing): scripted
	# through the same ceremony; if the game already has its
	# own swing pending, that landing is measured instead.
	cam.global_position = pit_pos
	cam.look_at(stake + Vector3(0.0, 0.3, 0.0))
	cam.current = true
	await frames(3)
	_watch_start()
	log0 = main.fx.play_log.size()
	var ok4: bool = await ai_throw(Vector3(-0.24, 0.0, -0.04))
	if not ok4:
		var tw: float = 0.0
		while tw < 25.0:
			await physics_frame
			tw += 1.0 / 60.0
			if new_log_entries(log0).size() > 0 and main.ai_flight.is_empty() \
					and not main.ai_throw_pending:
				ok4 = true
				break
	await create_timer(0.6).timeout
	var res2: Dictionary = await _watch_stop()
	report_window("THUD @ RINGSIDE", res2,
		new_log_entries(log0), pit_pos)
	check(ok4, "ringside: the AI's second shoe landed")
	check(float(res2["peak_db"]) < -3.0 and float(res2["peak_db"]) > -25.0,
		"ringside: thud present but not blasting, -25..-3 dBFS (got %.1f)"
		% float(res2["peak_db"]))

	# --- Window 3: the ringer at the line (second inning).
	var ins_ok: bool = await wait_phase("INSERT", 20.0)
	if ins_ok:
		main._continue_round()
		await frames(5)
	cam.global_position = line_pos
	cam.look_at(stake + Vector3(0.0, 0.3, 0.0))
	cam.current = true
	await frames(3)
	var ok5: bool = await player_throw()
	var ok6: bool = await player_throw()
	var phase2_ok: bool = await wait_phase("AI_TURN", 15.0)
	_watch_start()
	log0 = main.fx.play_log.size()
	var ok7: bool = await ai_throw(Vector3.ZERO)
	await create_timer(1.9).timeout # the bell's full sustain
	var res3: Dictionary = await _watch_stop()
	print("flow: round 2 player ", ok5, "/", ok6, " phase ", phase2_ok, " ai ringer ", ok7)
	report_window("RINGER @ LINE", res3, new_log_entries(log0), line_pos)
	var saw_ring: bool = false
	for e: Variant in new_log_entries(log0):
		if String((e as Dictionary)["event"]) == "ringer":
			saw_ring = true
	check(saw_ring, "the scripted ringer throw settled as a ringer (ring routed)")
	check(float(res3["peak_db"]) > -20.0,
		"line: the ringer's ring peaks above -20 dBFS (got %.1f)" % float(res3["peak_db"]))

	# --- Window 4 (Fix Pass 33): a SHORT throw lands on the
	# LAWN, heard from the line: the production release at
	# 90% velocity - a real throw with less on it, Chris's
	# own case. It must first-touch grass clear of the pit's
	# box zone and sound the grass thud, never the sand thud.
	# The two FP33 windows run on a FRESH game (start_game,
	# the game's own new-game path): the FP32 windows leave
	# the match mid-inning with the turn order set by who
	# scored, and a player_throw attempted out of turn can
	# latch a grab it cannot release - a fresh game puts the
	# player at the line, first throw, state STAND.
	main.start_game()
	await frames(5)
	print("flow: FP33 windows on a fresh game - phase ", String(main.phase),
		" state ", String(main.state))
	cam.global_position = line_pos
	cam.look_at(stake + Vector3(0.0, 0.3, 0.0))
	cam.current = true
	await frames(3)
	_watch_start()
	log0 = main.fx.play_log.size()
	var ok8: bool = await player_throw(Vector3.ZERO, 0.90)
	await create_timer(0.5).timeout
	var res4: Dictionary = await _watch_stop()
	report_window("GRASS THUD @ LINE (short throw)", res4,
		new_log_entries(log0), line_pos)
	var saw_grass: bool = false
	var grass_in_box: bool = false
	for e4: Variant in new_log_entries(log0):
		var d4: Dictionary = e4
		if String(d4["event"]) == "grass_thud":
			saw_grass = true
			var gp: Vector3 = d4["pos"]
			if absf(gp.x - stake.x) <= 0.914 and absf(gp.z - stake.z) <= 0.914:
				grass_in_box = true
	check(ok8, "grass: the short production throw landed")
	check(saw_grass, "grass: the lawn landing routed the grass thud")
	check(not grass_in_box, "grass: the landing was a true lawn contact, outside the pit's box zone")
	check(float(res4["peak_db"]) > -24.0,
		"line: the grass thud peaks above -24 dBFS (got %.1f)" % float(res4["peak_db"]))

	# --- Window 5 (Fix Pass 33): the player's second shoe of
	# the inning, aimed onto the pit's right side tie - a
	# genuine frame strike through the production path. The
	# knock must route and carry to the line.
	_watch_start()
	log0 = main.fx.play_log.size()
	var ok9: bool = await player_throw(Vector3(0.60, 0.0, 0.0))
	await create_timer(0.5).timeout
	var res5: Dictionary = await _watch_stop()
	report_window("WOOD KNOCK @ LINE (side-tie strike)", res5,
		new_log_entries(log0), line_pos)
	var saw_knock: bool = false
	for e5: Variant in new_log_entries(log0):
		if String((e5 as Dictionary)["event"]) == "wood_knock":
			saw_knock = true
	check(ok9, "wood: the tie-aimed production throw landed")
	check(saw_knock, "wood: the frame strike routed the wood knock")
	check(float(res5["peak_db"]) > -22.0,
		"line: the wood knock peaks above -22 dBFS (got %.1f)" % float(res5["peak_db"]))

	# --- CALIBRATION (not conviction evidence): the chain's own
	# gain for the ring stream at its game volume, two distances.
	for cfg: Array in [[line_pos, "12 m"], [pit_pos, "ringside"]]:
		var cpos: Vector3 = cfg[0]
		cam.global_position = cpos
		cam.look_at(stake + Vector3(0.0, 0.3, 0.0))
		cam.current = true
		await frames(3)
		_watch_start()
		main.fx.play_event("ringer", stake, 1.0)
		await create_timer(1.7).timeout
		var cres: Dictionary = await _watch_stop()
		print("CALIBRATION ring chain @ %s: bus peak %.1f dBFS"
			% [String(cfg[1]), float(cres["peak_db"])])

	print("AUDIO MEASURE DONE: failures=", failures)
	quit(1 if failures > 0 else 0)
