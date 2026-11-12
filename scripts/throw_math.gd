class_name ThrowMath
extends RefCounted

## Pure throw math for the toss test: windowed release estimation,
## ringer geometry, landing distance. No scene access - everything is
## fed in, so the logic suites exercise exactly what the headset runs.
##
## A sample is a Dictionary: { "t": float seconds, "pos": Vector3,
## "quat": Quaternion, "opos": Vector3 } in world space, timestamps
## honest/mono. "opos" is the XR origin's world position at the same
## instant (Fix Pass 2): with thumbstick locomotion the origin moves,
## and its motion must never leak into a release velocity - see
## estimate_velocity_origin_relative().

const METERS_TO_INCHES: float = 39.3701
# Fix Pass 19: the foul lines are TRUE lines now - they stand
# 3 ft in front of the pitching-end stake position, so a line's
# distance from the TARGET stake is 37 ft (11.278 m) for the
# 40 ft class and 27 ft (8.230 m) for the 30 ft class. Before
# FP19 the backyard's "lines" sat ON the removed home stake's
# plane, a full 12.192 / 9.144 m from the target.
const SHORT_LINE_DISTANCE_M: float = 8.230 # the 27 ft foul line, from the target stake
const STANDARD_LINE_DISTANCE_M: float = 11.278 # the 37 ft foul line, from the target stake


static func make_sample(t: float, pos: Vector3, quat: Quaternion, opos: Vector3 = Vector3.ZERO) -> Dictionary:
	return {"t": t, "pos": pos, "quat": quat, "opos": opos}


## Heading of a world forward vector, projected onto the XZ plane,
## in degrees from the court's -Z axis (the stake line). Negative =
## facing LEFT of the line, positive = right - the same sign as a
## velocity azimuth, so a throw record's head_yaw_deg /
## origin_yaw_deg can be compared directly against its release
## azimuth when the "stance or arm" question gets asked. Only x/z
## are read; pitch cannot leak in.
static func yaw_deg(fwd: Vector3) -> float:
	if Vector2(fwd.x, fwd.z).length() < 0.0001:
		return 0.0
	return rad_to_deg(atan2(fwd.x, -fwd.z))


## Which foul line a release belongs to, from the release point's
## horizontal distance to the stake: nearer the 30 ft class line
## distance (8.230 m - the 27 ft foul line) classifies as 30,
## nearer the 40 ft class distance (11.278 m - the 37 ft foul
## line) as 40. Height is ignored - a release is high by definition, and its
## height must not push a short-line throw into the standard class.
static func line_ft_for_release(release_pos: Vector3, stake_pos: Vector3) -> int:
	var d: float = Vector2(release_pos.x - stake_pos.x, release_pos.z - stake_pos.z).length()
	var to_short: float = absf(d - SHORT_LINE_DISTANCE_M)
	var to_standard: float = absf(d - STANDARD_LINE_DISTANCE_M)
	return 30 if to_short < to_standard else 40


## How close (in metres of stake distance) a point must sit to a
## foul line's distance to count as standing AT that line. Covers
## the stance box (the line +/- 0.40 m) plus a natural lean/reach,
## while the 3.048 m gap between the lines keeps mid-court and the
## pit firmly "neither".
const LINE_PROXIMITY_M: float = 0.75


## Which foul line a PERSON is standing at, or 0 for neither
## (Fix Pass 7: shoe stocking follows the player). Built on
## line_ft_for_release - the same nearer-line classification the
## throw records use - plus a proximity gate: the bare classifier
## always answers 30 or 40, but a player up at the pit inspecting
## a landing is at NEITHER line and must not drag the stocked
## shoe with him. Height is ignored, as in the release
## classification.
static func standing_line_ft(pos: Vector3, stake_pos: Vector3) -> int:
	var line_ft: int = line_ft_for_release(pos, stake_pos)
	var d: float = Vector2(pos.x - stake_pos.x, pos.z - stake_pos.z).length()
	var line_d: float = SHORT_LINE_DISTANCE_M if line_ft == 30 else STANDARD_LINE_DISTANCE_M
	return line_ft if absf(d - line_d) <= LINE_PROXIMITY_M else 0


## Per-sample speeds by central difference (endpoints one-sided).
static func sample_speeds(samples: Array) -> PackedFloat32Array:
	var speeds := PackedFloat32Array()
	speeds.resize(samples.size())
	for i: int in samples.size():
		var a: int = maxi(0, i - 1)
		var b: int = mini(samples.size() - 1, i + 1)
		if b == a:
			speeds[i] = 0.0
			continue
		var pa: Vector3 = samples[a]["pos"]
		var pb: Vector3 = samples[b]["pos"]
		var dt: float = float(samples[b]["t"]) - float(samples[a]["t"])
		speeds[i] = (pb - pa).length() / dt if dt > 0.0001 else 0.0
	return speeds


## Index of the fastest sample. The release window is anchored here,
## never on the last frame (the hand is already opening by then).
static func peak_speed_index(samples: Array) -> int:
	if samples.is_empty():
		return -1
	var speeds: PackedFloat32Array = sample_speeds(samples)
	var best: int = 0
	for i: int in speeds.size():
		if speeds[i] > speeds[best]:
			best = i
	return best


