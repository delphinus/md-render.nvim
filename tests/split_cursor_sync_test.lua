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

-- ----------------------------------------------------------------------
-- Test 7-9: the cursor sits at the same height on both sides
-- ----------------------------------------------------------------------
-- The two buffers spend screen rows very differently. A source line packed
-- with wiki links wraps over several rows, while the preview shortens each
-- link and fits the same line in one or two. So a source window can show only
-- a handful of buffer lines whose rendered counterpart is much shorter than the
-- preview window. Aligning the visible ranges cannot satisfy both ends then;
-- the bottom clamp used to win, and a heading at the top of the source showed
-- up in the middle of the preview.
--
-- What has to agree is where the cursor is: if it is on the top row of the
-- source, its counterpart is on the top row of the preview.

--- Short list items, a heading, then lines long enough to wrap many times.
---@return integer buf, integer heading_line
local function setup_wrapped_tail_buffer()
  local lines = {}
  for i = 1, 40 do
    table.insert(lines, "- item " .. i)
  end
  table.insert(lines, "")
  table.insert(lines, "## Target heading")
  local heading = #lines
  table.insert(lines, "")
  for i = 1, 12 do
    table.insert(lines, "- **long " .. i .. "** " .. string.rep("[[note-" .. i .. "|alias]] ", 20))
  end
  local buf = vim.api.nvim_create_buf(false, false)
  vim.bo[buf].filetype = "markdown"
  vim.api.nvim_buf_set_name(buf, "/tmp/md-render-split-anchor-test-" .. buf .. ".md")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_win_set_buf(0, buf)
  return buf, heading
end

--- Screen rows between the top of `win` and the first row of `line`.
local function rows_above(win, line)
  local top = view_of(win)[1]
  if line <= top then return 0 end
  return vim.api.nvim_win_text_height(win, { start_row = top - 1, end_row = line - 2 }).all
end

local function render_line_of(session, pattern)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(session.buf, 0, -1, false)) do
    if l:find(pattern, 1, true) then return i end
  end
end

test("a heading at the top of a wrapped source is at the top of the preview", function()
  local source, heading = setup_wrapped_tail_buffer()
  local source_win = vim.api.nvim_get_current_win()
  vim.wo[source_win].wrap = true

  preview.split { mods = { vertical = true } }
  local session = preview._toggle_sessions[source]
  local render_win = find_render_win(source)

  vim.api.nvim_set_current_win(source_win)
  vim.fn.winrestview { topline = heading, lnum = heading, col = 0 }
  assert_true(
    vim.fn.line "w$" < vim.api.nvim_buf_line_count(source),
    "fixture precondition: the source is not at the end of the file"
  )
  clear_sync_locks()
  vim.cmd "doautocmd CursorMoved"

  -- The heading's block starts with the blank row the renderer puts above it,
  -- so this is a line or so before the heading text itself.
  local target = session:source_to_rendered(heading)
  assert_true(
    math.abs(target - render_line_of(session, "Target heading")) <= 1,
    "fixture precondition: the heading maps onto its own block"
  )
  assert_eq(vim.api.nvim_win_get_cursor(render_win)[1], target, "the preview cursor is on the heading")
  assert_true(
    rows_above(render_win, target) <= 1,
    "the heading is on the top row of the preview, got row " .. rows_above(render_win, target)
  )

  cleanup(source, render_win)
end)

test("a cursor a third of the way down the source is there on the preview too", function()
  local source = setup_tall_md_buffer(120)
  local source_win = vim.api.nvim_get_current_win()

  preview.split { mods = { vertical = true } }
  local session = preview._toggle_sessions[source]
  local render_win = find_render_win(source)

  vim.api.nvim_set_current_win(source_win)
  local height = vim.api.nvim_win_get_height(source_win)
  local cursor = 121
  vim.fn.winrestview { topline = cursor - math.floor(height / 3), lnum = cursor, col = 0 }
  clear_sync_locks()
  vim.cmd "doautocmd CursorMoved"

  local src_frac = rows_above(source_win, cursor) / height
  local render_cursor = vim.api.nvim_win_get_cursor(render_win)[1]
  local dst_frac = rows_above(render_win, render_cursor) / vim.api.nvim_win_get_height(render_win)
  assert_true(
    math.abs(src_frac - dst_frac) <= 2 / height,
    ("the cursor is at the same height: source %.2f, preview %.2f"):format(src_frac, dst_frac)
  )
  assert_eq(
    render_cursor,
    math.floor(session:source_to_rendered_f(cursor) + 0.5),
    "the preview cursor is on the mapped line"
  )

  cleanup(source, render_win)
end)

test("a render cursor at the top puts a wrapped source line at the top", function()
  local source, heading = setup_wrapped_tail_buffer()
  local source_win = vim.api.nvim_get_current_win()
  vim.wo[source_win].wrap = true

  preview.split { mods = { vertical = true } }
  local session = preview._toggle_sessions[source]
  local render_win = find_render_win(source)

  -- The second long item, on the top row of the preview.
  local target = render_line_of(session, "long 2")
  vim.api.nvim_set_current_win(render_win)
  vim.fn.winrestview { topline = target, lnum = target, col = 0 }
  clear_sync_locks()
  vim.cmd "doautocmd CursorMoved"

  local src_cursor = vim.api.nvim_win_get_cursor(source_win)[1]
  assert_eq(src_cursor, heading + 3, "the source cursor is on the second long item")
  assert_true(
    rows_above(source_win, src_cursor) <= 1,
    "the item is on the top row of the source, got row " .. rows_above(source_win, src_cursor)
  )

  cleanup(source, render_win)
end)

test("the split opens with the cursor at the same height as in the source", function()
  local source, heading = setup_wrapped_tail_buffer()
  local source_win = vim.api.nvim_get_current_win()
  vim.wo[source_win].wrap = true
  vim.fn.winrestview { topline = heading, lnum = heading, col = 0 }

  preview.split { mods = { vertical = true } }
  local session = preview._toggle_sessions[source]
  local render_win = find_render_win(source)

  local target = session:source_to_rendered(heading)
  assert_true(
    rows_above(render_win, target) <= 1,
    "the heading is on the top row of the new preview, got row " .. rows_above(render_win, target)
  )

  cleanup(source, render_win)
end)

print(string.format("split_cursor_sync_test: %d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
