-- Test blockquotes that carry an indent.  CommonMark allows up to three
-- spaces in front of a `>` (four is an indented code block), and a quote
-- nested in a list item sits at the item's content column on top of that.
-- The indent in front of the marker is not content, so a top-level quote
-- renders flush left while one in a list item renders under the item.
-- Run: nvim --headless -u NONE --noplugin -l tests/blockquote_indent_test.lua

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

--- Render and return the non-blank output lines.
local function render(lines)
  local b = ContentBuilder.new()
  b:render_document(lines, { max_width = 60, indent = "" })
  local out = {}
  for _, line in ipairs(b:result().lines) do
    if not line:match "^%s*$" then table.insert(out, line) end
  end
  return out
end

-- Test 1: up to three spaces in front of the marker (spec example 230).
-- The indent is not content, so all of these render flush left and form a
-- single blockquote.
do
  local out = render { "   > # Foo", "   > bar", " > baz" }
  assert_eq(out, { "│ # Foo", "│ bar baz" }, "0-3 spaces should still be one blockquote, flush left")
end

-- Test 2: four spaces is too many (spec example 231) — an indented code
-- block, with the `>` as content
do
  local out = render { "    > # Foo" }
  assert_eq(out, { "> # Foo" }, "four spaces should not make a blockquote")
end

-- Test 3: a quote indented to a bullet item's content column belongs to it
do
  local out = render { "- item", "", "  > 項目の中の引用。", "  > その続き。" }
  assert_eq(
    out,
    { "• item", "  │ 項目の中の引用。その続き。" },
    "quote should render under its list item"
  )

  -- No blank line needed: a blockquote can interrupt the item's paragraph
  out = render { "- item", "  > 引用です。" }
  assert_eq(out, { "• item", "  │ 引用です。" }, "quote should interrupt the item's paragraph")
end

-- Test 4: the content column follows the marker width
do
  local out = render { "1. 手順", "", "   > 補足。" }
  assert_eq(out, { "1. 手順", "   │ 補足。" }, "ordered item content column is 3")

  out = render { "10. 手順", "", "    > 補足。" }
  assert_eq(out, { "10. 手順", "    │ 補足。" }, "a wider marker moves the content column")

  out = render { "-   item", "", "    > 引用。" }
  assert_eq(out, { "• item", "    │ 引用。" }, "extra spaces after the marker move the content column")
end

-- Test 5: quotes in different items are different blockquotes
do
  local out = render { "- a", "  - b", "    > 深い引用。", "  > 浅い引用。" }
  assert_eq(
    out,
    { "• a", "  ◦ b", "    │ 深い引用。", "  │ 浅い引用。" },
    "quotes in different containers must not be joined"
  )
end

-- Test 6: callouts, nested quotes and code fences work inside an item
do
  local out = render { "- item", "", "  > [!WARNING] 注意", "  > 本文です。", "  > 続きます。" }
  assert_eq(#out, 3, "callout header and body should both be indented")
  assert_eq(out[3], "  │ 本文です。続きます。", "callout body should join under the item")

  out = render { "- item", "", "  > 外側", "  > > 内側" }
  assert_eq(out, { "• item", "  │ 外側", "  │ │ 内側" }, "nested quote should keep the item's indent")

  out = render { "- item", "", "  > ```lua", "  > local x = 1", "  > ```" }
  assert_eq(out, { "• item", "  │ local x = 1" }, "code fence inside an indented quote should render")
end

-- Test 7: leaving the item puts the quote back at the top level
do
  local out = render { "- a", "  > 引用。", "普通の段落。", "> トップの引用。" }
  assert_eq(
    out,
    { "• a", "  │ 引用。", "普通の段落。", "│ トップの引用。" },
    "a quote after the list should render flush left"
  )
end

-- Test 8: a quote inside a fenced code block is content, not a quote
do
  local out = render { "```markdown", "  > これはコードの中身。", "```" }
  assert_eq(out, { "  > これはコードの中身。" }, "code block content must not be touched")

  out = render { "- item", "", "  ```markdown", "  > コードの中身。", "  ```" }
  assert_eq(out, { "• item", "  > コードの中身。" }, "code block in a list item must not be touched")
end

print(string.format("\nblockquote_indent_test: %d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
