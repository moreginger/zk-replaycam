# zk-replaycam

A widget that implements a spectator camera for [Zero-K](https://zero-k.info/)

Example video:

https://youtu.be/As0ma57rgAQ

## Overview

Is "Spec-K" too much work for you? You might be interested in ReplayCam... it's a widget that takes control of your camera in replay/spec mode, and attempts to focus on the most interesting stuff.

The strategy is fairly basic. It listens to a bunch of callins e.g for a unit being destroyed, then creates an event. Every second, events are ranked based on how unusual/important they seem, and the camera zooms to the action. Things it can currently do:

- Show a unit under attack, especially if near death
- Show areas where there is a lot of activity from opposing teams
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