## The subset used for a release estimate: from window_sec before the
## peak-speed sample through a small tail past it (the peak can sit a
## frame or two before the buffer end when the grip opens).
static func window_subset(samples: Array, window_sec: float = 0.150) -> Array:
	var out: Array = []
	if samples.size() < 2:
		return out
	var pk: int = peak_speed_index(samples)
	var t_peak: float = float(samples[pk]["t"])
	var t_lo: float = t_peak - window_sec
	var t_hi: float = t_peak + 0.030
	for raw: Variant in samples:
		var s: Dictionary = raw
		var t: float = float(s["t"])
		if t >= t_lo and t <= t_hi:
			out.append(s)
	if out.size() < 2:
		out = samples.slice(maxi(0, samples.size() - 3))
	return out


## Linear velocity from a least-squares QUADRATIC fit of position vs
## time over the release window, derivative evaluated AT the
## peak-speed instant. This is THE estimate the throw uses: the fit
## spans ~150 ms so one noisy frame moves it very little, and the
## quadratic term keeps it honest while the hand is still
## accelerating into the release (a plain slope fit lags by half the
## window under acceleration - measured, not theoretical).
static func estimate_velocity_windowed(samples: Array, window_sec: float = 0.150) -> Vector3:
	var sub: Array = window_subset(samples, window_sec)
	if sub.size() < 2:
		return Vector3.ZERO
	var pk: int = peak_speed_index(samples)
	var t_eval: float = float(samples[pk]["t"])
	if sub.size() < 3:
		# Degenerate window: two-point slope is all there is.
		var a: Dictionary = sub[0]
		var b: Dictionary = sub[sub.size() - 1]
		var dt: float = float(b["t"]) - float(a["t"])
		if dt < 0.0001:
			return Vector3.ZERO
		var pa: Vector3 = a["pos"]
		var pb: Vector3 = b["pos"]
		return (pb - pa) / dt
	var coeffs: Dictionary = _quadratic_fit(sub, t_eval)
	if coeffs.is_empty():
		return Vector3.ZERO
	var cx: Array = coeffs["cx"]
	var cy: Array = coeffs["cy"]
	var cz: Array = coeffs["cz"]
	return Vector3(float(cx[1]), float(cy[1]), float(cz[1]))


## The windowed quadratic fit itself, shared by every evaluation:
## normal equations for p(t) = c0 + c1*u + c2*u^2 with u = t - t_ref
## (centring keeps the sums conditioned), solved per axis. Returns
## {"cx": [c0, c1, c2], "cy": [...], "cz": [...]} or {} if singular.
static func _quadratic_fit(sub: Array, t_ref: float) -> Dictionary:
	var s: Array[float] = [0.0, 0.0, 0.0, 0.0, 0.0]
	var tx: Array[float] = [0.0, 0.0, 0.0]
	var ty: Array[float] = [0.0, 0.0, 0.0]
	var tz: Array[float] = [0.0, 0.0, 0.0]
	for raw: Variant in sub:
		var smp: Dictionary = raw
		var u: float = float(smp["t"]) - t_ref
		var p: Vector3 = smp["pos"]
		var pw: Array[float] = [1.0, u, u * u, u * u * u, u * u * u * u]
		for k: int in 5:
			s[k] += pw[k]
		for k2: int in 3:
			tx[k2] += pw[k2] * p.x
			ty[k2] += pw[k2] * p.y
			tz[k2] += pw[k2] * p.z
	var m: Array = [
		[s[0], s[1], s[2]],
		[s[1], s[2], s[3]],
		[s[2], s[3], s[4]],
	]
	var cx: Array = _solve3(m, [tx[0], tx[1], tx[2]])
	var cy: Array = _solve3(m, [ty[0], ty[1], ty[2]])
	var cz: Array = _solve3(m, [tz[0], tz[1], tz[2]])
	if cx.is_empty() or cy.is_empty() or cz.is_empty():
		return {}
	return {"cx": cx, "cy": cy, "cz": cz}


## Small Gaussian elimination for the 3x3 fit system; [] if singular.
static func _solve3(m: Array, v: Array) -> Array:
	var a: Array = [
		[float(m[0][0]), float(m[0][1]), float(m[0][2]), float(v[0])],
		[float(m[1][0]), float(m[1][1]), float(m[1][2]), float(v[1])],
		[float(m[2][0]), float(m[2][1]), float(m[2][2]), float(v[2])],
	]
	for col: int in 3:
		var piv: int = col
		for r: int in range(col + 1, 3):
			if absf(float(a[r][col])) > absf(float(a[piv][col])):
				piv = r
		if absf(float(a[piv][col])) < 0.0000000001:
			return []
		if piv != col:
			var tmp: Array = a[col]
			a[col] = a[piv]
			a[piv] = tmp
		for r2: int in range(col + 1, 3):
			var f: float = float(a[r2][col]) / float(a[col][col])
			for c2: int in range(col, 4):
				a[r2][c2] = float(a[r2][c2]) - f * float(a[col][c2])
	var out: Array[float] = [0.0, 0.0, 0.0]
	for r3: int in range(2, -1, -1):
		var acc: float = float(a[r3][3])
		for c3: int in range(r3 + 1, 3):
			acc -= float(a[r3][c3]) * out[c3]
		out[r3] = acc / float(a[r3][r3])
	return [out[0], out[1], out[2]]


