#!/usr/bin/env bash
# Play a replay through the widget with the full engine in a window, at normal speed, taking a
# screenshot every few game seconds (see rc_screenshots.lua), so placement and framing can be looked
# at afterwards. Like run-replay.sh, your own settings and infolog are untouched.
#
#   run-replay-headed.sh replay.sdfz out-dir [widget.lua] [max-seconds]
#
# out-dir gets infolog.txt and the screenshots, named by game frame. WIDTH and HEIGHT set the window.
set -euo pipefail

replay=$(realpath "$1")
mkdir -p "$2"
out=$(realpath "$2")
here=$(dirname "$(realpath "$0")")
widget=$(realpath "${3:-$here/../replaycam.lua}")
limit=${4:-1500}
zk=${ZK_DIR:-$HOME/.local/share/Steam/steamapps/common/Zero-K}

version=$(basename "$replay" .sdfz | sed 's/.*_//')
engine="$zk/engine/linux64/$version/spring"
[ -x "$engine" ] || engine=$(ls -d "$zk"/engine/linux64/*/spring | tail -1)

dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
mkdir -p "$dir/LuaUI/Widgets" "$dir/LuaUI/Config"
cp -r "$zk/cache" "$dir/"
cp "$zk"/LuaUI/Config/ZK_order.lua "$zk"/LuaUI/Config/ZK_data.lua "$dir/LuaUI/Config/"
cp "$widget" "$dir/LuaUI/Widgets/camera_replaycam.lua"
cp "$here/rc_autorun.lua" "$here/rc_screenshots.lua" "$dir/LuaUI/Widgets/"
# Your graphics settings, in a window and silent
grep -vE '^(Fullscreen|WindowBorderless|XResolutionWindowed|YResolutionWindowed|WindowPosX|WindowPosY|snd_volmaster) ' "$zk/springsettings.cfg" > "$dir/springsettings.cfg" || true
cat >> "$dir/springsettings.cfg" <<CFG
Fullscreen = 0
WindowBorderless = 0
XResolutionWindowed = ${WIDTH:-1600}
YResolutionWindowed = ${HEIGHT:-900}
WindowPosX = 0
WindowPosY = 0
snd_volmaster = 0
CFG

cd "$dir"
SPRING_DATADIR="$zk" timeout "$limit" stdbuf -oL -eL "$engine" --only-local --config "$dir/springsettings.cfg" --write-dir "$dir" "$replay" > "$out/infolog.txt" 2>&1 || true
# Name the screenshots by the game frame they were asked for at
mapfile -t frames < <(grep -a -o 'rc-screenshot,[0-9]*' "$out/infolog.txt" | cut -d, -f2)
i=0
for shot in $(ls "$dir"/screenshots/*.jpg 2>/dev/null | sort); do
	cp "$shot" "$out/f$(printf %06d "${frames[$i]:-$i}").jpg"
	i=$((i + 1))
done
echo "$i screenshots in $out"
