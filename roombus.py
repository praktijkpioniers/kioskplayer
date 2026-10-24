"""Room bus: the players of one room (a group) share state and events over the network.

Layers:
  Bus          publish(topic, payload) / subscribe(prefix, cb) / peers(); one envelope for every
               message (sender, clock, signature), duplicates dropped, a hello heartbeat
  transports   where a message is sent; several at once, the bus doesn't care which one delivers:
                 "udp-broadcast"                    the local subnet (255.255.255.255)
                 {"udp-multicast": "239.255.47.80"} a multicast group (TTL 1)
                 {"udp-peers": ["host", "host:port", "100.x.y.z"]}   unicast to a list (other
                                                    subnets, a tailnet, several instances on one box)
               all UDP transports share one socket on the bus port, so receiving is the same for all
  SharedState  a small key → value map that every player keeps a copy of; the newest write wins
               and it is re-announced periodically, so lost packets and rebooted players catch up

Nothing here is reliable on purpose (WiFi broadcast is not acknowledged): state is idempotent and
repeated, events carry a time far enough ahead. The clock is hybrid: wall-clock milliseconds
(players are NTP-synced) but never lower than anything seen, so the order stays right.

Try it:  python3 roombus.py listen [--group g] [--port 47800] [--peers h1,h2]
         python3 roombus.py set lang de [--group g] ...
"""

from __future__ import annotations

import collections
import hashlib
import hmac
import json
import os
import random
import socket
import struct
import threading
import time
from pathlib import Path
from typing import Any, Callable, Optional

PROTO = 1
MAGIC = b"RB1 "
DEFAULT_PORT = 47800
MAX_PACKET = 1400


def _log(msg: str) -> None:
    print(f"[roombus] {msg}", flush=True)


# ── transports ───────────────────────────────────────────────────────────────

class Transport:
    """Sends packets somewhere; receiving happens on the bus socket."""
    name = "?"

    def setup(self, sock: socket.socket) -> None:
        pass

    def send(self, sock: socket.socket, data: bytes) -> None:
        raise NotImplementedError


class UdpBroadcast(Transport):
    name = "udp-broadcast"

    def __init__(self, port: int, addr: str = "255.255.255.255"):
        self.dest = (addr, port)

    def send(self, sock, data):
        sock.sendto(data, self.dest)


class UdpMulticast(Transport):
    name = "udp-multicast"

    def __init__(self, port: int, group: str = "239.255.47.80", ttl: int = 1):
        self.group, self.port, self.ttl = group, port, ttl

    def setup(self, sock):
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, self.ttl)
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_LOOP, 1)
        mreq = struct.pack("4s4s", socket.inet_aton(self.group), socket.inet_aton("0.0.0.0"))
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)

    def send(self, sock, data):
        sock.sendto(data, (self.group, self.port))


class UdpPeers(Transport):
    """Unicast to a list of "host" / "host:port"; names are resolved again now and then (DHCP)."""
    name = "udp-peers"
    RESOLVE_S = 60.0

    def __init__(self, port: int, peers: list[str]):
        self.targets: list[tuple[str, int]] = []
        for p in peers:
            host, _, prt = str(p).rpartition(":") if ":" in str(p) else (str(p), "", "")
            self.targets.append((host, int(prt)) if prt else (str(p), port))
        self._cache: dict[tuple[str, int], tuple[float, Optional[tuple[str, int]]]] = {}

    def _resolve(self, target):
        now = time.monotonic()
        hit = self._cache.get(target)
        if hit and now - hit[0] < self.RESOLVE_S:
            return hit[1]
        try:
            ai = socket.getaddrinfo(target[0], target[1], socket.AF_INET, socket.SOCK_DGRAM)
            addr = ai[0][4] if ai else None
        except OSError:
            addr = None
        self._cache[target] = (now, addr)
        return addr

    def send(self, sock, data):
        for t in self.targets:
            addr = self._resolve(t)
            if addr:
                try:
                    sock.sendto(data, addr)
                except OSError:
                    pass


