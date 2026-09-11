-- Test that spaces written only to help lenient parsers see an inline marker
-- are closed up in CJK text, and left alone everywhere else.
-- Run: nvim --headless -u NONE --noplugin -l tests/cjk_marker_space_test.lua

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

--- Rendered text only, for the many cases that just check the gap.
---@param src string
---@return string
local function rendered(src)
  local text = Markdown.render(src)
  return text
end

--- The substring a highlight covers, so a shifted column shows up as a
--- mis-sliced string rather than as a number nobody can read.
---@param src string
---@param hl_group string
---@return string[]
local function spans(src, hl_group)
  local text, highlights = Markdown.render(src)
  local out = {}
  for _, hl in ipairs(highlights) do
    if hl.hl == hl_group then table.insert(out, text:sub(hl.col + 1, hl.end_col)) end
  end
  return out
end

-- Spaces are dropped between wide characters

test("bold between wide characters closes up", function()
  assert_eq(rendered "これは **強調** です。", "これは強調です。", "bold gap closed")
  assert_eq(spans("これは **強調** です。", "Bold"), { "強調" }, "bold still covers 強調")
end)

test("italic between wide characters closes up", function()
  assert_eq(rendered "これは *斜体* です。", "これは斜体です。", "italic gap closed")
  assert_eq(spans("これは *斜体* です。", "Italic"), { "斜体" }, "italic still covers 斜体")
end)

test("strikethrough between wide characters closes up", function()
  assert_eq(
    rendered "これは ~~取り消し~~ です。",
    "これは取り消しです。",
    "strikethrough gap closed"
  )
end)

test("highlight between wide characters closes up", function()
  assert_eq(rendered "これは ==目印== です。", "これは目印です。", "highlight gap closed")
end)

test("inline code between wide characters closes up", function()
  assert_eq(rendered "これは `コード` です。", "これはコードです。", "code span gap closed")
  assert_eq(
    spans("これは `コード` です。", "MdRenderInlineCode"),
    { "コード" },
    "code span still covers コード"
  )
end)

test("link with wide link text closes up", function()
  local text, _, links = Markdown.render "詳細は [ページ](https://example.com) を参照。"
  assert_eq(text, "詳細はページを参照。", "link gap closed")
  assert_eq(#links, 1, "one link")
  assert_eq(text:sub(links[1].col_start + 1, links[1].col_end), "ページ", "link still covers ページ")
end)

test("marker at start of line closes up on its one side", function()
  assert_eq(rendered "**強調** です。", "強調です。", "leading marker gap closed")
end)

test("marker at end of line closes up on its one side", function()
  assert_eq(rendered "これは **強調**", "これは強調", "trailing marker gap closed")
end)

test("only the wide side closes up", function()
  -- `)` is narrow, so the space before the marker belongs there.
  assert_eq(rendered "(注) **重要** です", "(注) 重要です", "narrow side keeps its space")
end)

-- Spaces are kept when either neighbour is narrow

test("narrow span content keeps its spaces", function()
  assert_eq(
    rendered "これは **mandatory** な変更です。",
    "これは mandatory な変更です。",
    "latin content keeps spaces"
  )
  assert_eq(rendered "これは **1** 番目", "これは 1 番目", "digit content keeps spaces")
end)

test("narrow link text keeps its spaces", function()
  assert_eq(
    rendered "詳細は [Confluence](https://example.com) を参照。",
    "詳細は Confluence を参照。",
    "latin link text keeps spaces"
  )
end)

test("narrow inline code keeps its spaces", function()
  assert_eq(rendered "これも `code` です。", "これも code です。", "latin code span keeps spaces")
end)

test("english text is untouched", function()
  assert_eq(rendered "This is **bold** text.", "This is bold text.", "english untouched")
end)

test("a visible marker keeps its space", function()
  -- The `#` of a tag stays on screen, so the gap is not markup.
  assert_eq(rendered "これは #tag です", "これは #tag です", "tag keeps its spaces")
end)

-- Spaces are kept when they hold two spans apart

test("space between two bold spans is kept", function()
  assert_eq(rendered "**あ** **い**", "あ い", "adjacent bold spans stay apart")
  assert_eq(spans("**あ** **い**", "Bold"), { "あ", "い" }, "both bold spans intact")
end)

test("space between two links is kept", function()
  local text, _, links = Markdown.render "[第一章](https://example.com/1) [第二章](https://example.com/2)"
  assert_eq(text, "第一章 第二章", "adjacent links stay apart")
  assert_eq(#links, 2, "two links")
  assert_eq(text:sub(links[1].col_start + 1, links[1].col_end), "第一章", "first link intact")
  assert_eq(text:sub(links[2].col_start + 1, links[2].col_end), "第二章", "second link intact")
end)

-- Spaces that are not markup are kept

test("unmatched marker keeps its spaces", function()
  -- No span was produced, so the spaces are literal text.
  assert_eq(rendered "これは ** です。", "これは ** です。", "unmatched marker untouched")
end)

test("ideographic space is kept", function()
  assert_eq(rendered "これは　**強調**　です。", "これは　強調　です。", "U+3000 untouched")
end)

test("space inside a span is kept", function()
  assert_eq(rendered "**強調 する**", "強調 する", "space inside the span untouched")
end)

-- Structural prefixes still line up afterwards

test("heading closes up and keeps its highlight", function()
  local text, highlights = Markdown.render "## これは **強調** です"
  assert_eq(text:sub(-#"これは強調です"), "これは強調です", "heading text closed up")
  assert_eq(highlights[1].hl, "MdRenderH2", "heading highlight present")
  assert_eq(highlights[1].end_col, #text, "heading highlight spans the whole line")
  assert_eq(spans("## これは **強調** です", "Bold"), { "強調" }, "bold inside heading still covers 強調")
end)

test("list item closes up and keeps its marker highlight", function()
  local text, highlights, _, _, list_marker = Markdown.render "- これは **強調** です"
  assert_eq(list_marker ~= nil, true, "list marker detected")
  assert_eq(text:sub(-#"これは強調です"), "これは強調です", "list item text closed up")
  assert_eq(highlights[1].end_col, #list_marker, "marker highlight still covers the marker")
  assert_eq(spans("- これは **強調** です", "Bold"), { "強調" }, "bold inside list item still covers 強調")
end)

test("blockquote closes up and keeps its prefix", function()
  local text = Markdown.render "> これは **強調** です"
  assert_eq(text, "│ これは強調です", "blockquote text closed up behind the prefix")
end)

-- Summary
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
