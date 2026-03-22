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

-- HTML inline tag tests

test("html: <b> renders as Bold", function()
  local text, highlights = render("<b>bold text</b>")
  assert_eq(text, "bold text", "html b: text should have tags stripped")
  local has_bold = false
  for _, hl in ipairs(highlights) do
    if hl.hl == "Bold" then has_bold = true end
  end
  assert_eq(has_bold, true, "html b: should have Bold highlight")
end)

test("html: <strong> renders as Bold", function()
  local text, highlights = render("<strong>bold</strong>")
  assert_eq(text, "bold", "html strong: tags should be stripped")
  assert_eq(highlights[1].hl, "Bold", "html strong: should be Bold")
end)

test("html: <i> renders as Italic", function()
  local text, highlights = render("<i>italic</i>")
  assert_eq(text, "italic", "html i: tags should be stripped")
  assert_eq(highlights[1].hl, "Italic", "html i: should be Italic")
end)

test("html: <em> renders as Italic", function()
  local text, highlights = render("<em>emphasis</em>")
  assert_eq(text, "emphasis", "html em: tags should be stripped")
  assert_eq(highlights[1].hl, "Italic", "html em: should be Italic")
end)

test("html: <code> renders as String", function()
  local text, highlights = render("<code>code</code>")
  assert_eq(text, "code", "html code: tags should be stripped")
  assert_eq(highlights[1].hl, "String", "html code: should be String")
end)

test("html: <s> renders as strikethrough", function()
  local text, highlights = render("<s>deleted</s>")
  assert_eq(text, "deleted", "html s: tags should be stripped")
  assert_eq(highlights[1].hl, "DiagnosticDeprecated", "html s: should be DiagnosticDeprecated")
end)

test("html: <del> renders as strikethrough", function()
  local text, highlights = render("<del>removed</del>")
  assert_eq(text, "removed", "html del: tags should be stripped")
  assert_eq(highlights[1].hl, "DiagnosticDeprecated", "html del: should be DiagnosticDeprecated")
end)

test("html: <u> renders as Underlined", function()
  local text, highlights = render("<u>underline</u>")
  assert_eq(text, "underline", "html u: tags should be stripped")
  assert_eq(highlights[1].hl, "Underlined", "html u: should be Underlined")
end)

test("html: <mark> renders as MdRenderHighlight", function()
  local text, highlights = render("<mark>highlighted</mark>")
  assert_eq(text, "highlighted", "html mark: tags should be stripped")
  assert_eq(highlights[1].hl, "MdRenderHighlight", "html mark: should be MdRenderHighlight")
end)

test("html: <kbd> renders as Special", function()
  local text, highlights = render("<kbd>Ctrl+C</kbd>")
  assert_eq(text, "Ctrl+C", "html kbd: tags should be stripped")
  assert_eq(highlights[1].hl, "Special", "html kbd: should be Special")
end)

