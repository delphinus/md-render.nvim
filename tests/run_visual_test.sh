#!/bin/bash
#
# Visual regression test for md-render.nvim
#
# Launches each available terminal emulator, opens a markdown preview,
# captures a screenshot, and optionally compares with reference images.
#
# Usage:
#   ./tests/run_visual_test.sh              # Run tests and capture screenshots
#   ./tests/run_visual_test.sh --update     # Update reference images
#   ./tests/run_visual_test.sh --compare    # Compare only (no new captures)
#
# Requirements:
#   - macOS (uses screencapture + Quartz)
#   - At least one of: wezterm, kitty, ghostty
#   - ImageMagick (magick) for comparison

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCREENSHOT_DIR="$PLUGIN_ROOT/tests/screenshots"
REFERENCE_DIR="$PLUGIN_ROOT/tests/screenshots/reference"
DIFF_DIR="$PLUGIN_ROOT/tests/screenshots/diff"
SIGNAL_FILE="$(mktemp)"

MODE="${1:-capture}"  # capture, --update, --compare
SSIM_THRESHOLD="0.95"  # minimum acceptable similarity (0-1)

# Terminal window geometry (in cells)
WIN_COLS=120
WIN_ROWS=40

# ============================================================================
# Helpers
# ============================================================================

cleanup() {
  rm -f "$SIGNAL_FILE"
}
trap cleanup EXIT

log() {
  echo "[visual-test] $*"
}

err() {
  echo "[visual-test] FAIL: $*" >&2
}

ensure_dirs() {
  mkdir -p "$SCREENSHOT_DIR" "$REFERENCE_DIR" "$DIFF_DIR"
}

# Wait for the signal file to be written (indicates Neovim preview is ready)
wait_for_ready() {
  local timeout="${1:-20}"
  local elapsed=0
  while [ ! -s "$SIGNAL_FILE" ]; do
    sleep 0.5
    elapsed=$((elapsed + 1))
    if [ "$elapsed" -ge $((timeout * 2)) ]; then
      err "Timed out waiting for Neovim preview to become ready"
      return 1
    fi
  done
  # Extra wait for image rendering to settle.
  # WezTerm clears image placements on redraw!, so we need to wait
  # until the animation timer re-places all images after its last redraw.
  sleep 3
  return 0
}

# Capture screenshot of a window owned by the given PID (macOS, via Quartz)
capture_screenshot() {
  local output_path="$1"
  local term_pid="$2"

  if python3 "$SCRIPT_DIR/capture_window.py" "$term_pid" "$output_path" 2>/dev/null; then
    if [ -f "$output_path" ] && [ -s "$output_path" ]; then
      return 0
    fi
  fi

  # Fallback: try screencapture with accessibility permissions prompt
  log "Trying screencapture (may require screen recording permission)..."
  if screencapture -x "$output_path" 2>/dev/null; then
    if [ -f "$output_path" ] && [ -s "$output_path" ]; then
      return 0
    fi
  fi

  err "Could not capture screenshot. Grant screen recording permission in:"
  err "  System Settings > Privacy & Security > Screen Recording"
  return 1
}

# Compare two images using ImageMagick SSIM
compare_images() {
  local actual="$1"
  local reference="$2"
  local diff_output="$3"

  if [ ! -f "$reference" ]; then
    log "No reference image: $reference (run with --update to create)"
    return 2
  fi

  # Compare with SSIM; magick compare writes the metric to stderr
  local ssim
  ssim=$(magick compare -metric SSIM "$actual" "$reference" "$diff_output" 2>&1 || true)
  echo "$ssim"
}

