# Generate replaycam stats from infolog output

import json
import re

re_event = 'event, (?P<type>.+?),.+$'
re_merge = 'merging events, (?P<type>.+?)$'
re_mie = 'mie, (?P<type>.+?),.+$'

data = {
    'event': {},
    'merge': {},
    'mie': {}
}

with open('infolog.txt') as file:
    while (line := file.readline()):
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

print(json.dumps(data))