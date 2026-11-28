# Intents

What the camera is for, and the targets it is held to. Changes are judged against these; the
numbers are where the code stands now (see `replaycam.lua`), not fixed rules.

## Show what a viewer would want to see

- The intent is to make watching a Zero-K battle feel cinematic, highlighting interesting and exciting moments.
- The camera movement mirrors that of a drone watching the action, but it permits jumps over larger distances to avoid large, rapid pans.
- Not only the biggest fight: use what players do (orders, cursors, units sent far, armed units
  closing on the enemy) and show setup/build when significant.
- Catch trouble before it starts, taking into account weapon range. Frame the threat as well as what it
  threatens.
- News breaks through: losing a commander or a costly unit, a capture, a big build.
- Fair share: over minutes, each area gets screen time in proportion to what is lost, taken or
  built there. An area owed time (summed over its neighbours, so a split front counts as one) scores
  higher; one over-watched scores lower. Quiet places lie dormant for 5 minutes, keeping what they
  are owed, so a fight returning there picks it up again.
- Between start and finish, a build is worth more the nearer it is to done: starting is news, finishing is a payoff, and the middle is waiting.

## Be decisive

- Few cuts, no ping-pong. A new shot holds until it frames its action and for 2s after.
- Switching costs more the further the camera has to go: something already on screen is cheap,
  a cut is dear.
- Don't leave a raid just before it strikes.
- When a fight dies down, give the overview (a wide lull shot) rather than chase small events.

## Move smoothly

- Pans settle in about 1-2s whatever the distance, arcing up over long moves.
- The action is never zoomed out of frame.
- Orbit slowly to see past terrain or take in nearby action, rather than jump.

## Frame tightly and efficiently

- Look at where the units are: the heavier group when they split, not the ground between.
- Lead moving units, with room ahead of them.
- Don't sit over wrecks: a dead unit counts for 2s.
- Near the map's edge, show more map: look off centre.

## Zoom with purpose

- Close shots: zoom in decisively (up to 1.6x) on a tight focus with nothing hotter near it.
- Close is earned by importance: how close matches how much is going on there against the typical
  shot (none below 0.6x, all at 1.5x). A close-up is punctuation; routine shots stay wide.
- Every zoom has a reason: a new shot, or something changing. Wide then close is one move, not
  two seconds apart on the same scene.
- Be close before the moment (units about to fire), and stay for its payoff.
- Zoom out to show something coming or keep units in frame, not to drift. Don't vacillate.

## Callouts: accurate, stable, out of the way

- Say what is happening at the focus on show, from its own tallies: a fight ("A vs B"), building,
  something built, a move, a highlight. Show the stats that go with what is said: build info
  for a build, battle stats for a fight.
- Keep the same wording for the same story: a build is "X making Y" from when it starts to when
  it is built, so the viewer can follow it.
- Hold for 3s before changing topic or naming other units; a fight's sides and a highlight change
  it at once.
- Name the right thing: the costliest recent build, fading with age, never a stale one.
  Never say something is being made once it is finished: say it was built.
- Name players and teams correctly, in their colours; sides in a fixed order (as they started on
  the map).
- Don't cover the action: sit where the fewest units are, off the game's windows, with pointers
  clear of units (more so when zoomed). The ring stays tight round the action and on screen.

## Change by evidence

- Every change that alters what is shown is measured on saved replays against a baseline
  (`scripts/run-replays.sh`); overlay-only changes need only the harness
  (`scripts/run-harness.py`).
- Metrics: deaths seen and framing, how early the camera arrives, ping-pong and short shots, the
  ring off screen, close-shot share and deaths seen while close (see the README).
- Judge the feel on headed recordings, stacked in step by game time for side-by-side comparison
  (`scripts/stack-videos.py`).
- Prefer one general rule over special cases.
