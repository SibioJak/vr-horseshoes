class_name GrabState
extends RefCounted

## The grab latch as a pure state machine, fed once per render frame
## by main with (candidate/latched hand, zone under that hand, analog
## grip float, hand speed, analog trigger float). Thresholds are
## ours, with hysteresis - never a bool squeeze read (the runtime's
## own threshold is undocumented).
##
## Both natural grab orders work by construction: the latch condition
## is a LEVEL (grip high AND zone present), not an edge, so squeezing
## first and then reaching the zone latches the frame the hand
## arrives, and reaching first then squeezing latches on the squeeze.
##
## SLIDE is Chris's own model, specified from the headset in Fix
## Pass 2 after the pass-1 mid-grip-band entry proved undiscoverable
## in practice ("I'm picking it up with grip. If I want to change
## the position, I also press trigger and this allows hand to slide
## back and forth"):
##   - Enter: ONLY while latched with the grip fully held, on a
##     FRESH trigger press (rising edge past TRIG_ON). A trigger
##     already held when the grab latches is consumed by the latch -
##     it cannot start a slide until it has been let go and pressed
##     again. Trigger-first-then-grip is a grab, never a slide.
##   - In slide mode the hand's travel along the held zone's
##     axis adjusts the grip offset - but only while the hand
##     is nearly still: at swing speed the anchor cannot shift,
##     so a trigger squeezed mid-swing can never move the grip
##     under a throw. (Fix Pass 22: main's mechanism is the
##     CARRIED slide - the shoe rides the hand and the offset
##     accumulates, clamped to the zone's extent. The original
##     world-freeze let the hand walk away from the parked
##     shoe entirely; this class owns only mode and gate.)
##   - Exit: trigger released below TRIG_OFF while the grip stays
##     held - the hold re-locks at the new anchor (slide_end).
##   - Releasing the GRIP is always the throw/drop path, in or out
##     of slide mode, and cancels any slide in progress.
## The pass-1 mid-band loosening entry is REMOVED - there is no
## second, hidden way into slide mode.

const GRIP_ON: float = 0.72
const GRIP_OFF: float = 0.30
const TRIG_ON: float = 0.6
const TRIG_OFF: float = 0.3
const SLIDE_MAX_HAND_SPEED: float = 0.6

var latched: bool = false
var hand: String = ""
var zone: String = ""
var slide_mode: bool = false # trigger held: slide mode is engaged
var sliding: bool = false # slide mode AND hand slow: the offset is being adjusted (shoe carried)
var _trig_prev: float = 0.0


## Returns an event: "", "latch", "release", "slide_start", "slide_end".
func update(p_hand: String, p_zone: String, grip: float, hand_speed: float, trigger: float) -> String:
	var trig_edge: bool = _trig_prev < TRIG_ON and trigger >= TRIG_ON
	_trig_prev = trigger
	if not latched:
		if grip >= GRIP_ON and p_zone != "":
			latched = true
			hand = p_hand
			zone = p_zone
			slide_mode = false
			sliding = false
			return "latch"
		return ""
	if grip <= GRIP_OFF:
		latched = false
		hand = ""
		zone = ""
		slide_mode = false
		sliding = false
		return "release"
	var ev: String = ""
	if not slide_mode and trig_edge and grip >= GRIP_ON:
		slide_mode = true
		ev = "slide_start"
	elif slide_mode and trigger <= TRIG_OFF:
		slide_mode = false
		sliding = false
		return "slide_end"
	sliding = slide_mode and hand_speed < SLIDE_MAX_HAND_SPEED
	return ev


func reset() -> void:
	latched = false
	hand = ""
	zone = ""
	slide_mode = false
	sliding = false
	_trig_prev = 0.0
