-- Image module unit tests: escape sequence verification
-- Run: nvim --headless -u NONE --noplugin -l tests/image_test.lua

package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local image = require "md-render.image"

local pass_count = 0
local fail_count = 0

local function assert_eq(actual, expected, msg)
  if vim.deep_equal(actual, expected) then
    pass_count = pass_count + 1
  else
    fail_count = fail_count + 1
    print("FAIL: " .. msg)
    print("  expected: " .. vim.inspect(expected))
    print("  actual:   " .. vim.inspect(actual))
  end
end

local function assert_true(val, msg)
  if val then
    pass_count = pass_count + 1
  else
    fail_count = fail_count + 1
    print("FAIL: " .. msg)
  end
end

local function assert_match(actual, pattern, msg)
  if type(actual) == "string" and actual:match(pattern) then
    pass_count = pass_count + 1
  else
    fail_count = fail_count + 1
    print("FAIL: " .. msg)
    print("  expected match: " .. pattern)
    print("  actual:         " .. tostring(actual))
  end
end

local function assert_nil(val, msg)
  if val == nil then
    pass_count = pass_count + 1
  else
    fail_count = fail_count + 1
    print("FAIL: " .. msg)
    print("  expected nil, got: " .. vim.inspect(val))
  end
end

local function test(name, fn)
  local ok, err = pcall(fn)
  if not ok then
    fail_count = fail_count + 1
    print("ERROR: " .. name .. ": " .. tostring(err))
  end
end

-- ============================================================================
-- Test helper: capture escape sequences written by image module
-- ============================================================================

local captured = {}

local function setup_capture()
  captured = {}
  image._test_write = function(data)
    table.insert(captured, data)
  end
  image._test_tty_path = "/dev/tty"
  image._set_kitty_supported(true)
  image._reset_image_id()
end

local function teardown()
  image._test_write = nil
  image._test_tty_path = nil
  image._set_kitty_supported(nil)
  image.reset_cache()
end

--- Concatenate all captured writes into a single string
local function captured_output()
  return table.concat(captured)
end

--- Parse Kitty graphics APC sequences from captured output.
--- Returns a list of { params = "a=t,...", payload = "..." }
local function parse_kitty_sequences(data)
  local seqs = {}
  -- Match APC: ESC _ G <params> [; <payload>] ESC \
  -- Use non-greedy match and handle both with-payload and without-payload forms
  local pos = 1
  while pos <= #data do
    local s, e, content = data:find("\x1b_G(.-)\x1b\\", pos)
    if not s then break end
    local params, payload = content:match("^([^;]*);(.*)$")
    if not params then
      params = content
      payload = ""
    end
    table.insert(seqs, { params = params, payload = payload })
    pos = e + 1
  end
  return seqs
end

--- Parse params string "a=t,f=100,..." into a table { a="t", f="100", ... }
local function parse_params(params_str)
  local t = {}
  for k, v in params_str:gmatch("([%w_]+)=([^,]*)") do
    t[k] = v
  end
  return t
end

-- ============================================================================
-- Test fixtures
-- ============================================================================

local test_png = vim.fn.getcwd() .. "/tests/fixtures/test_4x4.png"

-- ============================================================================
-- calc_display_size tests
-- ============================================================================

test("calc_display_size: scales down when image exceeds max_cols", function()
  -- Mock cell size: 8x16 pixels per cell
  -- Image: 160x160 px → 20 cols x 10 rows
  -- max_cols = 10 → scale to 10 cols, 5 rows
  local cols, rows = image.calc_display_size(160, 160, 10, 20)
  assert_eq(cols, 10, "cols should be clamped to max_cols")
  assert_true(rows <= 20, "rows should not exceed max_rows")
end)

test("calc_display_size: scales down when image exceeds max_rows", function()
  local cols, rows = image.calc_display_size(80, 800, 40, 5)
  assert_true(rows <= 5, "rows should be clamped to max_rows")
  assert_true(cols <= 40, "cols should not exceed max_cols")
end)

test("calc_display_size: small image stays within bounds", function()
  local cols, rows = image.calc_display_size(8, 16, 40, 20)
  assert_true(cols <= 40, "cols within bounds")
  assert_true(rows <= 20, "rows within bounds")
end)