def make_transports(specs: list[Any], port: int) -> list[Transport]:
    out: list[Transport] = []
    for spec in specs or []:
        kind, arg = (spec, None) if isinstance(spec, str) else next(iter(dict(spec).items()), (None, None))
        if kind == "udp-broadcast":
            out.append(UdpBroadcast(port, arg or "255.255.255.255"))
        elif kind == "udp-multicast":
            out.append(UdpMulticast(port, arg or "239.255.47.80"))
        elif kind == "udp-peers":
            out.append(UdpPeers(port, list(arg or [])))
        else:
            _log(f"unknown transport {spec!r}, skipped")
    return out


# ── the bus ──────────────────────────────────────────────────────────────────

class Bus:
    HELLO_S = 2.0
    ALIVE_S = 7.0

    def __init__(self, group: str, node: str = "", port: int = DEFAULT_PORT,
                 transports: Optional[list[Any]] = None, key: Optional[bytes] = None,
                 info: Optional[dict] = None, loss: float = 0.0):
        self.group = group
        self.node = node or socket.gethostname()
        self.port = port
        self.key = key
        self.info = dict(info or {})
        self.loss = loss                                   # testing: drop this fraction of incoming
        self.transports = make_transports(transports if transports is not None else ["udp-broadcast"], port)
        self._boot = "%08x" % random.getrandbits(32)       # tells a restarted sender from its old self
        self._seq = 0
        self._clock = 0
        self._lock = threading.Lock()
        self._subs: list[tuple[str, Callable[[str, Any, dict], None]]] = []
        self._seen: collections.deque = collections.deque(maxlen=4096)
        self._seen_set: set = set()
        self._peers: dict[str, dict] = {}
        self._sock: Optional[socket.socket] = None
        self._stop = threading.Event()

    # clock: wall-clock ms, but monotonic and never behind anything seen
    def tick(self, seen: int = 0) -> int:
        with self._lock:
            self._clock = max(self._clock + 1, int(time.time() * 1000), seen + 1 if seen else 0)
            return self._clock

    def _observe(self, c: int) -> None:
        with self._lock:
            if c > self._clock:
                self._clock = c

    def start(self) -> "Bus":
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        if hasattr(socket, "SO_REUSEPORT"):
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        s.bind(("0.0.0.0", self.port))
        for t in self.transports:
            try:
                t.setup(s)
            except OSError as e:
                _log(f"{t.name}: setup failed: {e}")
        self._sock = s
        threading.Thread(target=self._recv_loop, daemon=True, name="roombus-recv").start()
        threading.Thread(target=self._hello_loop, daemon=True, name="roombus-hello").start()
        _log(f"node {self.node} in group {self.group!r} on port {self.port} via "
             + ", ".join(t.name for t in self.transports))
        return self

    def stop(self) -> None:
        self._stop.set()
        if self._sock:
            try:
                self._sock.close()
            except OSError:
                pass

    def subscribe(self, prefix: str, cb: Callable[[str, Any, dict], None]) -> None:
        """cb(topic, payload, envelope) for every message whose topic starts with prefix."""
        self._subs.append((prefix, cb))

    def publish(self, topic: str, payload: Any) -> bool:
        with self._lock:
            self._seq += 1
            seq = self._seq
        env = {"v": PROTO, "g": self.group, "n": self.node, "b": self._boot, "q": seq,
               "c": self.tick(), "t": topic, "p": payload}
        data = self._encode(env)
        if len(data) > MAX_PACKET:
            _log(f"{topic}: {len(data)} bytes is too big, not sent")
            return False
        for t in self.transports:
            try:
                t.send(self._sock, data)
            except OSError:
                pass        # no route right now (WiFi down): the next announce tries again
        return True

    def peers(self) -> dict[str, dict]:
        """node → {"addr", "last", "info", "alive"} for everyone heard from."""
        now = time.monotonic()
        return {n: dict(p, alive=now - p["last"] < self.ALIVE_S) for n, p in self._peers.items()}

    # ── wire format ──
    def _sign(self, body: bytes) -> str:
        return hmac.new(self.key, body, hashlib.sha256).hexdigest()[:32] if self.key else ""

    def _encode(self, env: dict) -> bytes:
        body = json.dumps(env, separators=(",", ":"), sort_keys=True).encode()
        return MAGIC + self._sign(body).encode() + b" " + body

    def _decode(self, data: bytes) -> Optional[dict]:
        if not data.startswith(MAGIC):
            return None
        sig, _, body = data[len(MAGIC):].partition(b" ")
        if self.key and not hmac.compare_digest(sig.decode("ascii", "replace"), self._sign(body)):
            return None
        try:
            env = json.loads(body)
        except ValueError:
            return None
        if not isinstance(env, dict) or env.get("v") != PROTO or env.get("g") != self.group:
            return None
        return env

    def _recv_loop(self) -> None:
        while not self._stop.is_set():
            try:
                data, addr = self._sock.recvfrom(65535)
            except OSError:
                if self._stop.is_set():
                    return
                time.sleep(0.1)
                continue
            if self.loss and random.random() < self.loss:
                continue
            env = self._decode(data)
            if not env or env.get("n") == self.node:
                continue
            mid = (env.get("n"), env.get("b"), env.get("q"))
            if mid in self._seen_set:
                continue                  # the same message over another transport
            if len(self._seen) == self._seen.maxlen:
                self._seen_set.discard(self._seen[0])
            self._seen.append(mid)
            self._seen_set.add(mid)
            self._observe(int(env.get("c") or 0))
            peer = self._peers.setdefault(env["n"], {"info": {}})
            peer["addr"], peer["last"] = addr[0], time.monotonic()
            topic = str(env.get("t") or "")
            if topic == "bus/hello" and isinstance(env.get("p"), dict):
                peer["info"] = env["p"]
            for prefix, cb in list(self._subs):
                if topic.startswith(prefix):
                    try:
                        cb(topic, env.get("p"), env)
                    except Exception as e:
                        _log(f"subscriber for {prefix!r} failed: {e}")

    def _hello_loop(self) -> None:
        while not self._stop.wait(self.HELLO_S * random.uniform(0.8, 1.2)):
            self.publish("bus/hello", self.info)