## Release velocity with the locomoting origin removed (Fix Pass 2).
## Each sample's hand position is first expressed relative to the
## origin position recorded WITH that sample, in the frame of the
## origin's orientation at the release moment (release_basis); the
## windowed fit runs there and the result is rotated back to world.
## A player standing still (constant opos, however far he walked
## before the throw) gets exactly the pass-1 estimate - the relative
## positions differ from the world ones by a constant offset, which
## the fit cannot see. A player sliding forward with a still arm
## gets ~zero: his hand never moves relative to the origin.
static func estimate_velocity_origin_relative(samples: Array, release_basis: Basis) -> Vector3:
	if samples.is_empty():
		return Vector3.ZERO
	var rel: Array = _origin_relative_samples(samples, release_basis)
	var v_frame: Vector3 = estimate_velocity_windowed(rel)
	return release_basis * v_frame


## The per-sample origin removal shared by both origin-relative
## evaluations (see estimate_velocity_origin_relative for why).
static func _origin_relative_samples(samples: Array, release_basis: Basis) -> Array:
	var inv: Basis = release_basis.inverse()
	var rel: Array = []
	for raw: Variant in samples:
		var s: Dictionary = raw
		var p: Vector3 = s["pos"]
		var o: Vector3 = s.get("opos", Vector3.ZERO)
		rel.append(make_sample(float(s["t"]), inv * (p - o), s["quat"]))
	return rel


## The naive last-two-frames estimate. Exists ONLY as the negative
## control: the Duel proved this swings wildly near release, and the
## suite asserts it violates the tolerance the windowed fit meets.
static func estimate_velocity_single_frame(samples: Array) -> Vector3:
	if samples.size() < 2:
		return Vector3.ZERO
	var a: Dictionary = samples[samples.size() - 2]
	var b: Dictionary = samples[samples.size() - 1]
	var dt: float = float(b["t"]) - float(a["t"])
	if dt < 0.0001:
		return Vector3.ZERO
	var pa: Vector3 = a["pos"]
	var pb: Vector3 = b["pos"]
	return (pb - pa) / dt


## Angular velocity (rad/s, world axes) averaged over the same release
## window from consecutive quaternion deltas, shortest-arc corrected.
static func estimate_angular_velocity_windowed(samples: Array, window_sec: float = 0.150) -> Vector3:
	var sub: Array = window_subset(samples, window_sec)
	if sub.size() < 2:
		return Vector3.ZERO
	var sum := Vector3.ZERO
	var total_dt: float = 0.0
	for i: int in sub.size() - 1:
		var qa: Quaternion = sub[i]["quat"]
		var qb: Quaternion = sub[i + 1]["quat"]
		var dt: float = float(sub[i + 1]["t"]) - float(sub[i]["t"])
		if dt < 0.0001:
			continue
		var dq: Quaternion = qb * qa.inverse()
		if dq.w < 0.0:
			dq = -dq
		var w: float = clampf(dq.w, -1.0, 1.0)
		var angle: float = 2.0 * acos(w)
		if angle < 0.00001:
			continue
		var s: float = sqrt(maxf(0.0, 1.0 - w * w))
		var axis: Vector3
		if s < 0.0005:
			axis = Vector3(1.0, 0.0, 0.0)
		else:
			axis = Vector3(dq.x, dq.y, dq.z) / s
		sum += axis * (angle / dt) * dt
		total_dt += dt
	if total_dt < 0.0001:
		return Vector3.ZERO
	return sum / total_dt


# ============================================================
# Fix Pass 14: sub-step release evaluation.
#
# The disease (measured on Chris's throws-12, see
# analysis/quantization-2026-11-03.py): the release decision lands
# on the sampling grid, but the hand's direction sweeps ~430 deg/s
# on average - and ~800 deg/s locally - through the release zone,
# so one grid step of timing slop moves the computed launch
# elevation by a median 13.4 degrees. The fit itself is faithful;
# the READ INSTANT is what the grid corrupts.
#
# The cure is measurement, not assistance: find the true instant
# t* at which the grip analog crossed the let-go threshold
# (interpolated between the bracketing grip readings) and evaluate
# the SAME windowed quadratic fit at t* - velocity, angular
# velocity and position all read at t* from the same fitted
# motion. Nothing about the fit, the flight or the physics
# changes; 1:1 and no-assist remain absolute.
# ============================================================

## The interpolated instant at which a falling grip value crossed
## the let-go threshold, given the bracketing readings (t_prev,
## g_prev) -> (t_now, g_now). Degenerate brackets (no crossing,
## no time between readings) return t_now - the grid answer - so
## a caller can always use the result.
static func release_crossing_time(t_prev: float, g_prev: float, t_now: float, g_now: float, threshold: float) -> float:
	if t_now <= t_prev or g_prev <= threshold or g_now > threshold:
		return t_now
	var drop: float = g_prev - g_now
	if drop < 0.000001:
		return t_now
	var frac: float = clampf((g_prev - threshold) / drop, 0.0, 1.0)
	return t_prev + frac * (t_now - t_prev)