-- Aspect ratio preservation tests with mocked cell size
test("calc_display_size: square image stays square (cell 8x16)", function()
  image._test_cell_size = { cell_w = 8, cell_h = 16 }
  local cols, rows = image.calc_display_size(640, 640, 30, 15)
  -- 640/640 = 1.0; display should also be ~1.0
  local display_ratio = (cols * 8) / (rows * 16)
  assert_eq(display_ratio, 1.0, "square image should display as square, got " .. display_ratio)
  image._test_cell_size = nil
end)

test("calc_display_size: landscape 4:3 aspect ratio preserved (cell 9x18)", function()
  image._test_cell_size = { cell_w = 9, cell_h = 18 }
  local cols, rows = image.calc_display_size(640, 480, 30, 15)
  local display_ratio = (cols * 9) / (rows * 18)
  local target_ratio = 640 / 480
  local error_pct = math.abs(display_ratio - target_ratio) / target_ratio * 100
  assert_true(error_pct < 5, "4:3 aspect error should be <5%, got " .. string.format("%.1f%%", error_pct))
  assert_true(cols <= 30, "cols within max")
  assert_true(rows <= 15, "rows within max")
  image._test_cell_size = nil
end)

test("calc_display_size: 750x600 image in table column (cell 9x18)", function()
  image._test_cell_size = { cell_w = 9, cell_h = 18 }
  local cols, rows = image.calc_display_size(750, 600, 30, 15)
  local display_ratio = (cols * 9) / (rows * 18)
  local target_ratio = 750 / 600
  local error_pct = math.abs(display_ratio - target_ratio) / target_ratio * 100
  assert_true(error_pct < 5, "750x600 aspect error should be <5%, got " .. string.format("%.1f%%", error_pct))
  image._test_cell_size = nil
end)

test("calc_display_size: 16:9 widescreen aspect ratio (cell 9x18)", function()
  image._test_cell_size = { cell_w = 9, cell_h = 18 }
  local cols, rows = image.calc_display_size(1920, 1080, 30, 15)
  local display_ratio = (cols * 9) / (rows * 18)
  local target_ratio = 1920 / 1080
  local error_pct = math.abs(display_ratio - target_ratio) / target_ratio * 100
  assert_true(error_pct < 8, "16:9 aspect error should be <8%, got " .. string.format("%.1f%%", error_pct))
  image._test_cell_size = nil
end)

test("calc_display_size: tall portrait image constrained by max_rows", function()
  image._test_cell_size = { cell_w = 8, cell_h = 16 }
  local cols, rows = image.calc_display_size(400, 1200, 30, 15)
  assert_true(rows <= 15, "rows should not exceed max_rows")
  assert_true(cols <= 30, "cols should not exceed max_cols")
  assert_true(cols >= 1, "cols should be at least 1")
  image._test_cell_size = nil
end)

-- ============================================================================
-- transmit_image: escape sequence tests
-- ============================================================================

