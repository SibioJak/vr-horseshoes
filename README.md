# VR Horseshoes — Backyard Game v1

The toss test grew into a game (Godot 4.7, OpenXR, PCVR via editor).
A full two-pit backyard court, a pair of shoes each for you and the
AI opponent, and a real game of horseshoes: NHPA cancellation
scoring, first to 21. The toss itself is unchanged from the judged
test — 1:1 release, no assist. Design skeleton: `design-skeleton.md`.

## The game

- **Practice** is the old toss test: free throwing at either pit,
  from the 40 ft line or the 30 ft learning line, with the
  per-throw readouts (landing inches, flip/turn revolutions) on the
  board. Your pair of yellow shoes hangs on the rail stand at
  whichever end you're standing at.
- **Press A** (either hand) to start a game. You throw first.
- An **inning**: at one end, you throw both of your shoes, then the
  AI throws both of its blue ones. All four stay where they land.
- **Scoring (cancellation):** a ringer is worth 3; ringers cancel
  in pairs. Then only the side holding the closest shoe(s) inside
  6 inches scores — 1 point per shoe closer than the opponent's
  closest. Only one side scores per inning.
- **Between innings** the shoes are gathered, play reverses to the
  other pit, and the side that scored throws first (a scoreless
  inning alternates). Swap ends with **B**, or just walk there —
  arriving counts too.
- **First to 21** at an inning's end wins (no win-by-two). At game
  over: **A** plays again, **B** returns to practice.
- The **AI opponent** stands in the pitcher's box beside the
  throwing end and pitches a flip through the same physics as your
  shoes — no faked outcomes. It's a club player: measured over 220
  simulated throws it rings ~27% and puts ~74% of its shoes inside
  scoring range, worth about 1.6 points a side per inning in
  self-play. It never throws while you're in the lane.

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
- **A button:** start game / play again. **B button:** swap ends
  when prompted / back to practice at game over.
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
21 headlessly (scripted player throws + AI turns, end swaps by
button and by walking). `ai_measure.gd` is the AI tuning harness
that produced the line quoted above.

Rendered proofs land in `proofs/` (court_view.png — the full
court, both pits; board_closeup.png — the board mid-game;
board_from_foul_line.png, held_shoe.png).
Suites verify math and wiring — feel is judged in the headset only.
