-- Test HTML table rendering
-- Run: nvim --headless -u NONE --noplugin -l tests/html_table_test.lua

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

local function assert_true(val, msg)
  if val then
    pass_count = pass_count + 1
  else
    fail_count = fail_count + 1
    print("FAIL: " .. msg)
  end
end

local function assert_contains(str, substr, msg)
  if str and str:find(substr, 1, true) then
    pass_count = pass_count + 1
  else
    fail_count = fail_count + 1
    print("FAIL: " .. msg)
    print("  string:    " .. tostring(str))
    print("  expected:  " .. substr)
  end
end

-- Helper: render lines and return output lines
local function render(lines, opts)
  local b = ContentBuilder.new()
  b:render_document(lines, opts or { max_width = 80, indent = "  " })
  return b:result()
end

-- Test 1: Simple HTML table with <th> header
do
  local lines = {
    "<table>",
    "<tr><th>Name</th><th>Value</th></tr>",
    "<tr><td>foo</td><td>bar</td></tr>",
    "<tr><td>baz</td><td>qux</td></tr>",
    "</table>",
  }
  local result = render(lines)
  -- Should contain box-drawing borders (table rendered)
  local found_border = false
  local found_foo = false
  local found_name = false
  for _, line in ipairs(result.lines) do
    if line:find("│", 1, true) then found_border = true end
    if line:find("foo", 1, true) then found_foo = true end
    if line:find("Name", 1, true) then found_name = true end
  end
  assert_true(found_border, "HTML table should render with box-drawing borders")
  assert_true(found_foo, "HTML table should contain cell content 'foo'")
  assert_true(found_name, "HTML table should contain header 'Name'")
end

-- Test 2: HTML table without <th> (all <td>)
do
  local lines = {
    "<table>",
    "<tr><td>a</td><td>b</td></tr>",
    "<tr><td>c</td><td>d</td></tr>",
    "</table>",
  }
  local result = render(lines)
  local found_border = false
  local found_c = false
  for _, line in ipairs(result.lines) do
    if line:find("│", 1, true) then found_border = true end
    if line:find("c", 1, true) then found_c = true end
  end
  assert_true(found_border, "HTML table without <th> should render with borders")
  assert_true(found_c, "HTML table without <th> should contain 'c'")
end

-- Test 3: HTML table with align attributes
do
  local lines = {
    "<table>",
    '<tr><td align="center">centered</td><td align="right">right</td></tr>',
    "</table>",
  }
  local result = render(lines)
  local found = false
  for _, line in ipairs(result.lines) do
    if line:find("centered", 1, true) then found = true end
  end
  assert_true(found, "HTML table with align should render content")
end

-- Test 4: HTML table with inline HTML (<em>, <strong>)
do
  local lines = {
    "<table>",
    "<tr><td><em>italic</em></td><td><strong>bold</strong></td></tr>",
    "</table>",
  }
  local result = render(lines)
  local found_italic = false
  local found_bold = false
  for _, line in ipairs(result.lines) do
    if line:find("italic", 1, true) then found_italic = true end
    if line:find("bold", 1, true) then found_bold = true end
  end
  assert_true(found_italic, "HTML table should render <em> content")
  assert_true(found_bold, "HTML table should render <strong> content")
end

-- Test 5: HTML table with <img> tags (like README)
do
  local lines = {
    "<table>",
    "<tr>",
    '<td><img src="assets/demo/test.png" alt="Test" /></td>',
    '<td><img src="assets/demo/test.jpg" alt="Photo" /></td>',
    "</tr>",
    "</table>",
  }
  local result = render(lines)
  -- Image cells should show the alt text with a Nerd Font icon
  local found_any_content = false
  for _, line in ipairs(result.lines) do
    if line:find("│", 1, true) then found_any_content = true end
  end
  assert_true(found_any_content, "HTML table with <img> should render")
end

-- Test 6: Single-line HTML table
do
  local lines = {
    "<table><tr><th>H</th></tr><tr><td>D</td></tr></table>",
  }
  local result = render(lines)
  local found = false
  for _, line in ipairs(result.lines) do
    if line:find("│", 1, true) then found = true end
  end
  assert_true(found, "Single-line HTML table should render")
end

-- Test 7: HTML table inside <details>
do
  local lines = {
    "<details>",
    "<summary>Click to see table</summary>",
    "<table>",
    "<tr><th>Key</th><th>Val</th></tr>",
    "<tr><td>x</td><td>y</td></tr>",
    "</table>",
    "</details>",
  }
  -- fold_state[1] = false means expanded (not collapsed)
  local result = render(lines, { max_width = 80, indent = "  ", fold_state = { [1] = false } })
  -- Should have both the details header and table content
  local found_click = false
  local found_table = false
  for _, line in ipairs(result.lines) do
    if line:find("Click to see table", 1, true) then found_click = true end
    if line:find("│", 1, true) then found_table = true end
  end
  assert_true(found_click, "Details summary should render")
  assert_true(found_table, "Table inside details should render")
end

-- Test 8: Multi-line HTML table structure (each tag on its own line)
do
  local lines = {
    "<table>",
    "  <tr>",
    "    <th>Col A</th>",
    "    <th>Col B</th>",
    "  </tr>",
    "  <tr>",
    "    <td>1</td>",
    "    <td>2</td>",
    "  </tr>",
    "</table>",
  }
  local result = render(lines)
  local found_col_a = false
  local found_1 = false
  for _, line in ipairs(result.lines) do
    if line:find("Col A", 1, true) then found_col_a = true end
    if line:find("1", 1, true) then found_1 = true end
  end
  assert_true(found_col_a, "Multi-line HTML table should render headers")
  assert_true(found_1, "Multi-line HTML table should render data cells")
end

print(pass_count .. " passed, " .. fail_count .. " failed")
if fail_count > 0 then
  os.exit(1)
end
