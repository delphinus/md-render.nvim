-- Test fenced code blocks that carry an indent, i.e. the ones nested under
-- a list item.  The fence must still be recognised (not collapsed into a
-- paragraph), the content keeps the item's indent, and the code_blocks entry
-- must point at the dedented source so treesitter highlights line up.
-- Run: nvim --headless -u NONE --noplugin -l tests/code_fence_test.lua

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

local function build(lines)
  local b = ContentBuilder.new()
  b:render_document(lines, { max_width = 80, indent = "" })
  return b:result()
end

--- Rendered lines with the blank ones dropped.
local function render(lines)
  local out = {}
  for _, line in ipairs(build(lines).lines) do
    if not line:match "^%s*$" then table.insert(out, line) end
  end
  return out
end

-- Test 1: a fence indented under a bullet renders as a code block
do
  local out = render { "- item", "", "  ```lua", "  local x = 1", "  ```", "", "- next" }
  assert_eq(out, { "• item", "  local x = 1", "• next" }, "indented fence should render as code")
end

-- Test 2: the code block metadata is dedented and offset by the indent
do
  local content = build { "- item", "", "  ```lua", "  local x = 1", "    local y = 2", "  ```" }
  assert_eq(#content.code_blocks, 1, "one code block should be recorded")
  local block = content.code_blocks[1]
  assert_eq(block.language, "lua", "language should come from the info string")
  assert_eq(block.prefix_len, 2, "prefix_len should cover the fence indent")
  assert_eq(block.source_lines, { "local x = 1", "  local y = 2" }, "source should be dedented by the fence indent")
end

-- Test 3: relative indentation inside the block is preserved on screen
do
  local out = render { "1. 手順です。", "", "   ```sh", "   echo hi", "     echo deeper", "   ```" }
  assert_eq(
    out,
    { "1. 手順です。", "   echo hi", "     echo deeper" },
    "inner indentation should survive the dedent/re-indent"
  )
end

-- Test 4: an unindented fence is unaffected
do
  local content = build { "```lua", "local x = 1", "```" }
  assert_eq(content.lines, { "local x = 1" }, "top-level fence should render as before")
  assert_eq(content.code_blocks[1].prefix_len, 0, "top-level fence has no prefix")
  assert_eq(content.code_blocks[1].source_lines, { "local x = 1" }, "top-level source is untouched")
end

-- Test 5: the lang:filename form works with an indent too
do
  local out = render { "- item", "", "  ```lua:init.lua", "  local x = 1", "  ```" }
  assert_eq(#out, 3, "filename header should be rendered above the code")
  assert_eq(out[2]:match "init%.lua$" ~= nil, true, "filename header should be present")
  assert_eq(out[3], "  local x = 1", "code line keeps the item's indent")
end

--- Languages of the recorded code blocks, in order.
local function langs(lines)
  local out = {}
  for _, cb in ipairs(build(lines).code_blocks) do
    table.insert(out, cb.language)
  end
  return out
end

-- Test 6: spaces between the fence and the info string (GFM example 113)
do
  assert_eq(render { "``` bash", "echo hi", "```" }, { "echo hi" }, "``` bash should render as code")
  assert_eq(langs { "``` bash", "echo hi", "```" }, { "bash" }, "language after a space should be recorded")
  assert_eq(
    langs { "~~~~    ruby startline=3 $%@#$", "def foo(x)", "~~~~~~~" },
    { "ruby" },
    "only the first word of the info string is the language"
  )
end

-- Test 7: tilde fences (GFM examples 90, 111)
do
  assert_eq(render { "~~~bash", "echo hi", "~~~" }, { "echo hi" }, "~~~ fence should render as code")
  assert_eq(langs { "~~~bash", "echo hi", "~~~" }, { "bash" }, "~~~ fence should record its language")
  assert_eq(
    render({ "foo", "---", "~~~", "bar", "~~~", "# baz" })[2],
    "bar",
    "a ~~~ block after a setext heading should render as code"
  )
end

-- Test 8: only a matching fence closes the block (GFM examples 92-95, 107, 109, 117)
do
  assert_eq(render { "```", "aaa", "~~~", "```" }, { "aaa", "~~~" }, "~~~ does not close a ``` block")
  assert_eq(render { "~~~", "aaa", "```", "~~~" }, { "aaa", "```" }, "``` does not close a ~~~ block")
  assert_eq(render { "````", "aaa", "```", "``````" }, { "aaa", "```" }, "a shorter fence does not close")
  assert_eq(render { "~~~~~~", "aaa", "~~~ ~~" }, { "aaa", "~~~ ~~" }, "a fence with trailing text does not close")
  assert_eq(render { "```", "``` aaa", "```" }, { "``` aaa" }, "an info string does not close")
  assert_eq(render { "```", "aaa", "    ```" }, { "aaa", "    ```" }, "a fence indented four columns is content")
end

-- Test 9: a backtick fence's info string may not contain a backtick (GFM examples 115-116)
do
  assert_eq(#build({ "``` aa ```", "foo" }).code_blocks, 0, "``` aa ``` is an inline code span")
  assert_eq(langs { "~~~ aa ``` ~~~", "foo", "~~~" }, { "aa" }, "a tilde fence may carry backticks")
end

-- Test 10: the same forms work inside blockquotes and callouts
do
  assert_eq(langs { "> ``` bash", "> echo hi", "> ```" }, { "bash" }, "``` bash inside a blockquote")
  assert_eq(langs { "> [!NOTE]", "> ~~~bash", "> echo hi", "> ~~~" }, { "bash" }, "~~~ inside a callout")
  local out = render { "> ````", "> ```", "> ````" }
  assert_eq(out[#out], "│ ```", "a shorter fence inside a blockquote is content")
end

-- Test 11: a tilde block nested in a list keeps the item's indent
do
  local out = render { "- item", "", "  ~~~sh", "  echo hi", "  ~~~", "", "  after" }
  assert_eq(out, { "• item", "  echo hi", "  after" }, "~~~ nested in a list keeps the item's indent")
end

print(string.format("\ncode_fence_test: %d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
