-- Test keyboard toggling of folds / expandable regions (za and <CR>).
-- Mirrors the mouse <LeftRelease> behavior in display_utils.setup_float_keymaps,
-- but acting on the cursor line instead of the click position.
-- Run: nvim --headless -u NONE --noplugin -l tests/key_toggle_test.lua

package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local display_utils = require "md-render.display_utils"

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

local function assert_false(val, msg)
  assert_true(not val, msg)
end

local function test(name, fn)
  local ok, err = pcall(fn)
  if not ok then
    fail_count = fail_count + 1
    print("ERROR: " .. name .. ": " .. tostring(err))
  end
end

-- Feed keys and process them synchronously.
local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

--- Build a render-style buffer/window with synthetic content, install the
--- float keymaps, and return everything plus the captured toggle calls.
---@param content table
---@param close_keys? string[]
local function setup(content, close_keys)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, content.lines)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = 1,
    col = 1,
    width = 40,
    height = 10,
  })
  local ns = vim.api.nvim_create_namespace "md-render-key-toggle-test"

  local calls = { fold = {}, expand = {} }
  display_utils.setup_float_keymaps(buf, ns, win, content, nil, {
    close_keys = close_keys,
    get_content = function()
      return content
    end,
    on_fold_toggle = function(source_line, collapsed)
      table.insert(calls.fold, { source_line = source_line, collapsed = collapsed })
    end,
    on_expand_toggle = function(block_id, expanded)
      table.insert(calls.expand, { block_id = block_id, expanded = expanded })
    end,
  })

  return buf, win, calls
end

local function cleanup(win, buf)
  if win and vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  if buf and vim.api.nvim_buf_is_valid(buf) then pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
end

-- Content: line 1 = callout header (fold), lines 2-3 = expandable region, line 4 = plain.
local function make_content()
  return {
    lines = { "callout header", "code line 1", "code line 2", "plain text" },
    callout_folds = { { header_line = 0, source_line = 7, collapsed = false } },
    expandable_regions = { { start_line = 1, end_line = 2, block_id = 42, expanded = false } },
  }
end

-- ----------------------------------------------------------------------
-- Test 1: `za` on a fold header toggles the fold
-- ----------------------------------------------------------------------
test("za on fold header toggles the fold", function()
  local buf, win, calls = setup(make_content())
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  feed "za"
  assert_eq(#calls.fold, 1, "za on header: on_fold_toggle fires once")
  assert_eq(calls.fold[1], { source_line = 7, collapsed = true }, "za on header: toggles to collapsed")
  assert_eq(#calls.expand, 0, "za on header: expand not fired")
  cleanup(win, buf)
end)

-- ----------------------------------------------------------------------
-- Test 2: `<CR>` inside an expandable region toggles expansion
-- ----------------------------------------------------------------------
test("<CR> inside expandable region toggles expansion", function()
  local buf, win, calls = setup(make_content())
  vim.api.nvim_win_set_cursor(win, { 2, 0 })
  feed "<CR>"
  assert_eq(#calls.expand, 1, "<CR> in region: on_expand_toggle fires once")
  assert_eq(calls.expand[1], { block_id = 42, expanded = true }, "<CR> in region: toggles to expanded")
  assert_eq(#calls.fold, 0, "<CR> in region: fold not fired")
  cleanup(win, buf)
end)

-- ----------------------------------------------------------------------
-- Test 3: `za` also toggles an expandable region under the cursor
-- ----------------------------------------------------------------------
test("za inside expandable region toggles expansion", function()
  local buf, win, calls = setup(make_content())
  vim.api.nvim_win_set_cursor(win, { 3, 0 })
  feed "za"
  assert_eq(#calls.expand, 1, "za in region: on_expand_toggle fires once")
  assert_eq(calls.expand[1], { block_id = 42, expanded = true }, "za in region: toggles to expanded")
  cleanup(win, buf)
end)

-- ----------------------------------------------------------------------
-- Test 4: `za` on a plain line is a silent no-op
-- ----------------------------------------------------------------------
test("za on plain line is a no-op", function()
  local buf, win, calls = setup(make_content())
  vim.api.nvim_win_set_cursor(win, { 4, 0 })
  feed "za"
  assert_eq(#calls.fold, 0, "za on plain line: fold not fired")
  assert_eq(#calls.expand, 0, "za on plain line: expand not fired")
  cleanup(win, buf)
end)

-- ----------------------------------------------------------------------
-- Test 5: `<CR>` on a plain line does NOT close the window by default
-- (Enter is no longer a close key — closing on Enter is unintuitive).
-- ----------------------------------------------------------------------
test("<CR> on plain line does not close the window by default", function()
  local buf, win, calls = setup(make_content()) -- default close_keys: q / <Esc> / <C-c>
  vim.api.nvim_win_set_cursor(win, { 4, 0 })
  feed "<CR>"
  assert_true(vim.api.nvim_win_is_valid(win), "<CR> on plain line: window stays open")
  assert_eq(#calls.fold, 0, "<CR> on plain line: fold not fired")
  assert_eq(#calls.expand, 0, "<CR> on plain line: expand not fired")
  cleanup(win, buf)
end)

-- ----------------------------------------------------------------------
-- Test 6: `<C-c>` on a plain line closes the window (default close key)
-- ----------------------------------------------------------------------
test("<C-c> on plain line closes the window", function()
  local buf, win, _ = setup(make_content()) -- default close_keys include <C-c>
  vim.api.nvim_win_set_cursor(win, { 4, 0 })
  feed "<C-c>"
  assert_false(vim.api.nvim_win_is_valid(win), "<C-c> on plain line: window closed")
  cleanup(win, buf)
end)

-- ----------------------------------------------------------------------
-- Test 7: `q` on a plain line closes the window (default close key)
-- ----------------------------------------------------------------------
test("q on plain line closes the window", function()
  local buf, win, _ = setup(make_content())
  vim.api.nvim_win_set_cursor(win, { 4, 0 })
  feed "q"
  assert_false(vim.api.nvim_win_is_valid(win), "q on plain line: window closed")
  cleanup(win, buf)
end)

-- ----------------------------------------------------------------------
-- Test 8: in toggle mode (no close keys), <CR> on a plain line is a no-op
-- ----------------------------------------------------------------------
test("<CR> on plain line is a no-op in toggle mode", function()
  local buf, win, calls = setup(make_content(), {})
  vim.api.nvim_win_set_cursor(win, { 4, 0 })
  feed "<CR>"
  assert_true(vim.api.nvim_win_is_valid(win), "<CR> toggle mode: window stays open")
  assert_eq(#calls.fold, 0, "<CR> toggle mode: fold not fired")
  cleanup(win, buf)
end)

-- ----------------------------------------------------------------------
-- Test 9: when a caller opts <CR> into close_keys, <CR> still closes
-- on a plain line (cr_is_close fallback path remains supported).
-- ----------------------------------------------------------------------
test("<CR> still closes when explicitly a close key", function()
  local buf, win, _ = setup(make_content(), { "<CR>" })
  vim.api.nvim_win_set_cursor(win, { 4, 0 })
  feed "<CR>"
  assert_false(vim.api.nvim_win_is_valid(win), "<CR> as close key: window closed")
  cleanup(win, buf)
end)

print(string.format("key_toggle_test: %d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
