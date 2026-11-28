#!/usr/bin/env python3
"""Generate replaycam stats from infolog output.

Run the widget with STATS (or DEBUG) enabled, watch one or more replays, then:

    generate-stats.py [infolog.txt] [-o run.json]      # parse, write JSON, print summary
    generate-stats.py --compare base.json new.json     # compare two runs of the same replays

Camera metrics are graded against ground truth (unit deaths and damage, valued in metal),
which the widget logs straight from the callins. On the same replay the ground truth is
identical between runs, so only the camera differs.
"""

import argparse
import bisect
import json
import math
import re
import statistics
import sys

FPS = 30

# Infolog markers
re_frame = re.compile(r'\[f=(-?\d+)\] ')
re_rc = re.compile(r'\] rc-(?P<kind>\w+),(?P<rest>.*)$')
re_event = re.compile(r'\] event, (?P<type>.+?),')
re_merge = re.compile(r'\] merging events, (?P<type>.+?)$')
re_mie = re.compile(r'\] mie, (?P<type>.+?),')
re_opening = re.compile(r'Opening demofile (?P<demofile>.+)$')
re_connecting = re.compile(r'Connecting to battle, Zero-K v[^,]+, (?P<map>.+?),')
re_wins = re.compile(r'game_message: (.+ wins!|The game ended in a draw!)')

# Metric tuning
LEAD_WINDOW = (5, 1)        # seconds before an event that count as "anticipation"
MISS_WINDOW = (5, 2)        # seconds before/after an event in which it must be seen once
FRAMED_FOCUS = 0.5          # focus needed to count as "framed" for lead time
MAX_LEAD_S = 30
CLUSTER_RADIUS = 1000       # elmos, for context-relative framing
CLUSTER_WINDOW_S = 5
CLUSTER_PAD = 400           # elmos padding around the action's bounding box
JUMP_DISTANCE = 1536        # footprint centre moving further than this in 1s is a cut
FRAMED_AT_CUT_S = 0.2      # shots framed this soon after the cut didn't need to travel
CLOSE_ZOOM = 1.2           # a close shot: the lens zoomed in at least this much
CLOSE_NEAR = 1500          # elmos from the middle of a close shot: a death this near might have been seen less close
PINGPONG_S = 10
PINGPONG_RANGE = 512
SHORT_SHOT_S = 3            # shots this long or shorter count as quick cuts
SAME_SPOT_RANGE = 256       # elmos between consecutive shots that count as the same spot
FAR_CUT_RANGE = 1536        # long cuts; the widget's teleport distance before maxPanDistance rose to 2048
FAR_CUT_HIT = (10, 800)     # a far cut "hits" if a death follows within this many seconds and elmos
FIGHT_GAP_S = 10            # action this long after a fight's last action starts a new fight
FIGHT_MIN_VALUE = 300       # metal lost for a fight to count as a payoff worth setting up
SETUP_WINDOW = (10, 1)      # seconds before a fight starts in which its setup can be shown
SETUP_MIN_S = 2             # seconds framed in that window for the setup to count as shown
SETUP_IN_TIME_S = SETUP_WINDOW[1] + SETUP_MIN_S  # a scene this far ahead flagged the fight in time to set it up
COMBAT_DEATH = (5, 1, 400)  # a death counts if damage was logged this many seconds before/after, this close
BUILD_MIN_VALUE = 300       # metal for a finished build to count as news worth seeing
BUILD_WINDOW = (3, 3)       # seconds before/after a build finishes in which it must be seen once
FAIR_CELL = 512             # elmos: areas for fair share, each counted with its neighbours
FAIR_WINDOW_S = 180         # fair share is judged over windows this long
CALLOUT_MIN_VIEW = 200      # pixels: smaller views (the headless engine's 8x8) say nothing about callouts
HEADLINE_BRIEF_S = 3        # headlines replaced sooner than this were hard to read


# GEOMETRY

def clip_polygon(poly, xmin, zmin, xmax, zmax):
    """Sutherland-Hodgman clip of a polygon against an axis-aligned rectangle."""
    def clip(points, inside, intersect):
        out = []
        for i, cur in enumerate(points):
            prev = points[i - 1]
            if inside(cur):
                if not inside(prev):
                    out.append(intersect(prev, cur))
                out.append(cur)
            elif inside(prev):
                out.append(intersect(prev, cur))
        return out

    def at_x(x):
        return lambda a, b: (x, a[1] + (b[1] - a[1]) * (x - a[0]) / (b[0] - a[0]))

    def at_z(z):
        return lambda a, b: (a[0] + (b[0] - a[0]) * (z - a[1]) / (b[1] - a[1]), z)

    for inside, intersect in (
        (lambda p: p[0] >= xmin, at_x(xmin)),
        (lambda p: p[0] <= xmax, at_x(xmax)),
        (lambda p: p[1] >= zmin, at_z(zmin)),
        (lambda p: p[1] <= zmax, at_z(zmax)),
    ):
        poly = clip(poly, inside, intersect)
        if not poly:
            break
    return poly


def polygon_area_centroid(poly):
    a = cx = cz = 0.0
    for i, (x1, z1) in enumerate(poly):
        x2, z2 = poly[(i + 1) % len(poly)]
        cross = x1 * z2 - x2 * z1
        a += cross
        cx += (x1 + x2) * cross
        cz += (z1 + z2) * cross
    a /= 2
    if abs(a) < 1e-6:
        if not poly:
            return 0.0, (0.0, 0.0)
        return 0.0, (sum(p[0] for p in poly) / len(poly), sum(p[1] for p in poly) / len(poly))
    return abs(a), (cx / (6 * a), cz / (6 * a))


def point_in_polygon(x, z, poly):
    inside = False
    for i, (x1, z1) in enumerate(poly):
        x2, z2 = poly[i - 1]
        if (z1 > z) != (z2 > z) and x < (x2 - x1) * (z - z1) / (z2 - z1) + x1:
            inside = not inside
    return inside


# PARSING

