-- Pandoc attributes after an image: ![](a.png){width=16cm}
-- Run: nvim --headless -u NONE --noplugin -l tests/image_attributes_test.lua

package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local Markdown = require "md-render.markdown"
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

-- ============================================================================
-- strip_image_attributes
-- ============================================================================

test("strip: attributes after an image", function()
  assert_eq(Markdown.strip_image_attributes "![](fig.png){width=16cm}", "![](fig.png)", "plain image")
  assert_eq(
    Markdown.strip_image_attributes "![alt](fig.png){#fig1 .wide width=50%}",
    "![alt](fig.png)",
    "id, class and key=value"
  )
  assert_eq(
    Markdown.strip_image_attributes "[![alt](fig.png)](https://example.com){width=4cm}",
    "[![alt](fig.png)](https://example.com)",
    "linked image"
  )
  assert_eq(
    Markdown.strip_image_attributes "![a](a.png){width=4cm} ![b](b.png){width=4cm}",
    "![a](a.png) ![b](b.png)",
    "two images on one line"
  )
end)

test("strip: everything else is left alone", function()
  assert_eq(Markdown.strip_image_attributes "![](fig.png)", "![](fig.png)", "no attributes")
  assert_eq(
    Markdown.strip_image_attributes "[text](https://example.com){.class}",
    "[text](https://example.com){.class}",
    "a link that is not an image"
  )
  assert_eq(
    Markdown.strip_image_attributes "![](fig.png) {width=16cm}",
    "![](fig.png) {width=16cm}",
    "a space before the brace: not attributes (Pandoc agrees)"
  )
  assert_eq(Markdown.strip_image_attributes "plain {text}", "plain {text}", "no image at all")
end)

-- ============================================================================
-- An image line with attributes becomes an image placement
-- ============================================================================

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

local function render(lines)
  local b = ContentBuilder.new()
  b:render_document(lines, { max_width = 80, indent = "  ", buf_dir = fixtures })
  return b:result()
end

local function any_line_contains(out, needle)
  for _, line in ipairs(out.lines) do
    if line:find(needle, 1, true) then return true end
  end
  return false
end

test("an image line with attributes is shown as an image", function()
  with_kitty(function()
    local out = render { "![](test_4x4.png){width=16cm}" }
    assert_eq(#(out.image_placements or {}), 1, "one placement")
    assert_eq(any_line_contains(out, "{width=16cm}"), false, "the attributes are not shown as text")
  end)
end)

test("a linked image with attributes is shown as an image", function()
  with_kitty(function()
    local out = render { "[![alt](test_4x4.png)](https://example.com){width=4cm}" }
    assert_eq(#(out.image_placements or {}), 1, "one placement")
  end)
end)

test("two images with attributes on one line are both shown", function()
  with_kitty(function()
    local out = render { "![a](test_4x4.png){width=4cm} ![b](./test_4x4.png){width=4cm}" }
    assert_eq(#(out.image_placements or {}), 2, "two placements")
  end)
end)

test("text after the attributes keeps the line a paragraph", function()
  with_kitty(function()
    local out = render { "![](test_4x4.png){width=16cm} and some words" }
    assert_eq(#(out.image_placements or {}), 0, "no placement")
  end)
end)

print(string.format("\nimage_attributes_test: %d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
