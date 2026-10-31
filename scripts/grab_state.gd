class_name GrabState
extends RefCounted

## The grab latch as a pure state machine, fed once per render frame by
## main with (candidate/latched hand, zone under that hand, analog grip
## float, hand speed). Thresholds are ours, with hysteresis - never a
## bool squeeze read (the runtime's own threshold is undocumented).
##
## Both natural grab orders work by construction: the latch condition
## is a LEVEL (grip high AND zone present), not an edge, so squeezing
## first and then reaching the zone latches the frame the hand arrives,
## and reaching first then squeezing latches on the squeeze.
##
## Grip bands while latched:
##   >= GRIP_ON            locked hold, shoe follows the hand
##   GRIP_OFF..GRIP_ON     slide band - but only while the hand is
##                         nearly still (adjusting, not mid-swing)
##   <= GRIP_OFF           release

const GRIP_ON: float = 0.72
const GRIP_OFF: float = 0.30
const SLIDE_MAX_HAND_SPEED: float = 0.6

var latched: bool = false
var hand: String = ""
var zone: String = ""
var sliding: bool = false


## Returns an event: "", "latch", "release", "slide_start", "slide_end".
func update(p_hand: String, p_zone: String, grip: float, hand_speed: float) -> String:
	if not latched:
		if grip >= GRIP_ON and p_zone != "":
			latched = true
			hand = p_hand
			zone = p_zone
			sliding = false
			return "latch"
		return ""
	if grip <= GRIP_OFF:
		latched = false
		hand = ""
		zone = ""
		sliding = false
		return "release"
	var want_slide: bool = grip < GRIP_ON and hand_speed < SLIDE_MAX_HAND_SPEED
	if want_slide and not sliding:
		sliding = true
		return "slide_start"
	if not want_slide and sliding:
		sliding = false
		return "slide_end"
	return ""


func reset() -> void:
	latched = false
	hand = ""
	zone = ""
	sliding = false
