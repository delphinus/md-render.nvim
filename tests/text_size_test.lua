-- Test scaled heading placements (Kitty text sizing protocol, OSC 66)
-- Run: nvim --headless -u NONE --noplugin -l tests/text_size_test.lua

package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local ContentBuilder = require("md-render.content_builder").ContentBuilder
local text_size = require "md-render.text_size"
local markdown = require "md-render.markdown"

local pass_count = 0
local fail_count = 0

local function assert_true(val, msg)
  if val then
    pass_count = pass_count + 1
  else
    fail_count = fail_count + 1
    print("FAIL: " .. msg)
  end
end

local function assert_eq(actual, expected, msg)
  if actual == expected then
    pass_count = pass_count + 1
  else
    fail_count = fail_count + 1
    print(string.format("FAIL: %s\n  expected: %s\n  actual:   %s", msg, vim.inspect(expected), vim.inspect(actual)))
  end
end

-- The real probe talks to the terminal, which is not available headless.
local real_supports = text_size.supports
local function with_support(supported, fn)
  text_size.supports = function()
    return supported
  end
  local ok, err = pcall(fn)
  text_size.supports = real_supports
  if not ok then error(err) end
end

local function render(lines, opts)
  local b = ContentBuilder.new()
  b:render_document(lines, opts or { max_width = 80, indent = "  " })
  return b:result()
end

-- ---------------------------------------------------------------------------
-- Gating
-- ---------------------------------------------------------------------------

-- Test 0: on by default. Asserted before anything calls setup(), since every
-- later test sets `enabled` explicitly.
do
  assert_eq(text_size.config().enabled, true, "enabled by default")
end

