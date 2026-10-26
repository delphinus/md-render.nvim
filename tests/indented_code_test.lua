-- Test indented code blocks (four spaces of indentation).  The block ends at
-- the first line indented less, and the blank lines around it are kept like
-- those around any other block.
-- Run: nvim --headless -u NONE --noplugin -l tests/indented_code_test.lua

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

local function render(lines)
  local b = ContentBuilder.new()
  b:render_document(lines, { max_width = 60, indent = "" })
  return b:result().lines
end

-- Test 1: the blank line after the block is kept
do
  local out = render { "Before:", "", "    code line", "", "After." }
  assert_eq(out, { "Before:", "", "code line", "", "After." }, "blank line after the block should be kept")
end

-- Test 2: the same for a block of several lines
do
  local out = render { "Before:", "", "    one", "    two", "", "After." }
  assert_eq(out, { "Before:", "", "one", "two", "", "After." }, "multi-line block keeps the blank after it")
end

print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
