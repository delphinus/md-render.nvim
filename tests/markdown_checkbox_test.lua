-- Test checkbox rendering in Markdown.render
-- Run: nvim --headless -u NONE --noplugin -l tests/markdown_checkbox_test.lua

package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local Markdown = require "md-render.markdown"

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

-- Helper: render and return text, highlights, list_marker
local function render(input)
  local text, highlights, links, special_type, list_marker = Markdown.render(input)
  return text, highlights, list_marker
end

-- Unchecked checkbox
test("unchecked checkbox text", function()
  local text, highlights, list_marker = render("- [ ] todo item")
  -- list_marker should be the icon (no dash)
  assert_eq(list_marker:match "^%s*[-*]", nil, "unchecked: list_marker should not contain dash")
  -- rendered text should not contain [ ]
  assert_eq(text:find "%[ %]", nil, "unchecked: rendered text should not contain [ ]")
  -- rendered text should not start with "- "
  assert_eq(text:match "^%- ", nil, "unchecked: rendered text should not start with '- '")
  -- rendered text should contain the content
  assert(text:find "todo item", "unchecked: rendered text should contain 'todo item'")
  -- highlight should be Comment
  assert_eq(highlights[1].hl, "Comment", "unchecked: highlight should be Comment")
end)

-- Checked checkbox (lowercase x)
test("checked checkbox text", function()
  local text, highlights, list_marker = render("- [x] done item")
  assert_eq(text:find "%[x%]", nil, "checked: rendered text should not contain [x]")
  assert_eq(text:match "^%- ", nil, "checked: rendered text should not start with '- '")
  assert(text:find "done item", "checked: rendered text should contain 'done item'")
  assert_eq(highlights[1].hl, "DiagnosticOk", "checked: highlight should be DiagnosticOk")
end)

-- Checked checkbox (uppercase X)
test("checked checkbox uppercase X", function()
  local text, highlights, list_marker = render("- [X] done item")
  assert_eq(text:find "%[X%]", nil, "checked uppercase: rendered text should not contain [X]")
  assert_eq(highlights[1].hl, "DiagnosticOk", "checked uppercase: highlight should be DiagnosticOk")
end)

-- Partial checkbox (-)
test("partial checkbox text", function()
  local text, highlights, list_marker = render("- [-] in progress")
  assert_eq(text:find "%[%-%]", nil, "partial: rendered text should not contain [-]")
  assert(text:find "in progress", "partial: rendered text should contain 'in progress'")
  assert_eq(highlights[1].hl, "DiagnosticWarn", "partial: highlight should be DiagnosticWarn")
end)

-- Normal list item (no checkbox)
test("normal list item unchanged", function()
  local text, highlights, list_marker = render("- normal item")
  assert_eq(list_marker, "- ", "normal: list_marker should be '- '")
  assert(text:find "normal item", "normal: rendered text should contain 'normal item'")
  assert_eq(highlights[1].hl, "Special", "normal: highlight should be Special")
end)

-- Asterisk list marker with checkbox
test("asterisk list marker checkbox", function()
  local text, highlights, list_marker = render("* [x] done")
  assert_eq(text:find "%[x%]", nil, "asterisk: rendered text should not contain [x]")
  assert_eq(highlights[1].hl, "DiagnosticOk", "asterisk: highlight should be DiagnosticOk")
end)

-- Ordered list with checkbox
test("ordered list checkbox", function()
  local text, highlights, list_marker = render("1. [x] done")
  assert_eq(text:find "%[x%]", nil, "ordered: rendered text should not contain [x]")
  assert_eq(highlights[1].hl, "DiagnosticOk", "ordered: highlight should be DiagnosticOk")
end)

-- Indented checkbox
test("indented checkbox", function()
  local text, highlights, list_marker = render("  - [x] nested done")
  assert_eq(text:find "%[x%]", nil, "indented: rendered text should not contain [x]")
  assert(text:find "nested done", "indented: rendered text should contain 'nested done'")
  -- list_marker should preserve leading whitespace
  assert_eq(list_marker:match "^(%s+)", "  ", "indented: list_marker should have 2-space indent")
  assert_eq(highlights[1].hl, "DiagnosticOk", "indented: highlight should be DiagnosticOk")
  -- highlight col should start after indent (2 bytes)
  assert_eq(highlights[1].col, 2, "indented: highlight col should start at 2 (after indent)")
end)

