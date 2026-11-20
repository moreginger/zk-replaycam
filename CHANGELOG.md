# Changelog

## [?]

- Rework event selection to use more player input (command events, cursor position)
- Less battle centric - show slightly more build events
- Less janky instant camera transitions
- Show attacker information for unitDamaged event
- Stats logging (`STATS`) and `scripts/generate-stats.py` metrics for comparing camera runs
- Time-to-frame, unframed-cut and yaw-rate camera metrics
- New camera model: a drone orbiting the event on damped springs, so pans settle in ~1-2s whatever the distance, arc up over long moves, and the event can no longer be zoomed out of frame
- Shot lock: a new shot holds until it frames its event and for 2s after, unless something much bigger happens, and its screen time starts once framed. A weak pick is held as firmly as a fair one, so it is not replaced a second later
- Switching cost is measured from where the camera is looking: events already on screen are cheap to switch to, ones needing a cut cost the most
- Lull events replace the overview: when a fight dies down, a wide north-up shot frames the spread of activity, more likely after bigger fights. The game opens on a wide lull shot of the map. The first shot after a wide one closes in on its subject rather than keeping the wide frame
- Orbits: once framed, the camera may slowly fly around the event to see past terrain, keep the map in view or take in nearby action, and drifts once on long holds
- Fix camera crash when the event about to be shown lost its units
- Fewer quick cuts: the shown event keeps absorbing similar nearby events, and distant cuts need a bigger event
- Scene events replace hotspots: a scene is a place where one side's metal is coming within reach of the other's armed units, now or up to ~9s ahead on their current heading (orders are ignored). Clashes, raids and bombing runs score the same way, by how much the metal at stake has risen. A scene on show holds the camera only while its stake keeps growing. A scene under way ignores small moves of where the stake is rising, so its ring and framing stay put
- `setup` and scene metrics in `scripts/generate-stats.py`: was the camera, or a scene event, on a fight's opening spot before it started
- `scripts/run-replay.sh` plays replays unattended with the headless engine, and `scripts/run-harness.py` runs the widget against a stubbed game
- `scripts/run-replays.sh` plays every saved replay and compares the results with an earlier run
- EMP stuns are scored: a hit that stuns reports almost no damage, so each stun now counts once as the whole unit, at the half weight EMP already had. The stats ground truth counts them the same way
- A big scene rising close to the shot is taken into frame for a few seconds, without cutting to it
- Overlay replaces the commentary box. A callout points at the shot, with players and sides in their colours, the metal at stake in a scene or the progress and cost of a build, and what each side has destroyed in the fight there, with a bar split the same way. On the ground, a scene gets a ring and a tracked move or attack order gets an arrow to its target, with a move's time to arrive counting down. The callout sits on whichever side of the subject covers the fewest units on screen, further out if the fight is all around it, keeping off the game's own windows, and wide lull shots carry none. Damage with no attacker to point at no longer reads "unknown of unknown": with no one to blame, a burning unit is said to be burning
- Stats ignore deaths with no damage nearby (commander upgrades, reclaim), which the camera could never have shown
- Units that exist when the widget starts are picked up straight away
- Static units get their 1.5x boost only when damaged, destroyed or captured, not when built, so a lone mex build is less likely to steal the shot
- Foci replace events and the interest grid. Damage, deaths, captures, building, units sent far and rising scene stakes each add their metal to the nearest focus, which keeps it by kind and side in 16 one-second bins. The camera shows the focus whose recent heat, less passe for how long the camera has been near it, beats the one on show by the switching margin. A focus follows its action, merges with foci it runs into, and frames its recently involved units. Losing a commander or a costly unit, a capture or a big build is a highlight: it lifts its focus's score past passe for a few seconds and the callout leads with it, pointing at it
- The callout belongs to the focus: it says whether there is a fight (and between whom), one side under fire, trouble incoming, building, something built or a move, from the focus's own tallies, changing only once something new has held for 3s. The killed bar counts what each side has killed at the focus. The ring goes round the focus and follows it
- Wide lull shots frame the hottest foci, and orbits judge headings by units and focus heat in view
- Callouts name the player in on what is happening at the focus, in their colour, or when several are, their team with how many ("Team SnuggleBass (2)"). Teams go by Zero-K's full team name where it fits ("Team SnuggleBass", not "SnuggleBass", which reads as one player), here and on the wide shot's board, in the colour of the player they are named after. After a player's name the short name is enough ("muffa (SnuggleBass)"), and none at all in a team of one
- A built callout names the costliest thing finished there lately, not the latest, and says how many were built there and for how much metal
- The ring is in the colour of whoever the callout is about first: the side under fire, or with trouble incoming. A fight's ring and callout are grey
- The pointer to a single unit stops just outside the selection shape Zero-K draws for it (a square for buildings), so it no longer runs into a factory
- The callout is placed off where its subject will be once the camera arrives, so it no longer trails a pan and overshoots, and it waits while the camera is still bringing its subject on screen. It moves off its ring as soon as it is on the line, not only once well inside
- Headed runs (`scripts/run-replay-headed.sh`) record the window as video to `~/Downloads/replaycam/`
- Merged foci keep the costliest unit built in either, and the camera's lead ignores the velocity of units it has stopped tracking. Unused helpers and a near-zero position extrapolation are gone
- Pointers stop just outside the selection shape at the size Zero-K draws it (they stopped inside it)
- A move callout points at the unit its arrow starts from, not the middle of a spread-out squad
- A morphed unit or upgraded commander counts half its cost, and the callout says "upgraded" or "morphed"
- Combat is always a fight, headed "A vs B" with anyone who lost or dealt much there: no more flipping between "under fire from" and a fight. A fight replaces trouble incoming at once
- A stake's focus also takes in the other side's armed units on their way, so the camera frames the trouble as well as what it threatens

## [0.2.1] - 2023-04-02

- Fix broken event selection caused by a unit being too far outside the map

## [0.2.0] - 2023-04-02

- Smoother camera rotation and zoom
- Improved tracking of hotspot event
- Improved event prioritization (interest grid now includes all events)
- UI options
  - Disable tracking (bindable)
  - Disable user override, useful for recording
  - Experimental/debug option to show tracking reticle

## [0.1.0] - 2023-03-22

- Initial release
