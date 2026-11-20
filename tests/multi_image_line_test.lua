-- Several images on one line: every one is shown, in the order written
-- Run: nvim --headless -u NONE --noplugin -l tests/multi_image_line_test.lua

package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local ContentBuilder = require("md-render.content_builder").ContentBuilder
local image = require "md-render.image"

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

local function test(name, fn)
  local ok, err = pcall(fn)
  if not ok then
    fail_count = fail_count + 1
    print("ERROR: " .. name .. ": " .. tostring(err))
  end
end

-- image_placements are only added when the terminal supports the Kitty
-- graphics protocol, which CI runners do not.
local function with_kitty(fn)
  local original = image.supports_kitty
  image.supports_kitty = function()
    return true
  end
  local ok, err = pcall(fn)
  image.supports_kitty = original
  if not ok then error(err) end
end

local fixtures = vim.fn.getcwd() .. "/tests/fixtures"

--- The alt text of each image placement, in order.
---@param lines string[]
---@return string[]
local function titles(lines)
  local b = ContentBuilder.new()
  b:render_document(lines, { max_width = 80, indent = "  ", buf_dir = fixtures })
  local out = {}
  for _, p in ipairs(b:result().image_placements or {}) do
    table.insert(out, p.title)
  end
  return out
end

test("two images of the same file are both shown", function()
  with_kitty(function()
    assert_eq(titles { "![one](test_4x4.png) ![two](test_4x4.png)" }, { "one", "two" }, "two placements")
  end)
end)

test("plain and linked images keep the order they are written in", function()
  with_kitty(function()
    assert_eq(
      titles { "![first](test_4x4.png) [![second](test_4x4.png)](https://example.com) ![third](test_4x4.png)" },
      { "first", "second", "third" },
      "plain, linked, plain"
    )
  end)
end)

test("the image inside a linked image is not counted again", function()
  with_kitty(function()
    assert_eq(
      titles { "[![a](test_4x4.png)](https://example.com) [![b](test_4x4.png)](https://example.org)" },
      { "a", "b" },
      "two linked images, two placements"
    )
  end)
end)

print(string.format("\nmulti_image_line_test: %d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