def new_game(name):
    return {
        'name': name,
        'map': None,
        'map_size': None,
        'view_size': None,
        'first_frame': None,
        'last_frame': None,
        'counts': {'event': {}, 'merge': {}, 'mie': {}},
        'cam': [],      # [frame, cx, cy, cz, camType, shownId, shownType, override, [[x, z] x4], yaw, maxYawRate]
        'shown': [],    # [frame, id, type, x, z, camType]
        'framed': [],   # [frame, id]: the shot's tracking box first sat in frame
        'orbits': [],   # [frame, id, fromYawDeg, toYawDeg, reason, viewGain]
        'lulls': [],    # [frame, armed, fired, damageShort, damageLong, damagePeak]: lull event trigger, per second
        'extends': [],  # [frame, pickId, mergedType]: merges into the current pick
        'scenes': [],   # [frame, x, z, rise, soonShare]: scene events added
        'deaths': [],   # [frame, unitDef, x, z, value, allyTeam]
        'damage': [],   # [frame, x, z, value]
        'rings': [],    # [frame, x, z, radius]: the overlay's ring, each second it is drawn
        'zooms': [],    # [frame, zoom]: the lens zoomed in for a close shot, each second it is
        'boxes': [],    # [frame, frames, travel, holdTravel, moving, bx, by, w, h, pointer, focusN, otherN,
                        #  focusIn, otherIn, onWindow, [[x, z] x4], zone, lineFocus, lineOther, lineZone]:
                        #  the callout, each second it is drawn
        'docks': [],    # [frame, name, bx, by, focusIn, otherIn, onWindow, [[x, z] x4], zone]: the callout docked instead
        'windows': [],  # [frame, [[name, left, bottom, right, top]]]: the game's windows the callout keeps off
        'built': [],    # [frame, unitDef, x, z, value, allyTeam]: something worth 100 metal or more finished
        'callouts': [], # [frame, kind, id, headline]: the callout's headline changed (DEBUG)
        'places': [],   # [frame, reason]: the callout was given a new place off its subject (DEBUG)
    }


def parse_infolog(path):
    games = []
    game = None

    def started(g):
        return g['first_frame'] is not None

    def fresh_game():
        # Start markers (widget rc-game, "Opening demofile", "Connecting to battle") arrive in
        # varying order, and a replay may be reloaded before it plays. Reuse a game until it has
        # seen a game frame.
        nonlocal game
        if game is None or started(game):
            game = new_game(None)
            games.append(game)
        return game

    with open(path, errors='replace') as file:
        for line in file:
            if re_wins.search(line):
                game = None
                continue
            m = re_opening.search(line)
            if m:
                fresh_game()['name'] = m.group('demofile')
                continue
            m = re_connecting.search(line)
            if m:
                g = fresh_game()
                g['map'] = m.group('map')
                g['name'] = g['name'] or m.group('map')
                continue

            m = re_rc.search(line)
            if m and m.group('kind') == 'game':
                fresh_game()
            if game is None:
                continue

            fm = re_frame.search(line)
            frame = int(fm.group(1)) if fm else -1
            if frame >= 0:
                if game['first_frame'] is None:
                    game['first_frame'] = frame
                game['last_frame'] = frame

            if m:
                parse_rc(game, frame, m.group('kind'), m.group('rest').split(','))
                continue
            for regex, key in ((re_event, 'event'), (re_merge, 'merge'), (re_mie, 'mie')):
                m = regex.search(line)
                if m:
                    counts = game['counts'][key]
                    counts[m.group('type')] = counts.get(m.group('type'), 0) + 1
                    break

    for g in games:
        g['name'] = g['name'] or g['map'] or 'unknown'
    return [g for g in games if started(g)]


def parse_rc(game, frame, kind, f):
    try:
        if kind == 'game':
            # Map names can contain commas, so parse from the right
            game['map'] = ','.join(f[:-4])
            game['map_size'] = [int(f[-4]), int(f[-3])]
            game['view_size'] = [int(f[-2]), int(f[-1])]
        elif kind == 'cam':
            corners = [[float(f[i]), float(f[i + 1])] for i in range(7, 15, 2)]
            # Yaw fields were added later
            yaw, yaw_rate = (float(f[15]), float(f[16])) if len(f) >= 17 else (None, None)
            game['cam'].append([frame, float(f[0]), float(f[1]), float(f[2]), f[3], int(f[4]), f[5], int(f[6]), corners,
                                yaw, yaw_rate])
        elif kind == 'extend':
            game['extends'].append([frame, int(f[0]), f[1]])
        elif kind == 'lull':
            if len(f) >= 5:
                game['lulls'].append([frame, int(f[0]), int(f[1]), float(f[2]), float(f[3]), float(f[4])])
        elif kind == 'scene':
            game['scenes'].append([frame] + [float(v) for v in f[:4]])
        elif kind == 'orbit':
            # The view gain was added later
            game['orbits'].append([frame, int(f[0]), float(f[1]), float(f[2]), f[3], float(f[4]) if len(f) > 4 else None])
        elif kind == 'framed':
            game['framed'].append([frame, int(f[0])])
        elif kind == 'shown':
            game['shown'].append([frame, int(f[0]), f[1], float(f[2]), float(f[3]), f[4]])
        elif kind == 'death':
            game['deaths'].append([frame, f[0], float(f[1]), float(f[3]), float(f[4]), int(f[5])])
        elif kind == 'dmg':
            game['damage'].append([frame, float(f[0]), float(f[1]), float(f[2])])
        elif kind == 'ring':
            game['rings'].append([frame, float(f[0]), float(f[1]), float(f[2])])
        elif kind == 'zoom':
            game['zooms'].append([frame, float(f[0])])
        elif kind == 'box':
            corners = [[float(f[i]), float(f[i + 1])] for i in range(14, 22, 2)]
            # The share over the action was added later
            zone = float(f[22]) if len(f) > 22 else None
            # What the pointer crosses was added later: focus units, other units, share over the action
            line = [int(f[23]), int(f[24]), float(f[25])] if len(f) > 25 else [None, None, None]
            game['boxes'].append([frame, int(f[0])] + [float(v) for v in f[1:9]] + [int(v) for v in f[9:14]] + [corners, zone] + line)
        elif kind == 'dock':
            corners = [[float(f[i]), float(f[i + 1])] for i in range(6, 14, 2)]
            zone = float(f[14]) if len(f) > 14 else None
            game['docks'].append([frame, f[0], float(f[1]), float(f[2]), int(f[3]), int(f[4]), int(f[5]), corners, zone])
        elif kind == 'built':
            game['built'].append([frame, f[0], float(f[1]), float(f[2]), float(f[3]), int(f[4])])
        elif kind == 'callout':
            # Headlines can contain commas
            game['callouts'].append([frame, f[0], int(f[1]), ','.join(f[2:])])
        elif kind == 'windows':
            game['windows'].append([frame, [[w.split(':')[0]] + [float(v) for v in w.split(':')[1:]] for w in f if w]])
        elif kind == 'place':
            game['places'].append([frame, f[0]])
    except (ValueError, IndexError):
        print(f'warning: bad rc-{kind} line: {",".join(f)}', file=sys.stderr)


# METRICS

class View:
    __slots__ = ('frame', 'poly', 'area', 'centre', 'radius', 'focus', 'cam_type', 'shown_id', 'shown_type', 'override')


