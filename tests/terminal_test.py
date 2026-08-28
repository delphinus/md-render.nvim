#!/usr/bin/env python3
"""
Terminal end-to-end test: drive a real Kitty and assert on what it actually holds.

Sits between the unit tests (which check the bytes md-render emits) and the
visual regression tests (which compare pixels). The trick that makes this layer
cheap is that `kitty @ get-text --ansi` round-trips OSC 66 verbatim:

    ESC ] 66 ; s=2 ; Level One Heading ESC \\
    ESC ] 66 ; s=2:n=3:d=4:w=6 ; Level Th ESC \\

So "is this heading drawn at 1.5x" is answerable as an exact string match, with
no screenshot, no SSIM, and none of the font or timing sensitivity that comes
with comparing images.

Usage:
    tests/terminal_test.py                 # auto-detect kitty, use xvfb if present
    tests/terminal_test.py --kitty /path/to/kitty

Exits non-zero on failure.
"""

import argparse
import os
import re
import shutil
import signal as signal_mod
import subprocess
import sys
import tempfile
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

# nf-md-format_header_1 .. _6. Kitty gives a scaled run exactly `s` cells per
# source cell while reporting these as one cell wide, so an icon sharing a run
# with the heading text gets clipped and renders as a bare "H". It goes out on
# its own instead, in a block `w=1` wide — which is the two cells `pad_icon`
# already reserves — so the glyph has the room it is actually drawn in.
HEADING_ICONS = [chr(cp) for cp in range(0xF026B, 0xF026B + 6)]

# The icon run's own scale. `n=1:d=s` cancels the cell scale exactly, so the
# glyph stays at plain size; `v` is what it is there for, aligning it with the
# heading text inside the same block.
ICON_SCALE = (2, 1, 2)

# Where a fractionally scaled run sits in its block: 0 top, 1 bottom, 2
# centered. Kitty ignores it when there is no fraction, which is why level 1's
# text run is exempt below.
VERTICAL_ALIGN = 2

OSC66 = re.compile(rb"\x1b\]66;([^;]*);(.*?)(?:\x1b\\|\x07)", re.S)

# Heading level → the scale md-render is supposed to send for it, as
# `(s, n, d)`. Level 1 scales by whole cells and needs no fraction; the rest
# shrink the font inside those cells with `n` / `d`, which means they also have
# to state a per-run width in `w`.
#
# Compared key by key rather than as a string: Kitty stores the metadata as
# parsed values and `get-text` re-emits them in its own order, so what comes
# back for `s=2:n=3:d=4:w=6` is `w=6:s=2:n=3:d=4`.
LEVEL_SCALE = {
    1: (2, None, None),
    2: (2, 7, 8),
    3: (2, 3, 4),
    4: (2, 7, 10),
    5: (2, 5, 8),
    6: (2, 7, 12),
}

# The text each level's heading carries in the fixture. A fractionally scaled
# heading goes out as several runs, so these are matched against the level's
# payloads joined back together rather than against a single run.
LEVEL_TEXT = {
    1: "Level One Heading",
    2: "Level Two Heading",
    3: "Level Three Heading",
    4: "Level Four Heading",
    5: "Level Five Heading",
    6: "Level Six Heading",
}


def parse_meta(meta):
    """`w=6:s=2:n=3:d=4` -> {'w': 6, 's': 2, 'n': 3, 'd': 4}."""
    out = {}
    for pair in meta.split(":"):
        key, _, value = pair.partition("=")
        if value.isdigit():
            out[key] = int(value)
    return out


def is_icon_run(meta):
    """True for the plain-size run a level icon goes out in."""
    kv = parse_meta(meta)
    return (kv.get("s"), kv.get("n"), kv.get("d")) == ICON_SCALE and kv.get("w") == 1


def level_of(meta):
    """Heading level a run's metadata belongs to, or None if unrecognised.

    Icon runs are not a level: they carry the glyph, not the heading text, and
    every level sends the same metadata for them.
    """
    if is_icon_run(meta):
        return None
    kv = parse_meta(meta)
    got = (kv.get("s"), kv.get("n"), kv.get("d"))
    for level, expected in LEVEL_SCALE.items():
        if got == expected:
            return level
    return None

