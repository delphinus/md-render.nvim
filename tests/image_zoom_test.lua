-- Image zoom tests: finding the image under the cursor or mouse, sizing it to
-- fill the editor, and handing the screen back to the document afterwards
-- Run: nvim --headless -u NONE --noplugin -l tests/image_zoom_test.lua

package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local display_utils = require "md-render.display_utils"
local image = require "md-render.image"
local image_zoom = require "md-render.image_zoom"
local url_hover = require "md-render.url_hover"

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

local function assert_true(value, msg)
  assert_eq(not not value, true, msg)
end

local function test(name, fn)
  local ok, err = pcall(fn)
  if not ok then
    fail_count = fail_count + 1
    print("ERROR in " .. name .. ": " .. tostring(err))
  end
end

local PNG = vim.fn.getcwd() .. "/assets/demo/test.png" -- 160x120

--- Let queued tasks, scheduled callbacks and the 50 ms redraw debounce run.
local function settle()
  vim.wait(200, function()
    return false
  end, 10)
end

--- Stand in for the terminal: images "transmit" straight away and every
--- placement is recorded instead of written.
---@return { puts: table[], delete_all: integer, renders: table[], restore: fun() }
local function fake_terminal()
  local names = {
    "supports_kitty",
    "clear_all",
    "transmit_image_async",
    "put_image",
    "clear_placements",
    "delete_images",
    "delete_all",
    "render_mermaid_async",
  }
  local saved = {}
  for _, name in ipairs(names) do
    saved[name] = image[name]
  end
  local saved_cell = image._test_cell_size
  local t = { puts = {}, delete_all = 0, renders = {} }
  local next_id = 500
  image._test_cell_size = { cell_w = 10, cell_h = 20 }
  image.supports_kitty = function()
    return true
  end
  image.clear_all = function() end
  image.transmit_image_async = function(_, cb)
    next_id = next_id + 1
    cb(next_id)
  end
  image.put_image = function(id, win, row, col, cols, rows)
    table.insert(t.puts, { id = id, win = win, row = row, col = col, cols = cols, rows = rows })
  end
  image.clear_placements = function() end
  image.delete_images = function() end
  image.delete_all = function()
    t.delete_all = t.delete_all + 1
  end
  image.render_mermaid_async = function(source, cb, scale)
    table.insert(t.renders, { source = source, scale = scale })
    cb(PNG)
  end
  t.restore = function()
    for name, fn in pairs(saved) do
      image[name] = fn
    end
    image._test_cell_size = saved_cell
  end
  return t
end

--- A window showing a document with one image on lines 2-4.
---@return { win: integer, buf: integer, placement: table, content: table, state: table?, finish: fun() }
local function document()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# Title", "", "", "", "", "text after" })
  local win = vim.api.nvim_get_current_win()
  local prev = vim.api.nvim_win_get_buf(win)
  vim.api.nvim_win_set_buf(win, buf)
  local placement = { path = PNG, line = 1, col = 4, rows = 3, cols = 12, title = "test.png" }
  local content = { lines = {}, image_placements = { placement } }
  local doc = { win = win, buf = buf, placement = placement, content = content }
  doc.state = display_utils.setup_images(win, content, nil)
  doc.finish = function()
    image_zoom.close()
    settle()
    display_utils.cleanup_images(doc.state)
    vim.api.nvim_win_set_buf(win, prev)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
  return doc
end

-- ============================================================================
-- image_at
-- ============================================================================

test("image_at finds the image spanning a line and column", function()
  local a = { line = 2, col = 0, rows = 3, cols = 10 }
  local b = { line = 2, col = 12, rows = 3, cols = 10 }
  local ps = { a, b }
  assert_eq(display_utils.image_at(ps, 3, 15), b, "the image whose columns hold the position")
  assert_eq(display_utils.image_at(ps, 2, 5), a, "the first row counts")
  assert_eq(display_utils.image_at(ps, 5, 5), nil, "the row after the last does not")
  assert_eq(display_utils.image_at(ps, 3, 11), nil, "a column between two images is on neither")
  assert_eq(display_utils.image_at(ps, 3, 11, true), a, "loosely, it is on the line's first image")
  assert_eq(display_utils.image_at(nil, 3, 0, true), nil, "no placements, no image")
end)

-- ============================================================================
-- calc_display_size with allow_upscale
-- ============================================================================

test("calc_display_size enlarges only when asked", function()
  local saved = image._test_cell_size
  image._test_cell_size = { cell_w = 10, cell_h = 20 }
  local cols, rows = image.calc_display_size(100, 50, 40, 20)
  assert_eq({ cols, rows }, { 10, 3 }, "in the document an image keeps its own size at most")
  cols, rows = image.calc_display_size(100, 50, 40, 20, true)
  assert_eq({ cols, rows }, { 40, 10 }, "the zoom view fills the width")
  cols, rows = image.calc_display_size(100, 200, 40, 20, true)
  assert_eq({ cols, rows }, { 20, 20 }, "or the height, whichever runs out first")
  image._test_cell_size = saved
end)

-- ============================================================================
-- mermaid_scale
-- ============================================================================

test("mermaid_scale draws larger only as far as the zoom area needs", function()
  local cell = { cell_w = 10, cell_h = 20 }
  assert_eq(image_zoom._mermaid_scale(1000, 500, 100, 40, cell), 2, "already fills the width: default scale")
  assert_eq(image_zoom._mermaid_scale(1000, 500, 300, 40, cell), 4, "1.6x larger on screen: scale 2 * 1.6, rounded up")
  assert_eq(image_zoom._mermaid_scale(100, 50, 300, 100, cell), 8, "capped")
  assert_eq(image_zoom._mermaid_scale(1000, 500, 300, 40, nil), 2, "without a cell size, the default")
end)

