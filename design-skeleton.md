# VR Horseshoes — Design Skeleton v0.1

*Status: PENCILED, not inked (Chris, 2026-10-31). No build without Chris's explicit go.*
*One page, as designed in the VR Horseshoes chat on 2026-10-31. Locked items are Chris's decisions; open items are marked OPEN.*

## The game in one line

A simple, dedicated VR horseshoes game. One court, one verb — pitch the shoe — and the whole budget buys throw feel and the clank. The slot is empty: the nearest existing thing (H3VR) treats horseshoes as a gag toy with no pit, stakes, scoring, or match; cornhole and bocce already proved the dedicated backyard-throw game on Quest.

## The hinge

Everything lives or dies on the toss. Transfer from the (parked) VR Baseball Duel: windowed release sampling (hand velocity read over a window near release, never a single frame), the JSONL throw recorder/analyzer repointed at flip rate and landing spread, and real wrist angular velocity feeding an honestly tumbling rigid body — never a canned animation. What does NOT transfer: head-line aim, grip enrollment, velocity gears, boost. A real arm throws a real shoe 40 ft unaided, so the physics is true 1:1.

## Locked basics

- **Court, regulation:** stakes 40 ft apart, 1 in steel, 14–15 in above the pit, leaning ~3 in toward each other; pit ~31 × 43 in minimum; shoe ~2½ lb (max 2 lb 10 oz). Pitch from both ends in singles; seated or standing both work — it's a pendulum throw, not a windup.
- **Scoring, real:** ringer 3; closest shoe within 6 in, 1 (2 if both your shoes beat their best); cancellation scoring — only one pitcher scores per inning; rulings shown in-world as they happen (ringer, leaner, dead shoe), never hidden.
- **Match lengths, both:** quick games to 21 with cancellation scoring; season games are 40-shoe games.
- **Formats, both:** singles AND doubles. In doubles, partners stand at opposite pits — you stay at your end, your partner throws back. Doubles is where multiplayer shines.
- **Opponents:** AI opponents AND online multiplayer. Alternating turns is naturally turn-based, so multiplayer needs no simultaneity tricks.
- **No HUD.** Score and standings live in-world, on a physical board at the court.
- **No levels, no progression.** Your ringer percentage is your identity — it moves because you got better, not because you unlocked anything.
- **Shoes cosmetic only:** different designs in color and texture; no shoe ever throws better than another, so the leaderboard stays honest.

## Locations change the landing (not just the look)

- **Backyard — clay:** the live surface (and the real NHPA pit). Shoes slide after landing, leaners happen, a sliding shoe can knock an opponent's shoe out — or yours in.
- **Campground — packed dirt:** the middle game. Thud, one small bounce, a little skid.
- **Beach — sand:** the shoe digs and plows to a stop. Almost no bounce, no slide — what you throw is what you get.
- **Park — league courts:** rows of pits, other games around you; the natural home of doubles and season play. (Surface: OPEN — park pits vary in the real world too.)

Each surface changes the shot-making: on sand you fly it all the way to the stake; on clay you can land short and let it travel.

## Two pitching styles — where you grab the shoe sets your style

- **Flip (grab the toe/bridge):** the shoe somersaults end-over-end. The beginner's instinct; works on day one, but can bounce and chatter past the stake.
- **Turn (grab a shank/side):** the shoe stays mostly flat and rotates ~1¼ turns, arriving open-end to the stake and landing dead. The pro standard; harder to discover, harder to time — the mastery ceiling.

No style is chosen in a menu and neither is patched for balance: the physics is the physics. AI pitchers split by style too, so you can read an opponent's game from across the court.

## Getting rated — the Amateur Tour

No 100-shoe sitting (Chris: "your arm might fall off"). A new pitcher plays a **set tour of 5 amateur events**, ~20 shoes each, one per location/format:

1. Backyard (clay) — singles vs a weak flipper.
2. Campground (dirt) — singles vs a slightly better turn pitcher.
3. Beach (sand) — a quick game.
4. Park — first doubles, with an AI partner.
5. Backyard again — same pit as event 1, better opponent; you feel the 100 shoes of difference, then the board posts your rating.

At 100 cumulative shoes the game awards your **ringer % and class**, NHPA-style (real leagues seed classes by ringer percentage and use bowling-style handicaps), and season play opens. Quick games are open from minute one; the tour only gates the season. The tour is the tutorial — it never calls itself one. (Chris has played horseshoes twice in his life — once as a kid, once in Red Dead Redemption, where he quit over the controls. The game must teach by doing; in VR there is no throw "control scheme" to get wrong — you just throw.)

## Season & leaderboard

- A season is a run of 40-shoe matches in a class near your ringer %, against AI pitchers defined by their percentage, style, and dispersion — a 20% pitcher scatters, a 55% pitcher is trouble, an 80% pitcher is a wall. Multiplayer results count the same way.
- Standings = wins + ringer %, posted on the in-world board. That board is the return-play engine; there is no other meta-progression.

## Deliberately not in it

No levels, no unlocks, no characters, no enemies, no aim assist, no boost — nothing between the arm and the shoe.

## Open items

- Park pit surface.
- AI roster: how many pitchers, names/personalities, percentage spread.
- Season shape: number of matches, playoff/championship end, handicap use inside a class.
- Location extras beyond the four (county fair? desert?) — only if a tour/season needs one.
- Sound design pass: the clank is the reward (stake ring, shoe-on-shoe clatter, surface thud) — details OPEN.
- The DE test (not yet scoped, not built): one pit, one stake, recorder on, Chris tosses twenty shoes and judges grouping and flip/turn feel in the headset. Test tallies never substitute for his verdict.
