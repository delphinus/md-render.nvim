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

print(string.format("\ntext_size_test: %d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
