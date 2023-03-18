# zk-replaycam

## Overview

A widget that implements a spectator camera for [Zero-K](https://zero-k.info/)

## Details

Is "Spec-K" too much work for you? You might be interested in ReplayCam... it's a widget that takes control of your camera in replay/spec mode, and attempts to focus on the most interesting stuff.

The strategy is fairly basic. It listens to a bunch of callins e.g for a unit being destroyed, then creates an event. Every second, events are ranked based on how unusual/important they seem, and the camera zooms to the action. Things it can currently do:

- Show a unit under attack, especially if near death
- Show areas where there is a lot of activity from opposing teams
- Dynamically track and zoom multiple units of interest

There's a lot that it doesn't do well that I will hopefully get around to improving

- Better framing of attack events (need attacker info, dev BAR engine has feature)
- More organic camera rotation / zooming (panning works OK)
- Improved commentary on events
- Improved selection of units for "hotspot / something's going down" events
- Camera stickiness when a projectile is about to impact
- Artistic camera rotation
- Recording mode that disables user camera override
- Preferences e.g. stickiness

Example videos:

https://youtu.be/mEMOBLMRVRI