-- ============================================================================
-- open / close
-- ============================================================================

test("zoom fills the editor and takes the document's images down meanwhile", function()
  local term = fake_terminal()
  local doc = document()
  settle()

  assert_true(image_zoom.open(doc.placement), "open reports it opened")
  settle()
  local zwin = vim.api.nvim_get_current_win()
  assert_true(zwin ~= doc.win, "the zoom float takes the focus")
  local cfg = vim.api.nvim_win_get_config(zwin)
  assert_eq(cfg.relative, "editor", "it is a float over the editor")
  assert_eq(cfg.zindex, 60, "above the document's own float")
  local width, height = image_zoom._zoom_area()
  assert_eq({ cfg.width, cfg.height }, { width, height }, "as large as the editor allows")
  assert_true(doc.state.suspended, "the document's images are taken down")

  local zoom_put
  for _, put in ipairs(term.puts) do
    if put.win == zwin then zoom_put = put end
  end
  assert_true(zoom_put, "the image is placed in the zoom float")
  -- 160x120 px in 10x20 px cells, fitted into the area and enlarged.
  local cols, rows = image.calc_display_size(160, 120, width, height, true)
  assert_eq({ zoom_put.cols, zoom_put.rows }, { cols, rows }, "enlarged to fill the area")
  assert_true(zoom_put.cols > doc.placement.cols, "larger than in the document")

  image_zoom.close()
  settle()
  assert_eq(image_zoom.is_open(), false, "close closes it")
  assert_eq(vim.api.nvim_get_current_win(), doc.win, "the focus goes back to the document")
  assert_eq(doc.state.suspended, nil, "the document's images are put back")
  assert_eq(term.delete_all, 0, "closing the zoom does not delete every image in the terminal")

  doc.finish()
  assert_eq(term.delete_all, 1, "closing the last window with images still does")
  term.restore()
end)

test("<CR> on an image opens the zoom, and q closes it", function()
  local term = fake_terminal()
  local doc = document()
  display_utils.setup_float_keymaps(doc.buf, vim.api.nvim_create_namespace "zoom_test", doc.win, doc.content, nil, {
    close_keys = {},
  })
  settle()

  vim.api.nvim_win_set_cursor(doc.win, { 6, 0 })
  vim.api.nvim_feedkeys(vim.keycode "<CR>", "x", false)
  assert_eq(image_zoom.is_open(), false, "<CR> off the image does nothing")

  vim.api.nvim_win_set_cursor(doc.win, { 3, 0 })
  vim.api.nvim_feedkeys(vim.keycode "<CR>", "x", false)
  assert_true(image_zoom.is_open(), "<CR> on a row of the image opens it")

  vim.api.nvim_feedkeys("q", "x", false)
  settle()
  assert_eq(image_zoom.is_open(), false, "q closes it")
  assert_true(vim.api.nvim_win_is_valid(doc.win), "and leaves the document open")

  doc.finish()
  term.restore()
end)

test("a Mermaid diagram is drawn again at the scale the zoom needs", function()
  local term = fake_terminal()
  local doc = document()
  doc.placement.mermaid_text = "graph LR\n  A --> B"
  settle()

  image_zoom.open(doc.placement)
  settle()
  local width, height = image_zoom._zoom_area()
  local want = image_zoom._mermaid_scale(160, 120, width, height, image._test_cell_size)
  assert_true(want > image.MERMAID_DEFAULT_SCALE, "the test diagram is small enough to need it")
  assert_eq(#term.renders, 1, "one render")
  assert_eq(term.renders[1] and term.renders[1].scale, want, "at the computed scale")
  assert_eq(term.renders[1] and term.renders[1].source, doc.placement.mermaid_text, "of the same source")

  doc.finish()
  term.restore()
end)

test("an image that has not loaded yet is not offered", function()
  assert_eq(
    image_zoom.can_zoom { line = 0, col = 0, rows = 1, cols = 1, src_url = "https://example.com/a.png" },
    false,
    "still downloading"
  )
  assert_eq(
    image_zoom.can_zoom { line = 0, col = 0, rows = 1, cols = 1, mermaid_text = "graph LR" },
    true,
    "a diagram can be drawn on demand"
  )
  assert_eq(image_zoom.can_zoom(nil), false, "nothing there")
end)

-- ============================================================================
-- hint
-- ============================================================================

test("the hint shows while the cursor is on an image", function()
  local term = fake_terminal()
  local doc = document()
  url_hover.attach(doc.buf, vim.api.nvim_create_namespace "zoom_hint_test", doc.win, function()
    return doc.content.image_placements
  end)
  local internal = url_hover._internal()

  vim.api.nvim_win_set_cursor(doc.win, { 3, 0 })
  internal.update_cursor_hint()
  assert_eq(internal.state.current_url, internal.IMAGE_HINT, "on the image: the hint")
  assert_true(internal.state.hover_win and vim.api.nvim_win_is_valid(internal.state.hover_win), "in a float")

  vim.api.nvim_win_set_cursor(doc.win, { 6, 0 })
  internal.update_cursor_hint()
  assert_eq(internal.state.current_url, nil, "off the image: gone")

  doc.finish()
  term.restore()
end)

-- ============================================================================
-- Summary
-- ============================================================================

print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
