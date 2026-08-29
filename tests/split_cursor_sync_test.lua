-- MdRenderSplit cursor sync: the source cursor must not be dragged around by
-- the render side's own echo.
--
-- The map between the two buffers is many-to-one wherever the render collapses
-- source lines. A folded `<details>` is the sharpest case: every line of the
-- block renders as the single "▶ summary" line, so mapping that rendered line
-- back picks the block's *first* source line. Feed that back into the source
-- window and a held `j` never leaves the block — it walks a line or two in and
-- gets pulled to the top, over and over.
--
-- Sending the echo back is the part these tests fake, because the real thing is
-- a race: `sync_from_source` writes the render window, the write fires
-- CursorMoved / WinScrolled there, and the 30 ms `_syncing` lock is supposed to
-- swallow them. Under a busy configuration the events arrive after the lock has
-- released — which is why this only ever showed up with a full plugin set and
-- not with a minimal one. `clear_sync_locks()` reproduces exactly that state,
-- deterministically, and both entry points on the render side end up in the
-- same `sync_from_render`.
--
-- Run: nvim --headless -u NONE --noplugin -l tests/split_cursor_sync_test.lua

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

local function test(name, fn)
  local ok, err = pcall(fn)
  if not ok then
    fail_count = fail_count + 1
    print("ERROR: " .. name .. ": " .. tostring(err))
  end
end

-- ----------------------------------------------------------------------
-- Fixture
-- ----------------------------------------------------------------------

--- A buffer with one collapsed `<details>` block in the middle, padded on
--- both sides so the window has somewhere to scroll.
---
--- Returns the buffer plus the source line numbers of the block, so the
--- assertions can talk about "inside the block" without counting by hand.
---@param before integer filler lines before the block
---@param hidden integer body lines inside it
---@param after integer filler lines after it
---@return integer buf, integer block_start, integer block_end
local function setup_details_buffer(before, hidden, after)
  local lines = { "# Title", "" }
  for i = 1, before do
    table.insert(lines, "before line " .. i)
    table.insert(lines, "")
  end
  local block_start = #lines + 1
  table.insert(lines, "<details>")
  table.insert(lines, "<summary><strong>collapsed block</strong></summary>")
  table.insert(lines, "")
  for i = 1, hidden do
    table.insert(lines, "hidden line " .. i)
    table.insert(lines, "")
  end
  table.insert(lines, "</details>")
  local block_end = #lines
  table.insert(lines, "")
  for i = 1, after do
    table.insert(lines, "after line " .. i)
    table.insert(lines, "")
  end

  local buf = vim.api.nvim_create_buf(false, false)
  vim.bo[buf].filetype = "markdown"
  vim.api.nvim_buf_set_name(buf, "/tmp/md-render-split-cursor-test-" .. buf .. ".md")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_win_set_buf(0, buf)
  return buf, block_start, block_end
end

local function cleanup(source, render_win)
  if render_win and vim.api.nvim_win_is_valid(render_win) then vim.api.nvim_win_close(render_win, true) end
  if vim.api.nvim_buf_is_valid(source) then pcall(vim.api.nvim_buf_delete, source, { force = true }) end
end

local function find_render_win(source_buf)
  local session = preview._toggle_sessions[source_buf]
  if not session then return nil end
  local wins = vim.fn.win_findbuf(session.buf)
  return wins and wins[1] or nil
end

--- The sync lock releases via `vim.defer_fn`, which never fires in a
--- synchronous headless run. Clearing it by hand is also what makes these
--- tests model the bug: a real echo that outran the 30 ms timer.
local function clear_sync_locks()
  for _, session in pairs(preview._toggle_sessions or {}) do
    session._syncing = false
    if session._sync_unlock_timer then
      pcall(function()
        session._sync_unlock_timer:stop()
      end)
      session._sync_unlock_timer = nil
    end
  end
end

--- Deliver a CursorMoved for the render window as the render window, which
--- is how the echo of our own write arrives.
local function echo_from_render(session, render_win)
  clear_sync_locks()
  vim.api.nvim_win_call(render_win, function()
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = session.buf })
  end)
end

--- `{ topline, cursor_line }`, read the same way the sync records it:
--- `winsaveview()` reports the stored topline, `line('w0')` recomputes it, and
--- the two disagree until the next redraw — which never comes in a headless
--- run.
local function view_of(win)
  return vim.api.nvim_win_call(win, function()
    local v = vim.fn.winsaveview()
    return { v.topline, v.lnum }
  end)
end

--- Move the source cursor and let the sync run, as a user keystroke would.
---
--- `feedkeys` moves the cursor but fires nothing: a headless `-l` run never
--- gets back to the main loop, which is where Neovim notices the cursor has
--- moved. The event has to be raised by hand, the way the other split tests
--- do it.
local function press_j(source_win)
  vim.api.nvim_set_current_win(source_win)
  vim.api.nvim_feedkeys("j", "nx", false)
  clear_sync_locks()
  vim.cmd "doautocmd CursorMoved"
