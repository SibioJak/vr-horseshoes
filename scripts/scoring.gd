class_name Scoring
extends RefCounted

## NHPA cancellation scoring for one inning (Backyard Game v1).
## Pure math, no scene access: the logic suites feed hand-computed
## cases, the game feeds the four settled shoes of an inning.
##
## The rule, as Chris's brief states it:
##   - A ringer (shoe encircling the stake, per ThrowMath.is_ringer)
##     is worth 3 points. Ringers CANCEL in pairs across the two
##     sides; only the uncancelled remainder scores.
##   - A shoe within 6 in of the stake is a point shoe. After
##     ringer cancellation, only the side holding the closest
##     point shoe(s) scores: 1 per shoe closer than the opponent's
##     closest.
##   - Only one side scores per inning.
##
## The point-shoe comparison runs on NON-ringer shoes, with one
## addition the real game needs: an uncancelled ringer sits at
## distance 0, so it holds "closest" for its side - it blocks the
## opponent's point shoes entirely, while its own side's point
## shoes still score when they beat the opponent's closest.
## (Both ringers cancelled: the ringer rule is done, and the
## point shoes decide among themselves - that is what
## "cancellation" means in the NHPA game.)

const POINT_RANGE_IN: float = 6.0
const RINGER_POINTS: int = 3

# Fix Pass 44 (PROXIMITY scoring): the band edges, in inches.
# Every settled shoe scores by its distance to the stake:
# inside the first edge pays 4, then 3, 2, 1, and beyond the
# last edge nothing. A ringer measures ~0 in, so it simply
# lands in the 4 band - there is no separate ringer rule.
const PROXIMITY_RANGE_4: float = 6.0
const PROXIMITY_RANGE_3: float = 12.0
const PROXIMITY_RANGE_2: float = 24.0
const PROXIMITY_RANGE_1: float = 48.0


## shoes: Array of {"owner": "P"|"AI", "dist_in": float,
## "ringer": bool} - the settled results of one inning (normally
## two per side). Returns:
##   {"points_p": int, "points_ai": int,
##    "ringers_p": int, "ringers_ai": int,   (raw counts)
##    "scorer": "P"|"AI"|"",                 ("" = scoreless)
##    "summary": String}                     (board/detail line)
static func score_inning(shoes: Array) -> Dictionary:
	var ringers_p: int = 0
	var ringers_ai: int = 0
	var closest_p: float = INF
	var closest_ai: float = INF
	var points_p: int = 0
	var points_ai: int = 0
	for raw: Variant in shoes:
		var s: Dictionary = raw
		var d: float = float(s["dist_in"])
		if bool(s["ringer"]):
			if String(s["owner"]) == "P":
				ringers_p += 1
			else:
				ringers_ai += 1
		else:
			if String(s["owner"]) == "P":
				closest_p = minf(closest_p, d)
			else:
				closest_ai = minf(closest_ai, d)
	var rem_p: int = maxi(0, ringers_p - ringers_ai)
	var rem_ai: int = maxi(0, ringers_ai - ringers_p)
	points_p += RINGER_POINTS * rem_p
	points_ai += RINGER_POINTS * rem_ai
	# Effective closest for the point-shoe contest: an
	# uncancelled ringer is a shoe at distance 0.
	var eff_p: float = 0.0 if rem_p > 0 else closest_p
	var eff_ai: float = 0.0 if rem_ai > 0 else closest_ai
	if eff_p < eff_ai:
		for raw2: Variant in shoes:
			var s2: Dictionary = raw2
			if String(s2["owner"]) == "P" and not bool(s2["ringer"]):
				var d2: float = float(s2["dist_in"])
				if d2 <= POINT_RANGE_IN and d2 < eff_ai:
					points_p += 1
	elif eff_ai < eff_p:
		for raw3: Variant in shoes:
			var s3: Dictionary = raw3
			if String(s3["owner"]) == "AI" and not bool(s3["ringer"]):
				var d3: float = float(s3["dist_in"])
				if d3 <= POINT_RANGE_IN and d3 < eff_p:
					points_ai += 1
	var scorer: String = ""
	if points_p > 0 and points_ai == 0:
		scorer = "P"
	elif points_ai > 0 and points_p == 0:
		scorer = "AI"
	var summary: String = "NO SCORE"
	if scorer == "P":
		summary = "YOU +%d" % points_p
	elif scorer == "AI":
		summary = "OPP +%d" % points_ai
	if rem_p > 0:
		summary += " (RINGER)"
	elif rem_ai > 0:
		summary += " (OPP RINGER)"
	return {
		"points_p": points_p,
		"points_ai": points_ai,
		"ringers_p": ringers_p,
		"ringers_ai": ringers_ai,
		"scorer": scorer,
		"summary": summary,
	}


## Per-shoe lines for the round breakdown (Fix Pass 20's
## insert cam): one line per settled shoe, in throw order,
## each side numbered within itself. The result words are
## the insert's three: RINGER, the distance in inches for a
## point-range shoe, or NO SCORE with the distance kept.
static func shoe_lines(shoes: Array) -> Array:
	var lines: Array = []
	var n_p: int = 0
	var n_ai: int = 0
	for raw: Variant in shoes:
		var s: Dictionary = raw
		var who: String
		if String(s["owner"]) == "P":
			n_p += 1
			who = "YOU %d" % n_p
		else:
			n_ai += 1
			who = "OPP %d" % n_ai
		var res_text: String
		if bool(s["ringer"]):
			res_text = "RINGER"
		elif float(s["dist_in"]) <= POINT_RANGE_IN:
			res_text = "%.1f IN" % float(s["dist_in"])
		else:
			res_text = "NO SCORE (%.1f IN)" % float(s["dist_in"])
		lines.append("%s: %s" % [who, res_text])
	return lines