passed = failed = 0


def ok(msg):
    global passed
    passed += 1
    print(f"  ok   {msg}")


def bad(msg, detail=None):
    global failed
    failed += 1
    print(f"  FAIL {msg}")
    if detail:
        print(f"       {detail}")


def run_kitty(kitty, enabled, workdir):
    """Launch kitty+nvim, wait for the signal, return (scaled_runs, diagnostics)."""
    # A socket per run. Sharing one path lets a query land on a previous
    # instance that has not finished dying, which reads as "scaled text is
    # still on screen after being disabled".
    sock = workdir / f"sock-{int(enabled)}"
    signal = workdir / f"ready-{int(enabled)}"
    diag = workdir / f"diag-{int(enabled)}"

    env = dict(
        os.environ,
        MD_RENDER_E2E_ENABLED="1" if enabled else "0",
        MD_RENDER_E2E_SIGNAL=str(signal),
        MD_RENDER_E2E_DIAG=str(diag),
        # Kitty needs a GL context; CI has no GPU.
        LIBGL_ALWAYS_SOFTWARE="1",
    )

    cmd = [
        kitty,
        "-o", "allow_remote_control=yes",
        # A window narrow enough makes the preview float narrow enough that the
        # minimum-width guard declines to scale anything, which would look like
        # a failure. Ask for room.
        "-o", "font_size=10",
        # And a window *short* enough scrolls the later headings out of the
        # float, which reads the same way: the placements are built and simply
        # never drawn. Kitty opens at 80x24 cells by default no matter how big
        # the display is, which fits four of the fixture's seven headings —
        # `placements=9 drawn=4` in the diagnostics below. Ask for the rows too.
        # `remember_window_size` has to go first: while it is on, which is the
        # default, kitty ignores both of these.
        "-o", "remember_window_size=no",
        "-o", "initial_window_width=120c",
        "-o", "initial_window_height=60c",
        "--listen-on", f"unix:{sock}",
        "--directory", str(REPO),
        "nvim", "--clean", "-u", str(REPO / "tests/text_size_e2e_init.lua"),
    ]
    if shutil.which("xvfb-run"):
        cmd = ["xvfb-run", "-a", "--server-args=-screen 0 2400x1400x24"] + cmd

    # Keep the terminal's own output: when kitty refuses to start (a missing
    # shared library, no fonts) it says so there, and discarding it turns a
    # one-line diagnosis into a blind hunt.
    termlog = workdir / f"kitty-{int(enabled)}.log"
    logf = termlog.open("wb")
    # New session so the whole tree can be signalled: under xvfb-run the
    # process here is the wrapper, and killing it leaves kitty running.
    proc = subprocess.Popen(cmd, stdout=logf, stderr=subprocess.STDOUT, env=env, start_new_session=True)
    try:
        deadline = time.time() + 90
        while time.time() < deadline and not signal.exists():
            if proc.poll() is not None:
                logf.close()
                raise RuntimeError(
                    f"kitty exited early with code {proc.returncode}:\n"
                    + (termlog.read_text(errors="replace").strip() or "(no output)")
                )
            time.sleep(0.5)
        if not signal.exists():
            logf.close()
            raise RuntimeError(
                "timed out waiting for the preview to settle:\n"
                + (termlog.read_text(errors="replace").strip() or "(no output)")
            )

        out = subprocess.run(
            [kitty, "@", "--to", f"unix:{sock}", "get-text", "--extent", "screen", "--ansi"],
            capture_output=True, check=True, env=env,
        ).stdout
    finally:
        if not logf.closed:
            logf.close()
        try:
            os.killpg(os.getpgid(proc.pid), signal_mod.SIGKILL)
        except (ProcessLookupError, PermissionError):
            proc.kill()
        proc.wait(timeout=10)
        # Do not let a slow teardown bleed into the next run.
        for _ in range(20):
            if not sock.exists():
                break
            time.sleep(0.25)

    runs = [(m.decode(), t.decode("utf-8", "replace")) for m, t in OSC66.findall(out)]
    return runs, (diag.read_text() if diag.exists() else "(no diagnostics)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--kitty", default=shutil.which("kitty"))
    args = ap.parse_args()

    if not args.kitty:
        sys.exit("error: kitty not found; pass --kitty")

    version = subprocess.run([args.kitty, "--version"], capture_output=True, text=True).stdout.strip()
    print(f"terminal_test environment:\n  {version}")
    print(f"  xvfb: {'yes' if shutil.which('xvfb-run') else 'no (running against the real display)'}\n")

    with tempfile.TemporaryDirectory() as td:
        workdir = Path(td)

        print("scaled headings ON:")
        runs, diag = run_kitty(args.kitty, True, workdir)
        print("".join(f"    {line}\n" for line in diag.strip().splitlines()), end="")

        if not runs:
            bad("kitty holds at least one scaled run", f"none found; diagnostics above")
        else:
            ok(f"kitty holds {len(runs)} scaled run(s)")

        texts = [t for _, t in runs]

        # Nothing else in the plugin emits OSC 66, so every run has to be one
        # of the six heading levels — and at the exact metadata for that level.
        unknown = sorted({m for m, _ in runs if level_of(m) is None and not is_icon_run(m)})
        if unknown:
            bad("every scaled run matches a heading level", f"also saw {unknown}")
        else:
            ok("every scaled run matches a heading level")

        # Every level reserves a block `s` rows tall while only level 1 fills
        # it, so anything with a fraction has to say where in that block it
        # sits. Level 1's text run is the exception: with no fraction Kitty
        # ignores `v`, so it is not sent.
        adrift = sorted(
            {m for m, _ in runs if parse_meta(m).get("n") and parse_meta(m).get("v") != VERTICAL_ALIGN}
        )
        if adrift:
            bad(f"every fractional run is aligned v={VERTICAL_ALIGN}", f"saw {adrift}")
        else:
            ok(f"every fractional run is aligned v={VERTICAL_ALIGN}")

        # `w` is capped at 7 by the protocol; past that Kitty is free to
        # truncate or resize the run.
        over = sorted({m for m, _ in runs if not 1 <= parse_meta(m).get("w", 1) <= 7})
        if over:
            bad("every run asks for 1..7 cells", f"saw {over}")
        else:
            ok("every run asks for 1..7 cells")

        # Each level's runs, joined back into the heading they came from.
        joined = {}
        for meta, text in runs:
            level = level_of(meta)
            if level:
                joined[level] = joined.get(level, "") + text

        for level, want in LEVEL_TEXT.items():
            got = joined.get(level, "")
            if want in got:
                ok(f"h{level} is scaled")
            else:
                bad(f"h{level} is scaled", f"level {level} payload: {got!r}")

        # A long CJK heading wraps into several scaled blocks instead of
        # falling back to plain size. Both ends have to survive: a heading that
        # only scaled as far as it happened to fit would keep the first.
        cjk = joined.get(2, "")
        if "あいうえお" in cjk and "まみむめも" in cjk:
            ok("long CJK heading is scaled end to end")
        else:
            bad("long CJK heading is scaled end to end", f"level 2 payload: {cjk!r}")

        # The regression that shipped once: a level icon sharing a run with the
        # heading text is clipped by Kitty and renders as a bare "H". It may
        # appear, but only alone and only in an icon run.
        shared = [
            t for m, t in runs
            if any(icon in t for icon in HEADING_ICONS) and not (is_icon_run(m) and t in HEADING_ICONS)
        ]
        if shared:
            bad("the level icon only ever goes out in a run of its own", f"saw {shared}")
        else:
            ok("the level icon only ever goes out in a run of its own")

        # And it does go out: without this the check above passes just as
        # happily on a build that stopped drawing icons altogether.
        seen_icons = {t for m, t in runs if is_icon_run(m)}
        missing = [icon for icon in HEADING_ICONS if icon not in seen_icons]
        if missing:
            bad("every level's icon is drawn", f"no run for {missing}")
        else:
            ok("every level's icon is drawn")

        print("\nscaled headings OFF:")
        runs_off, diag_off = run_kitty(args.kitty, False, workdir)
        print("".join(f"    {line}\n" for line in diag_off.strip().splitlines()), end="")
        if runs_off:
            bad("nothing is scaled when disabled", f"found {runs_off}")
        else:
            ok("nothing is scaled when disabled")

    print(f"\nterminal_test: {passed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
