class_name ThrowRecorder
extends RefCounted

## Appends one JSON object per line to the throws file (user://throws.jsonl
## in production -> %APPDATA%\Godot\app_userdata\VR Horseshoes - Toss Test\
## throws.jsonl on Chris's PC). Same pattern as the Duel's recorder:
## every throw and every grab event is a record with a "type" field.

var path: String


func _init(p: String = "user://throws.jsonl") -> void:
	path = p


func log_record(rec: Dictionary) -> bool:
	var f: FileAccess = null
	if FileAccess.file_exists(path):
		f = FileAccess.open(path, FileAccess.READ_WRITE)
	else:
		f = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.seek_end()
	f.store_line(JSON.stringify(rec))
	f.close()
	return true


static func vec3_arr(v: Vector3) -> Array:
	return [v.x, v.y, v.z]


static func quat_arr(q: Quaternion) -> Array:
	return [q.x, q.y, q.z, q.w]


## Serialize a sample buffer with timestamps made relative to the
## first sample, so records stay readable.
static func sample_arr(samples: Array) -> Array:
	var out: Array = []
	if samples.is_empty():
		return out
	var t0: float = float(samples[0]["t"])
	for raw: Variant in samples:
		var s: Dictionary = raw
		var p: Vector3 = s["pos"]
		var q: Quaternion = s["quat"]
		var o: Vector3 = s.get("opos", Vector3.ZERO)
		out.append({
			"t": float(s["t"]) - t0,
			"p": vec3_arr(p),
			"q": quat_arr(q),
			"o": vec3_arr(o),
		})
	return out
