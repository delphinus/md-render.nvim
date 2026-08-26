#!/usr/bin/env python3
"""
Capture a screenshot of a single window.

Usage: capture_window.py <pid|--title SUBSTRING> <output.png>

Prefer --title. Terminals re-exec themselves, so the PID the shell knows is
often not the PID that owns the window: launching kitty and matching on `$!`
finds nothing. Matching the window title is reliable as long as the terminal
was launched with a distinctive one (`kitty --title MDRENDER_PROBE ...`).

This never falls back to a full-screen capture. An earlier version did, and
when PyObjC was missing it silently photographed the developer's entire
desktop and wrote it out as if it were a test artifact — wrong as a reference
image, and a privacy problem. A capture that cannot be scoped to one window is
a failure.

Requires:
  - PyObjC (`pip install pyobjc-framework-Quartz`) to resolve window ids
  - Screen Recording permission for whatever runs this (System Settings >
    Privacy & Security > Screen Recording). Without it `screencapture`
    fails or returns an empty image.
"""

import subprocess
import sys
import time


def load_quartz():
    try:
        import Quartz  # noqa: F401

        return Quartz
    except ImportError:
        sys.exit(
            "error: PyObjC is required to capture a single window.\n"
            "  pip install pyobjc-framework-Quartz\n"
            "Refusing to fall back to a full-screen capture."
        )


def on_screen_windows(Quartz):
    return Quartz.CGWindowListCopyWindowInfo(
        Quartz.kCGWindowListOptionOnScreenOnly | Quartz.kCGWindowListExcludeDesktopElements,
        Quartz.kCGNullWindowID,
    )


def area(win, Quartz):
    bounds = win.get(Quartz.kCGWindowBounds, {})
    return bounds.get("Width", 0) * bounds.get("Height", 0)


def find_by_pid(Quartz, target_pid):
    """Largest on-screen window owned by target_pid."""
    matches = [w for w in on_screen_windows(Quartz) if w.get(Quartz.kCGWindowOwnerPID, -1) == target_pid]
    return max(matches, key=lambda w: area(w, Quartz), default=None)


def find_by_title(Quartz, needle):
    """Largest on-screen window whose title contains needle."""
    matches = [w for w in on_screen_windows(Quartz) if needle in (w.get(Quartz.kCGWindowName) or "")]
    return max(matches, key=lambda w: area(w, Quartz), default=None)


def main():
    argv = sys.argv[1:]
    if len(argv) == 3 and argv[0] == "--title":
        finder, describe, output = (lambda q: find_by_title(q, argv[1])), f"title containing {argv[1]!r}", argv[2]
    elif len(argv) == 2:
        pid = int(argv[0])
        finder, describe, output = (lambda q: find_by_pid(q, pid)), f"pid {pid}", argv[1]
    else:
        sys.exit(f"Usage: {sys.argv[0]} <pid|--title SUBSTRING> <output.png>")

    Quartz = load_quartz()

    win = None
    for _ in range(10):  # the window may not be mapped yet
        win = finder(Quartz)
        if win is not None:
            break
        time.sleep(0.5)

    if win is None:
        sys.exit(f"error: no on-screen window matching {describe}")

    window_id = win.get(Quartz.kCGWindowNumber)
    result = subprocess.run(
        ["screencapture", "-l", str(window_id), "-o", "-x", output],
        capture_output=True,
    )
    if result.returncode != 0:
        sys.exit(
            f"error: screencapture failed for window {window_id}: {result.stderr.decode().strip()}\n"
            "Is Screen Recording permission granted?"
        )

    print(f"Captured window {window_id} ({describe}) -> {output}")


if __name__ == "__main__":
    main()