end

-- ----------------------------------------------------------------------
-- Test 1: the echo must not drag the source cursor to the top of a block
-- ----------------------------------------------------------------------
test("render echo leaves a cursor inside a collapsed <details> alone", function()
  local source, block_start = setup_details_buffer(6, 4, 6)
  local source_win = vim.api.nvim_get_current_win()

  preview.split()
  local session = preview._toggle_sessions[source]
  local render_win = find_render_win(source)
  assert_true(render_win ~= nil, "render window should exist after split")

  -- Four lines into the block: `<details>`, `<summary>`, blank, body.
  local inside = block_start + 3
  vim.api.nvim_set_current_win(source_win)
  vim.api.nvim_win_set_cursor(source_win, { inside, 0 })
  clear_sync_locks()
  vim.cmd "doautocmd CursorMoved"

  -- Precondition: this is a spot the round trip cannot preserve. The whole
  -- block shares one rendered line, and that line maps back to the start of
  -- the run — above the cursor, which is what dragged it backwards.
  local rendered = math.floor(session:source_to_rendered_f(inside) + 0.5)
  local back = math.floor(session:rendered_to_source_f(rendered) + 0.5)
  assert_true(
    back < inside and back >= block_start,
    "fixture precondition: source " .. inside .. " round-trips to " .. back .. ", inside the block and above it"
  )

  echo_from_render(session, render_win)

  assert_eq(vim.api.nvim_win_get_cursor(source_win)[1], inside, "source cursor stays where the user put it")

  cleanup(source, render_win)
end)

-- ----------------------------------------------------------------------
-- Test 2: holding `j` walks out of the block instead of circling in it
-- ----------------------------------------------------------------------
test("held j walks out of a collapsed <details> instead of looping", function()
  local source, block_start, block_end = setup_details_buffer(6, 6, 8)
  local source_win = vim.api.nvim_get_current_win()

  preview.split()
  local session = preview._toggle_sessions[source]
  local render_win = find_render_win(source)

  vim.api.nvim_set_current_win(source_win)
  vim.api.nvim_win_set_cursor(source_win, { block_start - 1, 0 })
  clear_sync_locks()
  vim.cmd "doautocmd CursorMoved"

  local seen = { vim.api.nvim_win_get_cursor(source_win)[1] }
  local presses = block_end - block_start + 4
  for _ = 1, presses do
    press_j(source_win)
    -- Every keystroke's sync writes the render window, and every write comes
    -- back late. This is the loop as recorded: `j`, echo, `j`, echo.
    echo_from_render(session, render_win)
    table.insert(seen, vim.api.nvim_win_get_cursor(source_win)[1])
  end

  local monotonic = true
  for i = 2, #seen do
    if seen[i] ~= seen[i - 1] + 1 then monotonic = false end
  end
  assert_true(monotonic, "every j advances exactly one line, got " .. table.concat(seen, " "))
  assert_true(
    seen[#seen] > block_end,
    "the cursor gets past </details> at " .. block_end .. ", reached " .. seen[#seen]
  )

  cleanup(source, render_win)
end)

-- ----------------------------------------------------------------------
-- Test 3: a source cursor that really is out of sync still gets corrected
-- ----------------------------------------------------------------------
test("render -> source still moves a cursor that is genuinely elsewhere", function()
  local source, block_start = setup_details_buffer(6, 4, 8)
  local source_win = vim.api.nvim_get_current_win()

  preview.split()
  local session = preview._toggle_sessions[source]
  local render_win = find_render_win(source)

  -- Park the source at the top and the render cursor on the block's line:
  -- the two sides disagree, so the sync has real work to do.
  vim.api.nvim_set_current_win(source_win)
  vim.api.nvim_win_set_cursor(source_win, { 1, 0 })
  clear_sync_locks()
  vim.cmd "doautocmd CursorMoved"

  local block_render_line = math.floor(session:source_to_rendered_f(block_start) + 0.5)
  vim.api.nvim_win_set_cursor(render_win, { block_render_line, 0 })
  local expected = math.max(1, math.floor(session:rendered_to_source_f(block_render_line) + 0.5))
  assert_true(expected > 1, "fixture precondition: the mapped source line is not where the cursor already is")

  clear_sync_locks()
  vim.api.nvim_win_call(render_win, function()
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = session.buf })
  end)

  assert_eq(vim.api.nvim_win_get_cursor(source_win)[1], expected, "source cursor follows the render cursor")

  cleanup(source, render_win)
end)