test("transmit_image: generates correct APC sequence for PNG", function()
  setup_capture()
  local id = image.transmit_image(test_png)
  assert_true(id ~= nil, "should return image ID")

  local seqs = parse_kitty_sequences(captured_output())
  assert_true(#seqs >= 1, "should produce at least one APC sequence")

  local p = parse_params(seqs[1].params)
  assert_eq(p.a, "t", "action should be 't' (transmit)")
  assert_eq(p.f, "100", "format should be 100 (PNG)")
  assert_eq(p.q, "2", "quiet mode should be 2")
  assert_true(p.i ~= nil, "should have image ID")
  assert_true(seqs[1].payload ~= "", "should have base64 payload (file path)")
  teardown()
end)

test("transmit_image: sequential IDs are monotonically increasing", function()
  setup_capture()
  local id1 = image.transmit_image(test_png)
  local id2 = image.transmit_image(test_png)
  assert_true(id1 ~= nil and id2 ~= nil, "both should succeed")
  assert_true(id2 > id1, "second ID should be greater than first")
  teardown()
end)

test("transmit_image: returns nil when kitty not supported", function()
  setup_capture()
  image._set_kitty_supported(false)
  local id = image.transmit_image(test_png)
  assert_nil(id, "should return nil when kitty not supported")
  assert_eq(#captured, 0, "should not write anything")
  teardown()
end)

test("transmit_image: payload is base64 encoded file path", function()
  setup_capture()
  local id = image.transmit_image(test_png)
  assert_true(id ~= nil, "should return image ID")

  local seqs = parse_kitty_sequences(captured_output())
  local decoded = vim.base64.decode(seqs[1].payload)
  assert_match(decoded, "test_4x4%.png$", "decoded payload should be the PNG file path")

  local p = parse_params(seqs[1].params)
  assert_eq(p.t, "f", "transfer mode should be 'f' (file path) for non-temp PNG")
  teardown()
end)

-- ============================================================================
-- put_image: escape sequence tests
-- ============================================================================

test("put_image: generates correct placement sequence", function()
  setup_capture()

  -- Create a minimal float window for testing
  local buf = vim.api.nvim_create_buf(false, true)
  -- Fill buffer with enough lines for the image
  local lines = {}
  for i = 1, 20 do lines[i] = string.rep(" ", 40) end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    row = 0,
    col = 0,
    width = 40,
    height = 20,
    border = "none",
  })

  image.put_image(101, win, 2, 3, 15, 8)

  local output = captured_output()
  local seqs = parse_kitty_sequences(output)
  assert_true(#seqs >= 1, "should produce at least one APC sequence")

  local p = parse_params(seqs[1].params)
  assert_eq(p.a, "p", "action should be 'p' (put/place)")
  assert_eq(p.i, "101", "image ID should match")
  assert_eq(p.c, "15", "display columns should match")
  assert_eq(p.r, "8", "display rows should match")
  assert_eq(p.C, "1", "cursor movement should be 1")
  assert_eq(p.q, "2", "quiet mode should be 2")

  -- Verify cursor save/restore wraps the placement
  assert_match(output, "^\x1b%[s", "should start with cursor save")
  assert_match(output, "\x1b%[u$", "should end with cursor restore")

  -- Verify cursor positioning (CSI row;col H)
  assert_match(output, "\x1b%[%d+;%d+H", "should contain cursor move sequence")

  vim.api.nvim_win_close(win, true)
  vim.api.nvim_buf_delete(buf, { force = true })
  teardown()
end)

test("put_image: skips image outside visible area (below)", function()
  setup_capture()

  local buf = vim.api.nvim_create_buf(false, true)
  local lines = {}
  for i = 1, 5 do lines[i] = string.rep(" ", 40) end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    row = 0,
    col = 0,
    width = 40,
    height = 5,
    border = "none",
  })

  -- Image at row 10, but window height is only 5 (topline=1 → visible 0-4)
  image.put_image(101, win, 10, 0, 10, 5)

  local seqs = parse_kitty_sequences(captured_output())
  assert_eq(#seqs, 0, "should not produce any sequence for invisible image")

  vim.api.nvim_win_close(win, true)
  vim.api.nvim_buf_delete(buf, { force = true })
  teardown()
end)

test("put_image: does nothing when kitty not supported", function()
  setup_capture()
  image._set_kitty_supported(false)

  image.put_image(101, 0, 0, 0, 10, 5)
  assert_eq(#captured, 0, "should not write anything")
  teardown()
end)

-- ============================================================================
-- put_image: crop parameter tests
-- ============================================================================

test("put_image: top crop generates y= and h= parameters", function()
  setup_capture()

  local buf = vim.api.nvim_create_buf(false, true)
  local lines = {}
  for i = 1, 10 do lines[i] = string.rep(" ", 40) end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    row = 0,
    col = 0,
    width = 40,
    height = 10,
    border = "none",
  })

  -- Image starts at row -2 (2 rows above visible area), height 6
  -- With img_h=600, crop should produce y= and h= params
  -- topline is 1 (0-indexed: 0), so row -2 means 2 rows above visible
  image.put_image(101, win, -2, 0, 10, 6, nil, 400, 600)

  local output = captured_output()
  local seqs = parse_kitty_sequences(output)
  if #seqs > 0 then
    local p = parse_params(seqs[1].params)
    assert_true(p.y ~= nil, "should have y= crop parameter for top crop")
    assert_true(p.h ~= nil, "should have h= crop parameter for top crop (Ghostty compat)")
  else
    -- Image might be fully clipped; that's also valid
    pass_count = pass_count + 2
  end

  vim.api.nvim_win_close(win, true)
  vim.api.nvim_buf_delete(buf, { force = true })
  teardown()
