-- Test YAML frontmatter rendering: truncation of overflowing values and
-- click-to-expand (mirrors table-cell expand behavior).
-- Run: nvim --headless -u NONE --noplugin -l tests/frontmatter_test.lua

package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local preview = require "md-render.preview"

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

local function assert_true(val, msg)
  if val then
    pass_count = pass_count + 1
  else
    fail_count = fail_count + 1
    print("FAIL: " .. msg)
  end
end

local function test(name, fn)
  local ok, err = pcall(fn)
  if not ok then
    fail_count = fail_count + 1
    print("ERROR: " .. name .. ": " .. tostring(err))
  end
end

-- A value long enough to overflow a narrow render width.
local LONG_VALUE = "あいうえおかきくけこさしすせそたちつてと"
local MAX_WIDTH = 20

-- ----------------------------------------------------------------------
-- Test 1: an overflowing frontmatter value is truncated with "…" and
-- registers an expandable region with a negative (frontmatter) block id.
-- ----------------------------------------------------------------------
test("overflowing frontmatter value truncates and registers a region", function()
  local lines = { "---", "hoge: " .. LONG_VALUE, "---", "", "body" }
  local content = preview.build_content(lines, { max_width = MAX_WIDTH })

  assert_eq(#content.expandable_regions, 1, "one expandable region for the overflowing entry")
  local region = content.expandable_regions[1]
  assert_true(region.block_id < 0, "frontmatter block id is negative (got " .. region.block_id .. ")")
  assert_eq(region.expanded, false, "region starts collapsed")
  assert_eq(region.start_line, region.end_line, "collapsed entry occupies a single line")

  local line = content.lines[region.start_line + 1]
  assert_true(line:sub(1, #"  hoge: ") == "  hoge: ", "line keeps the '  hoge: ' label prefix")
  assert_true(line:match "…$" ~= nil, "collapsed line ends with the … ellipsis")
  assert_true(vim.api.nvim_strwidth(line) <= MAX_WIDTH, "collapsed line fits within max_width")
end)

-- ----------------------------------------------------------------------
-- Test 2: expanding the entry wraps the value across lines, aligned to
-- the value column, and keeps the region clickable (still registered).
-- ----------------------------------------------------------------------
test("expanded frontmatter value wraps aligned to the value column", function()
  local lines = { "---", "hoge: " .. LONG_VALUE, "---", "", "body" }

  -- First pass: discover the block id.
  local collapsed = preview.build_content(lines, { max_width = MAX_WIDTH })
  local block_id = collapsed.expandable_regions[1].block_id

  -- Second pass with that entry expanded.
  local content = preview.build_content(lines, {
    max_width = MAX_WIDTH,
    expand_state = { [block_id] = true },
  })

  local region = content.expandable_regions[1]
  assert_eq(region.expanded, true, "region reports expanded")
  assert_true(region.end_line > region.start_line, "expanded entry spans multiple lines")

  local first = content.lines[region.start_line + 1]
  assert_true(first:sub(1, #"  hoge: ") == "  hoge: ", "first line keeps the label prefix")
  assert_true(first:match "…$" == nil, "expanded first line has no ellipsis")

  -- Continuation lines are indented to align under the value (col of "hoge: ").
  local value_col = #"  hoge" + 2 -- "  hoge" + ": "
  local expected_indent = string.rep(" ", value_col)
  for l = region.start_line + 1, region.end_line do
    local line = content.lines[l + 1]
    assert_true(vim.api.nvim_strwidth(line) <= MAX_WIDTH, "wrapped line " .. l .. " fits within max_width")
  end
  local second = content.lines[region.start_line + 2]
  assert_true(second:sub(1, #expected_indent) == expected_indent, "continuation line is indented to the value column")
  assert_true(second:sub(#expected_indent + 1, #expected_indent + 1) ~= " ", "continuation content follows the indent")

  -- The concatenation of value fragments reconstructs the original value.
  local parts = {}
  table.insert(parts, first:sub(value_col + 1))
  for l = region.start_line + 1, region.end_line do
    table.insert(parts, (content.lines[l + 1]):sub(value_col + 1))
  end
  local joined = table.concat(parts)
  assert_eq(joined, LONG_VALUE, "expanded fragments reconstruct the original value")
end)

-- ----------------------------------------------------------------------
-- Test 3: a short value that fits gets no region and no ellipsis.
-- ----------------------------------------------------------------------
test("short frontmatter value is left untouched", function()
  local lines = { "---", "k: v", "---", "", "body" }
  local content = preview.build_content(lines, { max_width = MAX_WIDTH })
  assert_eq(#content.expandable_regions, 0, "no region for a value that fits")
end)

-- ----------------------------------------------------------------------
-- Test 4: multiple overflowing entries get distinct block ids.
-- ----------------------------------------------------------------------
test("multiple overflowing entries get distinct block ids", function()
  local lines = {
    "---",
    "a: " .. LONG_VALUE,
    "b: " .. LONG_VALUE,
    "---",
    "",
    "body",
  }
  local content = preview.build_content(lines, { max_width = MAX_WIDTH })
  assert_eq(#content.expandable_regions, 2, "two regions for two overflowing entries")
  local id1 = content.expandable_regions[1].block_id
  local id2 = content.expandable_regions[2].block_id
  assert_true(id1 ~= id2, "block ids are distinct (" .. id1 .. " vs " .. id2 .. ")")
  assert_true(id1 < 0 and id2 < 0, "both block ids are negative")
end)

print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then vim.cmd "cquit 1" end
