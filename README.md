# VR Horseshoes — Backyard Game v1

The toss test grew into a game (Godot 4.7, OpenXR, PCVR via editor).
A one-pit backyard court — the real backyard form: one timber sand
pit, true foul lines at the pitching end, a pair of shoes each for
you and the AI opponent, and a real game of horseshoes: NHPA
cancellation scoring, first to 21. The toss itself is unchanged
from the judged test — 1:1 release, no assist. Design skeleton:
`design-skeleton.md`.

## The game

- **Practice** is the old toss test: free throwing at the one pit,
  from the 37 ft line (40 ft class) or the 27 ft learning line
  (30 ft class), with the per-throw readouts (landing inches,
  flip/turn revolutions) on the board. Your pair of yellow shoes
  hangs on the station at the 37 ft line, or on the slim peg post
  at the 27 ft line — the shoe waits where you are.
- **Press A** (either hand) to start a game. You throw first.
- An **inning**: at the pitching end, you throw both of your shoes,
  then the AI throws both of its blue ones from beside you. All
  four stay where they land.
- **Scoring (cancellation):** a ringer is worth 3; ringers cancel
  in pairs. Then only the side holding the closest shoe(s) inside
  6 inches scores — 1 point per shoe closer than the opponent's
  closest. Only one side scores per inning.
- **The rhythm (Fix Pass 20):** when the last shoe settles, the
  round tabulates itself — no walking anywhere. The round's
  score breakdown (each shoe's result, the cancellation
  arithmetic in plain words, the round's points, the match
  totals) goes up on the **rear scoreboard** behind the pit.
  **A** dismisses it and the next round is stocked, shoes
  gathered back to the pitching end. The side that scored
  throws first (a scoreless inning alternates). While a round
  is live you can't walk past the foul line; while the
  breakdown is up you can stroll down to the pit if you like —
  **A** seats you back behind the line for the next round.
- **The broadcast (Fix Pass 39):** a permanent billboard on the
  left of the lane, halfway down, carries a pit camera and
  nothing else — no text. The camera is a close-up camera: the
  pit fills the panel at rest, it eases to follow each flight
  (stake kept in frame), settles into a close-up of the lie,
  and when a shoe rings — yours or the AI's — it plays that
  throw back in slow motion (0.30×) all by itself. The rear
  board is the scoreboard: match score biggest, then the
  running state and per-throw readouts, and the round-end
  breakdown in their place; the full controls list stands in
  two columns underneath.
- **First to 21** at an inning's end wins (no win-by-two). At game
  over: **A** plays again, **B** returns to practice. In a game,
  **B** returns to practice at any time.
- The **AI opponent** stands in the pitcher's box beside you at
  the pitching end and pitches a flip through the same physics
  as your shoes — no faked outcomes. It's a club player:
  measured over 220 simulated throws at live pacing it rings
  25% and puts 78% of its shoes inside scoring range, worth
  about 1.14 points a side per inning in self-play. It never
  throws while you're in the lane.

## Controls (all of them — also listed on the board in-world)

- **Grab:** reach to a shoe on the rail — the part under your hand
  glints (toe = FLIP hold, either side/shank = TURN hold) with a
  haptic tick; squeeze the grip to latch. One shoe at a time.
- **Slide:** while holding, press the trigger too and slide your
  hand along the shoe; release the trigger to lock the new grip.
- **Throw:** swing underhand and open your hand. Release velocity
  and spin come from a windowed fit over the last ~150 ms of hand
  motion and your real wrist angular velocity.
- **Drop:** open your hand while still.
- **Move:** left stick walks, right stick turns (smoothly) — both
  live at once, so you can curve.
- **A button:** start game / next round / play again.
  **B button:** back to practice (in a game).
- **Recenter:** system menu / long-press (platform standard).

## Throws file

Every throw — yours and the AI's (hand = "AI") — is logged as JSONL
to:

```
%APPDATA%\Godot\app_userdata\VR Horseshoes - Toss Test\throws.jsonl
```

Send that file back after a session — it carries the release window
samples, velocities, rotation totals (flip vs turn), first contact,
settle position, landing distance in inches, and ringer flags.

## Tests (headless, this machine)

```
~/workspace/tools/godot/Godot_v4.7-stable_linux.x86_64 --headless --path . --script tests/run_tests.gd
~/workspace/tools/godot/Godot_v4.7-stable_linux.x86_64 --headless --path . --script tests/substep_bench.gd
~/workspace/tools/godot/Godot_v4.7-stable_linux.x86_64 --headless --path . --script tests/smoke_main.gd
~/workspace/tools/godot/Godot_v4.7-stable_linux.x86_64 --headless --path . --script tests/technique_audit.gd
~/workspace/tools/godot/Godot_v4.7-stable_linux.x86_64 --headless --path . --script tests/ai_measure.gd
xvfb-run -a -s "-screen 0 1280x800x24" ~/workspace/tools/godot/Godot_v4.7-stable_linux.x86_64 --path . --script tests/render_proofs.gd
```

The technique audit (Fix Pass 9) scripts each real pitching
technique — flip, 3/4 / 1-1/4 / 1-3/4 turns, reverse turn —
through the production release and proves it arrives at the
stake with its rotation count and opening intact. It is the
standing guard on the rule that the physics must allow every
technique, whatever it is. The sub-step bench (Fix Pass 14)
proves the release is read at the grip's true let-go instant,
interpolated between polls, not at the nearest tick: synthetic
swings with known crossing instants (grid-placement error
26–31 deg for the legacy peak read, ≤ 0.6 deg for the sub-step
read), a negative control with the path disabled, a continuity
probe over Chris's recorded throws, and the production path
end to end. Throw records carry the evidence per throw:
`release_timing` ("substep" / "grid" / "ai_exact"),
`substep_offset_ms`, and the bracketing grip readings. The smoke suite plays a full game to
21 headlessly (scripted player throws + AI turns, every inning
posting itself on settle and continuing on A — a complete game
with no walking at all, Fix Pass 20's rhythm). `ai_measure.gd` is the AI tuning
harness that produced the line quoted above.

Rendered proofs land in `proofs/` (court_view.png — the one-pit
yard on-axis: line end in front, pit under the board at the far
end; board_closeup.png — the board mid-game;
board_from_foul_line.png, held_shoe.png; board_breakdown.png —
the scoreboard at a round's end with the breakdown up, shot
from the throwing line; proof_billboard_flight.png /
proof_billboard_feed.png / proof_billboard_replay.png — the
billboard's close-up follow mid-flight, the settled-lie
close-up, and a slow-mo replay frame).
Suites verify math and wiring — feel is judged in the headset only.
