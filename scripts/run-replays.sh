#!/usr/bin/env bash
# Play every replay in replays/ through the widget with the headless engine, two at a time, and
# write runs/<map>-<label>.json for each. With a base label, compare each against that run.
#
#   run-replays.sh label [base-label]
#
# WIDGET is the widget file (default: the one here), JOBS how many engines to run at once and
# MAX_SECONDS a time limit per replay. Close Zero-K first: each engine needs about 3.5GB.
set -euo pipefail

label=$1
base=${2:-}
here=$(dirname "$(realpath "$0")")
root=$(dirname "$here")
mkdir -p "$root/runs/logs"

# A snapshot, so the widget can be edited while the replays play
widget=$(mktemp --suffix=.lua)
trap 'rm -f "$widget"' EXIT
cp "${WIDGET:-$root/replaycam.lua}" "$widget"

names=()
for replay in "$root"/replays/*.sdfz; do
	# Replays are named <date>_<time>_<map>_<engine version>.sdfz
	name=$(basename "$replay" .sdfz | cut -d_ -f3 | tr 'A-Z ' 'a-z-')
	names+=("$name")
	log="$root/runs/logs/$name-$label.txt"
	(
		"$here/run-replay.sh" "$replay" "$log" "$widget" ${MAX_SECONDS:-} > /dev/null 2>&1 || true
		python3 "$here/generate-stats.py" "$log" -o "$root/runs/$name-$label.json" > "$root/runs/logs/$name-$label.summary" 2>&1
	) &
	while [ "$(jobs -rp | wc -l)" -ge "${JOBS:-2}" ]; do wait -n; done
done
wait

for name in "${names[@]}"; do
	log="$root/runs/logs/$name-$label.txt"
	echo "== $name: $(grep -ac 'rc-autorun game over' "$log") finished, $(grep -a 'camera_replaycam' "$log" | grep -aci 'error') widget errors"
	if [ -n "$base" ] && [ -f "$root/runs/$name-$base.json" ]; then
		python3 "$here/generate-stats.py" --compare "$root/runs/$name-$base.json" "$root/runs/$name-$label.json"
	fi
done
