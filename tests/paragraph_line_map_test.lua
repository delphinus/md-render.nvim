-- source_line_map inside a paragraph joined from several source lines.
--
-- A paragraph's lines are joined into one before it is wrapped, so the rows
-- that come out of the wrap used to be attributed to the paragraph's first
-- line, all of them. Everything that maps between the source and the render
-- (the split's shadow cursor and scroll sync, toggling between the two) then
-- treated the paragraph as one opaque block: with the cursor on its last
-- line, the shadow lit up every row of it. Each row now goes to the source
-- line its first character comes from.
--
-- Run: nvim --headless -u NONE --noplugin -l tests/paragraph_line_map_test.lua

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

--- Render and return `{ { source_line, text }, ... }` for every row.
local function render(lines, width)
  local b = ContentBuilder.new()
  b:render_document(lines, { max_width = width, indent = "" })
  local r = b:result()
  local rows = {}
  for i, line in ipairs(r.lines) do
    table.insert(rows, { r.source_line_map[i], line })
  end
  return rows
end

--- Just the source lines of the rows, for the cases where the text is not
--- the point.
local function sources(lines, width)
  return vim.tbl_map(function(row)
    return row[1]
  end, render(lines, width))
end

-- Test 1: CJK sentences, one per source line
do
  local rows = render({
    "あいうえおかきくけこ一行目の文です。",
    "あいうえおかきくけこ二行目の文です。",
    "あいうえおかきくけこ三行目の文です。",
  }, 30)
  assert_eq(rows, {
    { 1, "あいうえおかきくけこ一行目の文" },
    { 1, "です。あいうえおかきくけこ二行" },
    { 2, "目の文です。あいうえおかきくけ" },
    { 3, "こ三行目の文です。" },
  }, "each row goes to the source line its first character comes from")
end

-- Test 2: Latin text, joined with a space
do
  local rows = render({
    "alpha beta gamma delta",
    "epsilon zeta eta theta",
    "iota kappa lambda",
  }, 16)
  assert_eq(rows, {
    { 1, "alpha beta gamma" },
    { 1, "delta epsilon" },
    { 2, "zeta eta theta" },
    { 3, "iota kappa" },
    { 3, "lambda" },
  }, "a row starting right after the joining space belongs to the next line")
end

-- Test 3: inline markup and a link in the joined lines
do
  local rows = render({
    "one **bold** word then",
    "a [link text](https://example.com) and",
    "the third line",
  }, 14)
  assert_eq(rows, {
    { 1, "one bold word" },
    { 1, "then a link" },
    { 2, "text and the" },
    { 3, "third line" },
  }, "markers and URLs that the render drops do not shift the rows")
end

-- Test 4: a list item and its continuation lines
do
  assert_eq(
    sources({ "- item one has words and", "  continues on a second", "  and a third line", "", "after" }, 16),
    { 1, 1, 2, 2, 3, 4, 5 },
    "continuation lines of a list item get their own rows"
  )
end

-- Test 5: a blockquote paragraph
do
  assert_eq(
    sources({ "> quoted first line of words", "> quoted second line of words" }, 20),
    { 1, 1, 2, 2 },
    "the quote marker in front of the joined line does not shift the rows"
  )
end

-- Test 6: a line that starts and ends inside one row has no row of its own
-- ("two" sits in the middle of the first row)
do
  assert_eq(
    sources({ "short one", "two", "and then a much longer third line" }, 20),
    { 1, 3, 3 },
    "a source line that never starts a row is not in the map"
  )
end

-- Test 7: emphasis spanning the join stays in order
--
-- The offset of a line is measured by rendering the text before it, which
-- leaves `**` unclosed there. That can move a row boundary by the width of
-- the markers, but never out of order.
do
  local map = sources({ "words before **bold that", "spans the join** and more", "words after" }, 12)
  local ordered = true
  for i = 2, #map do
    if map[i] < map[i - 1] then ordered = false end
  end
  assert_eq(ordered, true, "rows stay in source order: " .. table.concat(map, " "))
  assert_eq({ map[1], map[#map] }, { 1, 3 }, "the paragraph still starts at line 1 and ends at line 3")
end

-- Test 8: paragraphs that fit on one row are unchanged
do
  assert_eq(sources({ "short", "lines", "", "next" }, 80), { 1, 3, 4 }, "an unwrapped paragraph is still one row")
end

print(string.format("paragraph_line_map_test: %d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