-- Highlight range should cover only the icon, not content text
test("highlight covers only icon", function()
  local text, highlights, list_marker = render("- [x] some content")
  local hl = highlights[1]
  -- The highlight should end at the list_marker boundary (icon + space)
  assert_eq(hl.end_col, #list_marker, "icon hl: end_col should equal list_marker byte length")
  -- The highlight should NOT extend into content
  assert(hl.end_col <= #list_marker, "icon hl: should not extend past list_marker")
end)

-- Text without checkbox should not be affected
test("non-list text unaffected", function()
  local text, highlights, list_marker = render("just some text")
  assert_eq(list_marker, nil, "non-list: list_marker should be nil")
end)

-- Checkbox with inline formatting
test("checkbox with bold content", function()
  local text, highlights, list_marker = render("- [x] **bold task**")
  assert_eq(text:find "%[x%]", nil, "bold: rendered text should not contain [x]")
  assert(text:find "bold task", "bold: rendered text should contain 'bold task'")
  -- Should have checkbox highlight and bold highlight
  local has_checkbox = false
  local has_bold = false
  for _, hl in ipairs(highlights) do
    if hl.hl == "DiagnosticOk" then has_checkbox = true end
    if hl.hl == "Bold" then has_bold = true end
  end
  assert(has_checkbox, "bold: should have checkbox highlight")
  assert(has_bold, "bold: should have bold highlight")
end)

-- list_marker_type tests (CommonMark: same character/delimiter = same list)
test("list_marker_type: dash", function()
  assert_eq(Markdown.list_marker_type("- item"), "-", "dash should return '-'")
end)

test("list_marker_type: asterisk", function()
  assert_eq(Markdown.list_marker_type("* item"), "*", "asterisk should return '*'")
end)

test("list_marker_type: plus", function()
  assert_eq(Markdown.list_marker_type("+ item"), "+", "plus should return '+'")
end)

test("list_marker_type: ordered dot", function()
  assert_eq(Markdown.list_marker_type("1. item"), ".", "ordered dot should return '.'")
end)

test("list_marker_type: ordered paren", function()
  assert_eq(Markdown.list_marker_type("1) item"), ")", "ordered paren should return ')'")
end)

test("list_marker_type: indented dash", function()
  assert_eq(Markdown.list_marker_type("  - item"), "-", "indented dash should return '-'")
end)

test("list_marker_type: non-list", function()
  assert_eq(Markdown.list_marker_type("just text"), nil, "plain text should be nil")
end)

test("list_marker_type: blank line", function()
  assert_eq(Markdown.list_marker_type(""), nil, "blank line should be nil")
end)

-- render_document loose list collapsing tests
local ContentBuilder = require("md-render.content_builder").ContentBuilder

local function render_doc(input_lines, opts)
  local builder = ContentBuilder.new()
  builder:render_document(input_lines, opts or { max_width = 80, indent = "" })
  return builder.lines
end

test("loose list: blank lines between same-type items are collapsed", function()
  local lines = render_doc({
    "- item 1",
    "",
    "- item 2",
    "",
    "- item 3",
  })
  -- Should have 3 lines, no blank lines
  local blank_count = 0
  for _, l in ipairs(lines) do
    if l:match "^%s*$" then blank_count = blank_count + 1 end
  end
  assert_eq(blank_count, 0, "loose same-type: blank lines should be collapsed")
  assert_eq(#lines, 3, "loose same-type: should have 3 lines")
end)

test("loose list: blank lines between different marker types are kept (ul vs ol)", function()
  local lines = render_doc({
    "- item 1",
    "",
    "1. item 2",
  })
  local blank_count = 0
  for _, l in ipairs(lines) do
    if l:match "^%s*$" then blank_count = blank_count + 1 end
  end
  assert_eq(blank_count, 1, "ul vs ol: blank line should be kept")
end)

test("loose list: blank lines between different bullet chars are kept (- vs *)", function()
  local lines = render_doc({
    "- item 1",
    "",
    "* item 2",
  })
  local blank_count = 0
  for _, l in ipairs(lines) do
    if l:match "^%s*$" then blank_count = blank_count + 1 end
  end
  assert_eq(blank_count, 1, "dash vs asterisk: blank line should be kept")
end)

test("loose list: blank lines between different ordered delimiters are kept (. vs ))", function()
  local lines = render_doc({
    "1. item 1",
    "",
    "1) item 2",
  })
  local blank_count = 0
  for _, l in ipairs(lines) do
    if l:match "^%s*$" then blank_count = blank_count + 1 end
  end
  assert_eq(blank_count, 1, "dot vs paren: blank line should be kept")
end)

test("loose list with checkboxes: blank lines collapsed", function()
  local lines = render_doc({
    "- [ ] todo 1",
    "",
    "- [x] done 1",
    "",
    "- [-] partial 1",
  })
  local blank_count = 0
  for _, l in ipairs(lines) do
    if l:match "^%s*$" then blank_count = blank_count + 1 end
  end
  assert_eq(blank_count, 0, "checkbox loose list: blank lines should be collapsed")
  assert_eq(#lines, 3, "checkbox loose list: should have 3 lines")
end)

test("tight list: no change", function()
  local lines = render_doc({
    "- item 1",
    "- item 2",
    "- item 3",
  })
  assert_eq(#lines, 3, "tight list: should have 3 lines")
end)

-- render_document <details>/<summary> tests
local function render_doc_full(input_lines, opts)
  local builder = ContentBuilder.new()
  builder:render_document(input_lines, opts or { max_width = 80, indent = "" })
  return builder.lines, builder.callout_folds
end

test("details: collapsed by default (no open attribute)", function()
  local lines, folds = render_doc_full({
    "<details>",
    "<summary>Title</summary>",
    "",
    "Body content",
    "",
    "</details>",
  })
  -- Should show only the summary header, body is hidden
  assert_eq(#lines, 1, "collapsed details: should have 1 line (header only)")
  assert_eq(#folds, 1, "collapsed details: should have 1 fold entry")
  assert_eq(folds[1].collapsed, true, "collapsed details: fold should be collapsed")
  -- Header should contain the title
  local header = lines[1]
  assert_eq(header:match("Title") ~= nil, true, "collapsed details: header should contain title")
end)

test("details open: expanded by default with │ prefix", function()
  local lines, folds = render_doc_full({
    "<details open>",
    "<summary>Title</summary>",
    "",
    "Body content",
    "",
    "</details>",
  })
  -- Should show header + blank + body content
  assert_eq(#folds, 1, "open details: should have 1 fold entry")
  assert_eq(folds[1].collapsed, false, "open details: fold should be expanded")
  -- Body should be visible with │ prefix
  local has_body = false
  for _, l in ipairs(lines) do
    if l:match("│") and l:match("Body content") then has_body = true end
  end
  assert_eq(has_body, true, "open details: body should have │ prefix")
  -- Header should NOT have │ prefix
  local header = lines[1]
  assert_eq(header:match("^│") == nil, true, "open details: header should not have │ prefix")
end)

test("details: fold_state overrides default", function()
  local lines = render_doc_full({
    "<details>",
    "<summary>Title</summary>",
    "",
    "Body content",
    "",
    "</details>",
  }, { max_width = 80, indent = "", fold_state = { [1] = false } })
  -- fold_state says src_idx 1 (the <details> line) is NOT collapsed
  local has_body = false
  for _, l in ipairs(lines) do
    if l:match("Body content") then has_body = true end
  end
  assert_eq(has_body, true, "fold_state override: body should be visible")
end)

test("details: no summary tag renders default 'Details' label", function()
  local lines = render_doc_full({
    "<details open>",
    "Body without summary",
    "</details>",
  })
  local has_details_label = false
  for _, l in ipairs(lines) do
    if l:match("Details") then has_details_label = true end
  end
  assert_eq(has_details_label, true, "no summary: should use default 'Details' label")
end)

test("details: inline summary on details tag", function()
  local lines, folds = render_doc_full({
    "<details><summary>Inline Title</summary>",
    "",
    "Body",
    "",
    "</details>",
  })
  assert_eq(#folds, 1, "inline summary: should have 1 fold")
  assert_eq(lines[1]:match("Inline Title") ~= nil, true, "inline summary: header should contain title")
end)

test("details: nested details depth tracking", function()
  local lines = render_doc_full({
    "<details>",
    "<summary>Outer</summary>",
    "Outer body",
    "</details>",
  })
  -- Collapsed: only header visible
  assert_eq(#lines, 1, "nested: outer collapsed should have 1 line")
end)

-- Print summary
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
