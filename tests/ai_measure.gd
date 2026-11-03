extends SceneTree
## AI distribution measurement (Backyard Game v1, brief item 5):
## throw 220 AI releases through the PRODUCTION flight path -
## the pitcher's sampled release, the stake sweep guard, the
## real shoe physics and the production scoring measurements -
## and report the line: ringer %, shoes inside 6 in, and
## self-play points per inning (consecutive pairs scored
## against each other through Scoring, NHPA cancellation).
## Run: godot --headless --path . --script tests/ai_measure.gd

const THROWS: int = 220

var main: Node
var rng := RandomNumberGenerator.new()
var results: Array = [] # {dist_in, ringer}


func _initialize() -> void:
	_run()


func wait_physics(n: int) -> void:
	for i: int in n:
		await physics_frame


func throw_once(shoe_node: Shoe) -> Dictionary:
	var from_pos: Vector3 = AIPitcher.release_base_pos(1, 0.0)
	var rel: Dictionary
	if OS.has_feature("ai_perfect") or "--perfect" in OS.get_cmdline_user_args():
		rel = AIPitcher.base_release(from_pos, main.STAKE_POS)
	else:
		rel = AIPitcher.sample_release(rng, from_pos, main.STAKE_POS)
	# The release flag rides in an Array so the pitcher's
	# callback write is always visible to the wait below. A
	# swing whose release window (~0.18 s of animation time)
	# is jumped by one coarse _process delta on a loaded
	# machine never fires - that is a harness miss, not a
	# throw, so the SAME sampled release is replayed (up to
	# 5 attempts) instead of being measured sitting in the
	# hand. The release dict fully determines the flight, so
	# replaying it cannot bias the distribution.
	var fired_box: Array = [false]
	var fired: bool = false
	for attempt: int in 5:
		fired_box[0] = false
		main.ai_pitcher.place_at(1, 0.0)
		shoe_node.freeze = true
		main.ai_pitcher.play_throw(shoe_node, rel, func() -> void:
			main._wire_guard(shoe_node, "FAR")
			shoe_node.reset_stake_guard()
			shoe_node.freeze = false
			shoe_node.global_transform = Transform3D(rel["basis"], rel["pos"])
			shoe_node.linear_velocity = rel["vel"]
			shoe_node.angular_velocity = rel["ang"]
			fired_box[0] = true
		, func() -> void:
			pass)
		# Wait out the swing, then the flight, with the production
		# settle discipline (0.6 s minimum, rest thresholds).
		var frames_waited: int = 0
		while not bool(fired_box[0]) and frames_waited < 600:
			await physics_frame
			frames_waited += 1
		fired = bool(fired_box[0])
		if fired:
			break
	if not fired:
		print("AI MEASURE: harness miss - release never fired in 5 attempts")
		shoe_node.freeze = true
		return {"dist_in": -1.0, "ringer": false, "missed": true}
	var fly: int = 0
	var still: int = 0
	while fly < 600:
		await physics_frame
		fly += 1
		if fly > 36:
			if shoe_node.linear_velocity.length() < 0.10 \
					and shoe_node.angular_velocity.length() < 0.30:
				still += 1
			else:
				still = 0
			if still > 18:
				break
	shoe_node.freeze = true
	var stake_at := Vector3(main.STAKE_POS.x, shoe_node.global_position.y, main.STAKE_POS.z)
	var dist_in: float = ThrowMath.nearest_distance_inches(
		shoe_node.global_transform, stake_at, Shoe.WIDTH * 0.5, Shoe.LENGTH * 0.5)
	var ringer: bool = ThrowMath.is_ringer(
		shoe_node.global_transform, stake_at,
		Shoe.RINGER_INNER_HALF, Shoe.RINGER_Z_MIN, Shoe.RINGER_Z_MAX)
	return {"dist_in": dist_in, "ringer": ringer, "missed": false}


func _run() -> void:
	# Real-time pacing on purpose (see the speed_scale note
	# below): speeding the clock up multiplies the pitcher's
	# _process delta by the same factor, which is exactly
	# what jumps its release window on a loaded machine.
	Engine.time_scale = 1.0
	rng.seed = 20261102
	var packed: PackedScene = load("res://main.tscn")
	main = packed.instantiate()
	root.add_child(main)
	await process_frame
	await physics_frame
	# Harness pacing: the swing advances on _process deltas, so
	# a faster swing (or a faster clock) is MORE likely to have
	# its release window jumped on a loaded machine, not less.
	# Live pacing (1.0) plus the retry in throw_once keeps the
	# measurement honest at any load; the sampler and the
	# production flight are untouched.
	main.ai_pitcher.speed_scale = 1.0
	var pair: Array = main.ai_pair
	var misses: int = 0
	for i: int in THROWS:
		var shoe_node: Shoe = pair[i % 2]
		var res: Dictionary = await throw_once(shoe_node)
		if bool(res.get("missed", false)):
			misses += 1
		else:
			results.append(res)
		if (i + 1) % 25 == 0:
			print("AI MEASURE: progress %d/%d (misses %d)" % [i + 1, THROWS, misses])
		# Park the thrown shoe clear of the lane for the next one.
		shoe_node.global_transform = Transform3D(Basis.IDENTITY,
			Vector3(3.0 if i % 2 == 0 else -3.0, 0.4, -6.0))
	var ringers: int = 0
	var inside: int = 0
	var dist_sum: float = 0.0
	for res2: Dictionary in results:
		if bool(res2["ringer"]):
			ringers += 1
		if float(res2["dist_in"]) <= 6.0:
			inside += 1
		dist_sum += float(res2["dist_in"])
	# Self-play: consecutive fours as innings, 2 v 2.
	var innings: int = 0
	var pts_sum: float = 0.0
	var idx: int = 0
	while idx + 4 <= results.size():
		var shoes: Array = []
		for k: int in 4:
			var rr: Dictionary = results[idx + k]
			shoes.append({"owner": "P" if k < 2 else "AI",
				"dist_in": float(rr["dist_in"]), "ringer": bool(rr["ringer"])})
		var sc: Dictionary = Scoring.score_inning(shoes)
		pts_sum += float(int(sc["points_p"]) + int(sc["points_ai"]))
		innings += 1
		idx += 4
	print("AI MEASURE: n=%d ringers %d (%.1f%%) inside-6in %d (%.1f%%) mean dist %.1f in" % [
		results.size(), ringers, 100.0 * float(ringers) / float(results.size()),
		inside, 100.0 * float(inside) / float(results.size()),
		dist_sum / float(results.size())])
	print("AI MEASURE: self-play %.2f points per side per inning over %d innings" % [
		pts_sum / float(maxi(innings, 1)) / 2.0, innings])
	print("AI MEASURE: harness misses %d (excluded from the line)" % misses)
	quit(0)
