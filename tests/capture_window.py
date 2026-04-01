#!/usr/bin/env python3
"""
Capture a screenshot of a window owned by the given PID.

Usage: capture_window.py <pid> <output.png>

Uses macOS Quartz (CoreGraphics) to find the window and screencapture
to take the screenshot. Falls back to full-screen capture if the window
cannot be found.
"""

import subprocess
import sys
import time


def find_window_id(target_pid):
    """Find the CGWindowID for the largest window owned by target_pid."""
    try:
        import Quartz
    except ImportError:
        return None

    target_pid = int(target_pid)

    # CGWindowListCopyWindowInfo returns all on-screen windows
    window_list = Quartz.CGWindowListCopyWindowInfo(
        Quartz.kCGWindowListOptionOnScreenOnly | Quartz.kCGWindowListExcludeDesktopElements,
        Quartz.kCGNullWindowID,
    )

    best_id = None
    best_area = 0

    for win in window_list:
        pid = win.get(Quartz.kCGWindowOwnerPID, -1)
        if pid != target_pid:
            continue

        # Pick the largest window (by area) owned by this PID
        bounds = win.get(Quartz.kCGWindowBounds, {})
        w = bounds.get("Width", 0)
        h = bounds.get("Height", 0)
        area = w * h

        if area > best_area:
            best_area = area
            best_id = win.get(Quartz.kCGWindowNumber)

    return best_id


def main():
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <pid> <output.png>", file=sys.stderr)
        sys.exit(2)

    pid = int(sys.argv[1])
    output = sys.argv[2]

    # Retry a few times in case the window hasn't appeared yet
    window_id = None
    for attempt in range(10):
        window_id = find_window_id(pid)
        if window_id is not None:
            break
        time.sleep(0.5)

    if window_id is not None:
        # screencapture -l <CGWindowID> captures just that window
        result = subprocess.run(
            ["screencapture", "-l", str(window_id), "-o", "-x", output],
            capture_output=True,
        )
        if result.returncode == 0:
            print(f"Captured window {window_id} (pid {pid}) -> {output}")
            return
        else:
            print(
                f"screencapture failed for window {window_id}: {result.stderr.decode()}",
                file=sys.stderr,
            )

    # Fallback: full screen
    print(f"Warning: could not find window for PID {pid}, capturing full screen", file=sys.stderr)
    subprocess.run(["screencapture", "-x", output])


if __name__ == "__main__":
    main()