## The window for an arbitrary-instant read: peak-anchored exactly
## like window_subset, but widened to cover t_eval so the read is
## always an interpolation of the recorded motion, never an
## extrapolation past the buffer's ends.
static func eval_window_subset(samples: Array, t_eval: float, window_sec: float = 0.150) -> Array:
	var out: Array = []
	if samples.size() < 2:
		return out
	var pk: int = peak_speed_index(samples)
	var t_peak: float = float(samples[pk]["t"])
	var t_lo: float = minf(t_peak - window_sec, t_eval)
	var t_hi: float = maxf(t_peak + 0.030, t_eval)
	for raw: Variant in samples:
		var s: Dictionary = raw
		var t: float = float(s["t"])
		if t >= t_lo and t <= t_hi:
			out.append(s)
	if out.size() < 2:
		out = window_subset(samples, window_sec)
	return out


## The two samples bracketing t_eval in the buffer (clamped to the
## ends), as [a, b]; empty when the buffer is empty.
static func _bracketing_pair(samples: Array, t_eval: float) -> Array:
	if samples.is_empty():
		return []
	var prev: Dictionary = samples[0]
	for raw: Variant in samples:
		var s: Dictionary = raw
		var t: float = float(s["t"])
		if t >= t_eval:
			return [prev, s]
		prev = s
	return [prev, prev]


## Release velocity read at an arbitrary instant: the same
## windowed quadratic fit as estimate_velocity_windowed (same
## window family, same peak centring), with the derivative
## evaluated at t_eval instead of at the peak sample.
static func velocity_at_time(samples: Array, t_eval: float, window_sec: float = 0.150) -> Vector3:
	var sub: Array = eval_window_subset(samples, t_eval, window_sec)
	if sub.size() < 2:
		return Vector3.ZERO
	if sub.size() < 3:
		# Degenerate window: slope of the samples bracketing t_eval.
		var pair: Array = _bracketing_pair(samples, t_eval)
		if pair.size() < 2:
			return Vector3.ZERO
		var a: Dictionary = pair[0]
		var b: Dictionary = pair[1]
		var dt: float = float(b["t"]) - float(a["t"])
		if dt < 0.0001:
			return Vector3.ZERO
		var pa: Vector3 = a["pos"]
		var pb: Vector3 = b["pos"]
		return (pb - pa) / dt
	var pk: int = peak_speed_index(samples)
	var t_ref: float = float(samples[pk]["t"])
	var coeffs: Dictionary = _quadratic_fit(sub, t_ref)
	if coeffs.is_empty():
		return Vector3.ZERO
	var cx: Array = coeffs["cx"]
	var cy: Array = coeffs["cy"]
	var cz: Array = coeffs["cz"]
	var u: float = t_eval - t_ref
	return Vector3(
		float(cx[1]) + 2.0 * float(cx[2]) * u,
		float(cy[1]) + 2.0 * float(cy[2]) * u,
		float(cz[1]) + 2.0 * float(cz[2]) * u)


## Hand position read at an arbitrary instant from the same fit.
static func position_at_time(samples: Array, t_eval: float, window_sec: float = 0.150) -> Vector3:
	var sub: Array = eval_window_subset(samples, t_eval, window_sec)
	if sub.is_empty():
		return Vector3.ZERO
	if sub.size() < 3:
		var pair: Array = _bracketing_pair(samples, t_eval)
		if pair.size() < 2:
			var only: Dictionary = sub[0]
			var op: Vector3 = only["pos"]
			return op
		var a: Dictionary = pair[0]
		var b: Dictionary = pair[1]
		var dt: float = float(b["t"]) - float(a["t"])
		var pa: Vector3 = a["pos"]
		var pb: Vector3 = b["pos"]
		if dt < 0.0001:
			return pa
		var f: float = clampf((t_eval - float(a["t"])) / dt, 0.0, 1.0)
		return pa.lerp(pb, f)
	var pk: int = peak_speed_index(samples)
	var t_ref: float = float(samples[pk]["t"])
	var coeffs: Dictionary = _quadratic_fit(sub, t_ref)
	if coeffs.is_empty():
		var last: Dictionary = sub[sub.size() - 1]
		var lp: Vector3 = last["pos"]
		return lp
	var cx: Array = coeffs["cx"]
	var cy: Array = coeffs["cy"]
	var cz: Array = coeffs["cz"]
	var u: float = t_eval - t_ref
	return Vector3(
		float(cx[0]) + float(cx[1]) * u + float(cx[2]) * u * u,
		float(cy[0]) + float(cy[1]) * u + float(cy[2]) * u * u,
		float(cz[0]) + float(cz[1]) * u + float(cz[2]) * u * u)


## Origin-relative release velocity read at an arbitrary instant
## (Fix Pass 2's removal, Fix Pass 14's read point).
static func velocity_origin_relative_at_time(samples: Array, release_basis: Basis, t_eval: float, window_sec: float = 0.150) -> Vector3:
	if samples.is_empty():
		return Vector3.ZERO
	var rel: Array = _origin_relative_samples(samples, release_basis)
	var v_frame: Vector3 = velocity_at_time(rel, t_eval, window_sec)
	return release_basis * v_frame


