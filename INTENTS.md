# Intents

## The goal

An exciting replay lets the viewer follow the battle as a story and feel its turning points. They
see the moments that decide the game, they see them coming, they always know what they are looking
at and whose side is whose, and the camera never gets in the way.

Everything below serves that. Each principle says what matters; the notes under it ("Currently")
record how the camera does it today, with the numbers from `replaycam.lua`, and "Not yet" marks
where it falls short. The notes are means, not ends: replace them when a better way serves the
principle, and judge every change by whether the replay is better to watch.

## Show what matters

The story is in what is won and lost. Find the moments that change the game, and give each part of
the battle the attention its stakes deserve, not only the loudest fight.

Currently:

- Count what players do as well as what happens: orders, cursors, units sent far, armed units
  closing on the enemy. Show setup and building when significant.
- News breaks through: losing a commander or a costly unit, a capture, a big build.
- Fair share: over minutes, each area gets screen time in proportion to what is lost, taken or
  built there. An area owed time (summed over its neighbours, so a split front counts as one)
  scores higher; one over-watched scores lower. Quiet places lie dormant for 5 minutes, keeping
  what they are owed, so a fight returning there picks it up again.
- Between start and finish, a build is worth more the nearer it is to done: starting is news,
  finishing is a payoff, and the middle is waiting.

## See it coming, stay for the payoff

Excitement is anticipation, then release. Be there as trouble builds, so the viewer sees what is
about to happen, and stay long enough to see how it ends and what it changes: the base left open,
the push that follows.

Currently:

- Catch trouble before it starts, taking weapon range into account. Frame the threat as well as
  what it threatens.
- Don't leave a raid just before it strikes.
- Be close before the moment (units about to fire), and stay for its payoff.

Not yet:

- What a turning point leads to. A shot holds 2s past its framing and a wreck counts for 2s, but
  the camera does not look for what the loss exposes.

## Keep the viewer oriented

The viewer can't feel what they can't follow. Frame the action clearly, so it is always obvious
what to look at and where it is. Establish before detail: arriving somewhere new, show where it is
before closing in. Keep the geography steady: each side stays on its own side of the screen, so a
cut or an orbit never flips who is attacking whom.

Currently:

- Look at where the units are: the heavier group when they split, not the ground between.
- Lead moving units, with room ahead of them.
- The action is never zoomed out of frame.
- Don't sit over wrecks: a dead unit counts for 2s.
- Near the map's edge, show more map: look off centre.
- Long moves arc up, showing the map on the way; wide then close is one move (see Pace it).
- Orbits prefer facing north, so the map mostly keeps one orientation.

Not yet:

- Which side of the screen each team is on: headings are chosen by the view and by north, not by
  where the sides are.
- An establishing view after a cut, which lands straight on the shot.

## Pace it

Cuts and close-ups have force only when rationed. Hold a shot long enough to take it in, let quiet
moments be quiet, and save the close-up for what earns it.

Currently:

- Few cuts, no ping-pong. A new shot holds until it frames its action and for 2s after.
- Switching costs more the further the camera has to go: something already on screen is cheap, a
  cut is dear.
- When a fight dies down, give the overview (a wide lull shot) rather than chase small events.
- Close is earned by importance: how close matches how much is going on there against the typical
  shot (none at typical, the full 1.6x at twice), on a tight focus with nothing hotter near it.
  Zoom in decisively. A close-up is punctuation; routine shots stay wide.
- Every zoom has a reason: a new shot, or something changing. Wide then close is one move, not two
  seconds apart on the same scene. Zoom out to show something coming or keep units in frame, not
  to drift. Once committed, don't vacillate.

## Build to the climax

A game has a shape: the opening spreads out, skirmishes test, and a decisive push settles it. Let
the camera follow that shape, calmer and wider while the game is open, tighter and more intense as
it comes to a head, and end on the resolution.

Not yet:

- The camera behaves the same throughout the game, and does nothing special at its end.

## Keep the camera invisible

The viewer should notice the battle, not the camera. It moves like a drone following the action:
smooth and unhurried, but jumping over long distances rather than making large, rapid pans.

Currently:

- Pans settle in about 1-2s whatever the distance, arcing up over long moves.
- Orbit slowly to see past terrain or take in nearby action, rather than jump.

## Commentate briefly and truly

Like a good commentator, the callouts tell the viewer what they are seeing and who is involved,
never get it wrong, and never talk over the action.

Currently:

- Say what is happening at the focus on show, from its own tallies: a fight ("A vs B"), building,
  something built, a move, a highlight. Show the stats that go with what is said: build info for a
  build, battle stats for a fight.
- Keep the same wording for the same story: a build is "X making Y" from when it starts to when it
  is built, so the viewer can follow it.
- Hold for 3s before changing topic or naming other units; a fight's sides and a highlight change
  it at once.
- Name the right thing: the costliest recent build, fading with age, never a stale one. Never say
  something is being made once it is finished: say it was built.
- Name players and teams correctly, in their colours; sides in a fixed order (as they started on
  the map).
- Don't cover the action: sit where the fewest units are, off the game's windows, with pointers
  clear of units (more so when zoomed). The ring stays tight round the action and on screen.

## How changes are judged

Watching is the final judge; the metrics catch what the eye misses and guard against regressions.

- Every change that alters what is shown is measured on saved replays against a baseline
  (`scripts/run-replays.sh`); overlay-only changes need only the harness
  (`scripts/run-harness.py`).
- Metrics: deaths seen and framing, how early the camera arrives, ping-pong and short shots, the
  ring off screen, close-shot share and deaths seen while close (see the README).
- Judge the feel on headed recordings, stacked in step by game time for side-by-side comparison
  (`scripts/stack-videos.py`).
- Prefer one general rule over special cases.
