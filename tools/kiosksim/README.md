# kiosksim: try the seasonal themes on a desktop

A test mpv that behaves roughly like the kiosk: the idle logo, SPACE plays a video (themes in
video mode, a test subtitle on it) and returns to the logo at the end. Quit keys are disabled, so
a stray `q` over remote desktop doesn't close it. Theme preview keys work here (they don't on the
real players): 1–9 level, 0 calendar, v idle/video, t balloons, f web ×8, w new web, c send the cat, d the vampire next, m the mummy next, z the zombie next, k the frankenstein next, s a skeleton next (in a room, walkers and the cat sent with a key head for the screen next door).

    tools/kiosksim/run.sh [video]          # starts mpv on :0 with the theme engine
    python3 tools/kiosksim/drive.py 4 idle # load level 4 (manifest built by themes.py)
    python3 tools/kiosksim/drive.py 8 video 2 5   # ... and screenshots after 2 s and 5 s more
    python3 tools/kiosksim/drive.py catsheet      # the cat in a row of fixed poses (catsheet.png)

Screenshots and the IPC socket go to `$KIOSKSIM_DIR` (default `/tmp/kiosksim`).

## Several screens: a room

    python3 tools/kiosksim/multi.py [n=4] [level=8] [--gap 16] [--cols 2]  # n windows, one room (2×2 fills the screen)
    #   screens all round the room: k0 → k1 → ... → k0 again; --rows: window rows apart, --no-wrap
    python3 tools/kiosksim/multi.py key 0 b                        # a flyer now on window 0
    python3 tools/kiosksim/multi.py shot /tmp/kiosksim/row.png     # the whole row in one picture

Each window is its own kiosk: mpv with the theme engine, a room-bus node (UDP on 127.0.0.1,
ports 47900+) and the player's ThemeRoom bridge, so a flyer leaving one window comes in on the
next. Logs and sockets in `/tmp/kiosksim/k<i>/`. Stop: Ctrl+C, or kill the `mpv --geometry` ones.
