# zk-replaycam

A widget that implements a spectator camera for [Zero-K](https://zero-k.info/)

Example video:

https://youtu.be/As0ma57rgAQ

## Overview

Is "Spec-K" too much work for you? You might be interested in ReplayCam... it's a widget that takes control of your camera in replay/spec mode, and attempts to focus on the most interesting stuff.

The strategy is fairly basic. It listens to a bunch of callins, e.g. for a unit being damaged or destroyed, and adds what happened, in metal, to the nearest focus: a place where things are happening. Each focus keeps a few seconds of what went on there by kind and side. Every second, the camera goes to the focus with most going on, less what it has been watching for a while, and the callout says what is happening there. Things it can currently do:

- Show a unit under attack, especially if near death
- Show areas where there is a lot of activity from opposing teams
- Anticipate fights, raids and bombing runs by watching for armed units closing on enemy value
- Dynamically track and zoom multiple units of interest

There's a lot that it doesn't do well that I will hopefully get around to improving

- Better event anticipation
- Better framing of attack events (need attacker info, dev BAR engine has feature)
- Improved commentary on events
- Camera stickiness when a projectile is about to impact
- Artistic camera rotation

## Usage

**This is very much a beta, and only recommended for expert users.**

Install [replaycam.lua](./replaycam.lua) as a local widget, as per the [instructions here](https://zero-k.info/mediawiki/Widget_Configuration#Activate_local_widgets). After activating - Ctrl+F11 and search for ReplayCam in the Local widgets section - it will take over the camera when spectating a game or watching a replay. Just sit back and let it do the work! Using the mouse should briefly pause the camera. Note that ReplayCam switches to the cofc camera, which you may not be familiar with. It should restore your normal camera settings when deactivated or after the replay is finished.

## Known issues

- Doesn't interact well with Alt+Tab overview mode.

## Possible improvements

- Unit icon distance: the engine swaps units for icons beyond a set range from the camera (the `UnitIconDist` setting, `/disticon` in game). A close shot taken with a narrower lens from the usual height could still show icons. The widget could raise the range while it has the camera, and put the player's setting back afterwards, as it does with the camera settings.

## Measuring the camera

Set `STATS = true` (or `DEBUG = true`) in `replaycam.lua`, watch one or more replays, then run:

```bash
python3 scripts/generate-stats.py path/to/infolog.txt -o run.json
```

This writes per-game timelines and metrics to `run.json` and prints summary tables. Metrics are graded against ground truth (unit deaths and damage valued in metal; deaths with no damage nearby, such as commander upgrades, are ignored), so two runs over the same replays can be compared directly:

```bash
python3 scripts/generate-stats.py --compare base.json new.json
```

An infolog holds every replay watched in one session; `--game -1` keeps just the latest.

Tables are grouped by the principles in [INTENTS.md](INTENTS.md). In a comparison, `games` counts the games that got better and worse by more than 2% each, and a metric only gets a verdict when that agrees with the mean; otherwise it is `mixed`.

Key metrics, weighted by metal value:

- `seen` - the death was inside the camera's ground footprint
- `antic` (anticipation) - mean of focus × visible over 5s..1s before the death
- `focus` - 1 for a tight view (`--ref-area`), 0 when the whole map is visible, log-scaled
- `frame` - share of nearby action in view × how close the footprint is to that action's size
- `lead s` / `late` - how long the spot was framed beforehand, or how often the camera arrived after
- `missed` - share of losses never seen within 5s before to 2s after
- `fights` / `setup` / `setup s` - fights are runs of deaths and damage near each other, counted when at least 300 metal is lost. `setup` is the share of them (by metal lost) whose opening spot was framed for at least 2s in the 10s before the first hit, and `setup s` is the mean time it was framed
- `scnhit` / `scn s` - share of those fights (by metal lost) that a scene event flagged beforehand, and how many seconds ahead. Grades the prediction, whether or not the camera went there
- `scnprc` - share of scene events followed by action nearby within 10s
- `stlost` / `stlate` - why fights weren't set up, as shares of all fights by metal lost. `stlost`: a scene event flagged the fight at least 3s ahead, in time to get there, but the camera stayed elsewhere. `stlate`: no scene event flagged it that early. With `setup` they add up to 100%
- `fair` - how closely screen time follows the stakes over each 3 minutes: the overlap between where the camera looked and where metal was lost, each counted with its neighbouring 512-elmo cells. 1 is screen time in proportion to the losses everywhere
- `builds` / `bseen` - things worth 300 metal or more finished, and the share of them (by value) in view within 3s of finishing

Transition metrics (per shot, not value-weighted):

- `frm0` - share of shots framed at the cut: the event was already in view, or the camera teleported
- `frm s` / `frm90` - for the other shots, median and 90th percentile seconds from the cut to the event being framed (tracking box on screen, centre in the middle half)
- `unfrm` - share of those shots replaced before they ever framed their event
- `ringof` / `ringpt` - once a shot has framed its event, share of time the overlay's ring has its middle out of view, or less than half of it in view. In headless runs the view is a small square, so these only compare headless runs with each other
- `lull/m` - lull events fired per minute (fights that died down); how often they're shown is in the event type table
- `close` / `clzoom` - share of time on a close shot (the lens zoomed in at least 1.2x), and the mean zoom then
- `cldth` / `clseen` - deaths during close shots within 1500 of the middle of the shot, and the share of them (by value) seen: a close shot that misses them was too close
- `orb/m` / `drift` - orbits per minute, and the share that were drifts on a long hold rather than to a better heading
- `orbgn` - median view-score gain of orbits to a better heading (the threshold is `orbitConfig.margin`)
- `south` - share of time the camera faces more than 90 degrees from north
- `yaw90` / `yawmx` - 90th percentile and peak of the fastest yaw (deg/s) in each second, ignoring cuts and user control. Only headed runs give real numbers: headless frame times make them several times too high

Callout metrics, from headed runs only (the headless view is too small to place a callout):

- `up` - share of time a callout is drawn
- `move` / `hmove` - how far it travels on screen, in screen heights per second while drawn: in all, and within a shot (not counting moves to a new shot's subject)
- `still` - share of drawn frames it didn't move
- `plc/m` / `btr/m` - times a minute it was given a new place, and how many of those were for a better place rather than a new shot or being in the way (needs `DEBUG`)
- `hide` / `hdmg` - share of the deaths and damage in view while it was up that were under it (by value), against its ground footprint
- `cfoc` / `coth` - share of the focus's units, and of the other units on screen, under it
- `cwin` - share of time it overlaps one of the game's windows (`rc-windows` lines list them; some, like the empty selection panel and the chat area, are see-through)
- `czone` - share of its area over the action: round the focus's units on screen, with a tenth of the screen height to spare. The unit counts above hardly tell placements apart; this does
- `ptr` - median pointer length, in screen heights
- `say/m` / `brief` - headline changes a minute, and the share replaced or cut away from within 3s (needs `DEBUG`)

The summary also has a table of the same coverage for the callout docked at its size in each corner (`bl`, `br`, `tl`, `tr`) or the bottom middle (`bc`) over the same seconds, to compare placement strategies without building them.

## Running replays unattended

`scripts/run-replay.sh` plays a replay through the widget with the headless engine and saves the log for `generate-stats.py`. Nothing is shown, and your own Zero-K settings and infolog are left alone.

```bash
scripts/run-replay.sh replays/some-replay.sdfz run.txt
python3 scripts/generate-stats.py run.txt -o run.json
```

- The command panel is hidden (by `rc_autorun.lua`): it has nothing to show in a replay, and callouts would keep off it.
- The replay plays at normal speed, so a run takes as long as the game plus about 40s to load. The pregame is fast-forwarded and the engine quits when the game ends.
- Pass another widget file as the third argument to compare versions on the same replay.
- Each engine needs about 3.5GB of memory, which limits how many can run side by side.
- The headless view is square and tiny (8x8 pixels), so framing numbers differ from a real session. Compare headless runs with each other only.
- The map and game version of the replay must already be installed (watch any replay of them in Zero-K once).

To grade a change, `scripts/run-replays.sh` plays every replay in `replays/` two at a time and compares each with an earlier run:

```bash
scripts/run-replays.sh baseline            # before the change: writes runs/<map>-baseline.json
scripts/run-replays.sh mychange baseline   # after it: writes runs/<map>-mychange.json and compares
```

- Close Zero-K first, or there may not be enough memory for two engines.
- `replays/` and `runs/` are not tracked. Replays can be downloaded from a battle's page on zero-k.info ("Manual download"); short games with a lot going on work best.
- Runs of the same widget are not always identical: the camera works in real time, so one replay may differ slightly between runs. Treat small differences on a single replay as noise.
- For a change that should not alter what is shown, compare the `rc-shown` lines of the two logs in `runs/logs/`.

To see how things look, such as where callouts go, `scripts/run-replay-headed.sh` plays a replay with the full engine in a 1600x900 window (`WIDTH` and `HEIGHT` change it) and saves a screenshot every 3 game seconds, named by game frame:

```bash
scripts/run-replay-headed.sh replays/some-replay.sdfz runs/headed/mychange "" 300
```

- The last argument stops it after that many seconds; the first few minutes are often enough.
- The window opens on your desktop, with your graphics settings and no sound. It needs more memory than a headless run, so run one at a time with Zero-K closed.
- With `DEBUG` on, `rc-place` lines in its `infolog.txt` say when and why the callout was moved.
- It also records the window at 30 fps with GStreamer, to `~/Downloads/replaycam/<date>_<map>_<name>.mp4`, where the name is the output folder's unless `VIDEO_NAME` gives one. `VIDEO_DIR` puts it elsewhere and `VIDEO=0` turns it off. `FPS` sets the frame rate and `QUANT` the quality (x264, lower is better and bigger; 34 by default, 20 looks good at 30 fps).

To compare two versions side by side, record each with `SYNC=1`, which draws the game frame as a strip of squares in the bottom left corner, then stack the videos. Frames are matched by game frame, so different start-up times and engine stalls don't put them out of step, and the strip is cropped off:

```bash
SYNC=1 QUANT=20 VIDEO_NAME=new scripts/run-replay-headed.sh replays/some-replay.sdfz runs/headed/new new.lua 600
SYNC=1 QUANT=20 VIDEO_NAME=old scripts/run-replay-headed.sh replays/some-replay.sdfz runs/headed/old old.lua 600
scripts/stack-videos.py out.mp4 ~/Downloads/replaycam/<date>_<map>_new.mp4 "New" ~/Downloads/replaycam/<date>_<map>_old.mp4 "Old"
```

A widget only loads if Zero-K has it enabled under its name, so to record a copy of the widget under another name (such as the one shipped with Zero-K, "Action Tracking Camera", which is off once the DEV one is on), give the copy the DEV one's name.

## Testing offline

`scripts/run-harness.py` runs the widget against a stubbed game, without Zero-K: one side sends raiders or bombers at the other's base. It catches load and runtime errors, and reports when scenes fire, what is shown, how far the callout travels on screen, and the cost per game frame and per draw frame (where the callout is placed; `--crowd 2000` shows the worst case). It can't judge how the camera looks.

```bash
python3 scripts/run-harness.py raid --crowd 2000
```

It needs the Lua 5.4 shared library (`liblua5.4`), and so runs Lua 5.4 rather than the engine's 5.1.
