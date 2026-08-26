#!/usr/bin/env python3
"""
Terminal end-to-end test: drive a real Kitty and assert on what it actually holds.

Sits between the unit tests (which check the bytes md-render emits) and the
visual regression tests (which compare pixels). The trick that makes this layer
cheap is that `kitty @ get-text --ansi` round-trips OSC 66 verbatim:

    ESC ] 66 ; s=2 ; Short Heading ESC \\

So "is this heading drawn at double size" is answerable as an exact string
match, with no screenshot, no SSIM, and none of the font or timing sensitivity
that comes with comparing images.

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

# nf-md-format_header_1 .. _3. Kitty gives a scaled run exactly `scale` cells
# per source cell while reporting these as one cell wide, so an icon inside a
# run gets clipped and renders as a bare "H". They must stay out of the payload.
HEADING_ICONS = ["\U000f026b", "\U000f026c", "\U000f026d"]

OSC66 = re.compile(rb"\x1b\]66;([^;]*);(.*?)(?:\x1b\\|\x07)", re.S)

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

        # Every run must be s=2: nothing else is supposed to emit OSC 66.
        others = sorted({m for m, _ in runs if m != "s=2"})
        if others:
            bad("every scaled run is s=2", f"also saw {others}")
        else:
            ok("every scaled run is s=2")

        # h1 and h2 scale.
        for want in ("Short Heading", "Second Level"):
            if any(want == t for t in texts):
                ok(f"{want!r} is scaled")
            else:
                bad(f"{want!r} is scaled", f"payloads: {texts}")

        # h3 never scales.
        if any("Third Level" in t for t in texts):
            bad("h3 is not scaled", f"payloads: {texts}")
        else:
            ok("h3 is not scaled")

        # A long CJK heading wraps into several scaled blocks instead of
        # falling back to plain size.
        cjk = [t for t in texts if "あいうえお" in t or "まみむめも" in t]
        if len(cjk) >= 2:
            ok(f"long CJK heading wrapped into {len(cjk)} scaled blocks")
        else:
            bad("long CJK heading wraps into >= 2 scaled blocks", f"got {cjk}")

        # The regression that shipped once: the level icon inside a scaled run
        # is clipped by Kitty and renders as a bare "H".
        leaked = [t for t in texts if any(icon in t for icon in HEADING_ICONS)]
        if leaked:
            bad("the level icon stays out of scaled runs", f"leaked into {leaked}")
        else:
            ok("the level icon stays out of scaled runs")

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
