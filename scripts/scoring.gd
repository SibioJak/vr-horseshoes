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
