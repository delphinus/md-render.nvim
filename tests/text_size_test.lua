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

-- Test 1: disabled by default — no placements, no reserved rows
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

-- Test 3: only h1 and h2 scale
do
  text_size.setup { enabled = true }
  with_support(true, function()
    for level = 1, 6 do
      local scale = text_size.scale_for(level)
      if level <= 2 then
        assert_eq(scale, 2, "level " .. level .. " scales at s=2")
      else
        assert_eq(scale, nil, "level " .. level .. " stays plain")
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
      local scaled = p.col + vim.api.nvim_strwidth(p.text) * p.scale
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

print(string.format("\ntext_size_test: %d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
