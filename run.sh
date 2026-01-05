#!/usr/bin/env bash
cd /home/fons/buttonplay || exit 1
exec python3 /home/fons/buttonplay/webcontrol.py &
exec python3 /home/fons/buttonplay/kioskplayer.py
