#!/usr/bin/env python3
"""
Capture terminal output from a Neovim headless session running in a pty.

Usage:
  python3 tests/pty_capture.py <lua_file> [timeout_secs]

Runs: nvim --headless -u NONE --noplugin -l <lua_file>
inside a pty with TERM_PROGRAM=WezTerm (to enable Kitty graphics detection),
captures all output, and writes raw bytes to stdout.

Exit code matches the child process exit code.
"""

import os
import pty
import select
import signal
import sys
import time

def main():
    if len(sys.argv) < 2:
        print("Usage: pty_capture.py <lua_file> [timeout_secs]", file=sys.stderr)
        sys.exit(2)

    lua_file = sys.argv[1]
    timeout = float(sys.argv[2]) if len(sys.argv) > 2 else 10.0

    # Set env vars to simulate a Kitty-protocol-capable terminal
    env = os.environ.copy()
    env["TERM_PROGRAM"] = "WezTerm"
    env["TERM"] = "xterm-256color"
    # Remove any existing terminal hints that might interfere
    for key in ["KITTY_WINDOW_ID", "GHOSTTY_RESOURCES_DIR", "WEZTERM_EXECUTABLE"]:
        env.pop(key, None)

    # Create pty and fork
    pid, master_fd = pty.fork()

    if pid == 0:
        # Child: exec nvim
        os.execvpe("nvim", [
            "nvim", "--headless", "-u", "NONE", "--noplugin", "-l", lua_file
        ], env)
        # Should not reach here
        sys.exit(127)

    # Parent: read output from master_fd
    output = bytearray()
    start = time.monotonic()
    exit_code = None

    while True:
        elapsed = time.monotonic() - start
        remaining = timeout - elapsed
        if remaining <= 0:
            # Timeout: kill child
            os.kill(pid, signal.SIGTERM)
            _, status = os.waitpid(pid, 0)
            exit_code = 124  # timeout
            break

        ready, _, _ = select.select([master_fd], [], [], min(remaining, 0.1))
        if ready:
            try:
                data = os.read(master_fd, 65536)
                if not data:
                    break
                output.extend(data)
            except OSError:
                break

        # Check if child has exited
        wpid, status = os.waitpid(pid, os.WNOHANG)
        if wpid != 0:
            # Drain remaining output
            while True:
                r, _, _ = select.select([master_fd], [], [], 0.1)
                if not r:
                    break
                try:
                    data = os.read(master_fd, 65536)
                    if not data:
                        break
                    output.extend(data)
                except OSError:
                    break
            if os.WIFEXITED(status):
                exit_code = os.WEXITSTATUS(status)
            else:
                exit_code = 1
            break

    os.close(master_fd)

    # Write raw output to stdout
    sys.stdout.buffer.write(output)
    sys.stdout.buffer.flush()

    sys.exit(exit_code or 0)


if __name__ == "__main__":
    main()
