# Tests

## Overview

| Layer | What | Where | How |
|-------|------|-------|-----|
| 1. Unit tests | Escape sequence verification | CI (push/PR) | `nvim --headless -l tests/image_test.lua` |
| 2. PTY integration | E2E protocol output via pty | CI (push/PR) | `nvim --headless -l tests/pty_image_test.lua` |
| 3. Visual regression | Screenshot comparison across terminals | Local only | `./tests/run_visual_test.sh` |

## Running all CI tests locally

```bash
for f in tests/*_test.lua; do
  echo "=== $f ==="
  nvim --headless -u NONE --noplugin -l "$f"
done
```

## Layer 1: Unit tests

Mock-based tests that verify Kitty Graphics Protocol escape sequences without requiring a real terminal.

- `image_test.lua` -- `transmit_image`, `put_image`, crop parameters, delete commands, batch mode, terminal detection
- `tty_test.lua` -- TTY discovery (isatty, ttyname, socket peer)
- `link_types_test.lua` -- Link type distinction (external, anchor, Obsidian)
- `markdown_checkbox_test.lua` -- Checkbox rendering
- `html_table_test.lua` -- HTML table parsing

The image module exposes test hooks (`_test_write`, `_test_tty_path`, `_set_kitty_supported`, `_reset_image_id`) to allow escape sequence capture without terminal I/O.

## Layer 2: PTY integration tests

`pty_image_test.lua` launches Neovim inside a real pty (via `pty_capture.py`) with `TERM_PROGRAM=WezTerm`, captures raw terminal output, and parses Kitty Graphics Protocol APC sequences to verify:

- Transmit (`a=t`) sequences are emitted with correct format
- Delete (`a=d`) sequences use correct target specifiers
- Image IDs are consistent between transmit and delete

Requires Python 3 (uses the `pty` module).

## Layer 3: Visual regression tests

Screenshot-based tests that launch real terminal emulators and compare rendered output against reference images.

### Requirements

- macOS (uses `screencapture` and Quartz for window capture)
- At least one of: WezTerm, Kitty, Ghostty
- ImageMagick (`magick`) for SSIM comparison
- Screen Recording permission granted to the terminal running the script

### Usage

```bash
# First time: capture screenshots and save as reference
./tests/run_visual_test.sh --update

# After changes: capture and compare against reference (SSIM threshold: 0.95)
./tests/run_visual_test.sh

# Compare only (skip capture, use existing screenshots)
./tests/run_visual_test.sh --compare
```

### When to run

- After changing image display logic (`image.lua`, `display_utils.lua`)
- After changing layout/rendering (`content_builder.lua`)
- Before releases

### When to update reference images

```bash
./tests/run_visual_test.sh --update
```

Run this after intentional visual changes (new features, layout adjustments). Review the screenshots in `tests/screenshots/` before committing the updated references.

### Output

```
tests/screenshots/
  wezterm.png          # Latest capture
  kitty.png
  ghostty.png
  reference/           # Baseline images (tracked in git)
    wezterm.png
    kitty.png
    ghostty.png
  diff/                # SSIM diff images (gitignored)
    wezterm.png
    kitty.png
    ghostty.png
```

### Notes

- The test Markdown (`tests/fixtures/visual_test.md`) avoids using the same image file in multiple places to prevent WezTerm image ID conflicts.
- Animated GIF tests are included -- the animation timer affects image placement timing on WezTerm.
- `tests/capture_window.py` uses the macOS Quartz API to find window IDs by PID.

## Adding new tests

Follow the existing pattern:

```lua
-- tests/my_test.lua
-- Run: nvim --headless -u NONE --noplugin -l tests/my_test.lua

package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local pass_count = 0
local fail_count = 0

local function test(name, fn)
  local ok, err = pcall(fn)
  if not ok then
    fail_count = fail_count + 1
    print("ERROR: " .. name .. ": " .. tostring(err))
  end
end

-- ... tests ...

print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
```

Then add it to `.github/workflows/test.yml`.