# ============================================================
# Fix Pass 43 (THROW TEST): the windowed release read and the
# distance-gain compression, player path only.
#
# The windowed read: the AVERAGE of the hand's tracked
# velocity over the trailing window_sec of real recorded
# motion ending at t_eval - by the mean value theorem that
# is exactly (position(t_eval) - position(t_eval - window))
# / window, read off the same fitted motion as every other
# read here, in the same origin-relative frame. A constant-
# velocity hand reads identically to the instantaneous read;
# an accelerating hand reads the velocity it HAD at the
# window's midpoint, trailing the instantaneous read by half
# the window's worth of acceleration. The window clamps to
# the buffer's first sample: only real recorded motion is
# averaged, never an extrapolation before the buffer starts.
# ============================================================

static func average_velocity_origin_relative_at_time(samples: Array, release_basis: Basis, t_eval: float, window_sec: float) -> Vector3:
	if samples.is_empty():
		return Vector3.ZERO
	var rel: Array = _origin_relative_samples(samples, release_basis)
	var first_smp: Dictionary = rel[0]
	var t_lo: float = maxf(t_eval - window_sec, float(first_smp["t"]))
	var span: float = t_eval - t_lo
	if span < 0.004:
		# Degenerate: almost no recorded motion behind the
		# instant - the instantaneous read is all there is.
		return velocity_origin_relative_at_time(samples, release_basis, t_eval)
	var p_hi: Vector3 = position_at_time(rel, t_eval)
	var p_lo: Vector3 = position_at_time(rel, t_lo)
	return release_basis * ((p_hi - p_lo) / span)


## The centre speed for the compression: the launch speed
## that, at elevation elev_rad from release_pos, ballistically
## carries exactly to stake_pos (landing at the stake's own
## height) under SPIN_GRAVITY - the range equation solved for
## v^2: v^2 = g d^2 / (d sin 2e + 2 h cos^2 e), with d the
## horizontal release-to-stake distance and h the release
## height above the stake. Clamped to [6.0, 13.0] m/s.
## Returns -1.0 when the solve is ill-conditioned - a
## point-blank release, a near-flat or near-vertical
## elevation, a non-positive denominator - and the caller
## falls back to the unmodified speed for that throw.
static func centre_speed(elev_rad: float, release_pos: Vector3, stake_pos: Vector3) -> float:
	var d: float = Vector2(stake_pos.x - release_pos.x, stake_pos.z - release_pos.z).length()
	if d < 0.3:
		return -1.0
	if elev_rad < deg_to_rad(3.0) or elev_rad > deg_to_rad(80.0):
		return -1.0
	var h: float = release_pos.y - stake_pos.y
	var ce: float = cos(elev_rad)
	var denom: float = d * sin(2.0 * elev_rad) + 2.0 * h * ce * ce
	if denom <= 0.0001:
		return -1.0
	return clampf(sqrt(SPIN_GRAVITY * d * d / denom), 6.0, 13.0)


## The compression itself: the speed moves toward the centre
## speed by the soften fraction (0.5 = deviations land at
## half strength); the DIRECTION is preserved exactly - the
## result is the input vector rescaled. An ill-conditioned
## centre (centre_speed's -1.0) returns the input untouched.
static func soften_velocity(vel: Vector3, release_pos: Vector3, stake_pos: Vector3, soften: float) -> Vector3:
	var speed: float = vel.length()
	if speed < 0.0001:
		return vel
	var horiz: float = Vector2(vel.x, vel.z).length()
	if horiz < 0.0001:
		return vel
	var centre: float = centre_speed(atan2(vel.y, horiz), release_pos, stake_pos)
	if centre < 0.0:
		return vel
	var eff: float = centre + soften * (speed - centre)
	return vel * (eff / speed)


## Hand orientation at an arbitrary instant: slerp between the
## bracketing samples (clamped to the buffer's ends).
static func orientation_at_time(samples: Array, t_eval: float) -> Quaternion:
	if samples.is_empty():
		return Quaternion.IDENTITY
	var pair: Array = _bracketing_pair(samples, t_eval)
	var a: Dictionary = pair[0]
	var b: Dictionary = pair[1]
	var qa: Quaternion = a["quat"]
	var qb: Quaternion = b["quat"]
	var dt: float = float(b["t"]) - float(a["t"])
	if dt < 0.0001:
		return qa
	var f: float = clampf((t_eval - float(a["t"])) / dt, 0.0, 1.0)
	return qa.slerp(qb, f)


## Angular velocity at an arbitrary instant: the rotation from
## half a local step before t_eval to half a step after it, read
## off the slerped orientation stream - the instantaneous
## counterpart of the windowed average above.
static func angular_velocity_at_time(samples: Array, t_eval: float) -> Vector3:
	if samples.size() < 2:
		return Vector3.ZERO
	var pair: Array = _bracketing_pair(samples, t_eval)
	var a: Dictionary = pair[0]
	var b: Dictionary = pair[1]
	var step: float = float(b["t"]) - float(a["t"])
	if step < 0.0001:
		# t_eval sits past a buffer end: use the nearest real span.
		var first: Dictionary = samples[0]
		var second: Dictionary = samples[1]
		step = float(second["t"]) - float(first["t"])
		if step < 0.0001:
			return Vector3.ZERO
	var t_first: float = float(samples[0]["t"])
	var t_last: float = float(samples[samples.size() - 1]["t"])
	var ta: float = clampf(t_eval - 0.5 * step, t_first, t_last)
	var tb: float = clampf(t_eval + 0.5 * step, t_first, t_last)
	if tb - ta < 0.0001:
		return Vector3.ZERO
	var qa: Quaternion = orientation_at_time(samples, ta)
	var qb: Quaternion = orientation_at_time(samples, tb)
	var dq: Quaternion = qb * qa.inverse()
	if dq.w < 0.0:
		dq = -dq
	var w: float = clampf(dq.w, -1.0, 1.0)
	var angle: float = 2.0 * acos(w)
	if angle < 0.00001:
		return Vector3.ZERO
	var s: float = sqrt(maxf(0.0, 1.0 - w * w))
	var axis: Vector3
	if s < 0.0005:
		axis = Vector3(1.0, 0.0, 0.0)
	else:
		axis = Vector3(dq.x, dq.y, dq.z) / s
	return axis * (angle / (tb - ta))