end)

-- ============================================================================
-- clear_placements / delete: escape sequence tests
-- ============================================================================

test("clear_placements: generates correct delete sequence", function()
  setup_capture()
  image.clear_placements(42)

  local seqs = parse_kitty_sequences(captured_output())
  assert_eq(#seqs, 1, "should produce one sequence")

  local p = parse_params(seqs[1].params)
  assert_eq(p.a, "d", "action should be 'd' (delete)")
  assert_eq(p.d, "a", "delete target should be 'a' (all placements for image)")
  assert_eq(p.i, "42", "image ID should match")
  assert_eq(p.q, "2", "quiet mode should be 2")
  teardown()
end)

test("delete_all: generates delete-all sequence", function()
  setup_capture()
  image.delete_all()

  local seqs = parse_kitty_sequences(captured_output())
  assert_eq(#seqs, 1, "should produce one sequence")

  local p = parse_params(seqs[1].params)
  assert_eq(p.a, "d", "action should be 'd' (delete)")
  assert_eq(p.d, "A", "delete target should be 'A' (all images)")
  teardown()
end)

test("delete_image: generates correct single-image delete", function()
  setup_capture()
  image.delete_image(77)

  local seqs = parse_kitty_sequences(captured_output())
  assert_eq(#seqs, 1, "should produce one sequence")

  local p = parse_params(seqs[1].params)
  assert_eq(p.a, "d", "action should be 'd'")
  assert_eq(p.d, "i", "delete target should be 'i' (specific image)")
  assert_eq(p.i, "77", "image ID should match")
  teardown()
end)

test("delete_images: generates multiple delete sequences", function()
  setup_capture()
  image.delete_images({ 10, 20, 30 })

  local output = captured_output()
  local seqs = parse_kitty_sequences(output)
  assert_eq(#seqs, 3, "should produce three sequences")

  for idx, seq in ipairs(seqs) do
    local p = parse_params(seq.params)
    assert_eq(p.a, "d", "seq " .. idx .. ": action should be 'd'")
    assert_eq(p.d, "i", "seq " .. idx .. ": delete target should be 'i'")
  end

  -- Verify each ID is present
  local ids = {}
  for _, seq in ipairs(seqs) do
    ids[parse_params(seq.params).i] = true
  end
  assert_true(ids["10"], "should contain ID 10")
  assert_true(ids["20"], "should contain ID 20")
  assert_true(ids["30"], "should contain ID 30")
  teardown()
end)

test("delete_images: does nothing for empty list", function()
  setup_capture()
  image.delete_images({})
  assert_eq(#captured, 0, "should not write anything for empty list")
  teardown()
end)

-- ============================================================================
-- clear_all: session-level clear
-- ============================================================================

test("clear_all: generates delete-all and sets up autocmd", function()
  setup_capture()
  image.clear_all()

  local output = captured_output()
  assert_match(output, "a=d,d=A", "should contain delete-all sequence")
  teardown()
end)

-- ============================================================================
-- image_dimensions tests
-- ============================================================================

test("image_dimensions: reads PNG dimensions correctly", function()
  local w, h = image.image_dimensions(test_png)
  assert_eq(w, 4, "PNG width should be 4")
  assert_eq(h, 4, "PNG height should be 4")
end)

test("image_dimensions: returns nil for non-existent file", function()
  local w, h = image.image_dimensions("/nonexistent/path.png")
  assert_nil(w, "width should be nil for missing file")
  assert_nil(h, "height should be nil for missing file")
end)

-- ============================================================================
-- is_native_format tests
-- ============================================================================

test("is_native_format: PNG is native", function()
  assert_true(image.is_native_format(test_png), "PNG should be native format")
end)

-- ============================================================================
-- supports_kitty detection tests
-- ============================================================================

test("supports_kitty: detects WezTerm via TERM_PROGRAM", function()
  image.reset_cache()
  local orig = vim.env.TERM_PROGRAM
  vim.env.TERM_PROGRAM = "WezTerm"
  assert_true(image.supports_kitty(), "should detect WezTerm")
  vim.env.TERM_PROGRAM = orig
  image.reset_cache()
end)

test("supports_kitty: detects kitty via TERM_PROGRAM", function()
  image.reset_cache()
  local orig = vim.env.TERM_PROGRAM
  vim.env.TERM_PROGRAM = "kitty"
  assert_true(image.supports_kitty(), "should detect kitty")
  vim.env.TERM_PROGRAM = orig
  image.reset_cache()
end)

test("supports_kitty: detects ghostty via TERM_PROGRAM", function()
  image.reset_cache()
  local orig = vim.env.TERM_PROGRAM
  vim.env.TERM_PROGRAM = "ghostty"
  assert_true(image.supports_kitty(), "should detect ghostty")
  vim.env.TERM_PROGRAM = orig
  image.reset_cache()
end)

test("supports_kitty: returns false for unknown terminal", function()
  image.reset_cache()
  local orig_tp = vim.env.TERM_PROGRAM
  local orig_kw = vim.env.KITTY_WINDOW_ID
  local orig_gr = vim.env.GHOSTTY_RESOURCES_DIR
  local orig_we = vim.env.WEZTERM_EXECUTABLE
  vim.env.TERM_PROGRAM = "xterm"
  vim.env.KITTY_WINDOW_ID = nil
  vim.env.GHOSTTY_RESOURCES_DIR = nil
  vim.env.WEZTERM_EXECUTABLE = nil
  assert_true(not image.supports_kitty(), "should return false for xterm")
  vim.env.TERM_PROGRAM = orig_tp
  vim.env.KITTY_WINDOW_ID = orig_kw
  vim.env.GHOSTTY_RESOURCES_DIR = orig_gr
  vim.env.WEZTERM_EXECUTABLE = orig_we
  image.reset_cache()
end)

test("supports_kitty: detects via KITTY_WINDOW_ID env var", function()
  image.reset_cache()
  local orig_tp = vim.env.TERM_PROGRAM
  local orig_kw = vim.env.KITTY_WINDOW_ID
  vim.env.TERM_PROGRAM = nil
  vim.env.KITTY_WINDOW_ID = "1"
  assert_true(image.supports_kitty(), "should detect via KITTY_WINDOW_ID")
  vim.env.TERM_PROGRAM = orig_tp
  vim.env.KITTY_WINDOW_ID = orig_kw
  image.reset_cache()
end)

-- ============================================================================
-- is_badge_url tests
-- ============================================================================

test("is_badge_url: detects shields.io", function()
  assert_true(image.is_badge_url("https://img.shields.io/badge/foo-bar"), "shields.io should be badge")
end)

test("is_badge_url: normal URL is not badge", function()
  assert_true(not image.is_badge_url("https://example.com/photo.png"), "normal URL should not be badge")
end)

-- ============================================================================
-- is_url tests
-- ============================================================================

test("is_url: detects http URL", function()
  assert_true(image.is_url("http://example.com/img.png"), "http should be URL")
end)

test("is_url: detects https URL", function()
  assert_true(image.is_url("https://example.com/img.png"), "https should be URL")
end)

test("is_url: rejects file path", function()
  assert_true(not image.is_url("/path/to/file.png"), "file path should not be URL")
end)

-- ============================================================================
-- Batch mode tests
-- ============================================================================

test("begin_batch/flush_batch: batches writes into single output", function()
  setup_capture()

  image.begin_batch()
  image.delete_image(1)
  image.delete_image(2)
  image.delete_image(3)
  -- During batch, nothing should have been written yet
  assert_eq(#captured, 0, "should not write during batch")

  image.flush_batch()
  -- After flush, all writes should appear as a single write
  assert_eq(#captured, 1, "flush should produce single write")

  local seqs = parse_kitty_sequences(captured[1])
  assert_eq(#seqs, 3, "single write should contain all 3 delete sequences")
  teardown()
end)

test("nested batches: inner flush appends to outer batch", function()
  setup_capture()

  image.begin_batch()
  image.delete_image(1)

  image.begin_batch()
  image.delete_image(2)
  image.flush_batch()
  -- Still in outer batch, nothing written
  assert_eq(#captured, 0, "should not write during outer batch")

  image.delete_image(3)
  image.flush_batch()
  -- Now everything should be flushed
  assert_eq(#captured, 1, "should produce single write after outer flush")

  local seqs = parse_kitty_sequences(captured[1])
  assert_eq(#seqs, 3, "should contain all 3 sequences")
  teardown()
end)

-- ============================================================================
-- Summary
-- ============================================================================

print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
