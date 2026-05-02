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
  -- readonly is intentionally NOT set: Vim checks readonly before firing
  -- BufWriteCmd, so a readonly render buf would short-circuit `:w` with E45.
  -- Edit protection comes from modifiable=false above.
  assert_eq(vim.bo[cur].readonly, false, "render buf should NOT be readonly (so :w hits BufWriteCmd)")
  assert_eq(vim.bo[cur].buftype, "acwrite", "render buf should be acwrite (so :w hits BufWriteCmd)")
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

-- ----------------------------------------------------------------------
-- Test 8: live update autocmds are installed for the source buffer
-- ----------------------------------------------------------------------
test("live update autocmds are installed on first toggle", function()
  local source = setup_md_buffer({ "# Hello" })
  preview.toggle()

  local autocmds = vim.api.nvim_get_autocmds {
    group = preview._live_update_augroup(source),
    buffer = source,
  }
  local events = {}
  for _, ac in ipairs(autocmds) do events[ac.event] = true end

  assert_true(events.TextChanged, "TextChanged autocmd should be registered")
  assert_true(events.TextChangedI, "TextChangedI autocmd should be registered")
  assert_true(events.BufWritePost, "BufWritePost autocmd should be registered")
  assert_true(events.BufReadPost, "BufReadPost autocmd should be registered (for :e reload)")
  assert_true(events.FileChangedShellPost, "FileChangedShellPost autocmd should be registered")

  cleanup_buffer(source)
end)

-- ----------------------------------------------------------------------
-- Test 9: live rebuild fires after debounce when render is visible
-- ----------------------------------------------------------------------
test("live rebuild fires after debounce when render is visible", function()
  local source = setup_md_buffer({ "# Hello", "", "para" })
  local source_win = vim.api.nvim_get_current_win()

  preview.toggle()  -- render in source_win
  local render_buf = vim.api.nvim_win_get_buf(source_win)
  local before_lines = #vim.api.nvim_buf_get_lines(render_buf, 0, -1, false)

  -- Open source in a second window so render stays visible while we edit
  vim.cmd "vsplit"
  local edit_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(edit_win, source)

  vim.api.nvim_buf_set_lines(source, -1, -1, false, { "", "appended paragraph" })
  preview._schedule_live_rebuild(preview._toggle_sessions[source])

  vim.wait(300, function() return false end)

  local after_lines = #vim.api.nvim_buf_get_lines(render_buf, 0, -1, false)
  assert_true(
    after_lines > before_lines,
    "render should grow after live update (was " .. before_lines .. ", now " .. after_lines .. ")"
  )

  vim.api.nvim_win_close(edit_win, true)
  cleanup_buffer(source)
end)

-- ----------------------------------------------------------------------
-- Test 10: hidden render → edit only marks dirty (no rebuild, no timer)
-- ----------------------------------------------------------------------
test("hidden render → edit sets dirty without scheduling a rebuild", function()
  local source = setup_md_buffer({ "# Hello" })
  local win = vim.api.nvim_get_current_win()

  preview.toggle()  -- → render
  preview.toggle()  -- → source (render now hidden)

  local session = preview._toggle_sessions[source]
  assert_true(session ~= nil, "session should exist")
  assert_eq(session.dirty, false, "dirty should be false after toggle-back")

  vim.api.nvim_buf_set_lines(source, -1, -1, false, { "", "new line" })
  preview._schedule_live_rebuild(session)

  assert_eq(session.dirty, true, "dirty should be set immediately when render hidden")
  assert_true(session._debounce_timer == nil, "no debounce timer should be running")

  -- Wait past the debounce window to be extra sure nothing fires
  vim.wait(250, function() return false end)
  assert_true(session._debounce_timer == nil, "still no debounce timer after wait")

  -- Re-toggle should consume dirty and rebuild
  preview.toggle()
  assert_eq(session.dirty, false, "dirty should be cleared after re-toggle rebuild")

  local render_buf = vim.api.nvim_win_get_buf(win)
  local lines = vim.api.nvim_buf_get_lines(render_buf, 0, -1, false)
  local found = false
  for _, l in ipairs(lines) do
    if l:find("new line", 1, true) then found = true; break end
  end
  assert_true(found, "edited content should appear after re-toggle")

  cleanup_buffer(source)
end)