## The cancellation arithmetic in plain words (Fix Pass 20):
## how the round's points came to be, line by line - ringers
## cancel in pairs, a standing ringer scores, and point
## shoes score only for the side holding the closest (which
## is why a point-range shoe on the losing side earns the
## CLOSEST ONLY SCORES line when it was shut out).
static func explain_lines(shoes: Array, res: Dictionary) -> Array:
	var lines: Array = []
	var ringers_p: int = int(res["ringers_p"])
	var ringers_ai: int = int(res["ringers_ai"])
	var rem_p: int = maxi(0, ringers_p - ringers_ai)
	var rem_ai: int = maxi(0, ringers_ai - ringers_p)
	if ringers_p > 0 and ringers_ai > 0:
		lines.append("RINGERS CANCEL IN PAIRS")
	if rem_p == 1:
		lines.append("YOUR RINGER STANDS: +%d" % (RINGER_POINTS * rem_p))
	elif rem_p > 1:
		lines.append("YOUR RINGERS STAND: +%d" % (RINGER_POINTS * rem_p))
	if rem_ai == 1:
		lines.append("OPP RINGER STANDS: +%d" % (RINGER_POINTS * rem_ai))
	elif rem_ai > 1:
		lines.append("OPP RINGERS STAND: +%d" % (RINGER_POINTS * rem_ai))
	var point_p: int = int(res["points_p"]) - RINGER_POINTS * rem_p
	var point_ai: int = int(res["points_ai"]) - RINGER_POINTS * rem_ai
	if point_p == 1:
		lines.append("YOUR CLOSEST SHOE SCORES: +1")
	elif point_p > 1:
		lines.append("YOUR CLOSEST SHOES SCORE: +%d" % point_p)
	if point_ai == 1:
		lines.append("OPP CLOSEST SHOE SCORES: +1")
	elif point_ai > 1:
		lines.append("OPP CLOSEST SHOES SCORE: +%d" % point_ai)
	if String(res["scorer"]) != "" and _loser_had_point_shoe(shoes, res):
		lines.append("CLOSEST ONLY SCORES")
	if int(res["points_p"]) == 0 and int(res["points_ai"]) == 0:
		lines.append("NO SCORE THIS ROUND")
	return lines


## Fix Pass 44: the PROXIMITY band one settled shoe earns,
## by its distance to the stake (the same dist_in the
## classic scorer reads for point shoes). Band edges are
## inclusive: exactly 6 in pays 4, exactly 48 pays 1.
static func proximity_points(dist_in: float) -> int:
	if dist_in <= PROXIMITY_RANGE_4:
		return 4
	if dist_in <= PROXIMITY_RANGE_3:
		return 3
	if dist_in <= PROXIMITY_RANGE_2:
		return 2
	if dist_in <= PROXIMITY_RANGE_1:
		return 1
	return 0


## Fix Pass 44: PROXIMITY scoring for one inning - the
## second mode beside the classic cancellation above (which
## is untouched). EVERY shoe scores its band for its own
## side: no cancellation, no closest contest, both sides
## score every inning they land anything. Same input and
## result shape as score_inning, so the game's tabulation
## reads either mode the same way. "scorer" names the side
## that scored MORE this inning ("" on a tie) - the game
## uses it for the next inning's first throw, exactly as it
## uses the classic scorer.
static func score_inning_proximity(shoes: Array) -> Dictionary:
	var points_p: int = 0
	var points_ai: int = 0
	var ringers_p: int = 0
	var ringers_ai: int = 0
	for raw: Variant in shoes:
		var s: Dictionary = raw
		var pts: int = proximity_points(float(s["dist_in"]))
		if bool(s["ringer"]):
			if String(s["owner"]) == "P":
				ringers_p += 1
			else:
				ringers_ai += 1
		if String(s["owner"]) == "P":
			points_p += pts
		else:
			points_ai += pts
	var scorer: String = ""
	if points_p > points_ai:
		scorer = "P"
	elif points_ai > points_p:
		scorer = "AI"
	var summary: String = "NO SCORE"
	if points_p > 0 or points_ai > 0:
		summary = "YOU +%d - OPP +%d" % [points_p, points_ai]
	return {
		"points_p": points_p,
		"points_ai": points_ai,
		"ringers_p": ringers_p,
		"ringers_ai": ringers_ai,
		"scorer": scorer,
		"summary": summary,
	}


## Fix Pass 44: per-shoe lines for the PROXIMITY round
## breakdown - same owner numbering as shoe_lines, each
## line carrying the shoe's distance AND its band points,
## for both sides (every shoe scores, so every shoe's
## line shows what it earned, 0 included).
static func proximity_shoe_lines(shoes: Array) -> Array:
	var lines: Array = []
	var n_p: int = 0
	var n_ai: int = 0
	for raw: Variant in shoes:
		var s: Dictionary = raw
		var who: String
		if String(s["owner"]) == "P":
			n_p += 1
			who = "YOU %d" % n_p
		else:
			n_ai += 1
			who = "OPP %d" % n_ai
		var d: float = float(s["dist_in"])
		lines.append("%s: %.1f IN = %d PTS" % [who, d, proximity_points(d)])
	return lines


## Did the losing side land a point-range shoe that earned
## nothing? It lost the closest contest - or a standing
## ringer held closest (distance 0) against it.
static func _loser_had_point_shoe(shoes: Array, res: Dictionary) -> bool:
	var scorer: String = String(res["scorer"])
	if scorer == "":
		return false
	for raw: Variant in shoes:
		var s: Dictionary = raw
		if String(s["owner"]) != scorer and not bool(s["ringer"]) \
				and float(s["dist_in"]) <= POINT_RANGE_IN:
			return true
	return false
