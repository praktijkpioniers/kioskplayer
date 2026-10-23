#!/usr/bin/env python3
"""Write a test subtitle file: a two-line subtitle every 3 seconds for 3 minutes."""
import sys


def ts(t: float) -> str:
    return "%02d:%02d:%02d,%03d" % (int(t) // 3600, int(t) // 60 % 60, int(t) % 60, int(t % 1 * 1000))


with open(sys.argv[1], "w") as f:
    for i in range(60):
        f.write(f"{i + 1}\n{ts(i * 3)} --> {ts(i * 3 + 2.8)}\n"
                f"Dit is een testondertitel, regel {i + 1}\nmet een tweede regel eronder\n\n")