def build_views(game, ref_area):
    mx, mz = game['map_size']
    map_area = mx * mz
    log_span = math.log(map_area / ref_area) if map_area > ref_area else 1.0
    views, invalid = [], 0
    for frame, cx, _, cz, cam_type, shown_id, shown_type, override, corners, *_ in game['cam']:
        # Older widget versions logged the camera position for corners that missed the ground.
        if any(abs(x - cx) < 3 and abs(z - cz) < 3 for x, z in corners):
            invalid += 1
            continue
        v = View()
        v.frame = frame
        v.poly = clip_polygon([tuple(c) for c in corners], 0, 0, mx, mz)
        v.area, v.centre = polygon_area_centroid(v.poly)
        v.radius = math.sqrt(v.area / math.pi) if v.area > 0 else 1.0
        # 1 at ref_area or tighter, 0 when the whole map is in view, log-scaled between
        v.focus = 0.0 if v.area <= 0 else max(0.0, min(1.0, math.log(map_area / v.area) / log_span))
        v.cam_type, v.shown_id, v.shown_type, v.override = cam_type, shown_id, shown_type, override
        views.append(v)
    return views, invalid


def weighted_mean(pairs):
    total = sum(w for _, w in pairs)
    return sum(x * w for x, w in pairs) / total if total > 0 else None


def percentile(values, p):
    if not values:
        return None
    values = sorted(values)
    return values[min(len(values) - 1, int(p * len(values)))]


def fmt_time(frame):
    s = max(0, frame) // FPS
    return f'{s // 60}:{s % 60:02d}'


def combat_deaths(game):
    """Deaths with damage nearby just beforehand. The rest (commander upgrades, reclaim, cancelled
    builds) aren't losses the camera could have shown."""
    before, after, radius = COMBAT_DEATH
    damage = sorted(game['damage'])
    frames = [d[0] for d in damage]
    return [d for d in game['deaths'] if any(
        math.hypot(x - d[2], z - d[3]) <= radius
        for _, x, z, _ in damage[bisect.bisect_left(frames, d[0] - before * FPS):bisect.bisect_right(frames, d[0] + after * FPS)])]


def find_fights(game):
    """Group deaths and damage into fights: runs of action near each other with no long gap.
    A fight is located where it started and valued by the metal lost in it."""
    action = sorted([(d[0], d[2], d[3], d[4]) for d in game['deaths']] + [(d[0], d[1], d[2], 0.0) for d in game['damage']])
    fights = []
    for frame, x, z, value in action:
        fight = next((f for f in reversed(fights) if frame - f['last'] <= FIGHT_GAP_S * FPS
                      and math.hypot(x - f['lx'], z - f['lz']) <= CLUSTER_RADIUS), None)
        if fight is None:
            fight = {'frame': frame, 'x': x, 'z': z, 'value': 0.0}
            fights.append(fight)
        # Follow the fight as it moves
        fight['last'], fight['lx'], fight['lz'] = frame, x, z
        fight['value'] += value
    return fights


