"""Room bus self-test: N players on this machine (one port each, udp-peers over 127.0.0.1), with
packet loss, concurrent writes, a reboot and an intruder with the wrong key.

    python3 tools/roomsim.py [nodes] [loss]      e.g. 5 0.3
"""

import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import roombus  # noqa: E402

N = int(sys.argv[1]) if len(sys.argv) > 1 else 5
LOSS = float(sys.argv[2]) if len(sys.argv) > 2 else 0.3
BASE = 47900
KEY = b"test-key"


def node(i, key=KEY, loss=LOSS):
    ports = [f"127.0.0.1:{BASE + j}" for j in range(N) if j != i]
    bus = roombus.Bus("sim", node=f"kiosk{i}", port=BASE + i, transports=[{"udp-peers": ports}],
                      key=key, loss=loss).start()
    return bus, roombus.SharedState(bus, announce_s=0.5)


def agree(states, key, timeout=6.0):
    t0 = time.monotonic()
    while time.monotonic() - t0 < timeout:
        vals = {s.get(key) for s in states}
        if len(vals) == 1:
            return vals.pop(), time.monotonic() - t0
        time.sleep(0.05)
    return {s.bus.node: s.get(key) for s in states}, None


def check(name, ok, detail=""):
    print(f"{'ok  ' if ok else 'FAIL'} {name} {detail}")
    return ok


roombus.Bus.HELLO_S = 0.5
nodes = [node(i) for i in range(N)]
states = [s for _, s in nodes]
time.sleep(1.5)
good = True

# one writer
states[2].set("lang", "de")
v, t = agree(states, "lang")
good &= check("one write reaches everyone", v == "de", f"({t and round(t, 2)} s)")

# concurrent writes: all end on the same value
for i, s in enumerate(states):
    s.set("lang", ["ko", "fr", "en", "es", "nl"][i % 5])
v, t = agree(states, "lang")
good &= check("concurrent writes converge", t is not None, f"→ {v} ({t and round(t, 2)} s)")

# newest wins: a later write beats earlier ones
time.sleep(0.05)
states[0].set("lang", "it")
v, t = agree(states, "lang")
good &= check("a later write wins", v == "it", f"({t and round(t, 2)} s)")

# reboot: a fresh node with an empty state catches up
nodes[3][0].stop(); nodes[3][1].stop()
time.sleep(0.3)
nodes[3] = node(3)
states[3] = nodes[3][1]
v, t = agree(states, "lang")
good &= check("a rebooted player catches up", v == "it", f"({t and round(t, 2)} s)")

# a write right after a reboot, before hearing anyone, still wins (wall-clock based ordering)
nodes[4][0].stop(); nodes[4][1].stop()
time.sleep(0.3)
nodes[4] = node(4)
states[4] = nodes[4][1]
states[4].set("lang", "pt")
v, t = agree(states, "lang")
good &= check("a write straight after a reboot wins", v == "pt", f"({t and round(t, 2)} s)")

# intruder with a wrong key is ignored
bus_x = roombus.Bus("sim", node="intruder", port=BASE + N, key=b"wrong",
                    transports=[{"udp-peers": [f"127.0.0.1:{BASE + j}" for j in range(N)]}]).start()
roombus.SharedState(bus_x, announce_s=0.5).set("lang", "xx")
time.sleep(1.5)
good &= check("a wrong key is ignored", all(s.get("lang") == "pt" for s in states))

# a stateless selector (as an ESP32 would): room/set, no clock, no key handling beyond signing
sel = roombus.Bus("sim", node="selector", port=BASE + N + 1, key=KEY,
                  transports=[{"udp-peers": [f"127.0.0.1:{BASE + j}" for j in range(N)]}]).start()
for _ in range(3):
    sel.publish("room/set", {"key": "lang", "value": "ko", "src": "esp"})
    time.sleep(0.1)
v, t = agree(states, "lang")
good &= check("a selector's room/set reaches everyone", v == "ko", f"({t and round(t, 2)} s)")
good &= check("the selector shows as the source", states[1].entry("lang").get("by") == "selector")

peers = nodes[0][0].peers()
alive = sorted(n for n, p in peers.items() if p["alive"] and n.startswith("kiosk"))
good &= check("peers seen", len(alive) == N - 1, f"{alive}")
print("ALL OK" if good else "SOME FAILED")
sys.exit(0 if good else 1)