-- ----------------------------------------------------------------------
-- Test 11: rapid edits coalesce into a single rebuild via debounce
-- ----------------------------------------------------------------------
test("rapid edits coalesce into a single rebuild", function()
  local source = setup_md_buffer({ "# Hello" })
  local source_win = vim.api.nvim_get_current_win()

  preview.toggle()  -- render in source_win
  vim.cmd "vsplit"
  local edit_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(edit_win, source)

  local session = preview._toggle_sessions[source]
  local rebuild_count = 0
  local orig_rebuild = session.rebuild
  session.rebuild = function(self)
    rebuild_count = rebuild_count + 1
    return orig_rebuild(self)
  end

  -- 5 rapid edits within the debounce window (each ~20ms apart, total < 150ms)
  for i = 1, 5 do
    vim.api.nvim_buf_set_lines(source, -1, -1, false, { "edit " .. i })
    preview._schedule_live_rebuild(session)
    vim.wait(20, function() return false end)
  end

  -- Wait for the debounce to fire (last edit + 150ms + slack)
  vim.wait(300, function() return rebuild_count > 0 end)
  vim.wait(50, function() return false end)

  assert_eq(rebuild_count, 1, "5 rapid edits should coalesce into exactly 1 rebuild")

  session.rebuild = orig_rebuild
  vim.api.nvim_win_close(edit_win, true)
  cleanup_buffer(source)
end)

-- ----------------------------------------------------------------------
-- Test 12: BufWipeout cleanly stops a pending debounce timer
-- ----------------------------------------------------------------------
test("BufWipeout stops pending debounce timer cleanly", function()
  local source = setup_md_buffer({ "# Hello" })
  preview.toggle()
  vim.cmd "vsplit"
  vim.api.nvim_win_set_buf(0, source)

  local session = preview._toggle_sessions[source]
  vim.api.nvim_buf_set_lines(source, -1, -1, false, { "edit" })
  preview._schedule_live_rebuild(session)
  assert_true(session._debounce_timer ~= nil, "debounce timer should be live")

  vim.api.nvim_buf_delete(source, { force = true })
  -- Wait past the original 150ms — if the timer wasn't stopped, the deferred
  -- callback would fire on a wiped buffer and could throw. The assertion below
  -- will only succeed if cleanup ran.
  vim.wait(250, function() return false end)

  assert_true(preview._toggle_sessions[source] == nil, "session should be cleared")
end)

-- ----------------------------------------------------------------------
-- Test 13: live rebuild preserves window topline (winsaveview/restview)
-- ----------------------------------------------------------------------
test("live rebuild preserves render window topline", function()
  local lines = {}
  for i = 1, 100 do table.insert(lines, "line " .. i) end
  local source = setup_md_buffer(lines)
  local source_win = vim.api.nvim_get_current_win()

  preview.toggle()  -- render in source_win
  local render_win = source_win

  -- Scroll the render window so topline > 1
  vim.api.nvim_win_call(render_win, function()
    vim.fn.winrestview { topline = 50, lnum = 60 }
  end)
  local before = vim.api.nvim_win_call(render_win, function() return vim.fn.winsaveview() end)

  -- Edit source from a separate window (prepend a line)
  vim.cmd "vsplit"
  local edit_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(edit_win, source)
  vim.api.nvim_buf_set_lines(source, 0, 0, false, { "prepended" })
  preview._schedule_live_rebuild(preview._toggle_sessions[source])
  vim.wait(300, function() return false end)

  local after = vim.api.nvim_win_call(render_win, function() return vim.fn.winsaveview() end)
  assert_true(
    math.abs(after.topline - before.topline) <= 5,
    "topline should be ~preserved (was " .. before.topline .. ", now " .. after.topline .. ")"
  )

  vim.api.nvim_win_close(edit_win, true)
  cleanup_buffer(source)
end)

-- ----------------------------------------------------------------------
-- Test 13a: render buffer is named after the source for statusline display
-- ----------------------------------------------------------------------
test("render buffer name has [render] suffix", function()
  local source = setup_md_buffer({ "# Hello" })
  local source_name = vim.api.nvim_buf_get_name(source)
  preview.toggle()
  local render_buf = vim.api.nvim_win_get_buf(0)

  local render_name = vim.api.nvim_buf_get_name(render_buf)
  assert_eq(render_name, source_name .. " [render]", "render buf should be '<source> [render]'")

  cleanup_buffer(source)
end)