## The release evaluation the game branches on (Fix Pass 14):
## use_substep reads velocity and angular velocity at the true
## let-go instant t_star; otherwise the legacy grid read (velocity
## at the peak sample, windowed-average spin) - byte-for-byte the
## pre-pass-14 behaviour, kept as the negative control.
static func evaluate_release_at(samples: Array, release_basis: Basis, t_star: float, use_substep: bool) -> Dictionary:
	if use_substep and t_star >= 0.0:
		return {
			"vel": velocity_origin_relative_at_time(samples, release_basis, t_star),
			"ang": angular_velocity_at_time(samples, t_star),
		}
	return {
		"vel": estimate_velocity_origin_relative(samples, release_basis),
		"ang": estimate_angular_velocity_windowed(samples),
	}


# ============================================================
# Fix Pass 21: the grip cycle - named positions around the shoe.
#
# While a shoe is held, the free hand's face button walks the
# grip through NAMED positions, each declaring the total
# it is meant to throw (Smith, "Science at the Stake": the
# grip names the count - a shank hold toward the toe end
# declares 1 1/8 turns, mid-shank 1 1/4, toward the heel
# 1 3/8; the toe/bridge hold is the flip, 1.00). The cycle
# teaches the sport: the label by the shoe always names a
# position, and the spin governor (below) serves the position
# held at release. The three shank stops ride the existing
# shank zone's slide axis (Shoe.zones): slide_frac is the
# position's seat as a fraction of the zone's slide_max -
# toe end -1, middle 0, heel end +1 - and the grip+trigger
# slide stays the fine trim between stops.
#
# Fix Pass 26: the circuit crosses the shoe. Fix Pass 21's
# cycle only ever walked the holding hand's HOME shank (the
# shank on the hand's own side); the OTHER shank - the
# reverse-turn hold, a real grip - was reachable only by a
# cross-reach near-grab. The circuit is now seven stops:
# the toe, the home shank's three, then the FAR shank's
# three (the reverse family - the shoe seats with its
# opening flipped, Shoe.hold_transform mirrors the far
# hold's yaw), and back to the toe. Each position carries
# its side ("home" / "far"); a side resolves to a zone per
# hand (grip_home_zone / grip_far_zone below).
# ============================================================

const GRIP_POSITIONS: Array = [
	{"id": "toe", "name": "TOE GRIP", "label": "TOE GRIP · FLIP",
		"hold": "flip", "nominal": 1.0, "slide_frac": 0.0, "side": "none"},
	{"id": "shank_toe", "name": "SHANK · TOE", "label": "SHANK · TOE · 1⅛ TURN",
		"hold": "turn", "nominal": 1.125, "slide_frac": -1.0, "side": "home"},
	{"id": "shank_mid", "name": "SHANK · MID", "label": "SHANK · MID · 1¼ TURN",
		"hold": "turn", "nominal": 1.25, "slide_frac": 0.0, "side": "home"},
	{"id": "shank_heel", "name": "SHANK · HEEL", "label": "SHANK · HEEL · 1⅜ TURN",
		"hold": "turn", "nominal": 1.375, "slide_frac": 1.0, "side": "home"},
	{"id": "far_toe", "name": "FAR SHANK · TOE", "label": "FAR SHANK · TOE · 1⅛ TURN · REVERSE",
		"hold": "turn", "nominal": 1.125, "slide_frac": -1.0, "side": "far"},
	{"id": "far_mid", "name": "FAR SHANK · MID", "label": "FAR SHANK · MID · 1¼ TURN · REVERSE",
		"hold": "turn", "nominal": 1.25, "slide_frac": 0.0, "side": "far"},
	{"id": "far_heel", "name": "FAR SHANK · HEEL", "label": "FAR SHANK · HEEL · 1⅜ TURN · REVERSE",
		"hold": "turn", "nominal": 1.375, "slide_frac": 1.0, "side": "far"},
]


static func grip_position_count() -> int:
	return GRIP_POSITIONS.size()


static func grip_position(idx: int) -> Dictionary:
	return GRIP_POSITIONS[clampi(idx, 0, GRIP_POSITIONS.size() - 1)]


## Fix Pass 26: the shank zone on the holding hand's own side
## (the home shank) and the one across the shoe (the far
## shank, the reverse hold). Mirrored per hand, as the turn
## hold setups in Shoe.hold_transform are.
static func grip_home_zone(hand: String) -> String:
	return "shank_right" if hand == "R" else "shank_left"


static func grip_far_zone(hand: String) -> String:
	return "shank_left" if hand == "R" else "shank_right"


