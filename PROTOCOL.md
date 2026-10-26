# Room bus protocol (v1)

How the players in one room share state, and how a small device (an ESP32 language selector)
joins in. Implementation: `roombus.py`; self-test: `tools/roomsim.py`.

## Transport

- UDP, port **47800**, one datagram per message, at most 1400 bytes.
- Send to the broadcast address (`255.255.255.255` or the subnet's, e.g. `192.168.231.255`).
  Players may also be configured for multicast (`239.255.47.80`, TTL 1) or a unicast peer list
  (other subnets, a tailnet); they listen on the same port for all of them.
- Nothing is acknowledged. WiFi broadcast gets lost now and then, so **send commands 3× about
  300 ms apart** (duplicates are dropped by message id) and state is re-announced every ~2 s.

## Packet

```
RB1 <sig> <json>
```

- `RB1 ` — 4 bytes, the magic (with its space).
- `<sig>` — 32 lowercase hex chars: the first 16 bytes of HMAC-SHA256(key, `<json>` bytes exactly
  as sent). Empty when the room uses no key (then there are two spaces: `RB1  {...}`).
- `<json>` — an object, UTF-8, any key order and spacing (the signature covers the bytes as sent,
  so no canonical form is needed):

| field | required | meaning |
|---|---|---|
| `v` | yes | protocol version, `1` |
| `g` | yes | group (the room); `"default"` when not configured |
| `n` | yes | sender node name, unique in the room (e.g. `"esp-lang-1"`) |
| `q` | yes | sequence number, +1 per message (with `n`, `b` it identifies the message) |
| `t` | yes | topic |
| `p` | yes | payload (any JSON) |
| `b` | no  | boot id: random per start, so a restarted sender's low `q` isn't taken for duplicates. A device without one should start `q` at a random number |
| `c` | no  | the sender's clock (ms, ≥ wall clock); players send it, simple devices may leave it out |

Packets with another `v` or `g`, a bad signature, or the receiver's own `n` are ignored.

## Topics

| topic | from | payload |
|---|---|---|
| `bus/hello` | everyone, every ~2 s | `{"host": ..., ...}` free-form info; marks the sender alive (peer list) |
| `room/state` | players, every ~2 s and on change | `{key: {"v": value, "c": clock, "n": writer, "ts": unix time, ...meta}}` — the whole shared map; newest `(c, n)` per key wins |
| `room/set` | anyone, e.g. a selector | `{"key": k, "value": v, ...meta}` — every player hearing it writes `k = v` with its own clock (the device needs no clock or state) |

A selector only needs to **send** `room/set`. To show the current room language (an LED, a
display), it can also **listen** for `room/state` and read `p.lang.v`.

### Keys

| key | value |
|---|---|
| `lang` | the room's subtitle language: ISO 639-1 lowercase (`"nl"`, `"en"`, `"de"`, `"ko"`, ...) or `"off"`. Meta `src`: `"button"`, `"rfid"`, `"web"`, ... |
| `themes` | the room's theme settings, set from one player's web page (`themes_scope` `"room"`): an object with `themes_enabled`, `themes_disabled_types`, `themes_force`, `themes_level` (`"auto"` or 0..9), `themes_max_level`, `themes_date_override`, `themes_text`; each player with `themes_scope` `"room"` takes them over into its config.json. Meta `src`: `"web"` |

## Example (test vector)

Key `secret`, body (exactly these bytes):

```
{"v":1,"g":"default","n":"esp-lang-1","q":7,"t":"room/set","p":{"key":"lang","value":"de","src":"button"}}
```

Signature: `778b9951a00e0e95f625df08d05af1be`, so the datagram is

```
RB1 778b9951a00e0e95f625df08d05af1be {"v":1,"g":"default","n":"esp-lang-1","q":7,"t":"room/set","p":{"key":"lang","value":"de","src":"button"}}
```

## ESP32 sketch outline (Arduino)

```cpp
#include <WiFi.h>
#include <WiFiUdp.h>
#include "mbedtls/md.h"

WiFiUDP udp;
const char *KEY = "secret";                 // same as the players' key_file ("" = unsigned)
uint32_t seq = esp_random();                // random start: no boot id needed

void sendSet(const char *lang) {
  char body[200], pkt[260];
  snprintf(body, sizeof body,
    "{\"v\":1,\"g\":\"default\",\"n\":\"esp-lang-1\",\"q\":%lu,\"t\":\"room/set\","
    "\"p\":{\"key\":\"lang\",\"value\":\"%s\",\"src\":\"button\"}}", (unsigned long)++seq, lang);
  char sig[33] = "";
  if (*KEY) {
    uint8_t mac[32];
    mbedtls_md_hmac(mbedtls_md_info_from_type(MBEDTLS_MD_SHA256),
                    (const uint8_t *)KEY, strlen(KEY), (const uint8_t *)body, strlen(body), mac);
    for (int i = 0; i < 16; i++) sprintf(sig + 2 * i, "%02x", mac[i]);
  }
  int n = snprintf(pkt, sizeof pkt, "RB1 %s %s", sig, body);
  for (int r = 0; r < 3; r++) {             // the same packet 3×: same q, so it counts once
    udp.beginPacket(IPAddress(255, 255, 255, 255), 47800);
    udp.write((const uint8_t *)pkt, n);
    udp.endPacket();
    delay(300);
  }
}
```

## Later

Other carriers (BLE advertisements, MQTT, a relay) carry the same packet bytes; only the way
they travel differs.