-- ----------------------------------------------------------------------
-- Test 13b: BufWriteCmd is registered on the render buffer to forward :w
-- ----------------------------------------------------------------------
test("BufWriteCmd is registered on render buffer to forward :w", function()
  local source = setup_md_buffer({ "# Hello" })
  preview.toggle()
  local render_buf = vim.api.nvim_win_get_buf(0)

  local autocmds = vim.api.nvim_get_autocmds {
    event = "BufWriteCmd",
    buffer = render_buf,
  }
  assert_true(#autocmds >= 1, "BufWriteCmd should be registered on render buf")

  cleanup_buffer(source)
end)

-- ----------------------------------------------------------------------
-- Test 14: auto_on swaps to render and sets b:md_render_auto
-- ----------------------------------------------------------------------
test("auto_on flips to render and marks the buffer", function()
  local source = setup_md_buffer({ "# Hello", "", "para" })
  local win = vim.api.nvim_get_current_win()

  preview.auto_on()

  local cur = vim.api.nvim_win_get_buf(win)
  assert_false(cur == source, "should be on render after auto_on")
  assert_eq(vim.b[source].md_render_auto, true, "b:md_render_auto should be true")

  preview.auto_off()
  cleanup_buffer(source)
end)

-- ----------------------------------------------------------------------
-- Test 15: auto_on registers an InsertLeave autocmd (InsertEnter is
-- driven by buffer-local keymaps on the render buffer instead)
-- ----------------------------------------------------------------------
test("auto_on registers InsertLeave autocmd", function()
  local source = setup_md_buffer({ "# Hello" })
  preview.auto_on()

  local autocmds = vim.api.nvim_get_autocmds {
    group = preview._auto_augroup(source),
    buffer = source,
  }
  local events = {}
  for _, ac in ipairs(autocmds) do events[ac.event] = true end

  assert_true(events.InsertLeave, "InsertLeave autocmd should be registered")
  assert_false(events.InsertEnter, "InsertEnter autocmd should NOT be registered (handled via keymap)")

  preview.auto_off()
  cleanup_buffer(source)
end)

-- ----------------------------------------------------------------------
-- Test 15b: auto_on installs Insert-entry keymaps on the render buffer
-- ----------------------------------------------------------------------
test("auto_on installs i/I/a/A/o/O keymaps on render buffer", function()
  local source = setup_md_buffer({ "# Hello" })
  local win = vim.api.nvim_get_current_win()

  preview.auto_on()
  local render_buf = vim.api.nvim_win_get_buf(win)

  local keymaps = vim.api.nvim_buf_get_keymap(render_buf, "n")
  local mapped = {}
  for _, km in ipairs(keymaps) do mapped[km.lhs] = true end

  for _, key in ipairs({ "i", "I", "a", "A", "o", "O" }) do
    assert_true(mapped[key], "key '" .. key .. "' should be mapped on render buf")
  end

  preview.auto_off()

  local keymaps_after = vim.api.nvim_buf_get_keymap(render_buf, "n")
  local mapped_after = {}
  for _, km in ipairs(keymaps_after) do mapped_after[km.lhs] = true end

  for _, key in ipairs({ "i", "I", "a", "A", "o", "O" }) do
    assert_false(mapped_after[key], "key '" .. key .. "' should be removed after auto_off")
  end

  cleanup_buffer(source)
end)

-- ----------------------------------------------------------------------
-- Test 16: schedule_auto_transition("source") flips render → source after debounce
-- ----------------------------------------------------------------------
test("auto-transition to source swaps render → source after 50ms", function()
  local source = setup_md_buffer({ "# Hello" })
  local win = vim.api.nvim_get_current_win()

  preview.auto_on()  -- now on render
  local rendered = vim.api.nvim_win_get_buf(win)
  assert_false(rendered == source, "should start on render")

  preview._schedule_auto_transition(source, "source")
  vim.wait(120, function() return vim.api.nvim_win_get_buf(win) == source end)

  assert_eq(vim.api.nvim_win_get_buf(win), source, "should be back on source after debounce")

  preview.auto_off()
  cleanup_buffer(source)
end)

-- ----------------------------------------------------------------------
-- Test 17: schedule_auto_transition("render") flips source → render after debounce
-- ----------------------------------------------------------------------
test("auto-transition to render swaps source → render after 50ms", function()
  local source = setup_md_buffer({ "# Hello" })
  local win = vim.api.nvim_get_current_win()

  preview.auto_on()                                 -- render
  preview._schedule_auto_transition(source, "source")
  vim.wait(120, function() return vim.api.nvim_win_get_buf(win) == source end)
  assert_eq(vim.api.nvim_win_get_buf(win), source, "precondition: source")

  preview._schedule_auto_transition(source, "render")
  vim.wait(120, function() return vim.api.nvim_win_get_buf(win) ~= source end)

  assert_false(vim.api.nvim_win_get_buf(win) == source, "should be back on render after debounce")

  preview.auto_off()
  cleanup_buffer(source)
end)

-- ----------------------------------------------------------------------
-- Test 18: auto_off clears autocmds and leaves displayed mode untouched
-- ----------------------------------------------------------------------
test("auto_off clears autocmds and preserves displayed mode", function()
  local source = setup_md_buffer({ "# Hello" })
  local win = vim.api.nvim_get_current_win()

  preview.auto_on()
  local before_buf = vim.api.nvim_win_get_buf(win)

  preview.auto_off()

  assert_eq(vim.b[source].md_render_auto, nil, "b:md_render_auto should be cleared")
  assert_true(preview._auto_state[source] == nil, "_auto_state entry should be gone")

  -- nvim_get_autocmds raises when the group no longer exists, which is
  -- the expected outcome here.
  local ok, autocmds = pcall(vim.api.nvim_get_autocmds, {
    group = preview._auto_augroup(source),
    buffer = source,
  })
  assert_true(not ok or #autocmds == 0, "no auto autocmds should remain")

  assert_eq(vim.api.nvim_win_get_buf(win), before_buf, "displayed mode should be unchanged")

  cleanup_buffer(source)
end)

-- ----------------------------------------------------------------------
-- Test 19: auto_on rejects non-markdown buffers
-- ----------------------------------------------------------------------
test("auto_on rejects non-markdown buffers", function()
  local buf = vim.api.nvim_create_buf(false, false)
  vim.bo[buf].filetype = "text"
  vim.api.nvim_buf_set_name(buf, "/tmp/md-render-auto-test-not-md.txt")
  vim.api.nvim_win_set_buf(0, buf)

  preview.auto_on()

  assert_eq(vim.b[buf].md_render_auto, nil, "non-markdown buffer should not be marked")
  assert_true(preview._auto_state[buf] == nil, "no _auto_state entry should be created")

  cleanup_buffer(buf)
end)

-- ----------------------------------------------------------------------
-- Test 20: split from source opens a horizontal split showing render
-- ----------------------------------------------------------------------
test("split from source opens a split showing render", function()
  local source = setup_md_buffer({ "# Hello", "", "para" })
  local source_win = vim.api.nvim_get_current_win()
  local before_count = #vim.api.nvim_tabpage_list_wins(0)

  preview.split()

  local after_count = #vim.api.nvim_tabpage_list_wins(0)
  assert_eq(after_count, before_count + 1, "should add exactly one window")

  local new_win = vim.api.nvim_get_current_win()
  assert_false(new_win == source_win, "new window should be the active one")

  -- Source window unchanged
  assert_eq(vim.api.nvim_win_get_buf(source_win), source, "source window unchanged")
  -- New window shows render
  local render_buf = vim.api.nvim_win_get_buf(new_win)
  assert_false(render_buf == source, "split window should not show source")

  local state = vim.api.nvim_win_get_var(new_win, "md_render_state")
  assert_eq(state.mode, "render", "split window mode should be render")
  assert_eq(state.source_buf, source, "split window source_buf should match")
  assert_eq(state.render_buf, render_buf, "split window render_buf should match")

  vim.api.nvim_win_close(new_win, true)
  cleanup_buffer(source)
end)

-- ----------------------------------------------------------------------
-- Test 21: vertical modifier produces a vertical split
-- ----------------------------------------------------------------------
test("split with mods.vertical = true produces a vertical split", function()
  local source = setup_md_buffer({ "# Hello" })
  local source_win = vim.api.nvim_get_current_win()
  local before_height = vim.api.nvim_win_get_height(source_win)
  local before_width = vim.api.nvim_win_get_width(source_win)

  preview.split({ mods = { vertical = true } })

  local new_win = vim.api.nvim_get_current_win()
  local after_height = vim.api.nvim_win_get_height(source_win)
  local after_width = vim.api.nvim_win_get_width(source_win)
  assert_true(math.abs(after_height - before_height) <= 1,
    "heights should be ~unchanged in a vertical split")
  assert_true(after_width < before_width,
    "source width should shrink (was " .. before_width .. ", now " .. after_width .. ")")

  vim.api.nvim_win_close(new_win, true)
  cleanup_buffer(source)
end)

-- ----------------------------------------------------------------------
-- Test 22: split from a render-mode window opens source in the new split
-- ----------------------------------------------------------------------
test("split from render window opens source in the new split", function()
  local source = setup_md_buffer({ "# Hello", "", "body" })
  local orig_win = vim.api.nvim_get_current_win()

  preview.toggle()
  local render_buf = vim.api.nvim_win_get_buf(orig_win)
  assert_false(render_buf == source, "precondition: render mode")

  preview.split()
  local new_win = vim.api.nvim_get_current_win()
  assert_false(new_win == orig_win, "new window must be different")

  -- Original window still on render
  assert_eq(vim.api.nvim_win_get_buf(orig_win), render_buf, "orig win still on render")
  -- New split shows source
  assert_eq(vim.api.nvim_win_get_buf(new_win), source, "new split shows source buf")
  -- New split should NOT have md_render_state
  local has_state = pcall(vim.api.nvim_win_get_var, new_win, "md_render_state")
  assert_false(has_state, "new source split should have no md_render_state")

  vim.api.nvim_win_close(new_win, true)
  preview.toggle()  -- restore orig_win to source for clean teardown
  clear_win_state(orig_win)
  cleanup_buffer(source)
end)

-- ----------------------------------------------------------------------
-- Test 23: split shares the cached toggle render buffer
-- ----------------------------------------------------------------------
test("split shares the cached toggle render buffer", function()
  local source = setup_md_buffer({ "# Hello" })
  local orig_win = vim.api.nvim_get_current_win()

  preview.toggle()
  local toggle_render = vim.api.nvim_win_get_buf(orig_win)
  preview.toggle()  -- back to source

  preview.split()
  local split_win = vim.api.nvim_get_current_win()
  local split_render = vim.api.nvim_win_get_buf(split_win)

  assert_eq(split_render, toggle_render,
    "split must reuse the cached render buffer from the toggle session")

  vim.api.nvim_win_close(split_win, true)
  clear_win_state(orig_win)
  cleanup_buffer(source)
end)

-- ----------------------------------------------------------------------
-- Test 24: live update propagates to the split's render window
-- ----------------------------------------------------------------------
test("live update propagates to the split's render window", function()
  local source = setup_md_buffer({ "# Hello", "", "para" })
  local source_win = vim.api.nvim_get_current_win()

  preview.split()
  local split_win = vim.api.nvim_get_current_win()
  local render_buf = vim.api.nvim_win_get_buf(split_win)
  local before_lines = #vim.api.nvim_buf_get_lines(render_buf, 0, -1, false)

  -- Simulate edit + live rebuild (Phase 3 Test 8 pattern; doautocmd
  -- TextChanged is unreliable in headless contexts, so call the helper).
  vim.api.nvim_buf_set_lines(source, -1, -1, false, { "", "appended paragraph" })
  preview._schedule_live_rebuild(preview._toggle_sessions[source])

  vim.wait(300, function() return false end)

  local after_lines = #vim.api.nvim_buf_get_lines(render_buf, 0, -1, false)
  assert_true(after_lines > before_lines,
    "render in split should grow after live update (was "
      .. before_lines .. ", now " .. after_lines .. ")")

  vim.api.nvim_win_close(split_win, true)
  cleanup_buffer(source)
end)

-- ----------------------------------------------------------------------
-- Test 25: closing split window keeps render buf alive; toggle still works
-- ----------------------------------------------------------------------
test("closing split window keeps render buf alive; subsequent toggle works", function()
  local source = setup_md_buffer({ "# Hello" })
  local source_win = vim.api.nvim_get_current_win()

  preview.split()
  local split_win = vim.api.nvim_get_current_win()
  local render_buf = vim.api.nvim_win_get_buf(split_win)

  vim.api.nvim_win_close(split_win, true)

  assert_true(vim.api.nvim_buf_is_valid(render_buf),
    "render buf should outlive the split window (bufhidden=hide)")
  assert_true(preview._toggle_sessions[source] ~= nil,
    "session should remain cached for the source")

  vim.api.nvim_set_current_win(source_win)
  preview.toggle()
  assert_eq(vim.api.nvim_win_get_buf(source_win), render_buf,
    "toggle should reuse the same render buf after split close")

  preview.toggle()  -- back to source for clean teardown
  clear_win_state(source_win)
  cleanup_buffer(source)
end)

-- ----------------------------------------------------------------------
-- Test 26b: toggle hides number/relativenumber/list on render and
-- restores them on render -> source
-- ----------------------------------------------------------------------
test("toggle hides number/relativenumber/list and restores them", function()
  local source = setup_md_buffer({ "# Hello", "", "body" })
  local win = vim.api.nvim_get_current_win()
  vim.wo[win].number = true
  vim.wo[win].relativenumber = true
  vim.wo[win].list = true

  preview.toggle()  -- source -> render
  assert_false(vim.wo[win].number, "render: number off")
  assert_false(vim.wo[win].relativenumber, "render: relativenumber off")
  assert_false(vim.wo[win].list, "render: list off")

  preview.toggle()  -- render -> source
  assert_true(vim.wo[win].number, "source: number restored")
  assert_true(vim.wo[win].relativenumber, "source: relativenumber restored")
  assert_true(vim.wo[win].list, "source: list restored")

  clear_win_state(win)
  cleanup_buffer(source)
end)

-- ----------------------------------------------------------------------
-- Test 26c: split's render window has nonu/nornu/nolist; source window
-- keeps its original options
-- ----------------------------------------------------------------------
test("split render window hides nu/rnu/list; source unchanged", function()
  local source = setup_md_buffer({ "# Hello" })
  local source_win = vim.api.nvim_get_current_win()
  vim.wo[source_win].number = true
  vim.wo[source_win].relativenumber = true
  vim.wo[source_win].list = true

  preview.split()
  local split_win = vim.api.nvim_get_current_win()

  assert_false(vim.wo[split_win].number, "split render: number off")
  assert_false(vim.wo[split_win].relativenumber, "split render: relativenumber off")
  assert_false(vim.wo[split_win].list, "split render: list off")

  assert_true(vim.wo[source_win].number, "source: number unchanged")
  assert_true(vim.wo[source_win].relativenumber, "source: relativenumber unchanged")
  assert_true(vim.wo[source_win].list, "source: list unchanged")

  vim.api.nvim_win_close(split_win, true)
  cleanup_buffer(source)
end)

-- ----------------------------------------------------------------------
-- Test 26: split rejects non-markdown buffers and creates no new window
-- ----------------------------------------------------------------------
test("split rejects non-markdown buffers", function()
  local buf = vim.api.nvim_create_buf(false, false)
  vim.bo[buf].filetype = "text"
  vim.api.nvim_buf_set_name(buf, "/tmp/md-render-split-test-not-md.txt")
  vim.api.nvim_win_set_buf(0, buf)

  local before_count = #vim.api.nvim_tabpage_list_wins(0)
  preview.split()
  local after_count = #vim.api.nvim_tabpage_list_wins(0)

  assert_eq(after_count, before_count, "no window should be created on rejection")
  assert_eq(vim.api.nvim_win_get_buf(0), buf, "current window unchanged")

  cleanup_buffer(buf)
end)

-- ----------------------------------------------------------------------
-- Test 27: source CursorMoved syncs render cursor to the corresponding line
-- ----------------------------------------------------------------------
test("source cursor move syncs render window cursor", function()
  local source = setup_md_buffer({ "# Heading", "", "para 1", "", "para 2" })
  local source_win = vim.api.nvim_get_current_win()

  preview.split()
  local render_win = vim.api.nvim_get_current_win()
  local session = preview._toggle_sessions[source]
  assert_true(session ~= nil, "session should exist after split")

  -- Move source cursor to line 5 ("para 2"), trigger CursorMoved
  vim.api.nvim_set_current_win(source_win)
  vim.api.nvim_win_set_cursor(source_win, { 5, 0 })
  vim.cmd "doautocmd CursorMoved"

  local expected = session:source_to_rendered(5)
  local total = vim.api.nvim_buf_line_count(session.buf)
  expected = math.min(expected, total)
  assert_eq(vim.api.nvim_win_get_cursor(render_win)[1], expected,
    "render cursor should follow source to mapped line")

  vim.api.nvim_win_close(render_win, true)
  cleanup_buffer(source)
end)

-- ----------------------------------------------------------------------
-- Test 28: render CursorMoved syncs source cursor to the corresponding line
-- ----------------------------------------------------------------------
test("render cursor move syncs source window cursor", function()
  local source = setup_md_buffer({ "# Heading", "", "para 1", "", "para 2" })
  local source_win = vim.api.nvim_get_current_win()

  preview.split()
  local render_win = vim.api.nvim_get_current_win()
  local session = preview._toggle_sessions[source]

  -- Move render cursor and fire CursorMoved
  local total_render = vim.api.nvim_buf_line_count(session.buf)
  local target_render = math.min(3, total_render)
  vim.api.nvim_win_set_cursor(render_win, { target_render, 0 })
  vim.cmd "doautocmd CursorMoved"

  local expected_source = session:rendered_to_source(target_render)
  if expected_source then
    assert_eq(vim.api.nvim_win_get_cursor(source_win)[1], expected_source,
      "source cursor should follow render to mapped line")
  end

  vim.api.nvim_win_close(render_win, true)
  cleanup_buffer(source)
end)

-- ----------------------------------------------------------------------
-- Test 29: cursor sync is a no-op when only one side has a window
-- ----------------------------------------------------------------------
test("cursor sync no-op when only source is visible", function()
  local source = setup_md_buffer({ "# A", "", "B", "", "C" })
  local source_win = vim.api.nvim_get_current_win()

  -- Create the session via toggle then return to source so render is hidden.
  preview.toggle()
  preview.toggle()  -- back to source

  -- Should not error: no render window exists, sync handler returns early.
  vim.api.nvim_win_set_cursor(source_win, { 3, 0 })
  vim.cmd "doautocmd CursorMoved"

  assert_eq(vim.api.nvim_win_get_cursor(source_win)[1], 3,
    "source cursor unchanged when no render window")

  clear_win_state(source_win)
  cleanup_buffer(source)
end)

-- ----------------------------------------------------------------------
-- Test 30: BufWipeout removes the scroll-sync augroup
-- ----------------------------------------------------------------------
test("BufWipeout removes the scroll-sync augroup", function()
  local source = setup_md_buffer({ "# A" })
  preview.toggle()
  local augroup_name = "md_render_toggle_sync_" .. source

  -- precondition: augroup exists
  local ok = pcall(vim.api.nvim_get_autocmds, { group = augroup_name })
  assert_true(ok, "scroll-sync augroup should be installed")

  cleanup_buffer(source)

  local ok2 = pcall(vim.api.nvim_get_autocmds, { group = augroup_name })
  assert_false(ok2, "scroll-sync augroup should be removed on BufWipeout")
end)

-- ----------------------------------------------------------------------
-- Scroll sync edge alignment
-- ----------------------------------------------------------------------
-- Build a markdown buffer that is taller than the test window so the
-- top/bottom scroll sync branches actually have somewhere to scroll.
local function setup_tall_md_buffer(line_count)
  local lines = {}
  for i = 1, line_count do
    if i % 7 == 1 then
      table.insert(lines, "## section " .. i)
    else
      table.insert(lines, "line " .. i)
    end
  end
  return setup_md_buffer(lines)
end

--- The sync lock releases via `vim.defer_fn`, which never fires in
--- a synchronous headless test run. Clear it before triggering each
--- autocmd so subsequent syncs are not silently dropped.
local function clear_sync_locks()
  for _, session in pairs(preview._toggle_sessions or {}) do
    session._syncing = false
    if session._sync_unlock_timer then
      pcall(function() session._sync_unlock_timer:stop() end)
      session._sync_unlock_timer = nil
    end
  end
end

local function set_view(win, topline, cursor_line)
  vim.api.nvim_win_set_cursor(win, { cursor_line, 0 })
  vim.api.nvim_win_call(win, function()
    vim.fn.winrestview { topline = topline, lnum = cursor_line, col = 0 }
  end)
  clear_sync_locks()
  vim.cmd "doautocmd CursorMoved"
end

local set_source_view = set_view

--- Resolve the render window for the session bound to `source_buf`.
--- `preview.split()` returns focus to the source window, so the render
--- window is the *other* window showing the session's render buffer.
local function find_render_win(source_buf)
  local session = preview._toggle_sessions[source_buf]
  if not session then return nil end
  local wins = vim.fn.win_findbuf(session.buf)
  return wins and wins[1] or nil
end

test("source at file top -> render at file top", function()
  local source = setup_tall_md_buffer(200)
  local source_win = vim.api.nvim_get_current_win()

  preview.split()
  local render_win = find_render_win(source)
  assert_true(render_win ~= nil, "render window should exist after split")

  -- Move source somewhere in the middle first, then snap to top.
  vim.api.nvim_set_current_win(source_win)
  set_source_view(source_win, 100, 100)
  set_source_view(source_win, 1, 1)

  local render_view = vim.api.nvim_win_call(render_win, function()
    return vim.fn.winsaveview()
  end)
  assert_eq(render_view.topline, 1,
    "render.topline should be 1 when source is at file top")

  vim.api.nvim_win_close(render_win, true)
  cleanup_buffer(source)
end)

test("source at file bottom -> render at file bottom", function()
  local source = setup_tall_md_buffer(200)
  local source_win = vim.api.nvim_get_current_win()
  local source_lines = vim.api.nvim_buf_line_count(source)

  preview.split()
  local render_win = find_render_win(source)
  local session = preview._toggle_sessions[source]
  local render_lines = vim.api.nvim_buf_line_count(session.buf)

  vim.api.nvim_set_current_win(source_win)
  -- Park source at its very last line so botline == source_lines.
  vim.api.nvim_win_call(source_win, function()
    vim.fn.cursor(source_lines, 1)
    vim.cmd "normal! zb"
  end)
  clear_sync_locks()
  vim.cmd "doautocmd CursorMoved"

  local render_botline = vim.api.nvim_win_call(render_win, function()
    return vim.fn.line("w$")
  end)
  assert_eq(render_botline, render_lines,
    "render.botline should equal render_lines when source is at file bottom")

  vim.api.nvim_win_close(render_win, true)
  cleanup_buffer(source)
end)

test("render at file top -> source at file top", function()
  local source = setup_tall_md_buffer(200)
  local source_win = vim.api.nvim_get_current_win()

  preview.split()
  local render_win = find_render_win(source)

  -- Park source somewhere in the middle, then move render to top.
  vim.api.nvim_set_current_win(source_win)
  set_source_view(source_win, 100, 100)

  vim.api.nvim_set_current_win(render_win)
  set_view(render_win, 1, 1)

  local source_view = vim.api.nvim_win_call(source_win, function()
    return vim.fn.winsaveview()
  end)
  assert_eq(source_view.topline, 1,
    "source.topline should be 1 when render is at file top")

  vim.api.nvim_win_close(render_win, true)
  cleanup_buffer(source)
end)

test("render at file bottom -> source at file bottom", function()
  local source = setup_tall_md_buffer(200)
  local source_win = vim.api.nvim_get_current_win()
  local source_lines = vim.api.nvim_buf_line_count(source)

  preview.split()
  local render_win = find_render_win(source)
  local session = preview._toggle_sessions[source]
  local render_lines = vim.api.nvim_buf_line_count(session.buf)

  -- Park render at its very last line.
  vim.api.nvim_set_current_win(render_win)
  vim.api.nvim_win_call(render_win, function()
    vim.fn.cursor(render_lines, 1)
    vim.cmd "normal! zb"
  end)
  clear_sync_locks()
  vim.cmd "doautocmd CursorMoved"

  local source_botline = vim.api.nvim_win_call(source_win, function()
    return vim.fn.line("w$")
  end)
  assert_eq(source_botline, source_lines,
    "source.botline should equal source_lines when render is at file bottom")

  vim.api.nvim_win_close(render_win, true)
  cleanup_buffer(source)
end)

-- Repro of the user-reported bug: README.ja.md (long Japanese paragraphs
-- that wrap in a typical headless 80-col window) showed render at the
-- file bottom while source stayed several lines short. The pre-fix
-- topline arithmetic assumed 1 buffer line == 1 screen row; with 'wrap'
-- on (Vim's default), wrapped lines occupy more screen rows than buffer
-- rows, so `topline = source_lines - height + 1` left the file's last
-- lines below the destination's view.
--
-- These tests build a buffer of long lines that are guaranteed to wrap
-- in any reasonable test window and assert the user-visible invariant
-- (`line('w$') == source_lines`) on both sync directions.
local function setup_wrapping_md_buffer(line_count, line_text_repeat)
  local long = string.rep(line_text_repeat or "abcdefghij ", 30)
  local lines = {}
  for i = 1, line_count do
    if i % 5 == 1 then
      table.insert(lines, "## section " .. i)
    else
      table.insert(lines, long .. " (" .. i .. ")")
    end
  end
  return setup_md_buffer(lines)
end

test("source at bottom -> render at bottom (with wrapped lines)", function()
  local source = setup_wrapping_md_buffer(120)
  local source_win = vim.api.nvim_get_current_win()
  local source_lines = vim.api.nvim_buf_line_count(source)

  preview.split()
  local render_win = find_render_win(source)
  local session = preview._toggle_sessions[source]
  local render_lines = vim.api.nvim_buf_line_count(session.buf)

  vim.api.nvim_set_current_win(source_win)
  vim.api.nvim_win_call(source_win, function()
    vim.fn.cursor(source_lines, 1)
    vim.cmd "normal! zb"
  end)
  clear_sync_locks()
  vim.cmd "doautocmd CursorMoved"

  local render_botline = vim.api.nvim_win_call(render_win, function()
    return vim.fn.line("w$")
  end)
  assert_eq(render_botline, render_lines,
    "render.botline should equal render_lines even when source has wrapped lines")

  vim.api.nvim_win_close(render_win, true)
  cleanup_buffer(source)
end)

test("render at bottom -> source at bottom (with wrapped lines)", function()
  local source = setup_wrapping_md_buffer(120)
  local source_win = vim.api.nvim_get_current_win()
  local source_lines = vim.api.nvim_buf_line_count(source)

  preview.split()
  local render_win = find_render_win(source)
  local session = preview._toggle_sessions[source]
  local render_lines = vim.api.nvim_buf_line_count(session.buf)

  vim.api.nvim_set_current_win(render_win)
  vim.api.nvim_win_call(render_win, function()
    vim.fn.cursor(render_lines, 1)
    vim.cmd "normal! zb"
  end)
  clear_sync_locks()
  vim.cmd "doautocmd CursorMoved"

  local source_botline = vim.api.nvim_win_call(source_win, function()
    return vim.fn.line("w$")
  end)
  assert_eq(source_botline, source_lines,
    "source.botline should equal source_lines even when render has wrapped lines")

  vim.api.nvim_win_close(render_win, true)
  cleanup_buffer(source)
end)

test("source at top -> render at top (with wrapped lines)", function()
  local source = setup_wrapping_md_buffer(120)
  local source_win = vim.api.nvim_get_current_win()

  preview.split()
  local render_win = find_render_win(source)

  -- Park source somewhere in the middle first so the snap-to-top has
  -- something to undo.
  vim.api.nvim_set_current_win(source_win)
  set_source_view(source_win, 60, 60)
  set_source_view(source_win, 1, 1)

  local render_topline = vim.api.nvim_win_call(render_win, function()
    return vim.fn.line("w0")
  end)
  assert_eq(render_topline, 1,
    "render.topline should be 1 when source snaps to file top")

  vim.api.nvim_win_close(render_win, true)
  cleanup_buffer(source)
end)

test("render at top -> source at top (with wrapped lines)", function()
  local source = setup_wrapping_md_buffer(120)
  local source_win = vim.api.nvim_get_current_win()

  preview.split()
  local render_win = find_render_win(source)

  -- Park source somewhere in the middle so the snap is observable.
  vim.api.nvim_set_current_win(source_win)
  set_source_view(source_win, 60, 60)

  vim.api.nvim_set_current_win(render_win)
  set_view(render_win, 1, 1)

  local source_topline = vim.api.nvim_win_call(source_win, function()
    return vim.fn.line("w0")
  end)
  assert_eq(source_topline, 1,
    "source.topline should be 1 when render snaps to file top")

  vim.api.nvim_win_close(render_win, true)
  cleanup_buffer(source)
end)

print(string.format("toggle_test: %d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