## The position a hold currently declares, from the zone under
## the hand and the slide offset along the zone's axis
## (Shoe.zones, main's slide_offset): the toe zone always
## declares TOE GRIP; a shank hold declares the stop nearest
## its slide fraction (stops at -1, 0, +1, split at the
## +-0.5 midpoints) in the family its side names - the home
## shank's stops are 1-3, the far shank's 4-6 (Fix Pass 26).
## A grab starts here; the cycle advances from here; a slide
## settle re-derives here.
static func grip_index_for(zone: String, hand: String, slide_offset: float, slide_max: float) -> int:
	if zone == "toe" or slide_max <= 0.0:
		return 0
	var base: int = 1 if zone == grip_home_zone(hand) else 4
	var frac: float = clampf(slide_offset / slide_max, -1.0, 1.0)
	if frac < -0.5:
		return base
	if frac > 0.5:
		return base + 2
	return base + 1


## The slide offset a position declares on a zone with the
## given slide range.
static func grip_slide_offset(idx: int, slide_max: float) -> float:
	var p: Dictionary = grip_position(idx)
	return float(p["slide_frac"]) * slide_max


# ============================================================
# Fix Pass 16: the finger-drag term (spin governor).
#
# The disease (measured on Chris's throws-14): his shoes leave
# with total rotation SD 1.17 rev - scatter wider than a full
# turn, so the arrival phase is a lottery even on an aimed shoe.
# The diagnosis Chris accepted: a real pitch's spin is the
# wrist's spin MINUS a consistent finger-drag brake as the shoe
# slides off the hand. A VR controller has no edge, no slide,
# no drag - the build was missing a physical term, and the shoe
# inherited raw wrist angular velocity, flicks and all.
#
# The cure restores the term, on the STYLE AXIS ONLY (the flip
# axis for toe holds, world Y for shank holds - the same axes
# the flight accounting integrates). It works in TOTAL
# REVOLUTIONS over the predicted flight: the hand's total is
# pulled toward the hold's regulation nominal, keeping a
# residual share of the hand's own deviation, and the result is
# converted back to an angular velocity over the same flight
# time. Direction, speed, timing, release position and
# orientation, and every off-axis spin component stay the
# hand's. This is a missing force restored, not aim assist:
# with the term disabled the release spin is the input,
# untouched.
#
# Fix Pass 17: the flight the revolutions are counted over is
# the flight TO THE STAKE, not to the ground. Roy W. Smith,
# "Science at the Stake" (1946): "The turns given a shoe are
# indicated by the number of revolutions it makes in flight
# from the player's hand to the stake." Chris ruled the count
# follows the book (2026-11-03). The governor's clock is
# therefore the ballistic crossing time of the target stake's
# plane, capped by the ground-return time when the dirt comes
# first (governor_flight_time below). Pass 16 counted to
# ground return; on a 40 ft pitch that clock runs ~6% long,
# which left governed arrivals a few hundredths of a rev
# inside the stake-plane plan the technique audit judges.
# ============================================================

## Share of the hand's deviation from nominal that survives the
## drag. 0 would be a canned spin (the hand's rate erased);
## 1 would be no drag at all. 0.30 keeps the pitcher's own
## variation legible while the brake does its work.
const SPIN_DRAG_RESIDUAL: float = 0.30

## The game's gravity (project.godot does not override
## physics/3d/default_gravity, so the engine default rules).
const SPIN_GRAVITY: float = 9.8

const SPIN_NOMINAL_FLIP: float = 1.00
## Fix Pass 21: for PLAYER throws the governor's nominal no
## longer comes from this nearest-basin snap - it comes from
## the grip position held at release (GRIP_POSITIONS above:
## TOE 1.00, shank stops 1.125 / 1.25 / 1.375), passed in as
## govern_spin's declared_nominal. The basin set survives only
## as the fallback for a caller that declares nothing. The
## 0.75 basin disappears as a target: no grip declares it, and
## Smith called the 3/4 turn a trap (no wobble to break the
## fall, so it rebounds off the stake). A wild hand can still
## ARRIVE near 3/4 through the residual - the governor just
## never aims there.
const SPIN_NOMINAL_TURNS: Array[float] = [0.75, 1.25, 1.75]


## Predicted time of flight: from the release state, the time
## until the shoe returns to ground level (y = 0). Solves
## y0 + vy*t - g/2*t^2 = 0 for the positive root; 0 when the
## state is degenerate (no upward solution).
static func predicted_flight_time(release_pos: Vector3, vel: Vector3, gravity: float = SPIN_GRAVITY) -> float:
	if gravity <= 0.0:
		return 0.0
	var disc: float = vel.y * vel.y + 2.0 * gravity * release_pos.y
	if disc < 0.0:
		return 0.0
	return maxf(0.0, (vel.y + sqrt(disc)) / gravity)


## Predicted time for the thrown shoe to cross the TARGET
## STAKE'S PLANE (the plane through the stake, perpendicular
## to the court's long axis - z = stake_pos.z; the court's axis
## is z everywhere in this build). Purely kinematic in z: the
## time at which release_pos.z + vel.z*t reaches the plane.
## Returns -1 when there is no forward crossing to count: the
## release already sits at/past the plane, or the velocity does
## not carry the shoe toward it.
static func predicted_stake_plane_time(release_pos: Vector3, vel: Vector3, stake_pos: Vector3) -> float:
	var dz: float = stake_pos.z - release_pos.z
	if absf(dz) < 0.001 or absf(vel.z) < 0.001:
		return -1.0
	var t: float = dz / vel.z
	return t if t > 0.0 else -1.0


