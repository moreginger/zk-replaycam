# Generate replaycam stats from infolog output

import json
import re
import statistics

re_checked_events = 'checked (?P<events>.+?) events$'
re_event = 'event, (?P<type>.+?),.+$'
re_merge = 'merging events, (?P<type>.+?)$'
re_mie = 'mie, (?P<type>.+?),.+$'
re_opening = 'Opening demofile (?P<demofile>.+)$'
re_connecting = 'Connecting to battle, Zero-K v[^,]+, (?P<map>.+),'
re_wins = 'game_message: .+ wins!'

datas = []

def createEmptyData(demofile):
    return {
        'demofile': demofile,
        'event': {},
        'merge': {},
        'mie': {}
    }

data = None
checkedEvents = None

with open('infolog.txt') as file:
    while (line := file.readline()):
        match = re.search(re_wins, line)
        if match:
            data = None
            checkedEvents = None
            continue
        match = re.search(re_opening, line)
        if match:
            demofile = match.group('demofile')
            data = createEmptyData(demofile)
            checkedEvents = []
            datas.append(data)
            continue
        match = re.search(re_connecting, line)
        if match:
            map = match.group('map')
            data = createEmptyData(map)
            checkedEvents = []
            datas.append(data)
            continue
        if not data:
            continue
        match = re.search(re_event, line)
        if match:
            event_type = match.group('type')
            data['event'].setdefault(event_type, 0)
            data['event'][event_type] += 1
            continue
        match = re.search(re_merge, line)
        if match:
            event_type = match.group('type')
            data['merge'].setdefault(event_type, 0)
            data['merge'][event_type] += 1
            continue
        match = re.search(re_mie, line)
        if match:
            event_type = match.group('type')
            data['mie'].setdefault(event_type, 0)
            data['mie'][event_type] += 1
            continue
        match = re.search(re_checked_events, line)
        if match:
            events = match.group('events')
            checkedEvents.append(int(events))
            data['checked_events_mean'] = statistics.mean(checkedEvents)
            data['checked_events_max'] = max(checkedEvents)
            continue

print(json.dumps(datas))
