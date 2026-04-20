-- Test <figure> / <figcaption> rendering
-- Run: nvim --headless -u NONE --noplugin -l tests/figure_test.lua

package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local ContentBuilder = require("md-render.content_builder").ContentBuilder

local pass_count = 0
local fail_count = 0

local function assert_true(val, msg)
  if val then
    pass_count = pass_count + 1
  else
    fail_count = fail_count + 1
    print("FAIL: " .. msg)
  end
end

local function assert_false(val, msg)
  assert_true(not val, msg)
end

local function render(lines, opts)
  local b = ContentBuilder.new()
  b:render_document(lines, opts or { max_width = 80, indent = "  " })
  return b:result()
end

local function any_line_contains(out, needle)
  for _, line in ipairs(out.lines) do
    if line:find(needle, 1, true) then return true end
  end
  return false
end

-- Test 1: <em> inside <figcaption> is stripped (not shown literally)
do
  local out = render({
    "<figure align=\"center\">",
    "  <img src=\"x.png\" alt=\"x\" />",
    "  <figcaption><em>caption text</em></figcaption>",
    "</figure>",
  })
  assert_false(any_line_contains(out, "<em>"), "<em> opening tag should not appear in output")
  assert_false(any_line_contains(out, "</em>"), "</em> closing tag should not appear in output")
  assert_true(any_line_contains(out, "caption text"), "caption text should appear in output")
end

-- Test 2: long caption is wrapped (no line exceeds max_width significantly)
do
  local long_caption = string.rep("word ", 30):gsub("%s+$", "")
  local out = render({
    "<figure>",
    "  <img src=\"x.png\" alt=\"x\" />",
    "  <figcaption>" .. long_caption .. "</figcaption>",
    "</figure>",
  }, { max_width = 40, indent = "  " })

  local longest = 0
  for _, line in ipairs(out.lines) do
    local w = vim.api.nvim_strwidth(line)
    if w > longest then longest = w end
  end
  assert_true(longest <= 40, "no rendered line should exceed max_width=40 (got " .. longest .. ")")
end

-- Test 3: caption highlights include "Comment" base
do
  local out = render({
    "<figure>",
    "  <img src=\"x.png\" alt=\"x\" />",
    "  <figcaption>plain caption</figcaption>",
    "</figure>",
  })
  local found_comment = false
  for _, entry in ipairs(out.highlights or {}) do
    for _, hl in ipairs(entry.groups or {}) do
      if hl.hl == "Comment" then found_comment = true end
    end
  end
  assert_true(found_comment, "figcaption text should carry Comment highlight")
end

print(string.format("\nfigure_test: %d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