# ── shared state ─────────────────────────────────────────────────────────────

class SharedState:
    """key → value, the same on every player in the group; the newest write wins.

    Each entry remembers its clock, writer and wall time; the whole map is re-announced every
    announce_s (and at once on a change). on_change(key, value, entry) runs for local and
    remote changes that win.
    """

    def __init__(self, bus: Bus, topic: str = "room/state", announce_s: float = 2.0,
                 on_change: Optional[Callable[[str, Any, dict], None]] = None):
        self.bus, self.topic, self.announce_s = bus, topic, announce_s
        self.on_change = on_change
        self._lock = threading.Lock()
        self._entries: dict[str, dict] = {}
        bus.subscribe(topic, self._on_msg)
        self._stop = threading.Event()
        threading.Thread(target=self._announce_loop, daemon=True, name="roombus-state").start()

    def get(self, key: str, default: Any = None) -> Any:
        e = self._entries.get(key)
        return e["v"] if e else default

    def entry(self, key: str) -> Optional[dict]:
        e = self._entries.get(key)
        return dict(e) if e else None

    def items(self) -> dict[str, dict]:
        with self._lock:
            return {k: dict(e) for k, e in self._entries.items()}

    def set(self, key: str, value: Any, **meta: Any) -> dict:
        e = {"v": value, "c": self.bus.tick(), "n": self.bus.node, "ts": time.time(), **meta}
        with self._lock:
            self._entries[key] = e
        self._changed(key, e)
        self._announce()
        return e

    @staticmethod
    def _newer(a: dict, b: Optional[dict]) -> bool:
        return b is None or (a.get("c", 0), str(a.get("n"))) > (b.get("c", 0), str(b.get("n")))

    def _on_msg(self, topic, payload, env) -> None:
        if not isinstance(payload, dict):
            return
        won = []
        with self._lock:
            for k, e in payload.items():
                if isinstance(e, dict) and "c" in e and self._newer(e, self._entries.get(k)):
                    self._entries[k] = e
                    won.append((k, e))
        for k, e in won:
            self.bus._observe(int(e.get("c") or 0))
            self._changed(k, e)

    def _changed(self, key, e) -> None:
        if self.on_change:
            try:
                self.on_change(key, e["v"], e)
            except Exception as ex:
                _log(f"on_change {key}: {ex}")

    def _announce(self) -> None:
        with self._lock:
            snap = dict(self._entries)
        if snap:
            self.bus.publish(self.topic, snap)

    def _announce_loop(self) -> None:
        while not self._stop.wait(self.announce_s * random.uniform(0.8, 1.2)):
            self._announce()

    def stop(self) -> None:
        self._stop.set()


