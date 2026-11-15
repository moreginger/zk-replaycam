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
- Lull events replace the overview: when a fight dies down, a wide north-up shot frames the spread of activity, more likely after bigger fights. The game opens on a wide lull shot of the map.
- Orbits: once framed, the camera may slowly fly around the event to see past terrain, keep the map in view or take in nearby action, and drifts once on long holds
- Fix camera crash when the event about to be shown lost its units
- Fewer quick cuts: the shown event keeps absorbing similar nearby events, and distant cuts need a bigger event
- Scene events replace hotspots: a scene is a place where one side's metal is coming within reach of the other's armed units, now or up to ~9s ahead on their current heading (orders are ignored). Clashes, raids and bombing runs score the same way, by how much the metal at stake has risen. A scene on show holds the camera only while its stake keeps growing
- `setup` and scene metrics in `scripts/generate-stats.py`: was the camera, or a scene event, on a fight's opening spot before it started
- `scripts/run-replay.sh` plays replays unattended with the headless engine, and `scripts/run-harness.py` runs the widget against a stubbed game
- Stats ignore deaths with no damage nearby (commander upgrades, reclaim), which the camera could never have shown
- Units that exist when the widget starts are picked up straight away
- Static units get their 1.5x boost only when damaged, destroyed or captured, not when built, so a lone mex build is less likely to steal the shot

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