# Kill a process tree (the terminal and its children)
kill_term() {
  local pid="$1"
  # Try graceful kill first, then force
  kill "$pid" 2>/dev/null || true
  sleep 1
  kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

# ============================================================================
# Terminal launchers
# ============================================================================

run_wezterm() {
  log "Testing WezTerm..."
  rm -f "$SIGNAL_FILE"
  : > "$SIGNAL_FILE"  # Ensure it exists but is empty

  VISUAL_TEST_SIGNAL="$SIGNAL_FILE" wezterm start \
    --always-new-process \
    --cwd "$PLUGIN_ROOT" \
    -- nvim -u "$PLUGIN_ROOT/tests/visual_test_init.lua" &
  local term_pid=$!

  # WezTerm may re-exec, so find the actual GUI process
  sleep 2
  local gui_pid
  gui_pid=$(pgrep -f "wezterm-gui" | head -1 || echo "$term_pid")

  if wait_for_ready 20; then
    capture_screenshot "$SCREENSHOT_DIR/wezterm.png" "$gui_pid"
    log "WezTerm screenshot saved: $SCREENSHOT_DIR/wezterm.png"
  else
    err "WezTerm test timed out"
  fi

  kill_term "$term_pid"
  # Also kill the GUI process if different
  [ "$gui_pid" != "$term_pid" ] && kill_term "$gui_pid"
}

run_kitty() {
  log "Testing Kitty..."
  rm -f "$SIGNAL_FILE"
  : > "$SIGNAL_FILE"

  VISUAL_TEST_SIGNAL="$SIGNAL_FILE" kitty \
    --override "initial_window_width=${WIN_COLS}c" \
    --override "initial_window_height=${WIN_ROWS}c" \
    --override "allow_remote_control=yes" \
    --directory "$PLUGIN_ROOT" \
    nvim -u "$PLUGIN_ROOT/tests/visual_test_init.lua" &
  local term_pid=$!

  if wait_for_ready 20; then
    capture_screenshot "$SCREENSHOT_DIR/kitty.png" "$term_pid"
    log "Kitty screenshot saved: $SCREENSHOT_DIR/kitty.png"
  else
    err "Kitty test timed out"
  fi

  kill_term "$term_pid"
}

run_ghostty() {
  log "Testing Ghostty..."
  rm -f "$SIGNAL_FILE"
  : > "$SIGNAL_FILE"

  VISUAL_TEST_SIGNAL="$SIGNAL_FILE" ghostty \
    -e nvim -u "$PLUGIN_ROOT/tests/visual_test_init.lua" &
  local term_pid=$!

  if wait_for_ready 20; then
    capture_screenshot "$SCREENSHOT_DIR/ghostty.png" "$term_pid"
    log "Ghostty screenshot saved: $SCREENSHOT_DIR/ghostty.png"
  else
    err "Ghostty test timed out"
  fi

  kill_term "$term_pid"
}

# ============================================================================
# Main
# ============================================================================

ensure_dirs

# Detect available terminals
TERMINALS=()
command -v wezterm &>/dev/null && TERMINALS+=(wezterm)
command -v kitty   &>/dev/null && TERMINALS+=(kitty)
command -v ghostty &>/dev/null && TERMINALS+=(ghostty)

if [ ${#TERMINALS[@]} -eq 0 ]; then
  err "No supported terminal emulators found (need wezterm, kitty, or ghostty)"
  exit 1
fi

log "Found terminals: ${TERMINALS[*]}"

case "$MODE" in
  --compare)
    log "Compare-only mode"
    ;;
  --update)
    log "Update mode: new screenshots will become reference images"
    ;;
  *)
    log "Capture mode: taking screenshots"
    ;;
esac

# Run tests for each terminal (unless compare-only)
if [ "$MODE" != "--compare" ]; then
  for term in "${TERMINALS[@]}"; do
    case "$term" in
      wezterm) run_wezterm ;;
      kitty)   run_kitty   ;;
      ghostty) run_ghostty ;;
    esac
  done
fi

# Update reference images if requested
if [ "$MODE" = "--update" ]; then
  for term in "${TERMINALS[@]}"; do
    src="$SCREENSHOT_DIR/$term.png"
    if [ -f "$src" ]; then
      cp "$src" "$REFERENCE_DIR/$term.png"
      log "Updated reference: $REFERENCE_DIR/$term.png"
    fi
  done
  log "Reference images updated."
  exit 0
fi

# Compare with reference images
if command -v magick &>/dev/null; then
  pass=0
  fail_count=0
  skip=0

  for term in "${TERMINALS[@]}"; do
    actual="$SCREENSHOT_DIR/$term.png"
    ref="$REFERENCE_DIR/$term.png"
    diff_out="$DIFF_DIR/$term.png"

    if [ ! -f "$actual" ]; then
      log "SKIP $term: no screenshot captured"
      skip=$((skip + 1))
      continue
    fi

    if [ ! -f "$ref" ]; then
      log "SKIP $term: no reference image (run with --update first)"
      skip=$((skip + 1))
      continue
    fi

    ssim=$(compare_images "$actual" "$ref" "$diff_out")
    # Extract numeric SSIM (handle various ImageMagick output formats)
    ssim_num=$(echo "$ssim" | grep -oE '[0-9]+\.?[0-9]*' | head -1)

    if [ -z "$ssim_num" ]; then
      err "$term: could not compute SSIM (output: $ssim)"
      fail_count=$((fail_count + 1))
      continue
    fi

    # Compare SSIM against threshold
    above=$(python3 -c "print(1 if float('$ssim_num') >= $SSIM_THRESHOLD else 0)")
    if [ "$above" = "1" ]; then
      log "PASS $term: SSIM=$ssim_num (threshold=$SSIM_THRESHOLD)"
      pass=$((pass + 1))
    else
      err "$term: SSIM=$ssim_num < $SSIM_THRESHOLD — see diff: $diff_out"
      fail_count=$((fail_count + 1))
    fi
  done

  echo ""
  log "Results: $pass passed, $fail_count failed, $skip skipped"
  [ "$fail_count" -gt 0 ] && exit 1
else
  log "ImageMagick not found — screenshots captured but not compared"
  log "Install with: brew install imagemagick"
fi
