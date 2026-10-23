#!/bin/bash
# Test mpv with the theme engine, like the kiosk (see README.md). Usage: run.sh [video]
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
dir=${KIOSKSIM_DIR:-/tmp/kiosksim}
mkdir -p "$dir"
rm -f "$dir/mpv.sock"
video=${1:-$HOME/projects/Videos/Waterlinie museum TRAILER.mp4}
python3 "$here/testsubs.py" "$dir/test.srt"
export DISPLAY=${DISPLAY:-:0}
[ -z "$XAUTHORITY" ] && [ -f /run/user/$(id -u)/gdm/Xauthority ] && export XAUTHORITY=/run/user/$(id -u)/gdm/Xauthority
exec mpv --fs --no-border --force-window=yes --vo=gpu --hwdec=no --no-osc --idle=yes \
    --image-display-duration=inf --loop-file=inf --keep-open=no --cursor-autohide=always \
    --input-conf="$here/input.conf" --input-ipc-server="$dir/mpv.sock" --log-file="$dir/mpv.log" \
    --screenshot-format=png --screenshot-directory="$dir" \
    --script="$repo/themes/engine.lua" --script="$here/sim.lua" \
    --script-opts="kiosk-video=$video,kiosk-subs=$dir/test.srt,kiosk-logo=$repo/images/logo1.png" \
    "$repo/images/logo1.png"
