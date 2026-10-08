-- Test that rendered lines fit the window they are shown in, and that they use
-- all of it.  ContentBuilder used to wrap at `max_width` and prepend the indent
-- afterwards, so a window-sized `max_width` let lines run past the edge by the
-- indent's width, and 'wrap' put their last characters on a screen row of their
-- own at column 0.  Taking the indent off the window width instead cut code
-- blocks short, as they already counted it.
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

--- Headless Nvim keeps the windows at their old width until the layout
--- changes, so split and close one to make `columns` take effect.
local function set_columns(columns)
  vim.o.columns = columns
  vim.cmd "silent! only"
  vim.cmd "vsplit"
  vim.cmd "only"
  assert(vim.api.nvim_win_get_width(0) == columns, "the window is " .. columns .. " columns wide")
end

local function setup_md_buffer(doc)
  vim.cmd "silent! only"
  local buf = vim.api.nvim_create_buf(false, false)
  vim.bo[buf].filetype = "markdown"
  vim.api.nvim_buf_set_name(buf, "/tmp/md-render-content-width-test-" .. buf .. ".md")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, doc or DOC)
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
    set_columns(columns)
    local source = setup_md_buffer()
    preview.toggle()
    assert_eq(overflowing(vim.api.nvim_get_current_win()), {}, "toggle lines fit at " .. columns .. " columns")
    preview.toggle()
    pcall(vim.api.nvim_buf_delete, source, { force = true })
  end)

  test("split at " .. columns .. " columns", function()
    set_columns(columns)
    local source = setup_md_buffer()
    preview.split { mods = { vertical = false } }
    assert_eq(overflowing(render_win()), {}, "split lines fit at " .. columns .. " columns")
    pcall(vim.api.nvim_buf_delete, source, { force = true })
  end)

  test("pager at " .. columns .. " columns", function()
    set_columns(columns)
    local source = setup_md_buffer()
    preview.show_pager()
    assert_eq(overflowing(render_win()), {}, "pager lines fit at " .. columns .. " columns")
    pcall(vim.api.nvim_buf_delete, source, { force = true })
  end)
end

-- A code line as wide as the window less the indent fits as it is.
test("code block uses the full width", function()
  set_columns(40)
  local code = string.rep("1234567890", 4):sub(1, 38)
  local source = setup_md_buffer { "```text", code, "```" }
  preview.toggle()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  assert_eq(vim.tbl_contains(lines, "  " .. code), true, "the 38-column code line is not truncated at 40 columns")
  preview.toggle()
  pcall(vim.api.nvim_buf_delete, source, { force = true })
end)

print(string.format("content_width_test: %d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
