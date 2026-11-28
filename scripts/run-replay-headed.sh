#!/usr/bin/env bash
# Play a replay through the widget with the full engine in a window, at normal speed, taking a
# screenshot every few game seconds (see rc_screenshots.lua), so placement and framing can be looked
# at afterwards. Like run-replay.sh, your own settings and infolog are untouched.
#
#   run-replay-headed.sh replay.sdfz out-dir [widget.lua] [max-seconds]
#
# out-dir gets infolog.txt and the screenshots, named by game frame. WIDTH and HEIGHT set the window.
# The window is also recorded at FPS frames a second (default 30) to VIDEO_DIR (default
# ~/Downloads/replaycam), as <date>_<map>_<VIDEO_NAME>.mp4; VIDEO_NAME defaults to the name of
# out-dir. VIDEO=0 skips it. QUANT sets the x264 quality: lower is better and bigger (default 34).
# SYNC=1 draws the game frame in the bottom left corner (rc_frameclock.lua), for stack-videos.py.
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
[ "${SYNC:-0}" = 0 ] || cp "$here/rc_frameclock.lua" "$dir/LuaUI/Widgets/"
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
# X11 (XWayland under Wayland), so the window can be recorded without asking
SDL_VIDEODRIVER=x11 SPRING_DATADIR="$zk" timeout "$limit" stdbuf -oL -eL "$engine" --only-local --config "$dir/springsettings.cfg" --write-dir "$dir" "$replay" > "$out/infolog.txt" 2>&1 &
engine_pid=$!

video=
if [ "${VIDEO:-1}" != 0 ] && command -v gst-launch-1.0 > /dev/null; then
	video_dir=${VIDEO_DIR:-$HOME/Downloads/replaycam}
	mkdir -p "$video_dir"
	# Replays are named <date>_<time>_<map>_<engine version>.sdfz
	map=$(basename "$replay" .sdfz | cut -d_ -f3 | tr 'A-Z ' 'a-z-')
	stem="$video_dir/$(date +%F)_${map}_${VIDEO_NAME:-$(basename "$out")}"
	video="$stem.mp4"
	n=2
	while [ -e "$video" ]; do video="$stem-$n.mp4"; n=$((n + 1)); done
	# The engine's window, once it has one
	xid=
	for _ in $(seq 120); do
		xid=$(xwininfo -root -tree 2>/dev/null | grep -i '("spring"' | grep -E " ${WIDTH:-1600}x${HEIGHT:-900}\+" | awk '{print $1}' | head -1 || true)
		[ -n "$xid" ] || ! kill -0 "$engine_pid" 2>/dev/null && break
		sleep 0.5
	done
	if [ -n "$xid" ]; then
		# Matroska survives the window going away mid-frame; it is turned into mp4 afterwards
		# Frames stamped as they are grabbed, then dropped or repeated to make FPS a second. No B-frames,
		# which matroska keeps no decode times for, so the mp4 would come out too long.
		gst-launch-1.0 -q -e ximagesrc xid="$xid" use-damage=false show-pointer=false do-timestamp=true \
			! videorate ! video/x-raw,framerate=${FPS:-30}/1 ! videoconvert ! video/x-raw,format=I420 \
			! x264enc speed-preset=veryfast pass=qual quantizer=${QUANT:-34} key-int-max=$((${FPS:-30} * 5)) bframes=0 \
			! h264parse ! matroskamux ! filesink location="$dir/video.mkv" > "$dir/video.log" 2>&1 &
		recorder_pid=$!
	else
		echo "No engine window found to record"
		video=
	fi
fi

wait "$engine_pid" || true
if [ -n "$video" ]; then
	kill -INT "$recorder_pid" 2>/dev/null || true
	wait "$recorder_pid" || true
	if gst-launch-1.0 -q filesrc location="$dir/video.mkv" ! matroskademux ! h264parse ! mp4mux ! filesink location="$video" > /dev/null 2>&1; then
		echo "Video: $video"
	else
		video="${video%.mp4}.mkv"
		cp "$dir/video.mkv" "$video" && echo "Video: $video"
	fi
fi
# Name the screenshots by the game frame they were asked for at
mapfile -t frames < <(grep -a -o 'rc-screenshot,[0-9]*' "$out/infolog.txt" | cut -d, -f2)
i=0
for shot in $(ls "$dir"/screenshots/*.jpg 2>/dev/null | sort); do
	cp "$shot" "$out/f$(printf %06d "${frames[$i]:-$i}").jpg"
	i=$((i + 1))
done
echo "$i screenshots in $out"