## The governor's flight clock (Fix Pass 17): the stake-plane
## crossing time, CAPPED by the ground-return time - a
## dirt-bound throw that lands before it ever reaches the plane
## is counted over the flight it actually gets. Falls back to
## the ground-return time whenever no forward crossing exists.
## This is the single flight-time definition the mechanism and
## its bench share, so the bench's standards hold by
## construction on whichever branch a release takes.
static func governor_flight_time(release_pos: Vector3, vel: Vector3, stake_pos: Vector3) -> float:
	var t_ground: float = predicted_flight_time(release_pos, vel)
	var t_stake: float = predicted_stake_plane_time(release_pos, vel, stake_pos)
	if t_stake <= 0.0:
		return t_ground
	return minf(t_stake, t_ground)


## The finger-drag term itself. Takes the FP14 read's angular
## velocity (world axes), the release transform (its basis.x is
## the flip axis; its origin.y anchors the flight prediction),
## the release velocity, the hold ("flip" / "turn") and the
## TARGET STAKE's position - the stake the throw is aimed at,
## whose plane ends the revolution count (Fix Pass 17). Returns
## {"ang", "hand_total", "applied_total", "nominal",
## "flight_time", "governed"}: the angular velocity to apply
## (the input, untouched, when disabled, when the hold is not a
## pitched style, or when no flight can be predicted), and the
## evidence the recorder keeps. Totals are SIGNED revolutions
## about the style axis in the recorder's own convention (flip:
## the release basis.x component; turn: the world Y component),
## counted hand-to-stake per governor_flight_time.
## Fix Pass 21: `declared_nominal` is the unsigned count the
## grip held at release declares (ThrowMath.grip_position);
## when positive it IS the nominal - the governor serves the
## declaration, sign still following the hand. The default
## (<= 0, undeclared) keeps the FP16 behaviour for direct
## callers: flip 1.00, turns snapped to the nearest basin.
static func govern_spin(ang: Vector3, release_tf: Transform3D, vel: Vector3, hold: String, stake_pos: Vector3, enabled: bool, declared_nominal: float = -1.0) -> Dictionary:
	var out: Dictionary = {
		"ang": ang, "hand_total": 0.0, "applied_total": 0.0,
		"nominal": 0.0, "flight_time": 0.0, "governed": false,
	}
	var is_flip: bool = hold == "flip"
	if not is_flip and hold != "turn":
		return out
	var tof: float = governor_flight_time(release_tf.origin, vel, stake_pos)
	out["flight_time"] = tof
	if tof < 0.05:
		return out
	var axis: Vector3 = release_tf.basis.x.normalized() if is_flip else Vector3.UP
	var rate: float = ang.dot(axis)
	var hand_total: float = rate * tof / TAU
	out["hand_total"] = hand_total
	out["applied_total"] = hand_total
	var sgn: float = 1.0 if hand_total >= 0.0 else -1.0
	var nominal: float
	if declared_nominal > 0.0:
		# Fix Pass 21: the grip declares the count.
		nominal = sgn * declared_nominal
	elif is_flip:
		nominal = sgn * SPIN_NOMINAL_FLIP
	else:
		nominal = sgn * SPIN_NOMINAL_TURNS[0]
		for cand: float in SPIN_NOMINAL_TURNS:
			if absf(sgn * cand - hand_total) < absf(nominal - hand_total):
				nominal = sgn * cand
	# The nominal is evidence even when the governor is off:
	# the throw record keeps the declared count either way.
	out["nominal"] = nominal
	if not enabled:
		return out
	var applied_total: float = nominal + (hand_total - nominal) * SPIN_DRAG_RESIDUAL
	out["applied_total"] = applied_total
	var applied_rate: float = applied_total * TAU / tof
	out["ang"] = ang + axis * (applied_rate - rate)
	out["governed"] = true
	return out


## Ringer test, straight-edge approximated: with the shoe settled, the
## stake must sit inside the shoe's inner opening - between the inner
## toe edge and the heel tips, within the inner width (minus stake
## radius) - and the shoe must lie roughly flat.
static func is_ringer(shoe_tf: Transform3D, stake_pos: Vector3, inner_half_width: float, z_min: float, z_max: float) -> bool:
	if shoe_tf.basis.y.y < 0.60:
		return false
	var local: Vector3 = shoe_tf.affine_inverse() * stake_pos
	if absf(local.y) > 0.07:
		return false
	return absf(local.x) <= inner_half_width and local.z >= z_min and local.z <= z_max


## Distance in inches from the stake axis to the nearest point of the
## shoe's footprint rectangle (0 when the stake is over the shoe).
static func nearest_distance_inches(shoe_tf: Transform3D, stake_pos: Vector3, half_w: float, half_l: float) -> float:
	var local: Vector3 = shoe_tf.affine_inverse() * stake_pos
	var cx: float = clampf(local.x, -half_w, half_w)
	var cz: float = clampf(local.z, -half_l, half_l)
	var d: float = Vector2(local.x - cx, local.z - cz).length()
	return d * METERS_TO_INCHES