-- ----------------------------------------------------------------------
-- Test 4: an untouched render window is recognised as our own write
-- ----------------------------------------------------------------------
-- Not just the cursor: the echo used to rewrite the source *view* as well, so
-- the whole thing — topline included — has to survive it.
test("an echo from an untouched render window changes nothing on the source", function()
  local source, block_start = setup_details_buffer(20, 4, 20)
  local source_win = vim.api.nvim_get_current_win()

  preview.split()
  local session = preview._toggle_sessions[source]
  local render_win = find_render_win(source)

  vim.api.nvim_set_current_win(source_win)
  vim.api.nvim_win_set_cursor(source_win, { block_start + 3, 0 })
  clear_sync_locks()
  vim.cmd "doautocmd CursorMoved"

  local before = view_of(source_win)
  assert_true(
    session._synced_views ~= nil and session._synced_views[render_win] ~= nil,
    "the sync records the view it wrote into the render window"
  )
  -- `{ topline, cursor_line, written_at }`; the timestamp is not part of the
  -- view, so compare the two fields that are.
  local record = session._synced_views and session._synced_views[render_win] or {}
  assert_eq({ record[1], record[2] }, view_of(render_win), "and the record matches what the window holds")

  echo_from_render(session, render_win)

  assert_eq(view_of(source_win), before, "source topline and cursor both survive the echo")

  cleanup(source, render_win)
end)

-- ----------------------------------------------------------------------
-- Test 5: the preview is not scrolled back over its own scrolling
-- ----------------------------------------------------------------------
-- Placing the cursor scrolls the render window forward by a line on its own.
-- The next sync derives a topline from the source's range through a rounded
-- map, so it comes out a line behind, and writing it scrolls the window back.
-- Held down, that is the preview shuddering once every couple of keystrokes —
-- 11 such writes in 59 on a `j` sweep through this repo's README.ja.md.
--
-- Faked here by nudging the render window forward the way its own cursor
-- placement would, since a headless run never redraws and so never scrolls a
-- window by itself.
local function setup_tall_md_buffer(count)
  local lines = {}
  for i = 1, count do
    if i % 6 == 1 then
      table.insert(lines, "## section " .. i)
    else
      table.insert(lines, string.rep("word ", 12) .. "(" .. i .. ")")
    end
    table.insert(lines, "")
  end
  local buf = vim.api.nvim_create_buf(false, false)
  vim.bo[buf].filetype = "markdown"
  vim.api.nvim_buf_set_name(buf, "/tmp/md-render-split-jitter-test-" .. buf .. ".md")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_win_set_buf(0, buf)
  return buf
end

test("a preview that scrolled itself a line ahead is left where it is", function()
  local source = setup_tall_md_buffer(120)
  local source_win = vim.api.nvim_get_current_win()

  preview.split()
  local render_win = find_render_win(source)

  vim.api.nvim_set_current_win(source_win)
  vim.api.nvim_win_set_cursor(source_win, { 80, 0 })
  clear_sync_locks()
  vim.cmd "doautocmd CursorMoved"

  local settled = view_of(render_win)[1]
  assert_true(settled > 1, "precondition: the sync scrolled the preview into the middle of the buffer")

  -- One line forward, cursor untouched: what the render window does to itself.
  vim.api.nvim_win_call(render_win, function()
    vim.fn.winrestview { topline = settled + 1 }
  end)
  clear_sync_locks()
  vim.api.nvim_set_current_win(source_win)
  vim.cmd "doautocmd CursorMoved"

  assert_eq(view_of(render_win)[1], settled + 1, "the sync does not drag the preview back a line")

  cleanup(source, render_win)
end)

-- ...but the tolerance is a line, not a licence to drift.
test("a preview that is really out of position is still scrolled back", function()
  local source = setup_tall_md_buffer(120)
  local source_win = vim.api.nvim_get_current_win()

  preview.split()
  local render_win = find_render_win(source)
  local session = preview._toggle_sessions[source]

  vim.api.nvim_set_current_win(source_win)
  vim.api.nvim_win_set_cursor(source_win, { 80, 0 })
  clear_sync_locks()
  vim.cmd "doautocmd CursorMoved"

  local settled = view_of(render_win)[1]
  local render_lines = vim.api.nvim_buf_line_count(session.buf)
  local far = math.min(settled + 20, render_lines)
  vim.api.nvim_win_call(render_win, function()
    vim.fn.winrestview { topline = far }
  end)
  clear_sync_locks()
  vim.api.nvim_set_current_win(source_win)
  vim.cmd "doautocmd CursorMoved"

  local top = view_of(render_win)[1]
  assert_true(
    math.abs(top - settled) <= 1,
    "the preview is put back where the source says it belongs: " .. settled .. " vs " .. top
  )

  cleanup(source, render_win)
end)

print(string.format("split_cursor_sync_test: %d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
