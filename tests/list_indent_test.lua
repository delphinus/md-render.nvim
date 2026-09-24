-- Test the blocks that follow a list item's first paragraph.  In CommonMark
-- everything indented to an item's content column belongs to that item, so a
-- second paragraph, a table or a heading written there renders under the
-- item rather than flush left.  The item's own marker line and fenced code
-- keep their indentation, because those two measure their own prefix.
-- Run: nvim --headless -u NONE --noplugin -l tests/list_indent_test.lua

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
local function render(lines, max_width)
  local b = ContentBuilder.new()
  b:render_document(lines, { max_width = max_width or 60, indent = "" })
  local out = {}
  for _, line in ipairs(b:result().lines) do
    if not line:match "^%s*$" then table.insert(out, line) end
  end
  return out
end

-- Test 1: a second paragraph sits at the item's content column
do
  local out = render {
    "1. 最初の段落。",
    "",
    "   二つめの段落。",
    "",
    "   三つめの段落。",
    "2. 次の項目。",
  }
  assert_eq(out, {
    "1. 最初の段落。",
    "   二つめの段落。",
    "   三つめの段落。",
    "2. 次の項目。",
  }, "every paragraph of an item should render under it")
end

-- Test 2: the indent comes off the wrap budget, so a continuation paragraph
-- wraps in the same column as the item's own text.  This is what used to
-- break: wrap_words drops leading whitespace, so a paragraph long enough to
-- wrap lost the indent entirely while a short one kept it.
do
  local out = render({ "1. あ", "", "   " .. string.rep("あ", 14) }, 20)
  assert_eq(out, {
    "1. あ",
    "   ああああああああ",
    "   ああああああ",
  }, "a wrapped continuation paragraph should keep the item's column")
end

-- Test 3: the content column follows the marker width
do
  local out = render { "10. 手順です。", "", "    補足の段落。" }
  assert_eq(out, { "10. 手順です。", "    補足の段落。" }, "a wider marker moves the content column")

  out = render { "-   項目です。", "", "    補足の段落。" }
  assert_eq(
    out,
    { "• 項目です。", "    補足の段落。" },
    "extra spaces after the marker move the content column"
  )
end

-- Test 4: a nested item's continuation goes to the nested column
do
  local out = render { "- 外側", "  - 内側", "", "    内側の続き。", "", "- 次の外側" }
  assert_eq(out, {
    "• 外側",
    "  ◦ 内側",
    "    内側の続き。",
    "• 次の外側",
  }, "continuation should follow the innermost open item")
end

-- Test 5: a lazy continuation (no blank line) still joins the item's own
-- paragraph, indented or not
do
  -- No space at the join: a soft break between two wide characters is not a
  -- word gap.  See wrap.join_soft_lines.
  local out = render { "1. 最初の行", "   同じ段落の続き", "2. 次の項目" }
  assert_eq(
    out,
    { "1. 最初の行同じ段落の続き", "2. 次の項目" },
    "an indented continuation line should join"
  )

  out = render { "1. 最初の行", "lazy な続き", "2. 次の項目" }
  assert_eq(out, { "1. 最初の行 lazy な続き", "2. 次の項目" }, "a lazy continuation line should join")
end

-- Test 6: leaving the item puts the paragraph back at the top level
do
  local out = render { "- 項目", "", "  中の段落。", "", "外の段落。" }
  assert_eq(
    out,
    { "• 項目", "  中の段落。", "外の段落。" },
    "a paragraph after the list should render flush left"
  )
end

-- Test 7: other blocks written at the content column belong to the item too
do
  local out = render { "- 項目", "", "  ## 中の見出し" }
  assert_eq(#out, 2, "a heading in an item should be one rendered line")
  assert_eq(out[2]:match "^%s*", "  ", "a heading in an item should be indented, not literal text")

  out = render { "- 項目", "", "  | a | b |", "  |---|---|", "  | 1 | 2 |" }
  assert_eq(out, {
    "• 項目",
    "  │ a │ b │",
    "  │───│───│",
    "  │ 1 │ 2 │",
  }, "a table in an item should render under it")
end

-- Test 8: fenced code keeps whatever indentation it was written with, and
-- its content is never touched
do
  local out = render { "- 項目", "", "  ```lua", "  local x = 1", "  ```" }
  assert_eq(out, { "• 項目", "  local x = 1" }, "a fence in an item should render its content")

  out = render { "- 項目", "", "  ```markdown", "     ぶら下がった行", "  ```" }
  assert_eq(out, { "• 項目", "     ぶら下がった行" }, "code block content must not be dedented")
end

-- Test 9: with no list open there is nothing to dedent
do
  local out = render { "```", "  > コードの中身", "```" }
  assert_eq(out, { "  > コードの中身" }, "a top-level code block must not be touched")

  out = render { "段落です。", "", "- 項目", "", "  中の段落。" }
  assert_eq(
    out,
    { "段落です。", "• 項目", "  中の段落。" },
    "only the paragraph inside the item picks up an indent"
  )
end

-- Test 10: a tab in the indentation advances to the next multiple of four,
-- so a tab-indented item nests exactly as a four-space one does, wraps under
-- its own text, and no tab reaches the output
do
  local long = string.rep("あ", 30)
  local tabbed = render({ "- 外側", "\t- " .. long }, 24)
  assert_eq(tabbed, render({ "- 外側", "    - " .. long }, 24), "a tab should indent like four spaces")
  assert_eq(
    #tabbed[3]:match "^ *",
    vim.api.nvim_strwidth(tabbed[2]:match "^ *[^ ]+ "),
    "a tab-indented item should hang under its text"
  )
  assert_eq(table.concat(tabbed):find("\t", 1, true), nil, "no tab should reach the output")

  assert_eq(
    render { "- 外側", "  \t- 内側" },
    render { "- 外側", "    - 内側" },
    "a tab after spaces should stop at column four"
  )

  local out = render { "- 項目", "", "  ```", "  \tx = 1", "  ```" }
  assert_eq(out[2]:find("\t", 1, true) ~= nil, true, "a tab in fenced code is content and must stay")
end

print(string.format("\nlist_indent_test: %d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
