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
const SHORT_LINE_DISTANCE_M: float = 9.144 # 30 ft from the stake
const STANDARD_LINE_DISTANCE_M: float = 12.192 # 40 ft from the stake


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
## horizontal distance to the stake: nearer the 30 ft (9.144 m) line
## distance classifies as 30, nearer the 40 ft (12.192 m) distance as
## 40. Height is ignored - a release is high by definition, and its
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
