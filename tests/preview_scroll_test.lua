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
  local source_win = vim.api.nvim_get_current_win()
  preview.show()
  local win = vim.api.nvim_get_current_win()
  local r = {
    topline = vim.fn.line "w0",
    height = vim.api.nvim_win_get_height(win),
    lines = vim.api.nvim_buf_line_count(0),
    rows = vim.api.nvim_win_text_height(win, {}).all,
    cursor = vim.api.nvim_win_get_cursor(win)[1],
    cursor_row = vim.fn.winline(),
  }
  vim.api.nvim_win_close(win, true)
  r.source_cursor = vim.api.nvim_win_get_cursor(source_win)[1]
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

  -- Near EOF, earlier text fills the rows that centering would leave empty.
  r = open(lines, 397)
  assert_eq(r.rows, r.lines, "the EOF fixture should not wrap")
  assert_eq(r.cursor, 397, "the EOF adjustment should preserve the mapped cursor")
  assert_eq(r.cursor_row + r.lines - r.cursor, r.height, "the last line should fill the float's last screen row")
  assert_eq(r.source_cursor, 397, "opening and closing the float should preserve the source cursor")
end

-- An attached UI verifies native wrapping and the actual following text on screen.
local child = vim.fn.jobstart(
  { vim.v.progpath, "--embed", "--headless", "-n", "-u", "NONE", "--noplugin", "-i", "NONE" },
  { rpc = true }
)
local function child_lua(code)
  return vim.rpcrequest(child, "nvim_exec_lua", code, {})
end
local ok, err = pcall(function()
  vim.rpcrequest(child, "nvim_ui_attach", 120, 40, { rgb = true })
  child_lua [[
    package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
    require("md-render.text_size").setup { enabled = false }
    vim.o.scrolloff, vim.o.laststatus = 0, 2
    local lines = {}
    for i = 1, 13 do
      lines[#lines + 1] = ("Para%02d "):format(i) .. string.rep("x", 145)
      lines[#lines + 1] = ""
    end
    vim.bo.filetype = "markdown"
    vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
    vim.api.nvim_win_set_cursor(0, {21, 0})
    _G.source_win = vim.api.nvim_get_current_win()
    _G.source_buf = vim.api.nvim_get_current_buf()
    _G.source_tick = vim.api.nvim_buf_get_changedtick(source_buf)
    require("md-render.preview").show_tab()
  ]]
  vim.rpcrequest(child, "nvim_command", "redraw!")
  child_lua [[
    local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
    local session = require("md-render.preview")._sessions[buf]
    assert(vim.api.nvim_win_text_height(win, {}).all > vim.api.nvim_buf_line_count(buf), "fixture must wrap on screen")
    assert(vim.api.nvim_win_get_cursor(win)[1] == session:source_to_rendered(21), "mapped cursor changed")
    local pos
    for line, text in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
      local col = text:find("Para12", 1, true)
      if col then pos = vim.fn.screenpos(win, line, col); break end
    end
    assert(pos and pos.row > 0, "the paragraph after the cursor is off screen")
    local cells = {}
    for col = pos.col, pos.col + 5 do cells[#cells + 1] = vim.fn.screenstring(pos.row, col) end
    assert(table.concat(cells) == "Para12", "the following paragraph was not drawn")
    vim.api.nvim_win_close(win, true)
    assert(vim.api.nvim_win_get_buf(source_win) == source_buf, "closing the preview lost the source")
    assert(vim.api.nvim_win_get_cursor(source_win)[1] == 21, "source cursor changed")
    assert(vim.api.nvim_buf_get_changedtick(source_buf) == source_tick, "source text changed")
  ]]
end)
vim.fn.jobstop(child)
assert_eq(ok, true, "wrapped paragraphs stay visible: " .. tostring(err))

print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
