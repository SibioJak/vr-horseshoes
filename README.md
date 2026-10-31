# VR Horseshoes — Toss Test

DE feel-test for VR Horseshoes (Godot 4.7, OpenXR, PCVR via editor).
One pit, one stake at 40 ft, twenty shoes. The project lives or dies
on the toss; nothing else is in this build. Design skeleton:
`design-skeleton.md`.

## Run it

Pull the repo, open in Godot 4.7, press F5 (Quest 3 via Virtual
Desktop/VDXR, same as the Duel). Stand or sit behind the white foul
line. The board at your left lists every control.

- **Grab:** reach to the shoe on the stand — the part under your hand
  glints (toe = FLIP hold, either side/shank = TURN hold) with a
  haptic tick; squeeze the grip to latch. Squeeze-then-reach works
  too; the latch is a level, not an edge.
- **Slide:** while holding, loosen the grip halfway and stay still —
  the shoe stays in the world and your hand slides along it. Squeeze
  full to lock the new grip point.
- **Throw:** swing underhand and open your hand. Release velocity and
  spin come from a windowed fit over the last ~150 ms of hand motion
  and your real wrist angular velocity. 1:1 — no assist, no scaling.
- **Drop:** open your hand while still. The shoe returns to the stand
  by itself after every throw or drop.
- **Recenter:** system menu / long-press (platform standard).

Toss 20 — 10 flip, 10 turn — and judge: does it go where you thought
you threw it, does each hold feel like itself, does your grouping
tighten as you adjust?

## Throws file

Every grab and throw is logged as JSONL to:

```
%APPDATA%\Godot\app_userdata\VR Horseshoes - Toss Test\throws.jsonl
```

Send that file back after a session — it carries the release window
samples, velocities, rotation totals (flip vs turn), first contact,
settle position, landing distance in inches, and ringer flags.

## Tests (headless, this machine)

```
~/workspace/tools/godot/Godot_v4.7-stable_linux.x86_64 --headless --path . --script tests/run_tests.gd
~/workspace/tools/godot/Godot_v4.7-stable_linux.x86_64 --headless --path . --script tests/smoke_main.gd
xvfb-run -a -s "-screen 0 1280x800x24" ~/workspace/tools/godot/Godot_v4.7-stable_linux.x86_64 --path . --script tests/render_proofs.gd
```

Rendered proofs land in `proofs/` (court_view.png, held_shoe.png).
Suites verify math and wiring — feel is judged in the headset only.
