-- Test where the floating preview opens.  It centers the line under the
-- source cursor, but must not scroll past the end: a document that fits the
-- window shows from its first line.
-- Run: nvim --headless -u NONE --noplugin -l tests/preview_scroll_test.lua

package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local preview = require "md-render.preview"

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

vim.o.lines, vim.o.columns = 40, 120

--- Open the float on `lines` with the source cursor on `cursor_line`, and
--- return the float's topline, height and line count.
local function open(lines, cursor_line)
  local path = vim.fn.tempname() .. ".md"
  vim.fn.writefile(lines, path)
  vim.cmd("edit " .. path)
  vim.api.nvim_win_set_cursor(0, { cursor_line, 0 })
  preview.show()
  local win = vim.api.nvim_get_current_win()
  local r = {
    topline = vim.fn.line "w0",
    height = vim.api.nvim_win_get_height(win),
    lines = vim.api.nvim_buf_line_count(0),
  }
  vim.api.nvim_win_close(win, true)
  vim.cmd "bwipeout!"
  vim.fn.delete(path)
  return r
end

-- Test 1: a short document starts at its first line, wherever the cursor is
do
  local r = open({ "## Heading", "", "One.", "", "Two.", "", "Three.", "", "Four." }, 9)
  assert_eq(r.lines <= r.height, true, "the document should fit the float")
  assert_eq(r.topline, 1, "a document that fits should not be scrolled")
end

-- Test 2: a long document still centers the cursor line
do
  local lines = {}
  for i = 1, 200 do
    table.insert(lines, ("Paragraph %d."):format(i))
    table.insert(lines, "")
  end
  local r = open(lines, 199)
  assert_eq(r.topline > 1, true, "the cursor line in the middle of a long document should be scrolled to")
  assert_eq(r.topline <= r.lines - r.height + 1, true, "the last line should not leave empty rows below it")
end

print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
