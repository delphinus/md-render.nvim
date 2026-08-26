# Tests

## Overview

| Layer | What | Catches | Where | How |
|-------|------|---------|-------|-----|
| 1. Unit tests | The bytes md-render *emits* | Protocol regressions | CI (push/PR) | `make test` |
| 2. Media tools | The commands md-render *runs* | An external tool changing under us | CI (push/PR **and weekly**) | `nvim --headless -u NONE --noplugin -l tests/media_test.lua` |
| 3. Terminal | What the terminal actually *holds* | Scaled text drawn wrong, or not at all | CI (push/PR **and weekly**) | `tests/terminal_test.py` |
| 4. Visual regression | What the terminal actually *draws* | Clipped glyphs, images that never paint | Local only | `./tests/run_visual_test.sh` |

Layer 2 exists because of a silent breakage: FFmpeg 9 removed `-vsync`, frame extraction failed for every video and animated GIF, and nothing noticed — the emitted escape sequences were still correct and no commit had touched the code. The failure mode was the toolchain moving, so the test runs on a schedule, not just on push.

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

Tests monkey-patch `vim.api.nvim_ui_send` to capture the bytes the image module would emit (mirrors Neovim's own `test/functional/ui/img_spec.lua`). The image module also exposes `_set_kitty_supported` and `_reset_image_id` for state control.

## Layer 2: Media tool tests

`media_test.lua` runs the real external tools (ffmpeg, ffprobe, ImageMagick, sips) against the bundled assets in `assets/demo/` and asserts that frames and PNGs actually come out.

Two details make it meaningful rather than decorative:

- **It forces a cache miss.** Both the frame cache and the converted-PNG cache are keyed on a hash of the source path, so testing a bundled path directly would hit a cache from an earlier run and never invoke the tool. The test copies each asset to a unique temporary path first.
- **It refuses to pass by not testing.** A missing tool is reported as `skip` so contributors without ffmpeg can still run `make test`, but CI sets `MD_RENDER_REQUIRE_MEDIA_TOOLS=1`, which turns every skip into a failure.

The test prints the version of each tool it found; when the matrix goes red the first useful question is which toolchain it went red on.

### FFmpeg matrix

`.github/workflows/media.yml` runs the suite against FFmpeg 6.1, 7.1, 8.1, 9.0 and master, plus a weekly `schedule`.

Spanning majors is the point. Ubuntu 24.04 still ships FFmpeg 6.1, so a job that ran `apt-get install ffmpeg` would have stayed green through the entire `-vsync` incident. The 8.x/9.x/master entries point at BtbN's rolling `latest` release, so the scheduled run picks up new point releases and reports drift; 6.1 and 7.1 come from a pinned older autobuild, because BtbN drops EOL branches from `latest` while keeping the release assets reachable.

## Layer 3: Terminal tests

`terminal_test.py` launches a real Kitty (under `xvfb-run` when present), runs Neovim with the plugin, and asserts on what the terminal ended up holding.

The trick that makes this cheap is that `kitty @ get-text --ansi` **round-trips OSC 66 verbatim**:

```
ESC ] 66 ; s=2 ; Short Heading ESC \
```

So "is this heading drawn at double size" is an exact string match — no screenshot, no SSIM, and none of the font or timing sensitivity of comparing images. It asserts that `#`/`##` scale and `###` does not, that a long CJK heading wraps into several scaled blocks instead of falling back to plain size, that the level icon stays out of the payload (it gets clipped inside a scaled run), and that nothing is scaled when the feature is off.

`.github/workflows/terminal.yml` runs it against Kitty **0.40.0** (the version that introduced the protocol, so the floor this can work on) and **latest**, crossed with Neovim **v0.12.0** and **nightly**, plus a weekly schedule.

Ubuntu's own kitty package is 0.32 — below the 0.40 the protocol needs — so the workflow takes the release tarball. Kitty then needs its runtime dependencies installed by hand: `fontconfig` plus a font, and the X client libraries it `dlopen`s (`libxcursor1`, `libxrandr2`, `libxi6`, `libxinerama1`, `libxkbcommon-x11-0`). A missing one is a startup failure, not a link error — without libXcursor kitty dies with `Failed to dlopen .../kitty.glfw-x11.so`.

## Layer 4: Visual regression tests

Screenshot-based tests that launch real terminal emulators and compare rendered output against reference images.

### Requirements

- macOS (uses `screencapture` and Quartz for window capture)
- At least one of: WezTerm, Kitty, Ghostty
- ImageMagick (`magick`) for SSIM comparison
- **PyObjC**: `pip install pyobjc-framework-Quartz`. Without it the capture cannot be scoped to one window and the script aborts.
- **Screen Recording permission** for whatever runs the script (System Settings > Privacy & Security > Screen Recording)

This layer is a deliberate gate, not something to run on every save. Most questions people reach for a screenshot to answer are cheaper in layer 3: it opens GUI windows and takes over the screen while it runs, and a whole-window SSIM is sensitive to font, colorscheme and OS updates.

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
- `tests/capture_window.py` finds the window by **title**, not PID: terminals re-exec, so the PID the shell holds often does not own the window. `tests/visual_test_init.lua` sets the title from Neovim via `'title'` (OSC 2), which every supported terminal honours — unlike the per-terminal command line flags, which differ and do not all set the name macOS reports.
- The script **never falls back to a full-screen capture**. An earlier version did, and with PyObjC missing it silently photographed the whole desktop and wrote it out as a reference image.
- Much of what a screenshot is reached for can be answered without pixels: `kitty @ get-text` reports the actual cell grid, which is enough to check things like whether a heading occupies a two-row multicell group. Reserve this layer for questions that genuinely need pixels.

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

`make test` globs `tests/*_test.lua`, so a new file is picked up automatically — no workflow change needed.
