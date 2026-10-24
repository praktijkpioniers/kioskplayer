# kiosksim: try the seasonal themes on a desktop

A test mpv that behaves roughly like the kiosk: the idle logo, SPACE plays a video (themes in
video mode, a test subtitle on it) and returns to the logo at the end. Quit keys are disabled, so
a stray `q` over remote desktop doesn't close it. Theme preview keys work here (they don't on the
real players): 1–9 level, 0 calendar, v idle/video, t balloons, f web ×8, w new web, c send the cat, d the vampire next.

    tools/kiosksim/run.sh [video]          # starts mpv on :0 with the theme engine
    python3 tools/kiosksim/drive.py 4 idle # load level 4 (manifest built by themes.py)
    python3 tools/kiosksim/drive.py 8 video 2 5   # ... and screenshots after 2 s and 5 s more
    python3 tools/kiosksim/drive.py catsheet      # the cat in a row of fixed poses (catsheet.png)

Screenshots and the IPC socket go to `$KIOSKSIM_DIR` (default `/tmp/kiosksim`).
