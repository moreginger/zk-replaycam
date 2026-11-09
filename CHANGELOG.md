# Changelog

## [?]

- Rework event selection to use more player input (command events, cursor position)
- Less battle centric - show slightly more build and overview events
- Less janky instant camera transitions
- Show attacker information for unitDamaged event
- Stats logging (`STATS`) and `scripts/generate-stats.py` metrics for comparing camera runs
- Time-to-frame, unframed-cut and yaw-rate camera metrics
- New camera model: a drone orbiting the event on damped springs, so pans settle in ~1-2s whatever the distance, arc up over long moves, and the event can no longer be zoomed out of frame
- Shot lock: a new shot holds until it frames its event and for 2s after, unless something much bigger happens, and its screen time starts once framed
- Switching cost is measured from where the camera is looking: events already on screen are cheap to switch to, ones needing a cut cost the most
- Orbits: once framed, the camera may slowly fly around the event to see past terrain, keep the map in view or take in nearby action, and drifts once on long holds
- Overview shown mostly in lulls rather than during fights, and less in the opening
- Fix camera crash when the event about to be shown lost its units
- Fewer quick cuts: the shown event keeps absorbing similar nearby events, and distant cuts need a bigger event

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