test("html: <sub> strips tags without highlight", function()
  local text, highlights = render("<sub>subscript</sub>")
  assert_eq(text, "subscript", "html sub: tags should be stripped")
  assert_eq(#highlights, 0, "html sub: should have no highlights")
end)

test("html: <sup> strips tags without highlight", function()
  local text, highlights = render("<sup>superscript</sup>")
  assert_eq(text, "superscript", "html sup: tags should be stripped")
  assert_eq(#highlights, 0, "html sup: should have no highlights")
end)

test("html: <a href> renders as link", function()
  local text, highlights, _ = render('<a href="https://example.com">click here</a>')
  assert_eq(text, "click here", "html a: tags should be stripped")
  assert_eq(highlights[1].hl, "Underlined", "html a: should be Underlined")
end)

test("html: <a href> produces link metadata", function()
  local Markdown = require "md-render.markdown"
  local text, _, links = Markdown.render('<a href="https://example.com">link text</a>')
  assert_eq(text, "link text", "html a link: text")
  assert_eq(#links, 1, "html a link: should have 1 link")
  assert_eq(links[1].url, "https://example.com", "html a link: url should match")
end)

test("html: <img> renders as image display", function()
  local Markdown = require "md-render.markdown"
  local text, highlights, links = Markdown.render('<img src="photo.png" alt="My Photo">')
  assert(text:find("My Photo"), "html img: should contain alt text")
  assert(text:find("🖼"), "html img: should contain image icon")
  assert_eq(#links, 1, "html img: should have 1 link")
  assert_eq(links[1].url, "photo.png", "html img: link url should be src")
end)

test("html: <img> without alt shows filename", function()
  local Markdown = require "md-render.markdown"
  local text = Markdown.render('<img src="/path/to/image.jpg">')
  assert(text:find("image.jpg"), "html img no alt: should show filename")
end)

test("html: unknown tags are kept with Comment highlight", function()
  local text, highlights = render("<div>content</div>")
  assert_eq(text, "<div>content</div>", "html unknown: tags should be kept")
  local found_open = false
  local found_close = false
  for _, h in ipairs(highlights) do
    if h.hl == "Comment" and text:sub(h.col + 1, h.end_col) == "<div>" then found_open = true end
    if h.hl == "Comment" and text:sub(h.col + 1, h.end_col) == "</div>" then found_close = true end
  end
  assert_eq(found_open, true, "html unknown: <div> should have Comment highlight")
  assert_eq(found_close, true, "html unknown: </div> should have Comment highlight")
end)

test("html: self-closing unknown tags are kept with Comment highlight", function()
  local text, highlights = render("before<br/>after")
  assert_eq(text, "before<br/>after", "html br: tag should be kept")
  local found = false
  for _, h in ipairs(highlights) do
    if h.hl == "Comment" and text:sub(h.col + 1, h.end_col) == "<br/>" then found = true end
  end
  assert_eq(found, true, "html br: should have Comment highlight")
end)

test("html: inline comments are stripped", function()
  local text = render("before<!-- comment -->after")
  assert_eq(text, "beforeafter", "html comment: inline comment should be removed")
end)

test("html: standalone comment line is stripped", function()
  local text = render("<!-- this is a comment -->")
  assert_eq(text, "", "html comment: standalone comment should be removed")
end)

test("html: tags inside backticks are preserved", function()
  local text = render("`<b>not bold</b>`")
  assert(text:find("<b>"), "html in backtick: <b> should be preserved")
end)

test("html: mixed markdown and html", function()
  local text, highlights = render("**bold** and <i>italic</i>")
  assert_eq(text, "bold and italic", "mixed: markers and tags stripped")
  local has_bold, has_italic = false, false
  for _, hl in ipairs(highlights) do
    if hl.hl == "Bold" then has_bold = true end
    if hl.hl == "Italic" then has_italic = true end
  end
  assert_eq(has_bold, true, "mixed: should have Bold")
  assert_eq(has_italic, true, "mixed: should have Italic")
end)

test("html: <strike> renders as strikethrough", function()
  local text, highlights = render("<strike>old</strike>")
  assert_eq(text, "old", "html strike: tags should be stripped")
  assert_eq(highlights[1].hl, "DiagnosticDeprecated", "html strike: should be DiagnosticDeprecated")
end)

-- render_document HTML block-level tests

test("html: <h1> renders as heading", function()
  local lines = render_doc({ "<h1>Title</h1>" })
  assert_eq(#lines, 1, "html h1: should have 1 line")
  assert(lines[1]:find("Title"), "html h1: should contain title text")
end)

test("html: <h3> renders as heading level 3", function()
  local lines = render_doc({ "<h3>Section</h3>" })
  assert(lines[1]:find("Section"), "html h3: should contain section text")
end)

test("html: <hr> renders as horizontal rule", function()
  local lines = render_doc({
    "above",
    "<hr>",
    "below",
  })
  local has_rule = false
  for _, l in ipairs(lines) do
    if l:match("─") then has_rule = true end
  end
  assert_eq(has_rule, true, "html hr: should have horizontal rule")
  assert_eq(#lines, 5, "html hr: should have 5 lines (text + blank + rule + blank + text)")
end)

test("html: <hr/> self-closing renders as rule", function()
  local lines = render_doc({
    "above",
    "<hr/>",
    "below",
  })
  local has_rule = false
  for _, l in ipairs(lines) do
    if l:match("─") then has_rule = true end
  end
  assert_eq(has_rule, true, "html hr/: should have horizontal rule")
end)

-- HTML inside <details> tests

test("details: inline HTML tags work in body", function()
  local lines = render_doc_full({
    "<details open>",
    "<summary>Info</summary>",
    "",
    "<b>bold text</b> inside details",
    "",
    "</details>",
  })
  local has_body = false
  for _, l in ipairs(lines) do
    if l:match("bold text") and l:match("│") then has_body = true end
  end
  assert_eq(has_body, true, "details inline html: body with <b> should have │ prefix")
end)

test("details: <h3> works in body", function()
  local lines = render_doc_full({
    "<details open>",
    "<summary>Heading test</summary>",
    "",
    "<h3>Sub Section</h3>",
    "",
    "</details>",
  })
  local has_heading = false
  for _, l in ipairs(lines) do
    if l:match("Sub Section") and l:match("│") then has_heading = true end
  end
  assert_eq(has_heading, true, "details h3: heading should have │ prefix")
end)

test("details: <hr> works in body with │ prefix", function()
  local lines = render_doc_full({
    "<details open>",
    "<summary>Rule test</summary>",
    "",
    "<hr>",
    "",
    "</details>",
  })
  local has_rule_with_prefix = false
  for _, l in ipairs(lines) do
    if l:match("─") and l:match("│") then has_rule_with_prefix = true end
  end
  assert_eq(has_rule_with_prefix, true, "details hr: rule should have │ prefix")
end)

test("details: <a> link works in body", function()
  local builder = ContentBuilder.new()
  builder:render_document({
    "<details open>",
    "<summary>Links</summary>",
    "",
    '<a href="https://example.com">click</a>',
    "",
    "</details>",
  }, { max_width = 80, indent = "" })
  local has_link = false
  for _, l in ipairs(builder.lines) do
    if l:match("click") and l:match("│") then has_link = true end
  end
  assert_eq(has_link, true, "details a: link text should have │ prefix")
  local has_link_meta = false
  for _, link in ipairs(builder.link_metadata) do
    if link.url == "https://example.com" then has_link_meta = true end
  end
  assert_eq(has_link_meta, true, "details a: should have link metadata")
end)

-- Nested HTML tag tests

test("html nested: <b><i>text</i></b>", function()
  local text, highlights = render("<b><i>text</i></b>")
  assert_eq(text, "text", "nested bi: tags should be stripped")
  local has_bold, has_italic = false, false
  for _, hl in ipairs(highlights) do
    if hl.hl == "Bold" then has_bold = true end
    if hl.hl == "Italic" then has_italic = true end
  end
  assert_eq(has_bold, true, "nested bi: should have Bold")
  assert_eq(has_italic, true, "nested bi: should have Italic")
end)

test("html nested: <a><b>text</b></a>", function()
  local Markdown = require "md-render.markdown"
  local text, highlights, links = Markdown.render('<a href="https://example.com"><b>link</b></a>')
  assert_eq(text, "link", "nested a-b: tags should be stripped")
  local has_bold, has_underlined = false, false
  for _, hl in ipairs(highlights) do
    if hl.hl == "Bold" then has_bold = true end
    if hl.hl == "Underlined" then has_underlined = true end
  end
  assert_eq(has_bold, true, "nested a-b: should have Bold")
  assert_eq(has_underlined, true, "nested a-b: should have Underlined")
  assert_eq(#links, 1, "nested a-b: should have 1 link")
  assert_eq(links[1].url, "https://example.com", "nested a-b: url should match")
end)

test("html nested: highlight positions are correct", function()
  local text, highlights = render("before <b><i>inner</i></b> after")
  assert_eq(text, "before inner after", "nested pos: text correct")
  for _, hl in ipairs(highlights) do
    if hl.hl == "Bold" then
      assert_eq(hl.col, 7, "nested pos: Bold start")
      assert_eq(hl.end_col, 12, "nested pos: Bold end")
    end
    if hl.hl == "Italic" then
      assert_eq(hl.col, 7, "nested pos: Italic start")
      assert_eq(hl.end_col, 12, "nested pos: Italic end")
    end
  end
end)

-- Multi-line HTML tag tests

test("html multiline: inline <b> spanning lines", function()
  local lines = render_doc({ "<b>bold", "text</b>" })
  -- Should be joined into one line with bold
  local found = false
  for _, l in ipairs(lines) do
    if l:match("bold text") then found = true end
  end
  assert_eq(found, true, "multiline b: should join lines with space")
end)

test("html multiline: block <div> joins and strips tags", function()
  local lines = render_doc({
    "<div>",
    "line one",
    "line two",
    "</div>",
  })
  local found = false
  for _, l in ipairs(lines) do
    if l:match("line one") and l:match("line two") then found = true end
  end
  assert_eq(found, true, "multiline div: lines should be joined")
  -- Tags are now kept with Comment highlight, not stripped
  local has_div = false
  for _, l in ipairs(lines) do
    if l:match("<div>") then has_div = true end
  end
  assert_eq(has_div, true, "multiline div: <div> tags should be kept with Comment highlight")
end)

test("html multiline: nested same-type block", function()
  local lines = render_doc({
    "<div>",
    "<div>inner</div>",
    "</div>",
  })
  local has_inner = false
  for _, l in ipairs(lines) do
    if l:match("inner") then has_inner = true end
  end
  assert_eq(has_inner, true, "nested div: inner content should show")
end)

test("html multiline: <p> joins content", function()
  local lines = render_doc({
    "<p>",
    "Paragraph content here.",
    "</p>",
  })
  local found = false
  for _, l in ipairs(lines) do
    if l:match("Paragraph content") then found = true end
  end
  assert_eq(found, true, "multiline p: content should show")
end)

test("html multiline: <h1> with img and links (neovim-style)", function()
  local builder = ContentBuilder.new()
  builder:render_document({
    '<h1 align="center">',
    '  <img src="https://example.com/logo.png" alt="Neovim">',
    '',
    '  <a href="https://neovim.io/doc/">Documentation</a> |',
    '  <a href="https://example.com/chat">Chat</a>',
    '</h1>',
  }, { max_width = 80, indent = "" })
  -- Image is split out from heading: image line(s) + heading line with links
  local all_text = table.concat(builder.lines, "\n")
  assert(all_text:find("Neovim"), "h1 multiline: should contain Neovim (from img alt)")
  assert(all_text:find("Documentation"), "h1 multiline: should contain Documentation")
  assert(all_text:find("Chat"), "h1 multiline: should contain Chat")
  -- Should have heading highlight
  local has_h1 = false
  for _, hl in ipairs(builder.highlights) do
    for _, g in ipairs(hl.groups) do
      if g.hl == "MdRenderH1" then has_h1 = true end
    end
  end
  assert_eq(has_h1, true, "h1 multiline: should have MdRenderH1 highlight")
end)

test("html multiline: inline <b> has Bold highlight after join", function()
  local builder = ContentBuilder.new()
  builder:render_document({
    "<b>bold",
    "text</b>",
  }, { max_width = 80, indent = "" })
  local has_bold = false
  for _, hl in ipairs(builder.highlights) do
    for _, g in ipairs(hl.groups) do
      if g.hl == "Bold" then has_bold = true end
    end
  end
  assert_eq(has_bold, true, "multiline b highlight: should have Bold")
end)

test("html multiline: code block inside block element not broken", function()
  local lines = render_doc({
    "<div>",
    "```python",
    "print('hello')",
    "```",
    "</div>",
  })
  local has_print = false
  for _, l in ipairs(lines) do
    if l:match("print") then has_print = true end
  end
  assert_eq(has_print, true, "div+code: code content should render")
end)

test("html multiline: tags inside code blocks not preprocessed", function()
  local lines = render_doc({
    "```",
    "<div>",
    "should stay",
    "</div>",
    "```",
  })
  local has_div = false
  for _, l in ipairs(lines) do
    if l:match("<div>") then has_div = true end
  end
  assert_eq(has_div, true, "code block div: <div> should be preserved")
end)

test("html multiline: <div> with attributes", function()
  local lines = render_doc({
    '<div class="note" id="foo">',
    "styled content",
    "</div>",
  })
  local found = false
  for _, l in ipairs(lines) do
    if l:match("styled content") then found = true end
  end
  assert_eq(found, true, "div attrs: content should show")
  -- Tags are now kept with Comment highlight, not stripped
end)

test("html multiline: unclosed tag outputs lines as-is", function()
  local lines = render_doc({
    "<b>unclosed",
    "still here",
  })
  assert_eq(#lines >= 1, true, "unclosed: should output something")
end)

test("html multiline: <div> content on opening tag line", function()
  local lines = render_doc({
    "<div>first line content",
    "second line",
    "</div>",
  })
  local has_first, has_second = false, false
  for _, l in ipairs(lines) do
    if l:match("first line content") then has_first = true end
    if l:match("second line") then has_second = true end
  end
  assert_eq(has_first, true, "div inline open: first line content")
  assert_eq(has_second, true, "div inline open: second line content")
end)

test("html block comment: single-line comment is skipped", function()
  local lines = render_doc({
    "before",
    "<!-- this is a comment -->",
    "after",
  })
  for _, l in ipairs(lines) do
    assert_eq(l:match("comment"), nil, "html block comment: should not show comment")
  end
  local has_before, has_after = false, false
  for _, l in ipairs(lines) do
    if l:match("before") then has_before = true end
    if l:match("after") then has_after = true end
  end
  assert_eq(has_before, true, "html block comment: before should show")
  assert_eq(has_after, true, "html block comment: after should show")
end)

test("html block comment: multi-line comment is skipped", function()
  local lines = render_doc({
    "before",
    "<!-- multi",
    "line comment",
    "-->",
    "after",
  })
  for _, l in ipairs(lines) do
    assert_eq(l:match("multi"), nil, "html multi comment: should not show first line")
    assert_eq(l:match("line comment"), nil, "html multi comment: should not show middle")
  end
  local has_before, has_after = false, false
  for _, l in ipairs(lines) do
    if l:match("before") then has_before = true end
    if l:match("after") then has_after = true end
  end
  assert_eq(has_before, true, "html multi comment: before should show")
  assert_eq(has_after, true, "html multi comment: after should show")
end)

-- Print summary
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
