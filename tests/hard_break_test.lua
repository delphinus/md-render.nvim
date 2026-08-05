-- Test CommonMark hard line breaks inside paragraphs:
--   * two or more trailing spaces  -> break
--   * trailing backslash           -> break
--   * neither (soft break)         -> lines are joined into one paragraph
-- Run: nvim --headless -u NONE --noplugin -l tests/hard_break_test.lua

package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local ContentBuilder = require("md-render.content_builder").ContentBuilder

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

--- Render and return the non-blank output lines with the indent stripped.
local function render(lines)
  local b = ContentBuilder.new()
  b:render_document(lines, { max_width = 80, indent = "" })
  local out = {}
  for _, line in ipairs(b:result().lines) do
    if not line:match "^%s*$" then table.insert(out, line) end
  end
  return out
end

-- Test 1: two trailing spaces break the line
do
  local out = render { "半角スペースあり。  ", "あいうえお。" }
  assert_eq(out, { "半角スペースあり。", "あいうえお。" }, "two trailing spaces should break the line")
end

-- Test 2: no trailing spaces = soft break, lines are joined
-- (no space between the two 和字, see the join tests at the bottom)
do
  local out = render { "半角スペースなし。", "かきくけこ。" }
  assert_eq(out, { "半角スペースなし。かきくけこ。" }, "soft break should join into one line")
end

-- Test 3: trailing backslash breaks the line and the marker is not shown
do
  local out = render { "backslash break.\\", "next line." }
  assert_eq(out, { "backslash break.", "next line." }, "trailing backslash should break the line")
end

-- Test 4: a single trailing space is not a hard break
do
  local out = render { "one space ", "joined." }
  assert_eq(out, { "one space joined." }, "single trailing space should not break the line")
end

-- Test 5: hard break in the middle of a longer paragraph
do
  local out = render { "a", "b  ", "c", "d" }
  assert_eq(out, { "a b", "c d" }, "only the hard-broken line should split the paragraph")
end

-- Test 6: inline constructs still span soft-broken lines
do
  local out = render { "see [the", "docs](https://example.com) here" }
  assert_eq(out, { "see the docs here" }, "multi-line link should still be joined")
end

-- Test 7: trailing spaces on the last line of a paragraph are dropped
do
  local out = render { "trailing.  " }
  assert_eq(out, { "trailing." }, "dangling hard break marker should not leave trailing spaces")
end

-- Test 7b: block-level lines already end their own line; the marker is
-- dropped instead of leaving a stray trailing space
do
  local out = render { "> 引用の一行目。  ", "> 引用の二行目。" }
  assert_eq(
    out,
    { "│ 引用の一行目。", "│ 引用の二行目。" },
    "blockquote should not keep the marker spaces"
  )

  out = render { "- リスト項目。  ", "  次の行。" }
  assert_eq(out, { "• リスト項目。", "  次の行。" }, "list item should not keep the marker spaces")
end

-- Soft break joining: a space is inserted only where it is needed.

-- Test 8: 和字 <-> 和字 across a soft break joins with no space
do
  local out = render { "禁則処理を実装しており、", "句読点が行頭に来ることを防ぎます。" }
  assert_eq(
    out,
    { "禁則処理を実装しており、句読点が行頭に来ることを防ぎます。" },
    "wide chars on both sides should join without a space"
  )
end

-- Test 9: 英字 on either side keeps the space
do
  local out = render { "BudouX", "を使います。" }
  assert_eq(out, { "BudouX を使います。" }, "latin before the break should keep the space")

  out = render { "これは", "BudouX です。" }
  assert_eq(out, { "これは BudouX です。" }, "latin after the break should keep the space")
end

-- Test 10: latin <-> latin keeps the space (CommonMark behavior)
do
  local out = render { "one", "two" }
  assert_eq(out, { "one two" }, "latin on both sides should keep the space")
end

-- Test 11: leading whitespace on a continuation line is dropped
do
  local out = render { "indented", "   continuation" }
  assert_eq(out, { "indented continuation" }, "continuation indent should collapse to one space")
end

-- Test 12: a continuation paragraph keeps the indent that aligns it with
-- its list item (only the *continuation* lines get their indent stripped)
do
  local out = render { "- item", "  続きの段落です。", "  さらに続きます。" }
  assert_eq(
    out,
    { "• item", "  続きの段落です。さらに続きます。" },
    "continuation paragraph should keep its indent"
  )
end

-- Test 13: half-width katakana is not treated as wide
do
  local out = render { "ｱｲｳ", "ｴｵ" }
  assert_eq(out, { "ｱｲｳ ｴｵ" }, "half-width katakana should keep the space")
end

print(string.format("\nhard_break_test: %d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