# ── config ───────────────────────────────────────────────────────────────────

def bus_from_config(room: dict, info: Optional[dict] = None) -> Optional[Bus]:
    """The "room" section of config.json → a started Bus, or None when off.

    {"enabled": true, "group": "zaal2", "node": "", "port": 47800,
     "transports": ["udp-broadcast", {"udp-peers": ["100.92.49.115"]}],
     "key_file": "~/.config/kioskplayer/room.key"}
    """
    if not room or not room.get("enabled") or not room.get("group"):
        return None
    key = None
    kf = str(room.get("key_file") or "")
    if kf:
        try:
            key = Path(kf).expanduser().read_bytes().strip() or None
        except OSError as e:
            _log(f"key_file {kf}: {e}; messages go unsigned")
    return Bus(str(room["group"]), node=str(room.get("node") or ""),
               port=int(room.get("port") or DEFAULT_PORT),
               transports=room.get("transports") or ["udp-broadcast"], key=key, info=info).start()


def _main() -> None:
    import argparse
    ap = argparse.ArgumentParser(description="room bus test tool")
    ap.add_argument("cmd", choices=["listen", "set"])
    ap.add_argument("args", nargs="*")
    ap.add_argument("--group", default="test")
    ap.add_argument("--node", default="")
    ap.add_argument("--port", type=int, default=DEFAULT_PORT)
    ap.add_argument("--peers", default="", help="comma list for udp-peers")
    ap.add_argument("--multicast", default="", help="multicast group instead of broadcast")
    ap.add_argument("--key-file", default="")
    a = ap.parse_args()
    tr: list[Any] = [{"udp-multicast": a.multicast}] if a.multicast else ["udp-broadcast"]
    if a.peers:
        tr.append({"udp-peers": a.peers.split(",")})
    bus = bus_from_config({"enabled": True, "group": a.group, "node": a.node or f"{socket.gethostname()}-cli",
                           "port": a.port, "transports": tr, "key_file": a.key_file})
    state = SharedState(bus, on_change=lambda k, v, e: _log(f"state {k} = {v!r} (by {e.get('n')})"))
    bus.subscribe("", lambda t, p, e: t.startswith(("bus/", "room/state")) or _log(f"{e['n']}: {t} {p!r}"))
    if a.cmd == "set":
        k, v = a.args[0], (a.args[1] if len(a.args) > 1 else None)
        time.sleep(2.5)                   # hear the others first
        state.set(k, v)
        time.sleep(1.0)
        return
    last = 0.0
    while True:
        time.sleep(1)
        if time.monotonic() - last > 10:
            last = time.monotonic()
            _log("peers: " + (", ".join(f"{n}@{p['addr']}{'' if p['alive'] else ' (gone)'}"
                                         for n, p in bus.peers().items()) or "none"))


if __name__ == "__main__":
    _main()
