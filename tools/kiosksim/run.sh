#!/bin/bash
# Test mpv with the theme engine, like the kiosk (see README.md). Usage: run.sh [video]
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
dir=${KIOSKSIM_DIR:-/tmp/kiosksim}
mkdir -p "$dir"
rm -f "$dir/mpv.sock"
video=${1:-$HOME/projects/Videos/Waterlinie museum TRAILER.mp4}
python3 "$here/testsubs.py" "$dir/test.srt"
subs="$dir/test.srt"          # the video's own subtitles when there are (name.nl.srt, name.srt)
for s in "${video%.*}.nl.srt" "${video%.*}.srt"; do [ -f "$s" ] && { subs=$s; break; }; done
export DISPLAY=${DISPLAY:-:0}
[ -z "$XAUTHORITY" ] && [ -f /run/user/$(id -u)/gdm/Xauthority ] && export XAUTHORITY=/run/user/$(id -u)/gdm/Xauthority
# KIOSKSIM_GEOMETRY=WxH+X+Y: a window instead of full screen (several kiosks side by side, multi.py)
if [ -n "$KIOSKSIM_GEOMETRY" ]; then screen="--geometry=$KIOSKSIM_GEOMETRY --title=${KIOSKSIM_TITLE:-kiosksim}"; else screen=--fs; fi
exec mpv $screen --no-border --force-window=yes --vo=gpu --hwdec=no --no-osc --idle=yes \
    --image-display-duration=inf --loop-file=inf --keep-open=no --cursor-autohide=always \
    --input-conf="$here/input.conf" --input-ipc-server="$dir/mpv.sock" --log-file="$dir/mpv.log" \
    --screenshot-format=png --screenshot-directory="$dir" \
    --script="$repo/themes/engine.lua" --script="$here/sim.lua" \
    --script-opts-append="kiosk-video=$video" --script-opts-append="kiosk-subs=$subs" \
    --script-opts-append="kiosk-logo=$repo/images/logo1.png" --script-opts-append="kiosk-loop=${KIOSKSIM_LOOP:-no}" \
    "$repo/images/logo1.png"
