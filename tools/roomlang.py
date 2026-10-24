"""Room language self-test: three players (kioskplayer's App with a fake mpv) and a selector on
the room bus over 127.0.0.1.

    python3 tools/roomlang.py
"""

import queue
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import kioskplayer as kp  # noqa: E402
import roombus  # noqa: E402

BASE = 48000


class FakeIpc:
    def __init__(self):
        self.shown = []

    def show_text(self, text, ms):
        self.shown.append(text)

    def get_property(self, *a, **k):
        return None

    def set_property(self, *a, **k):
        pass


class FakeRenderer:
    def __init__(self):
        self.ipc = FakeIpc()


def make(i, n=3):
    p = kp.App.__new__(kp.App)        # no mpv, no GPIO: only what the language logic uses
    p.renderer = FakeRenderer()
    p.cfg = {"play_mode": "VIDEO"}
    p.state = "IDLE"
    p.subtitle_lang_prefer = ["nl", "en", "de", "fr"]
    p.subtitle_remember_s, p.room_lang_remember_s, p.subtitle_scope = 120, 1200, "room"
    p._subtitle_pref_index, p._subtitle_pref_set_t, p._subtitle_changed_t = 0, None, None
    p._room_q = queue.Queue()
    p.room_bus = roombus.Bus("t", node=f"kiosk{i}", port=BASE + i,
                             transports=[{"udp-peers": [f"127.0.0.1:{BASE + j}" for j in range(n) if j != i]}]).start()
    p.room = roombus.SharedState(p.room_bus, on_change=lambda k, v, e, p=p: p._room_q.put((k, v, e)))
    return p


ps = [make(i) for i in range(3)]
sel = roombus.Bus("t", node="esp", port=BASE + 10,
                  transports=[{"udp-peers": [f"127.0.0.1:{BASE + j}" for j in range(3)]}]).start()
good = True


def pump():
    time.sleep(0.3)
    for p in ps:                      # what the main loop does
        while not p._room_q.empty():
            p._handle_room_change(*p._room_q.get())


def langs():
    return [p._preferred_language_active(time.time()) for p in ps]


def check(name, got, want):
    global good
    ok = got == want
    good &= ok
    print(f"{'ok  ' if ok else 'FAIL'} {name}: {got}")


ps[0]._handle_subtitle_press(time.time()); pump()
check("a press on screen 0 sets the room", langs(), ["nl"] * 3)
ps[1]._handle_subtitle_press(time.time()); pump()
check("a press elsewhere continues from the room language", langs(), ["en"] * 3)
sel.publish("room/set", {"key": "lang", "value": "fr", "src": "rfid"}); pump()
check("a selector sets the room", langs(), ["fr"] * 3)
check("one message on each other screen per change", ps[2].renderer.ipc.shown, ["Language: NL", "Language: EN", "Language: FR"])
sel.publish("room/set", {"key": "lang", "value": "ko", "src": "rfid"}); pump()
check("a language a screen doesn't offer is skipped there", langs(), ["fr"] * 3)
ps[2].subtitle_scope = "screen"
ps[0]._handle_subtitle_press(time.time()); pump()
check("a per-screen player keeps its own", langs(), ["off", "off", "fr"])
print("ALL OK" if good else "SOME FAILED")
sys.exit(0 if good else 1)
