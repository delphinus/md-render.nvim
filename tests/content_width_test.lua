-- Test that rendered lines fit the window they are shown in.  ContentBuilder
-- wraps at `max_width` and prepends the indent afterwards, so a window-sized
-- `max_width` let lines run past the edge by the indent's width, and 'wrap'
-- put their last characters on a screen row of their own at column 0.
-- Run: nvim --headless -u NONE --noplugin -l tests/content_width_test.lua

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

local function test(name, fn)
  local ok, err = pcall(fn)
  if not ok then
    fail_count = fail_count + 1
    print("ERROR: " .. name .. ": " .. tostring(err))
  end
end

-- Mixed CJK and ASCII so that the wrap points land at odd and even columns.
local DOC = {
  "# Title",
  "",
  "- [x] " .. string.rep("あいうえお abc ", 8),
  "    - " .. string.rep("かきくけこ `x = 1` ", 8),
  "",
  string.rep("さしすせそ def ", 10),
}

local function setup_md_buffer()
  vim.cmd "silent! only"
  local buf = vim.api.nvim_create_buf(false, false)
  vim.bo[buf].filetype = "markdown"
  vim.api.nvim_buf_set_name(buf, "/tmp/md-render-content-width-test-" .. buf .. ".md")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, DOC)
  vim.api.nvim_win_set_buf(0, buf)
  return buf
end

--- Lines of the window's buffer wider than its text area.
local function overflowing(win)
  local width = vim.api.nvim_win_get_width(win) - vim.fn.getwininfo(win)[1].textoff
  local out = {}
  for _, line in ipairs(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)) do
    if vim.api.nvim_strwidth(line) > width then table.insert(out, line) end
  end
  return out
end

local function render_win()
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.bo[vim.api.nvim_win_get_buf(w)].filetype == "md-render" then return w end
  end
end

for _, columns in ipairs { 40, 51, 60, 73 } do
  test("toggle at " .. columns .. " columns", function()
    vim.o.columns = columns
    local source = setup_md_buffer()
    preview.toggle()
    assert_eq(overflowing(vim.api.nvim_get_current_win()), {}, "toggle lines fit at " .. columns .. " columns")
    preview.toggle()
    pcall(vim.api.nvim_buf_delete, source, { force = true })
  end)

  test("split at " .. columns .. " columns", function()
    vim.o.columns = columns
    local source = setup_md_buffer()
    preview.split { mods = { vertical = false } }
    assert_eq(overflowing(render_win()), {}, "split lines fit at " .. columns .. " columns")
    pcall(vim.api.nvim_buf_delete, source, { force = true })
  end)

  test("pager at " .. columns .. " columns", function()
    vim.o.columns = columns
    local source = setup_md_buffer()
    preview.show_pager()
    assert_eq(overflowing(render_win()), {}, "pager lines fit at " .. columns .. " columns")
    pcall(vim.api.nvim_buf_delete, source, { force = true })
  end)
end

print(string.format("content_width_test: %d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
