-- Test :MdRenderToggle (same-window source ↔ render swap)
-- Run: nvim --headless -u NONE --noplugin -l tests/toggle_test.lua

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

--- Set up a markdown buffer in the current window with the given lines.
---@param lines string[]
---@return integer bufnr
local function setup_md_buffer(lines)
  local buf = vim.api.nvim_create_buf(false, false)
  vim.bo[buf].filetype = "markdown"
  vim.api.nvim_buf_set_name(buf, "/tmp/md-render-toggle-test-" .. buf .. ".md")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_win_set_buf(0, buf)
  return buf
end

local function cleanup_buffer(buf)
  if vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
end

local function clear_win_state(win)
  pcall(vim.api.nvim_win_del_var, win, "md_render_state")
end

-- ----------------------------------------------------------------------
-- Test 1: source → render swaps the buffer in the same window
-- ----------------------------------------------------------------------
test("source → render swaps buffer in the same window", function()
  local source = setup_md_buffer({ "# Hello", "", "Some text" })
  local win = vim.api.nvim_get_current_win()

  preview.toggle()

  local cur = vim.api.nvim_win_get_buf(win)
  assert_false(cur == source, "render mode should not show the source buffer")

  local state = vim.w[win].md_render_state
  assert_true(type(state) == "table", "window-local state should exist")
  assert_eq(state.mode, "render", "mode should be render")
  assert_eq(state.source_buf, source, "source_buf should match the original")
  assert_eq(state.render_buf, cur, "render_buf should match current buffer")

  -- Render buf is read-only and non-modifiable
  assert_eq(vim.bo[cur].modifiable, false, "render buf should be nomodifiable")
  assert_eq(vim.bo[cur].readonly, true, "render buf should be readonly")
  assert_eq(vim.bo[cur].buftype, "nofile", "render buf should be nofile")
  assert_eq(vim.bo[cur].bufhidden, "hide", "render buf should be hidden (kept alive)")

  cleanup_buffer(source)
end)

-- ----------------------------------------------------------------------
-- Test 2: render → source swaps back to the original buffer
-- ----------------------------------------------------------------------
test("render → source swaps back to original buffer", function()
  local source = setup_md_buffer({ "# Hello", "", "Some text" })
  local win = vim.api.nvim_get_current_win()

  preview.toggle()  -- → render
  local render_buf = vim.api.nvim_win_get_buf(win)
  preview.toggle()  -- → source

  assert_eq(vim.api.nvim_win_get_buf(win), source, "should be back on source buffer")

  local state = vim.w[win].md_render_state
  assert_eq(state.mode, "source", "mode should be source")
  assert_true(vim.api.nvim_buf_is_valid(render_buf), "render buf should still be alive (cached)")

  cleanup_buffer(source)
end)

-- ----------------------------------------------------------------------
-- Test 3: round-trip reuses the same render buffer (cached session)
-- ----------------------------------------------------------------------
test("round-trip reuses the same render buffer", function()
  local source = setup_md_buffer({ "# Hello" })
  local win = vim.api.nvim_get_current_win()

  preview.toggle()
  local first_render = vim.api.nvim_win_get_buf(win)
  preview.toggle()
  preview.toggle()
  local second_render = vim.api.nvim_win_get_buf(win)

  assert_eq(first_render, second_render, "render buf should be reused across toggles")

  cleanup_buffer(source)
end)

-- ----------------------------------------------------------------------
-- Test 4: cursor position survives source → render → source
-- ----------------------------------------------------------------------
test("cursor position survives round-trip via source_line_map", function()
  local source = setup_md_buffer({
    "# Heading 1",
    "",
    "First paragraph.",
    "",
    "## Heading 2",
    "",
    "Second paragraph.",
    "",
    "Last line.",
  })
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_cursor(win, { 7, 0 }) -- "Second paragraph."

  preview.toggle()
  preview.toggle()

  local final_line = vim.api.nvim_win_get_cursor(win)[1]
  -- Source line 7 should round-trip back close to itself (allow ±1 for mapping
  -- artifacts on heading-adjacent lines).
  assert_true(
    math.abs(final_line - 7) <= 2,
    "cursor should return near source line 7 (got " .. final_line .. ")"
  )

  cleanup_buffer(source)
end)

-- ----------------------------------------------------------------------
-- Test 5: non-markdown buffer is rejected
-- ----------------------------------------------------------------------
test("non-markdown buffer is rejected", function()
  local win = vim.api.nvim_get_current_win()
  clear_win_state(win)

  local buf = vim.api.nvim_create_buf(false, false)
  vim.bo[buf].filetype = "text"
  vim.api.nvim_buf_set_name(buf, "/tmp/md-render-toggle-test-not-md.txt")
  vim.api.nvim_win_set_buf(win, buf)

  preview.toggle()

  -- Buffer should not have changed and no state should have been written
  assert_eq(vim.api.nvim_win_get_buf(win), buf, "non-markdown buffer should be left as-is")
  local state_ok = pcall(vim.api.nvim_win_get_var, win, "md_render_state")
  assert_false(state_ok, "no state should be set on rejection")

  cleanup_buffer(buf)
end)

-- ----------------------------------------------------------------------
-- Test 6: BufWipeout on source clears the cached session
-- ----------------------------------------------------------------------
test("BufWipeout on source clears cached session", function()
  local source = setup_md_buffer({ "# Hello" })

  preview.toggle()
  assert_true(preview._toggle_sessions[source] ~= nil, "session should be cached")

  vim.api.nvim_buf_delete(source, { force = true })
  -- Give autocmd a chance
  vim.cmd "doautocmd BufWipeout"

  assert_true(preview._toggle_sessions[source] == nil, "session should be cleared after BufWipeout")
end)

-- ----------------------------------------------------------------------
-- Test 7: source change is reflected on next toggle
-- ----------------------------------------------------------------------
test("source change is reflected on next source → render toggle", function()
  local source = setup_md_buffer({ "# Hello" })
  local win = vim.api.nvim_get_current_win()

  preview.toggle()
  local first_render = vim.api.nvim_win_get_buf(win)
  local first_lines = vim.api.nvim_buf_get_lines(first_render, 0, -1, false)

  preview.toggle()  -- back to source
  vim.api.nvim_buf_set_lines(source, 0, -1, false, { "# Hello", "", "Added paragraph." })

  preview.toggle()  -- back to render — should reflect new source
  local render_buf = vim.api.nvim_win_get_buf(win)
  local new_lines = vim.api.nvim_buf_get_lines(render_buf, 0, -1, false)

  -- Line count should have grown (new paragraph added)
  assert_true(#new_lines > #first_lines, "render content should reflect source changes (lines: "
    .. #first_lines .. " → " .. #new_lines .. ")")

  cleanup_buffer(source)
end)

print(string.format("toggle_test: %d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
