#!/usr/bin/env bash
# Play a replay through the widget with the headless engine, at normal speed, and save the log
# for generate-stats.py. Nothing is shown and your own Zero-K settings and infolog are untouched:
# each run gets a throwaway write directory. Runs can go in parallel.
#
#   run-replay.sh replay.sdfz out-infolog.txt [widget.lua] [max-seconds]
#
# The widget must have STATS (or DEBUG) on, and must be enabled in your Zero-K widget list, as
# your widget configuration is copied. ZK_DIR is the Zero-K install.
set -euo pipefail

replay=$(realpath "$1")
out=$(realpath "$2")
here=$(dirname "$(realpath "$0")")
widget=$(realpath "${3:-$here/../replaycam.lua}")
limit=${4:-1500}
zk=${ZK_DIR:-$HOME/.local/share/Steam/steamapps/common/Zero-K}

# Replays are named ..._<engine version>.sdfz
version=$(basename "$replay" .sdfz | sed 's/.*_//')
engine="$zk/engine/linux64/$version/spring-headless"
[ -x "$engine" ] || engine=$(ls -d "$zk"/engine/linux64/*/spring-headless | tail -1)

dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
mkdir -p "$dir/LuaUI/Widgets" "$dir/LuaUI/Config"
# The archive cache saves rescanning every map
cp -r "$zk/cache" "$dir/"
cp "$zk"/LuaUI/Config/ZK_order.lua "$zk"/LuaUI/Config/ZK_data.lua "$dir/LuaUI/Config/"
cp "$widget" "$dir/LuaUI/Widgets/camera_replaycam.lua"
cp "$here/rc_autorun.lua" "$dir/LuaUI/Widgets/"

# The engine only flushes its infolog now and then, so keep its line-buffered output instead
cd "$dir"
SPRING_DATADIR="$zk" timeout "$limit" stdbuf -oL -eL "$engine" --only-local --write-dir "$dir" "$replay" > "$out" 2>&1 || true
grep -a -m1 "rc-autorun game over" "$out" || echo "warning: no game over seen, stopped after ${limit}s" >&2