def compute_metrics(game, ref_area):
    duration_s = max(1, (game['last_frame'] - game['first_frame']) / FPS)
    minutes = duration_s / 60
    metrics = {'duration_s': round(duration_s)}
    game = dict(game, deaths=combat_deaths(game))

    # Event type stats (DEBUG logging), available for old logs too
    types = sorted(set().union(*[set(c) for c in game['counts'].values()]))
    by_type = {}
    for t in types:
        events = game['counts']['event'].get(t, 0)
        merges = game['counts']['merge'].get(t, 0)
        mies = game['counts']['mie'].get(t, 0)
        by_type[t] = {
            'events_per_min': events / minutes,
            'merge_ratio': merges / (events + merges) if events + merges else None,
            'mie_per_min': mies / minutes,
            'selection_rate': mies / events if events else None,
        }
    metrics['by_type'] = by_type

    if not game['map_size'] or not game['cam']:
        return metrics

    views, invalid = build_views(game, ref_area)
    metrics['invalid_cam_share'] = invalid / len(game['cam'])
    if not views:
        return metrics
    frames = [v.frame for v in views]

    def view_at(frame):
        """Most recent view at or before frame."""
        i = bisect.bisect_right(frames, frame) - 1
        return views[i] if i >= 0 else None

    def views_between(f0, f1):
        return views[bisect.bisect_left(frames, f0):bisect.bisect_right(frames, f1)]

    def sees(v, x, z):
        return v is not None and v.area > 0 and point_in_polygon(x, z, v.poly)

    # Points of action, for context-relative framing
    action = sorted([(d[0], d[2], d[3]) for d in game['deaths']] + [(d[0], d[1], d[2]) for d in game['damage']])
    action_frames = [a[0] for a in action]

    def ideal_area(frame, x, z):
        lo = bisect.bisect_left(action_frames, frame - CLUSTER_WINDOW_S * FPS)
        hi = bisect.bisect_right(action_frames, frame + CLUSTER_WINDOW_S * FPS)
        pts = [(ax, az) for _, ax, az in action[lo:hi] if math.hypot(ax - x, az - z) <= CLUSTER_RADIUS] or [(x, z)]
        xs, zs = [p[0] for p in pts], [p[1] for p in pts]
        return (max(xs) - min(xs) + 2 * CLUSTER_PAD) * (max(zs) - min(zs) + 2 * CLUSTER_PAD), pts

    # Per-death grading
    graded = []
    for frame, unit_def, x, z, value, ally_team in game['deaths']:
        v = view_at(frame)
        seen = sees(v, x, z)
        lead_views = views_between(frame - LEAD_WINDOW[0] * FPS, frame - LEAD_WINDOW[1] * FPS)
        anticipation = statistics.mean(v2.focus if sees(v2, x, z) else 0.0 for v2 in lead_views) if lead_views else 0.0
        ever_seen = any(sees(v2, x, z) for v2 in views_between(frame - MISS_WINDOW[0] * FPS, frame + MISS_WINDOW[1] * FPS))

        # Lead time: seconds the event spot was continuously framed before it happened.
        # Negative if the camera only arrived afterwards.
        lead = None
        i = bisect.bisect_right(frames, frame) - 1
        if seen and v.focus >= FRAMED_FOCUS:
            j = i
            while j > 0 and frame - views[j - 1].frame <= MAX_LEAD_S * FPS \
                    and views[j - 1].focus >= FRAMED_FOCUS and sees(views[j - 1], x, z):
                j -= 1
            lead = (frame - views[j].frame) / FPS
        else:
            for v2 in views_between(frame + 1, frame + MISS_WINDOW[1] * FPS):
                if v2.focus >= FRAMED_FOCUS and sees(v2, x, z):
                    lead = -(v2.frame - frame) / FPS
                    break

        framing = 0.0
        offcentre = None
        if seen:
            ideal, pts = ideal_area(frame, x, z)
            coverage = sum(1 for px, pz in pts if sees(v, px, pz)) / len(pts)
            framing = coverage * min(1.0, ideal / v.area)
            offcentre = min(1.0, math.hypot(x - v.centre[0], z - v.centre[1]) / v.radius)

        graded.append({
            'frame': frame, 'unit': unit_def, 'x': x, 'z': z, 'value': value, 'ally_team': ally_team,
            'seen': seen, 'focus': v.focus if seen else 0.0, 'anticipation': anticipation,
            'ever_seen': ever_seen, 'lead': lead, 'framing': framing, 'offcentre': offcentre,
        })

    total_value = sum(g['value'] for g in graded)

    def wm(key, rows=graded):
        return weighted_mean([(g[key], g['value']) for g in rows if g[key] is not None])

    metrics['deaths'] = len(graded)
    metrics['death_value'] = round(total_value)
    metrics['seen_at_death'] = wm('seen')
    metrics['focus_at_death'] = wm('focus')
    metrics['anticipation'] = wm('anticipation')
    metrics['framing'] = wm('framing')
    metrics['offcentre'] = wm('offcentre')
    metrics['missed_value'] = sum(g['value'] for g in graded if not g['ever_seen']) / total_value if total_value else None
    leads = [g for g in graded if g['lead'] is not None]
    metrics['lead_s'] = wm('lead', [g for g in leads if g['lead'] >= 0])
    metrics['late_share'] = sum(g['value'] for g in leads if g['lead'] < 0) / sum(g['value'] for g in leads) if leads else None

    # Setups: was the camera (or a scene event) on a fight's opening spot before it kicked off?
    fights = find_fights(game)
    big = [f for f in fights if f['value'] >= FIGHT_MIN_VALUE]
    scenes = game.get('scenes', [])
    scene_frames = [s[0] for s in scenes]
    for f in big:
        f0, f1 = f['frame'] - SETUP_WINDOW[0] * FPS, f['frame'] - SETUP_WINDOW[1] * FPS
        before = views_between(f0, f1)
        framed = sum(1 for v in before if v.focus >= FRAMED_FOCUS and sees(v, f['x'], f['z']))
        f['setup_s'] = framed * (f1 - f0) / FPS / len(before) if before else 0.0
        near = [s for s in scenes[bisect.bisect_left(scene_frames, f0):bisect.bisect_right(scene_frames, f['frame'])]
                if math.hypot(s[1] - f['x'], s[2] - f['z']) <= CLUSTER_RADIUS]
        f['scene_lead'] = (f['frame'] - near[0][0]) / FPS if near else None
        f['in_time'] = f['scene_lead'] is not None and f['scene_lead'] >= SETUP_IN_TIME_S
    big_value = sum(f['value'] for f in big)
    metrics['fights'] = len(big)
    if big:
        metrics['setup_share'] = sum(f['value'] for f in big if f['setup_s'] >= SETUP_MIN_S) / big_value
        metrics['setup_s'] = weighted_mean([(f['setup_s'], f['value']) for f in big])
    if big and scenes:
        metrics['scene_hit'] = sum(f['value'] for f in big if f['scene_lead'] is not None) / big_value
        metrics['scene_lead_s'] = weighted_mean([(f['scene_lead'], f['value']) for f in big if f['scene_lead'] is not None])
        # Fights not set up, by why: flagged in time but the camera stayed elsewhere, or flagged too
        # late (or not at all) to get there
        missed = [f for f in big if f['setup_s'] < SETUP_MIN_S]
        metrics['setup_lost'] = sum(f['value'] for f in missed if f['in_time']) / big_value
        metrics['setup_late'] = sum(f['value'] for f in missed if not f['in_time']) / big_value
        # Share of scene events with action nearby soon after
        metrics['scene_precision'] = sum(1 for s in scenes if any(
            math.hypot(ax - s[1], az - s[2]) <= CLUSTER_RADIUS
            for _, ax, az in action[bisect.bisect_left(action_frames, s[0]):
                                    bisect.bisect_right(action_frames, s[0] + SETUP_WINDOW[0] * FPS)])) / len(scenes)

    # Fairness between ally teams: share of each side's losses that was seen
    by_ally = {}
    for g in graded:
        a = by_ally.setdefault(g['ally_team'], [0.0, 0.0])
        a[0] += g['value'] * g['seen']
        a[1] += g['value']
    seen_by_ally = {str(k): s / t for k, (s, t) in by_ally.items() if t > 0}
    metrics['seen_by_ally'] = seen_by_ally
    metrics['ally_balance'] = min(seen_by_ally.values()) / max(seen_by_ally.values()) \
        if len(seen_by_ally) > 1 and max(seen_by_ally.values()) > 0 else None

    # Damage on screen, weighted by focus
    dmg_pairs = []
    for frame, x, z, value in game['damage']:
        v = view_at(frame)
        dmg_pairs.append((v.focus if sees(v, x, z) else 0.0, value))
    metrics['damage_on_screen'] = weighted_mean(dmg_pairs)

    # Per-second action: on screen vs elsewhere, dead air and yield by shown type
    action_by_view = [[0.0, 0.0] for _ in views]
    for frame, x, z, value in [(d[0], d[2], d[3], d[4]) for d in game['deaths']] + game['damage']:
        i = bisect.bisect_right(frames, frame) - 1
        if i >= 0:
            action_by_view[i][1] += value
            if sees(views[i], x, z):
                action_by_view[i][0] += value
    busy = percentile([t for _, t in action_by_view if t > 0], 0.5) or 0
    metrics['dead_air_s'] = sum(1 for s, t in action_by_view if s == 0 and t >= busy and busy > 0) * (duration_s / max(1, len(views)))

    type_time, type_yield = {}, {}
    for v, (on_screen, _) in zip(views, action_by_view):
        type_time[v.shown_type] = type_time.get(v.shown_type, 0) + 1
        type_yield[v.shown_type] = type_yield.get(v.shown_type, 0.0) + on_screen * v.focus
    for t, n in type_time.items():
        row = by_type.setdefault(t, {})
        row['screen_share'] = n / len(views)
        row['yield_per_s'] = type_yield[t] / n

    # Camera behaviour
    metrics['overview_share'] = sum(1 for v in views if v.cam_type == 'overview') / len(views)
    metrics['override_share'] = sum(1 for v in views if v.override) / len(views)
    metrics['mean_focus'] = statistics.mean(v.focus for v in views)
    moves = [math.hypot(b.centre[0] - a.centre[0], b.centre[1] - a.centre[1]) / max(1e-6, (b.frame - a.frame) / FPS)
             for a, b in zip(views, views[1:]) if a.area > 0 and b.area > 0]
    metrics['jumps_per_min'] = sum(1 for m in moves if m > JUMP_DISTANCE) / minutes
    metrics['pan_speed'] = statistics.median([m for m in moves if m <= JUMP_DISTANCE]) if moves else None

    shown = game['shown']
    metrics['shots_per_min'] = len(shown) / minutes
    shot_lengths = [(b[0] - a[0]) / FPS for a, b in zip(shown, shown[1:])]
    metrics['shot_s_median'] = statistics.median(shot_lengths) if shot_lengths else None
    metrics['shot_s_p10'] = percentile(shot_lengths, 0.1)
    pingpong = 0
    for i in range(2, len(shown)):
        a, c = shown[i - 2], shown[i]
        if c[0] - a[0] <= PINGPONG_S * FPS and math.hypot(c[3] - a[3], c[4] - a[4]) <= PINGPONG_RANGE \
                and math.hypot(shown[i - 1][3] - a[3], shown[i - 1][4] - a[4]) > PINGPONG_RANGE:
            pingpong += 1
    metrics['pingpong_per_min'] = pingpong / minutes

    # Fluidity: quick cuts, cuts that stay put, and long jumps that don't lead anywhere
    metrics['short_shot_share'] = sum(1 for s in shot_lengths if s <= SHORT_SHOT_S + 0.05) / len(shot_lengths) if shot_lengths else None
    cuts = [(a, b, math.hypot(b[3] - a[3], b[4] - a[4])) for a, b in zip(shown, shown[1:])
            if a[5] == b[5] == 'tracking']
    metrics['same_spot_cut_share'] = sum(1 for *_, d in cuts if d < SAME_SPOT_RANGE) / len(cuts) if cuts else None
    far = [b for _, b, d in cuts if d >= FAR_CUT_RANGE]
    metrics['far_cuts_per_min'] = len(far) / minutes
    hit_s, hit_range = FAR_CUT_HIT
    metrics['far_cut_hit'] = sum(1 for b in far if any(
        b[0] <= d[0] <= b[0] + hit_s * FPS and math.hypot(d[2] - b[3], d[3] - b[4]) < hit_range
        for d in game['deaths'])) / len(far) if far else None
    metrics['extends_per_min'] = len(game.get('extends', [])) / minutes

    # Transitions: how long a shot takes to frame its event, and how often it is cut before then
    framed = game.get('framed', [])
    if framed:
        framed_at = {}
        for frame, event_id in framed:
            framed_at.setdefault(event_id, []).append(frame)
        times, unframed, ended = [], 0, 0
        for i, (start, event_id, *_) in enumerate(shown):
            end = shown[i + 1][0] if i + 1 < len(shown) else None
            hit = next((f for f in framed_at.get(event_id, []) if f >= start and (end is None or f < end)), None)
            if hit is not None:
                times.append((hit - start) / FPS)
            elif end is not None:
                unframed += 1
            if end is not None:
                ended += 1
        # Only shots that had to travel: the rest were in view already, or arrived by teleport.
        travel = [t for t in times if t > FRAMED_AT_CUT_S]
        metrics['framed_at_cut_share'] = (len(times) - len(travel)) / len(shown) if shown else None
        metrics['frame_s_median'] = statistics.median(travel) if travel else None
        metrics['frame_s_p90'] = percentile(travel, 0.9)
        metrics['unframed_cut_share'] = unframed / (unframed + len(travel)) if unframed + len(travel) else None
    # The ring off the shot, once the shot has framed its subject: the overlay thinks the action is
    # somewhere the camera isn't showing
    rings = game.get('rings', [])
    if rings and framed and shown:
        starts = [s[0] for s in shown]
        settled = []
        for frame, x, z, r in rings:
            i = bisect.bisect_right(starts, frame) - 1
            v = view_at(frame)
            if i >= 0 and v and any(shown[i][0] <= f <= frame and e == shown[i][1] for f, e in framed):
                points = [(x + r * math.sin(a * math.pi / 12), z + r * math.cos(a * math.pi / 12)) for a in range(24)]
                on = sum(1 for px, pz in points if sees(v, px, pz)) / len(points)
                settled.append((on, sees(v, x, z)))
        if settled:
            metrics['ring_off_share'] = sum(1 for _, m in settled if not m) / len(settled)
            metrics['ring_part_share'] = sum(1 for on, _ in settled if on < 0.5) / len(settled)
    # Close shots: seconds the lens was zoomed in at least CLOSE_ZOOM, and deaths near them then seen
    close = {z[0] // FPS: z[1] for z in game.get('zooms', []) if z[1] >= CLOSE_ZOOM}
    metrics['close_share'] = len(close) / len(game['cam']) if game['cam'] else None
    metrics['close_zoom'] = statistics.mean(close.values()) if close else None
    during = []
    for g in graded:
        v = view_at(g['frame'])
        if g['frame'] // FPS in close and v and math.hypot(g['x'] - v.centre[0], g['z'] - v.centre[1]) <= CLOSE_NEAR:
            during.append(g)
    metrics['close_deaths'] = len(during)
    metrics['close_seen'] = weighted_mean([(g['seen'], g['value']) for g in during]) if during else None
    orbits = game.get('orbits', [])
    if orbits:
        metrics['orbits_per_min'] = len(orbits) / minutes
        metrics['orbit_drift_share'] = sum(1 for o in orbits if o[4] == 'drift') / len(orbits)
        gains = [o[5] for o in orbits if len(o) > 5 and o[5] is not None and o[4] != 'drift']
        metrics['orbit_gain_median'] = statistics.median(gains) if gains else None
    # Lull events fired: fights that died down
    lulls = game.get('lulls', [])
    if lulls:
        metrics['lulls_fired_per_min'] = sum(1 for row in lulls if row[2]) / minutes
    yaws = [c[9] for c in game['cam'] if len(c) > 9 and c[9] is not None and not c[7]]
    if yaws:
        # Widget yaw pi faces north
        metrics['away_from_north_share'] = sum(
            1 for y in yaws if abs((y - math.pi + math.pi) % (2 * math.pi) - math.pi) > math.pi / 2) / len(yaws)
    yaw_rates = [c[10] for c in game['cam'] if len(c) > 10 and c[10] is not None and not c[7]]
    if yaw_rates:
        metrics['yaw_rate_p90'] = percentile(yaw_rates, 0.9)
        metrics['yaw_rate_max'] = max(yaw_rates)

    # Big builds finished: seen at some point around finishing
    builds = [b for b in game.get('built', []) if b[4] >= BUILD_MIN_VALUE]
    if builds:
        before, after = BUILD_WINDOW
        metrics['builds'] = len(builds)
        metrics['builds_seen'] = weighted_mean([
            (1.0 if any(sees(v2, b[2], b[3]) for v2 in views_between(b[0] - before * FPS, b[0] + after * FPS)) else 0.0, b[4])
            for b in builds])

    metrics['fair_share'] = fair_share(game, views, graded)
    metrics.update(callout_metrics(game, views, graded, minutes, lambda frame, x, z: sees(view_at(frame), x, z)))

    # Biggest losses the camera never showed, for checking in the replay
    missed = sorted((g for g in graded if not g['ever_seen']), key=lambda g: -g['value'])[:10]
    metrics['missed_highlights'] = [
        {'time': fmt_time(g['frame'] - game['first_frame']), 'frame': g['frame'], 'unit': g['unit'],
         'value': round(g['value']), 'x': round(g['x']), 'z': round(g['z'])}
        for g in missed
    ]
    return metrics


def fair_share(game, views, graded):
    """How closely screen time follows the stakes, over each FAIR_WINDOW_S: the overlap between where
    the camera looked and where metal was lost (deaths and damage), each spread over neighbouring
    cells so that a fight on a border counts as one place. 1 is all screen time where the stakes
    were, in proportion; 0 is none of it. Windows count by their stakes."""
    def cell(x, z):
        return int(x // FAIR_CELL), int(z // FAIR_CELL)

    window = FAIR_WINDOW_S * FPS
    stakes, time = {}, {}
    for frame, x, z, value in [(g['frame'], g['x'], g['z'], g['value']) for g in graded] + game['damage']:
        w = stakes.setdefault(frame // window, {})
        w[cell(x, z)] = w.get(cell(x, z), 0.0) + value
    for v in views:
        if not v.override and v.area > 0:
            w = time.setdefault(v.frame // window, {})
            w[cell(*v.centre)] = w.get(cell(*v.centre), 0) + 1

    def spread(d):
        out = {}
        for (cx, cz), v in d.items():
            for dx in (-1, 0, 1):
                for dz in (-1, 0, 1):
                    out[(cx + dx, cz + dz)] = out.get((cx + dx, cz + dz), 0.0) + v
        total = sum(out.values())
        return {k: v / total for k, v in out.items()} if total > 0 else {}

    pairs = []
    for w, s in stakes.items():
        total = sum(s.values())
        if total > 0:
            a, b = spread(s), spread(time.get(w, {}))
            pairs.append((sum(min(v, b.get(k, 0.0)) for k, v in a.items()), total))
    return weighted_mean(pairs)


def callout_metrics(game, views, graded, minutes, seen_at):
    """How the callout moved and what it covered, from rc-box lines; and what it would have covered
    docked in a corner or the bottom middle instead, from rc-dock lines. Only for views big enough
    to say (headed runs). seen_at(frame, x, z) says whether a point was in view then."""
    view_size = game.get('view_size') or [0, 0]
    boxes = game.get('boxes', [])
    if min(view_size) < CALLOUT_MIN_VIEW or not boxes:
        return {}
    vsy = view_size[1]
    m = {'callout_share': len(boxes) / len(views) if views else None}
    # Motion in screen heights per second, while drawn: in all, and within a shot
    m['callout_move'] = statistics.mean(b[2] / vsy for b in boxes)
    m['callout_hold_move'] = statistics.mean(b[3] / vsy for b in boxes)
    frames = sum(b[1] for b in boxes)
    m['callout_still'] = 1 - sum(b[4] for b in boxes) / frames if frames else None
    places = game.get('places', [])
    if places or game.get('callouts'):
        m['callout_places_per_min'] = len(places) / minutes
        m['callout_better_per_min'] = sum(1 for p in places if p[1] == 'better') / minutes
    m['callout_pointer'] = statistics.median(b[9] / vsy for b in boxes)
    focus_n, other_n = sum(b[10] for b in boxes), sum(b[11] for b in boxes)

    # Deaths and damage in view while a callout was up, and the share of them under it. Each flush
    # says where the callout was over the second before it.
    def rect_rows(rows, poly_at):
        return [(r[0], poly_at(r)) for r in rows]

    def under(rects):
        starts = [r[0] for r in rects]

        def at(frame):
            i = bisect.bisect_left(starts, frame)
            return rects[i][1] if i < len(rects) and rects[i][0] - frame <= FPS else None
        return at

    box_at = under(rect_rows(boxes, lambda b: b[15]))
    events = [(g['frame'], g['x'], g['z'], g['value']) for g in graded if g['seen']]
    hits = [(f, x, z, v) for f, x, z, v in game['damage'] if seen_at(f, x, z)]

    def hidden(at, rows):
        up = [(r, at(r[0])) for r in rows]
        up = [(r, poly) for r, poly in up if poly is not None]
        total = sum(r[3] for r, _ in up)
        return sum(r[3] for r, poly in up if point_in_polygon(r[1], r[2], poly)) / total if total > 0 else None

    m['callout_hidden'] = hidden(box_at, events)
    m['callout_hidden_damage'] = hidden(box_at, hits)
    m['callout_focus_cover'] = sum(b[12] for b in boxes) / focus_n if focus_n else None
    m['callout_other_cover'] = sum(b[13] for b in boxes) / other_n if other_n else None
    m['callout_window'] = sum(1 for b in boxes if b[14]) / len(boxes)
    zones = [b[16] for b in boxes if b[16] is not None]
    m['callout_zone'] = statistics.mean(zones) if zones else None
    lines = [b for b in boxes if b[17] is not None and b[9] > 0]
    if lines:
        m['pointer_units'] = statistics.mean(b[17] + b[18] for b in lines)
        m['pointer_zone'] = statistics.mean(b[19] for b in lines)

    # The same for each dock, against the same seconds
    docks = {'actual': {'hide': m['callout_hidden'], 'hdmg': m['callout_hidden_damage'],
                        'focus': m['callout_focus_cover'], 'other': m['callout_other_cover'],
                        'window': m['callout_window'], 'zone': m['callout_zone']}}
    by_name = {}
    for d in game.get('docks', []):
        by_name.setdefault(d[1], []).append(d)
    for name, rows in sorted(by_name.items()):
        # Box frames index the unit counts for the same second
        counts = {b[0]: (b[10], b[11]) for b in boxes}
        fn = sum(counts.get(r[0], (0, 0))[0] for r in rows)
        on = sum(counts.get(r[0], (0, 0))[1] for r in rows)
        at = under(rect_rows(rows, lambda r: r[7]))
        docks[name] = {'hide': hidden(at, events), 'hdmg': hidden(at, hits),
                       'focus': sum(r[4] for r in rows) / fn if fn else None,
                       'other': sum(r[5] for r in rows) / on if on else None,
                       'window': sum(1 for r in rows if r[6]) / len(rows),
                       'zone': statistics.mean(r[8] for r in rows if r[8] is not None) if any(r[8] is not None for r in rows) else None}
    m['callout_docks'] = docks

    # Headlines: how often they change, and how many were gone before they could be read (replaced,
    # or the shot changed)
    callouts = game.get('callouts', [])
    if callouts:
        ends = sorted([c[0] for c in callouts] + [s[0] for s in game['shown']])
        brief = 0
        for c in callouts:
            i = bisect.bisect_right(ends, c[0])
            if i < len(ends) and ends[i] - c[0] < HEADLINE_BRIEF_S * FPS:
                brief += 1
        m['headlines_per_min'] = len(callouts) / minutes
        m['headline_brief_share'] = brief / len(callouts)
    return m


# OUTPUT

# Sections follow INTENTS.md. (key, label, format, higher_is_better)
SECTIONS = [
    ('Show what matters', [
        ('deaths', 'deaths', '{:.0f}', None),
        ('seen_at_death', 'seen', '{:.0%}', True),
        ('missed_value', 'missed', '{:.0%}', False),
        ('damage_on_screen', 'dmg', '{:.2f}', True),
        ('dead_air_s', 'dead s', '{:.0f}', False),
        ('ally_balance', 'bal', '{:.2f}', True),
        ('fair_share', 'fair', '{:.2f}', True),
        ('builds', 'builds', '{:.0f}', None),
        ('builds_seen', 'bseen', '{:.0%}', True),
    ]),
    ('See it coming, stay for the payoff', [
        ('anticipation', 'antic', '{:.2f}', True),
        ('lead_s', 'lead s', '{:.1f}', True),
        ('late_share', 'late', '{:.0%}', False),
        ('fights', 'fights', '{:.0f}', None),
        ('setup_share', 'setup', '{:.0%}', True),
        ('setup_s', 'setup s', '{:.1f}', True),
        ('scene_hit', 'scnhit', '{:.0%}', True),
        ('scene_lead_s', 'scn s', '{:.1f}', True),
        ('scene_precision', 'scnprc', '{:.0%}', True),
        ('setup_lost', 'stlost', '{:.0%}', False),
        ('setup_late', 'stlate', '{:.0%}', False),
    ]),
    ('Keep the viewer oriented', [
        ('focus_at_death', 'focus', '{:.2f}', True),
        ('framing', 'frame', '{:.2f}', True),
        ('offcentre', 'offctr', '{:.2f}', False),
        ('framed_at_cut_share', 'frm0', '{:.0%}', None),
        ('frame_s_median', 'frm s', '{:.1f}', False),
        ('frame_s_p90', 'frm90', '{:.1f}', False),
        ('unframed_cut_share', 'unfrm', '{:.0%}', False),
        ('ring_off_share', 'ringof', '{:.0%}', False),
        ('ring_part_share', 'ringpt', '{:.0%}', False),
        ('away_from_north_share', 'south', '{:.0%}', None),
    ]),
    ('Pace it', [
        ('shots_per_min', 'shot/m', '{:.1f}', None),
        ('shot_s_median', 'shot s', '{:.1f}', None),
        ('pingpong_per_min', 'ping/m', '{:.2f}', False),
        ('short_shot_share', 'short', '{:.0%}', False),
        ('same_spot_cut_share', 'same', '{:.0%}', False),
        ('far_cuts_per_min', 'far/m', '{:.1f}', False),
        ('far_cut_hit', 'farhit', '{:.0%}', True),
        ('extends_per_min', 'ext/m', '{:.1f}', None),
        ('overview_share', 'ovw', '{:.0%}', None),
        ('lulls_fired_per_min', 'lull/m', '{:.1f}', None),
        ('mean_focus', 'mfocus', '{:.2f}', None),
        ('close_share', 'close', '{:.0%}', None),
        ('close_zoom', 'clzoom', '{:.2f}', None),
        ('close_deaths', 'cldth', '{:.0f}', None),
        ('close_seen', 'clseen', '{:.0%}', True),
    ]),
    ('Keep the camera invisible', [
        ('jumps_per_min', 'jump/m', '{:.1f}', False),
        ('orbits_per_min', 'orb/m', '{:.1f}', None),
        ('orbit_drift_share', 'drift', '{:.0%}', None),
        ('orbit_gain_median', 'orbgn', '{:.2f}', None),
        ('yaw_rate_p90', 'yaw90', '{:.0f}', False),
        ('yaw_rate_max', 'yawmx', '{:.0f}', False),
    ]),
    ('Commentate (headed runs only)', [
        ('callout_share', 'up', '{:.0%}', None),
        ('callout_move', 'move', '{:.2f}', False),
        ('callout_hold_move', 'hmove', '{:.2f}', False),
        ('callout_still', 'still', '{:.0%}', True),
        ('callout_places_per_min', 'plc/m', '{:.1f}', False),
        ('callout_better_per_min', 'btr/m', '{:.1f}', False),
        ('callout_hidden', 'hide', '{:.1%}', False),
        ('callout_hidden_damage', 'hdmg', '{:.1%}', False),
        ('callout_focus_cover', 'cfoc', '{:.1%}', False),
        ('callout_other_cover', 'coth', '{:.1%}', False),
        ('callout_window', 'cwin', '{:.0%}', False),
        ('callout_zone', 'czone', '{:.0%}', False),
        ('callout_pointer', 'ptr', '{:.2f}', None),
        ('pointer_units', 'pcross', '{:.1f}', False),
        ('pointer_zone', 'pzone', '{:.0%}', False),
        ('headlines_per_min', 'say/m', '{:.1f}', None),
        ('headline_brief_share', 'brief', '{:.0%}', False),
    ]),
    ('Run', [
        ('duration_s', 'dur s', '{:.0f}', None),
        ('override_share', 'user', '{:.0%}', None),
        ('invalid_cam_share', 'badcam', '{:.0%}', False),
    ]),
]
SUMMARY_COLUMNS = [c for _, cols in SECTIONS for c in cols]
# A change on one game smaller than this share of the value is noise
GAME_NOISE = 0.02

TYPE_COLUMNS = [
    ('events_per_min', 'ev/min', '{:.1f}'),
    ('merge_ratio', 'merge', '{:.0%}'),
    ('mie_per_min', 'mie/min', '{:.2f}'),
    ('selection_rate', 'select', '{:.2%}'),
    ('screen_share', 'screen', '{:.0%}'),
    ('yield_per_s', 'yield/s', '{:.1f}'),  # on-screen metal value per second × focus
]


def fmt(value, f):
    return '-' if value is None else f.format(value)


def print_table(headers, rows, out=sys.stdout):
    widths = [max(len(str(h)), *(len(str(r[i])) for r in rows)) for i, h in enumerate(headers)]
    line = '  '.join(str(h).rjust(w) if i else str(h).ljust(w) for i, (h, w) in enumerate(zip(headers, widths)))
    print(line, file=out)
    print('-' * len(line), file=out)
    for r in rows:
        print('  '.join(str(c).rjust(w) if i else str(c).ljust(w) for i, (c, w) in enumerate(zip(r, widths))), file=out)
    print(file=out)


def short_name(game):
    name = game['name'].replace('\\', '/').rsplit('/', 1)[-1]
    return name if len(name) <= 40 else '…' + name[-39:]


def mean_metrics(games):
    """Mean of each summary metric across games (unweighted)."""
    out = {}
    for key, *_ in SUMMARY_COLUMNS:
        values = [g['metrics'].get(key) for g in games if g['metrics'].get(key) is not None]
        out[key] = statistics.mean(values) if values else None
    return out


def print_summary(games, out=sys.stdout):
    if not games:
        print('No games found.', file=out)
        return
    mean = mean_metrics(games) if len(games) > 1 else None
    for title, section in SECTIONS:
        cols = [c for c in section if any(g['metrics'].get(c[0]) is not None for g in games)]
        if not cols:
            continue
        rows = [[short_name(g)] + [fmt(g['metrics'].get(k), f) for k, _, f, _ in cols] for g in games]
        if mean:
            rows.append(['MEAN'] + [fmt(mean[k], f) for k, _, f, _ in cols])
        print(f'{title}:', file=out)
        print_table(['game'] + [c[1] for c in cols], rows, out)

    if not any(g['metrics'].get('deaths') for g in games):
        print('No rc-* lines found: enable STATS in replaycam.lua for camera metrics.\n', file=out)

    for g in games:
        docks = g['metrics'].get('callout_docks')
        if docks:
            print(f'Callout where drawn and docked instead: {short_name(g)}', file=out)
            print_table(['place', 'hide', 'hdmg', 'cfoc', 'coth', 'cwin', 'czone'],
                        [[name] + [fmt(d.get(k), f) for k, f in (('hide', '{:.1%}'), ('hdmg', '{:.1%}'), ('focus', '{:.1%}'),
                                                                  ('other', '{:.1%}'), ('window', '{:.0%}'), ('zone', '{:.0%}'))]
                         for name, d in docks.items()], out)
        by_type = g['metrics'].get('by_type') or {}
        if by_type:
            print(f'Event types: {short_name(g)}', file=out)
            rows = [[t] + [fmt(by_type[t].get(k), f) for k, _, f in TYPE_COLUMNS] for t in sorted(by_type)]
            print_table(['type'] + [c[1] for c in TYPE_COLUMNS], rows, out)
        missed = g['metrics'].get('missed_highlights')
        if missed:
            print(f'Biggest missed losses: {short_name(g)}', file=out)
            print_table(['time', 'frame', 'unit', 'value', 'x', 'z'],
                        [[m['time'], m['frame'], m['unit'], m['value'], m['x'], m['z']] for m in missed], out)


def compare(base_path, new_path, out=sys.stdout):
    with open(base_path) as f:
        base = json.load(f)
    with open(new_path) as f:
        new = json.load(f)

    def keyed(games):
        seen, out_ = {}, {}
        for g in games:
            n = seen[g['name']] = seen.get(g['name'], 0) + 1
            out_[f"{g['name']}#{n}"] = g
        return out_

    kb, kn = keyed(base['games']), keyed(new['games'])
    common = [k for k in kb if k in kn]
    if not common:
        print('No games in common between the two runs.', file=out)
        return
    for k in set(kb) ^ set(kn):
        print(f'note: {k} only in one run, ignored', file=sys.stderr)
    for k in common:
        b, n = kb[k]['metrics'].get('death_value'), kn[k]['metrics'].get('death_value')
        if b and n and abs(b - n) / b > 0.01:
            print(f'warning: {k} ground truth differs ({b} vs {n}): replays may not match', file=sys.stderr)

    mb = mean_metrics([kb[k] for k in common])
    mn = mean_metrics([kn[k] for k in common])
    print(f'Comparing {len(common)} game(s): {base_path} -> {new_path}', file=out)
    print('games: how many got better and worse by more than noise; a verdict needs the mean and most games to agree\n', file=out)
    for title, section in SECTIONS:
        rows = []
        for key, label, f, higher_better in section:
            if mb[key] is None and mn[key] is None:
                continue
            delta, verdict, games = '-', '', ''
            if mb[key] is not None and mn[key] is not None:
                d = mn[key] - mb[key]
                delta = ('+' if d >= 0 else '') + f.format(d)
                if higher_better is not None:
                    up = down = 0
                    for k in common:
                        b, n = kb[k]['metrics'].get(key), kn[k]['metrics'].get(key)
                        if b is not None and n is not None and abs(n - b) > GAME_NOISE * max(abs(b), abs(n), 1e-9):
                            if (n > b) == higher_better:
                                up += 1
                            else:
                                down += 1
                    games = f'+{up} -{down}'
                    if abs(d) > 1e-9 and up + down > 0:
                        verdict = ('better' if (d > 0) == higher_better else 'worse') if (up > down) == ((d > 0) == higher_better) and up != down else 'mixed'
            rows.append([label, key, fmt(mb[key], f), fmt(mn[key], f), delta, games, verdict])
        if rows:
            print(f'{title}:', file=out)
            print_table(['metric', 'key', 'base', 'new', 'delta', 'games', ''], rows, out)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('infolog', nargs='?', default='infolog.txt')
    parser.add_argument('-o', '--output', help='write JSON here (default: stdout, summary to stderr)')
    parser.add_argument('--compare', nargs=2, metavar=('BASE', 'NEW'), help='compare two JSON outputs')
    parser.add_argument('--ref-area', type=float, default=2_500_000,
                        help='ground footprint (elmos^2) that counts as fully focused (default: 2.5e6, about the tightest tracking shot)')
    parser.add_argument('--game', type=int, action='append',
                        help='keep only this game index (0-based, negative counts from the end, repeatable)')
    parser.add_argument('--no-timelines', action='store_true', help='omit raw timelines from the JSON')
    args = parser.parse_args()

    if args.compare:
        compare(*args.compare)
        return

    games = parse_infolog(args.infolog)
    if args.game:
        games = [games[i] for i in args.game]
    for g in games:
        g['metrics'] = compute_metrics(g, args.ref_area)
        if args.no_timelines:
            for k in ('cam', 'shown', 'framed', 'orbits', 'lulls', 'extends', 'scenes', 'deaths', 'damage',
                      'rings', 'zooms', 'boxes', 'docks', 'built', 'callouts', 'places', 'windows'):
                del g[k]

    result = {'infolog': args.infolog, 'ref_area': args.ref_area, 'games': games}
    if args.output:
        with open(args.output, 'w') as f:
            json.dump(result, f)
        print_summary(games)
    else:
        json.dump(result, sys.stdout)
        print()
        print_summary(games, out=sys.stderr)


if __name__ == '__main__':
    main()