-- Test 1: turning it off leaves no placements and no reserved rows
do
  text_size.setup { enabled = false }
  with_support(true, function()
    local out = render { "# Heading", "", "Body." }
    assert_eq(#out.text_placements, 0, "disabled: no text placements")
    assert_eq(out.lines[2], "  Body.", "disabled: no row reserved under the heading")
  end)
end

-- Test 2: an unsupporting terminal must not reserve rows either, or every
-- heading would be followed by a stray blank line
do
  text_size.setup { enabled = true }
  with_support(false, function()
    local out = render { "# Heading", "", "Body." }
    assert_eq(#out.text_placements, 0, "unsupported terminal: no text placements")
    assert_eq(out.lines[2], "  Body.", "unsupported terminal: no row reserved")
  end)
end

-- Test 3: every level scales, on a ladder that only ever descends. `s` stays
-- at 2 throughout so that no level reserves more than one extra row.
do
  text_size.setup { enabled = true }
  with_support(true, function()
    local prev
    for level = 1, 6 do
      local spec = text_size.spec_for(level)
      assert_true(spec ~= nil, "level " .. level .. " scales")
      if spec then
        assert_eq(spec.s, 2, "level " .. level .. " reserves exactly one extra row")
        assert_true(spec.ratio > 1, "level " .. level .. " is larger than plain text")
        if prev then assert_true(spec.ratio < prev, "level " .. level .. " is smaller than level " .. (level - 1)) end
        prev = spec.ratio
      end
    end
    assert_eq(text_size.spec_for(7), nil, "there is no level 7")
  end)
  text_size.setup { enabled = false }
end

-- Test 3b: the protocol bounds every value we send. `d` is capped at 15 and
-- `w` at 7, and exceeding either makes Kitty reject or mis-size the run.
do
  text_size.setup { enabled = true }
  with_support(true, function()
    for level = 1, 6 do
      local spec = text_size.spec_for(level)
      assert_true(spec.s >= 1 and spec.s <= 7, "level " .. level .. ": s within 1..7")
      if spec.n then
        assert_true(spec.d <= 15, "level " .. level .. ": d within the protocol's limit")
        assert_true(spec.n < spec.d, "level " .. level .. ": n < d")
        local runs = text_size.split_run(string.rep("x", 200), spec)
        for _, run in ipairs(runs) do
          assert_true(run.w >= 1 and run.w <= 7, "level " .. level .. ": w within 1..7")
        end
      end
    end
  end)
  text_size.setup { enabled = false }
end

-- Test 3c: a run's advertised width matches what it actually draws. The
-- terminal is told `w` cells per run, so the painted width is the sum of
-- those, not `strwidth(text) * ratio` — which is what the fit check relies on.
do
  text_size.setup { enabled = true }
  with_support(true, function()
    for level = 1, 6 do
      local spec = text_size.spec_for(level)
      for _, text in ipairs {
        "The quick brown fox jumps over the lazy dog",
        "あいうえおかきくけこさしすせそ",
      } do
        local runs, width = text_size.split_run(text, spec)
        local sum, joined = 0, {}
        for _, run in ipairs(runs) do
          sum = sum + (run.w > 0 and run.w * spec.s or vim.api.nvim_strwidth(run.text) * spec.s)
          table.insert(joined, run.text)
        end
        assert_eq(width, sum, "level " .. level .. ": reported width is the sum of the runs")
        assert_eq(table.concat(joined), text, "level " .. level .. ": splitting loses no text")
        -- Rounding `w` up can only ever add cells, and never more than one
        -- `s`-block's worth in total (see `heading_scale_plan`).
        local exact = vim.api.nvim_strwidth(text) * spec.ratio
        assert_true(width >= exact - 0.001, "level " .. level .. ": never narrower than the exact size")
        assert_true(width < exact + spec.s, "level " .. level .. ": no more than one block of slack")
      end
    end
  end)
  text_size.setup { enabled = false }
end

-- ---------------------------------------------------------------------------
-- Placements
-- ---------------------------------------------------------------------------

-- Test 4: a scaled heading reserves one row and registers one placement
do
  text_size.setup { enabled = true }
  with_support(true, function()
    local out = render { "# Heading", "", "Body." }
    assert_eq(#out.text_placements, 1, "one placement for one heading")
    local p = out.text_placements[1]
    assert_eq(p.line, 0, "placement anchored to the heading line")
    assert_eq(p.scale, 2, "placement scale")
    assert_eq(p.num, nil, "h1 needs no fractional scale")
    assert_eq(#p.runs, 1, "h1 goes out as a single run")
    assert_eq(p.runs[1].w, 0, "h1 lets the terminal work out the width")
    assert_eq(p.width, vim.api.nvim_strwidth(p.text) * 2, "h1 covers twice its plain width")
    assert_eq(p.hl, "MdRenderH1", "placement highlight group")
    assert_eq(out.lines[2], "", "one blank row reserved for the taller glyphs")
    assert_eq(out.lines[3], "  Body.", "body follows the reserved row")
  end)
  text_size.setup { enabled = false }
end

-- Test 5: the level icon is excluded from the scaled run. Kitty clips a
-- scaled run to `scale` cells per source cell, and these glyphs report as one
-- cell while being drawn wider, so an included icon renders as a bare "H".
do
  text_size.setup { enabled = true }
  with_support(true, function()
    local out = render { "## Heading" }
    local p = out.text_placements[1]
    assert_eq(p.text, "Heading", "icon is not part of the scaled text")
    local icon = markdown.heading_icon(2)
    assert_true(not p.text:find(icon, 1, true), "icon glyph absent from the payload")
    local line = out.lines[p.line + 1]
    assert_true(line:find(icon, 1, true) ~= nil, "icon stays in the buffer line")
    assert_eq(line:sub(p.col + 1, p.col + #p.text), p.text, "placement col points at the text")
  end)
  text_size.setup { enabled = false }
end

-- Test 6: a heading too wide to double gets wrapped, one placement per line,
-- and each scaled line fits within max_width
do
  text_size.setup { enabled = true }
  with_support(true, function()
    local max_width = 60
    local out = render({ "## " .. string.rep("word ", 20) }, { max_width = max_width, indent = "  " })
    assert_true(#out.text_placements > 1, "long heading wraps into several scaled blocks")
    for _, p in ipairs(out.text_placements) do
      local scaled = p.col + p.width
      assert_true(scaled <= max_width, string.format("scaled block fits (%d <= %d)", scaled, max_width))
      local line = out.lines[p.line + 1]
      assert_eq(line:sub(p.col + 1, p.col + #p.text), p.text, "wrapped placement anchored correctly")
      assert_eq(out.lines[p.line + 2], "", "each wrapped line reserves its own row")
    end
  end)
  text_size.setup { enabled = false }
end

-- Test 7: a window too narrow to wrap sensibly leaves the heading plain
do
  text_size.setup { enabled = true }
  with_support(true, function()
    local out = render({ "# Heading" }, { max_width = 16, indent = "  " })
    assert_eq(#out.text_placements, 0, "no scaling when the halved width is too narrow")
    assert_eq(#out.lines, 1, "and no row is reserved")
  end)
  text_size.setup { enabled = false }
end

-- Test 8: links inside a wrapped scaled heading keep pointing at the line
-- they were distributed to, despite the reserved rows shifting everything
do
  text_size.setup { enabled = true }
  with_support(true, function()
    local out = render({
      "# See [alpha](https://example.com/a) then [bravo](https://example.com/b) and more words here",
    }, { max_width = 60, indent = "  " })
    assert_true(#out.link_metadata >= 2, "both links survive")
    for _, l in ipairs(out.link_metadata) do
      local line = out.lines[l.line + 1] or ""
      assert_true(line ~= "", "link " .. l.url .. " does not land on a reserved blank row")
    end
  end)
  text_size.setup { enabled = false }
end

-- Test 9: a deeper heading scales too, and carries the fractional metadata
do
  text_size.setup { enabled = true }
  with_support(true, function()
    local out = render({ "#### Fourth Level" }, { max_width = 80, indent = "  " })
    assert_eq(#out.text_placements, 1, "h4 registers a placement")
    local p = out.text_placements[1]
    assert_eq(p.text, "Fourth Level", "icon stays out of the h4 payload")
    assert_eq(p.hl, "MdRenderH4", "h4 uses its own highlight group")
    assert_eq(p.num, 7, "h4 numerator")
    assert_eq(p.den, 10, "h4 denominator")
    assert_true(#p.runs >= 2, "h4 splits into several runs")
    assert_eq(out.lines[2], "", "h4 still reserves exactly one row")
  end)
  text_size.setup { enabled = false }
end

-- Test 10: a two-cell CJK character never straddles a run boundary, which
-- would leave the run a fraction of a cell wide and shift the rest of the
-- heading. Chunk sizes are even for exactly this reason.
do
  text_size.setup { enabled = true }
  with_support(true, function()
    for level = 2, 6 do
      local spec = text_size.spec_for(level)
      local runs = text_size.split_run(string.rep("あ", 40), spec)
      for i, run in ipairs(runs) do
        local w = vim.api.nvim_strwidth(run.text)
        assert_eq(w % 2, 0, string.format("level %d run %d ends on a whole CJK character", level, i))
        -- Only the trailing run is allowed to round its width up: it holds
        -- whatever is left over, which need not be a whole chunk.
        if i < #runs then
          assert_eq(run.w, w * spec.n / spec.d, string.format("level %d run %d asks for an exact width", level, i))
        end
      end
    end
  end)
  text_size.setup { enabled = false }
end

-- Test 11: rounding slack is pushed onto a word boundary. `w` is rounded up
-- because Kitty drops characters that do not fit, and the leftover cells paint
-- as background — a gap in mid-word if the run ends there, an unremarkably
-- wider space if it ends after one.
do
  text_size.setup { enabled = true }
  with_support(true, function()
    for level = 2, 6 do
      local spec = text_size.spec_for(level)
      -- CJK words separated by spaces: the chunk boundary lands mid-word
      -- unless the split goes looking for the space.
      local runs = text_size.split_run("あいうえお かきくけこ さしすせそ たちつてと", spec)
      for i, run in ipairs(runs) do
        local cw = vim.api.nvim_strwidth(run.text)
        local exact = (cw * spec.n) % spec.d == 0
        local at_word_end = run.text:sub(-1) == " "
        if i < #runs then
          assert_true(exact or at_word_end, string.format("level %d run %d hides its slack (%q)", level, i, run.text))
        end
      end
    end
  end)
  text_size.setup { enabled = false }
end

-- Test 12: hiding the slack costs cells, so a caller that cannot spare them
-- gets the compact split back instead.
do
  text_size.setup { enabled = true }
  with_support(true, function()
    local spec = text_size.spec_for(2)
    -- Short words: cutting after every one of them wastes more on rounding
    -- than filling each run to the chunk would.
    local text = "あい うえ おか きく けこ さし すせ"
    local _, pretty = text_size.split_run(text, spec)
    local compact_runs, compact = text_size.split_run(text, spec, pretty - 1)
    assert_true(compact < pretty, "the compact split is narrower than the pretty one")
    local joined = {}
    for _, run in ipairs(compact_runs) do
      table.insert(joined, run.text)
    end
    assert_eq(table.concat(joined), text, "the compact split loses no text either")
    local _, unchanged = text_size.split_run(text, spec, pretty)
    assert_eq(unchanged, pretty, "a budget that fits keeps the pretty split")
  end)
  text_size.setup { enabled = false }
end

-- Test 13: a caller that will never paint the runs (a picker previewer) opts
-- out at build time, so it does not get rows reserved for text nobody draws.
do
  text_size.setup { enabled = true }
  with_support(true, function()
    local out = render({ "# Heading", "", "Body." }, { max_width = 80, indent = "  ", text_scale = false })
    assert_eq(#out.text_placements, 0, "text_scale = false: no placements")
    assert_eq(out.lines[2], "  Body.", "text_scale = false: no row reserved")
  end)
  text_size.setup { enabled = false }
end

-- Test 14: a full-screen repaint by another module is a hand-off, not a loss.
-- Kitty graphics placements and these OSC 66 runs both live outside Neovim's
-- grid and are both destroyed by a repaint neither module can observe, so
-- whoever repaints announces it and the other puts itself back.
do
  local display_utils = require "md-render.display_utils"
  text_size.setup { enabled = true }
  with_support(true, function()
    local out = render { "# Heading", "", "Body." }
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, out.lines)
    local win = vim.api.nvim_get_current_win()
    local prev_buf = vim.api.nvim_win_get_buf(win)
    vim.api.nvim_win_set_buf(win, buf)

    local painted = 0
    local real_paint = text_size.paint
    text_size.paint = function()
      painted = painted + 1
    end

    local state = text_size.attach(win, out)
    assert_true(state ~= nil, "attaches when there are placements")
    -- Repaints nobody announces still happen (other plugins, the terminal
    -- shifting cells on a mouse scroll), so the runs are re-asserted on a tick.
    assert_true(state.keepalive_timer ~= nil, "a keep-alive tick is running")

    painted = 0
    display_utils.announce_repaint "image"
    assert_eq(painted, 1, "an image repaint makes the scaled text repaint")

    painted = 0
    display_utils.announce_repaint "text_size"
    assert_eq(painted, 0, "our own repaint does not bounce back at us")

    text_size.paint = real_paint
    text_size.detach(state)
    assert_eq(state.keepalive_timer, nil, "detaching stops the keep-alive tick")
    vim.api.nvim_win_set_buf(win, prev_buf)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
  text_size.setup { enabled = false }
end

-- Test 15: a scroll destroys the runs in the same frame it happens, long
-- before any debounce could fire, so they are written again on the event
-- itself. Waiting left the headings plain-size for a measured 50 ms per wheel
-- notch, which is what the pulsing while scrolling was.
do
  text_size.setup { enabled = true }
  with_support(true, function()
    local out = render { "# Heading", "", "Body." }
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, out.lines)
    local win = vim.api.nvim_get_current_win()
    local prev_buf = vim.api.nvim_win_get_buf(win)
    vim.api.nvim_win_set_buf(win, buf)

    local writes = {}
    local real_send = vim.api.nvim_ui_send
    vim.api.nvim_ui_send = function(s)
      table.insert(writes, s)
    end

    local state = text_size.attach(win, out)
    assert_true(state ~= nil, "attaches when there are placements")

    -- Let the paint scheduled by attach() land, so what follows is only the
    -- scroll's doing.
    vim.wait(200, function()
      return #writes > 0
    end, 5)

    local before = #writes
    text_size._stats.invalidations = 0
    vim.api.nvim_exec_autocmds("WinScrolled", { modeline = false })
    -- Deliberately shorter than SETTLED_MS: the point is that the runs are
    -- back before the debounced paint has even been considered.
    vim.wait(60, function()
      return #writes > before
    end, 5)

    assert_true(#writes > before, "a scroll rewrites the runs without waiting for the debounce")
    assert_true(
      writes[#writes] ~= nil and writes[#writes]:find("\27]66;", 1, true) ~= nil,
      "and what it writes is the OSC 66 runs"
    )
    assert_eq(text_size._stats.invalidations, 0, "the immediate rewrite costs no full-screen repaint")

    -- Cursor movement does not destroy anything, so it stays on the debounce.
    local settled = #writes
    vim.api.nvim_exec_autocmds("CursorMoved", { modeline = false })
    vim.wait(40, function()
      return #writes > settled
    end, 5)
    assert_eq(#writes, settled, "a cursor move does not trigger the immediate path")

    vim.api.nvim_ui_send = real_send
    text_size.detach(state)
    vim.api.nvim_win_set_buf(win, prev_buf)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
  text_size.setup { enabled = false }
end

-- Test 16: the level icon is carried on the placement so it can be repainted
-- at plain size alongside the scaled text. It is kept out of `text` — the
-- anchor check compares that against the buffer — and points at its own
-- column, which is where the indent ends.
do
  text_size.setup { enabled = true }
  with_support(true, function()
    local out = render { "## Heading", "", "Body." }
    local p = out.text_placements[1]
    assert_eq(p.icon, markdown.heading_icon(2), "the placement carries the level glyph")
    assert_eq(p.icon_col, 2, "and the column it sits at, right after the indent")
    assert_true(p.icon_col < p.col, "the icon comes before the scaled text")
    assert_true(not p.text:find(p.icon, 1, true), "the glyph is still absent from the scaled payload")

    -- A wrapped heading only carries the icon on its first line.
    local wrapped = render({ "### " .. string.rep("word ", 40) }, { max_width = 40, indent = "  " })
    assert_true(#wrapped.text_placements > 1, "the long heading wraps into several placements")
    assert_eq(wrapped.text_placements[1].icon, markdown.heading_icon(3), "first line carries the icon")
    assert_eq(wrapped.text_placements[2].icon, nil, "continuation lines do not")
  end)
  text_size.setup { enabled = false }
end

-- Test 17: what actually goes to the terminal. Every level reserves a block
-- `s` rows tall while only `#` fills it, so the fractional levels are centered
-- inside it with `v=`, and the icon goes out as a run of its own at plain size
-- so that it lands in the same place as the text it labels.
do
  text_size.setup { enabled = true }
  with_support(true, function()
    local out = render { "## Heading", "", "Body." }
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, out.lines)
    local win = vim.api.nvim_get_current_win()
    local prev_buf = vim.api.nvim_win_get_buf(win)
    vim.api.nvim_win_set_buf(win, buf)

    local writes = {}
    local real_send = vim.api.nvim_ui_send
    vim.api.nvim_ui_send = function(s)
      table.insert(writes, s)
    end

    local state = text_size.attach(win, out)
    vim.wait(300, function()
      return #writes > 0
    end, 5)
    local sent = table.concat(writes)

    local spec = text_size.spec_for(2)
    assert_true(
      sent:find(string.format(":n=%d:d=%d:", spec.n, spec.d), 1, true) ~= nil,
      "h2 goes out at its fractional scale"
    )
    assert_true(sent:find(":v=2;", 1, true) ~= nil, "and centered inside its block")
    assert_true(
      sent:find("s=2:n=1:d=2:w=1:v=2;" .. markdown.heading_icon(2), 1, true) ~= nil,
      "the icon is its own run: plain size, one cell, same alignment"
    )

    -- The separator between the icon's block and the text's is covered by
    -- neither, and a block is always an even number of cells wide, so neither
    -- can be widened to reach it. Left alone it shows the heading's background
    -- on the reserved row's neighbour and the window's on the reserved row
    -- itself — a seam. Plain spaces in the heading's colours close it.
    -- In cells, not bytes: the icon is a four-byte glyph one cell wide, and
    -- what has to be covered is the screen column between the two blocks.
    local p = out.text_placements[1]
    local prefix_w = vim.api.nvim_strwidth(markdown.heading_icon_prefix(2))
    local gap = prefix_w - p.scale
    assert_eq(gap, 1, "pad_icon's two cells plus one separator leave one cell over")
    -- An SGR ends in `m`, and the heading text here has no spaces in it, so
    -- "colours followed by exactly this many spaces" cannot match a run.
    assert_true(
      sent:find("m" .. string.rep(" ", gap) .. "\27", 1, true) ~= nil,
      "the gap is filled with spaces in the heading's colours"
    )

    vim.api.nvim_ui_send = real_send
    text_size.detach(state)
    vim.api.nvim_win_set_buf(win, prev_buf)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
  text_size.setup { enabled = false }
end

-- Test 18: `#` is the one level with no fraction, and Kitty ignores `v` unless
-- `n < d`. Sending it anyway would be noise, so the text run does without —
-- but the icon run has a fraction of its own (`n=1:d=s`, which is plain size)
-- and does carry it.
do
  text_size.setup { enabled = true }
  with_support(true, function()
    local out = render { "# Heading", "", "Body." }
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, out.lines)
    local win = vim.api.nvim_get_current_win()
    local prev_buf = vim.api.nvim_win_get_buf(win)
    vim.api.nvim_win_set_buf(win, buf)

    local writes = {}
    local real_send = vim.api.nvim_ui_send
    vim.api.nvim_ui_send = function(s)
      table.insert(writes, s)
    end

    local state = text_size.attach(win, out)
    vim.wait(300, function()
      return #writes > 0
    end, 5)
    local sent = table.concat(writes)

    assert_true(sent:find("\27]66;s=2;Heading", 1, true) ~= nil, "h1 goes out as a bare s=2 run")
    assert_true(
      sent:find("s=2:n=1:d=2:w=1:v=2;" .. markdown.heading_icon(1), 1, true) ~= nil,
      "its icon still centers in the block"
    )

    vim.api.nvim_ui_send = real_send
    text_size.detach(state)
    vim.api.nvim_win_set_buf(win, prev_buf)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
  text_size.setup { enabled = false }
end

-- Test 19: a window appearing or disappearing recomposes the screen and takes
-- the runs with it, the same way a scroll does. Plugins that follow the mouse
-- pointer churn floats constantly — one recording had the runs destroyed about
-- four times a second with no scrolling at all — so these two events put them
-- back at once rather than waiting for the `SafeState` rate limit.
do
  text_size.setup { enabled = true }
  with_support(true, function()
    local out = render { "# Heading", "", "Body." }
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, out.lines)
    local win = vim.api.nvim_get_current_win()
    local prev_buf = vim.api.nvim_win_get_buf(win)
    vim.api.nvim_win_set_buf(win, buf)

    local writes = {}
    local real_send = vim.api.nvim_ui_send
    vim.api.nvim_ui_send = function(s)
      table.insert(writes, s)
    end

    local state = text_size.attach(win, out)
    vim.wait(300, function()
      return #writes > 0
    end, 5)

    for _, event in ipairs { "WinNew", "WinClosed" } do
      local before = #writes
      text_size._stats.invalidations = 0
      vim.api.nvim_exec_autocmds(event, { modeline = false })
      -- Shorter than SETTLED_MS on purpose: the point is that it does not wait.
      vim.wait(60, function()
        return #writes > before
      end, 5)
      assert_true(#writes > before, event .. " puts the runs back without waiting for the debounce")
      assert_eq(text_size._stats.invalidations, 0, event .. " costs no full-screen repaint")
    end

    vim.api.nvim_ui_send = real_send
    text_size.detach(state)
    vim.api.nvim_win_set_buf(win, prev_buf)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
  text_size.setup { enabled = false }
end

-- Test 20: a queued paint no longer blocks re-asserting an unchanged layout.
-- The old guard sat at the top of `reassert` and returned whenever a paint was
-- pending — which is for up to `BURST_MS` after any scroll or cursor movement,
-- exactly when somebody else's repaint is most likely. Re-sending bytes that
-- are already correct cannot make anything worse.
do
  text_size.setup { enabled = true }
  with_support(true, function()
    local out = render { "# Heading", "", "Body." }
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, out.lines)
    local win = vim.api.nvim_get_current_win()
    local prev_buf = vim.api.nvim_win_get_buf(win)
    vim.api.nvim_win_set_buf(win, buf)

    local writes = {}
    local real_send = vim.api.nvim_ui_send
    vim.api.nvim_ui_send = function(s)
      table.insert(writes, s)
    end

    local state = text_size.attach(win, out)
    vim.wait(300, function()
      return #writes > 0
    end, 5)

    -- Queue a paint, then ask for a re-assert before it can fire.
    vim.api.nvim_exec_autocmds("CursorMoved", { modeline = false })
    assert_true(state.redraw_timer ~= nil, "a paint is queued")
    local keepalives = text_size._stats.keepalives
    state.last_reassert_at = nil -- past the rate limit
    vim.api.nvim_exec_autocmds("SafeState", { modeline = false })
    assert_true(text_size._stats.keepalives > keepalives, "an unchanged layout is re-asserted even with a paint queued")

    vim.api.nvim_ui_send = real_send
    text_size.detach(state)
    vim.api.nvim_win_set_buf(win, prev_buf)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
  text_size.setup { enabled = false }
end

-- Test 21: after a scroll, `reassert` still recognises the layout.
--
-- This is what made the two changes above look like they had done nothing.
-- `restore_runs_now` used to leave `state.last_layout` pointing at where the
-- runs were *before* the scroll, so every later `reassert` saw a mismatch and
-- declined to re-send. A wheel being turned re-arms the debounce at BURST_MS
-- for as long as it keeps turning, so that mismatch could stand for the whole
-- scroll, and recovery fell to whatever else happened to repaint.
do
  text_size.setup { enabled = true }
  with_support(true, function()
    local out = render { "# Heading", "", "Body." }
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, out.lines)
    local win = vim.api.nvim_get_current_win()
    local prev_buf = vim.api.nvim_win_get_buf(win)
    vim.api.nvim_win_set_buf(win, buf)

    local writes = {}
    local real_send = vim.api.nvim_ui_send
    vim.api.nvim_ui_send = function(s)
      table.insert(writes, s)
    end

    local state = text_size.attach(win, out)
    vim.wait(300, function()
      return #writes > 0
    end, 5)

    vim.api.nvim_exec_autocmds("WinScrolled", { modeline = false })
    vim.wait(60, function()
      return state.owes_invalidate == true
    end, 5)
    assert_true(state.owes_invalidate == true, "the immediate write records that a clear is still owed")

    -- The re-assert must now take the cheap path even though a paint is queued.
    local keepalives = text_size._stats.keepalives
    state.last_reassert_at = nil
    vim.api.nvim_exec_autocmds("SafeState", { modeline = false })
    assert_true(
      text_size._stats.keepalives > keepalives,
      "and the layout it wrote is the one reassert compares against"
    )

    -- The clear itself is not lost: the debounced paint still performs it.
    text_size._stats.invalidations = 0
    text_size.paint(state)
    assert_eq(text_size._stats.invalidations, 1, "the owed full-screen repaint still happens")
    assert_true(state.owes_invalidate == false, "and is only owed once")

    vim.api.nvim_ui_send = real_send
    text_size.detach(state)
    vim.api.nvim_win_set_buf(win, prev_buf)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
  text_size.setup { enabled = false }
end

-- Test 22: the redraw notification does not depend on autocmds.
--
-- `'eventignore'` is the hole every event-based recovery falls into. A plugin
-- that wraps its work in `eventignore = "all"` — nvim-scrollview does, around
-- a refresh it runs about twenty times a second — silences every autocmd
-- while it opens, moves and closes windows, and each of those recomposes the
-- screen and takes the runs with it. A decoration provider is not an autocmd.
do
  text_size.setup { enabled = true }
  with_support(true, function()
    local out = render { "# Heading", "", "Body." }
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, out.lines)
    local win = vim.api.nvim_get_current_win()
    local prev_buf = vim.api.nvim_win_get_buf(win)
    vim.api.nvim_win_set_buf(win, buf)

    local state = text_size.attach(win, out)
    assert_true(state ~= nil, "attaches when there are placements")

    -- The provider is registered against a namespace, not against a window.
    local providers = 0
    for name in pairs(vim.api.nvim_get_namespaces()) do
      if name == "md_render_text_size_redraw" then providers = providers + 1 end
    end
    assert_eq(providers, 1, "attaching registers the redraw notification")

    -- Under `eventignore=all` the events it used to rely on say nothing.
    local seen = 0
    local id = vim.api.nvim_create_autocmd({ "WinNew", "WinClosed" }, {
      callback = function()
        seen = seen + 1
      end,
    })
    local saved = vim.o.eventignore
    vim.o.eventignore = "all"
    local scratch = vim.api.nvim_create_buf(false, true)
    local w = vim.api.nvim_open_win(scratch, false, {
      relative = "editor",
      row = 0,
      col = 0,
      width = 10,
      height = 3,
      style = "minimal",
    })
    vim.api.nvim_win_close(w, true)
    vim.o.eventignore = saved
    assert_eq(seen, 0, "a window opening and closing under eventignore fires no autocmd")

    vim.api.nvim_del_autocmd(id)
    vim.api.nvim_buf_delete(scratch, { force = true })
    text_size.detach(state)
    vim.api.nvim_win_set_buf(win, prev_buf)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
  text_size.setup { enabled = false }
end

print(string.format("\ntext_size_test: %d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
