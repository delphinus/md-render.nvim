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

print(string.format("\ncode_fence_test: %d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
