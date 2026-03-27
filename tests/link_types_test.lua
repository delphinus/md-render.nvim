-- Test link type distinction (external, anchor, Obsidian)
-- Run: nvim --headless -u NONE --noplugin -l tests/link_types_test.lua

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

local function assert_match(actual, pattern, msg)
  if actual and actual:match(pattern) then
    pass_count = pass_count + 1
  else
    fail_count = fail_count + 1
    print("FAIL: " .. msg)
    print("  expected match: " .. pattern)
    print("  actual:         " .. tostring(actual))
  end
end

local function test(name, fn)
  local ok, err = pcall(fn)
  if not ok then
    fail_count = fail_count + 1
    print("ERROR: " .. name .. ": " .. tostring(err))
  end
end

-- heading_slug tests

test("heading_slug: simple text", function()
  assert_eq(Markdown.heading_slug("Hello World"), "hello-world", "simple heading slug")
end)

test("heading_slug: strips bold markers", function()
  assert_eq(Markdown.heading_slug("My **Bold** Heading"), "my-bold-heading", "bold markers stripped")
end)

test("heading_slug: strips inline code", function()
  assert_eq(Markdown.heading_slug("Using `code` here"), "using-code-here", "code markers stripped")
end)

test("heading_slug: strips link syntax", function()
  assert_eq(Markdown.heading_slug("See [docs](https://example.com)"), "see-docs", "link syntax stripped")
end)

test("heading_slug: strips wikilink syntax", function()
  assert_eq(Markdown.heading_slug("About [[Page|display]]"), "about-display", "wikilink syntax stripped")
end)

test("heading_slug: collapses hyphens", function()
  assert_eq(Markdown.heading_slug("A - B - C"), "a-b-c", "hyphens collapsed")
end)

test("heading_slug: removes special characters", function()
  assert_eq(Markdown.heading_slug("What's New?"), "whats-new", "special chars removed")
end)

test("heading_slug: Japanese text preserved", function()
  local slug = Markdown.heading_slug("日本語テスト")
  assert_eq(slug, "日本語テスト", "Japanese text preserved in slug")
end)

-- Wikilink URL generation tests

test("wikilink [[#heading]] generates anchor URL", function()
  local _, _, links = Markdown.render("[[#My Heading]]")
  assert_eq(#links, 1, "wikilink anchor: one link")
  assert_eq(links[1].url, "#my-heading", "wikilink anchor: URL is #slug")
end)

test("wikilink [[page]] generates advanced-uri URL", function()
  local _, _, links = Markdown.render("[[SomePage]]")
  assert_eq(#links, 1, "wikilink page: one link")
  assert_eq(links[1].url, "obsidian://advanced-uri?filepath=SomePage", "wikilink page: advanced-uri URL")
end)

test("wikilink [[page#heading]] generates advanced-uri URL with heading", function()
  local _, _, links = Markdown.render("[[SomePage#Section]]")
  assert_eq(#links, 1, "wikilink page#heading: one link")
  assert_eq(links[1].url, "obsidian://advanced-uri?filepath=SomePage&heading=Section", "wikilink page#heading: advanced-uri with heading")
end)

test("wikilink [[#heading|alias]] generates anchor URL", function()
  local _, _, links = Markdown.render("[[#My Section|go here]]")
  assert_eq(#links, 1, "wikilink anchor alias: one link")
  assert_eq(links[1].url, "#my-section", "wikilink anchor alias: URL is #slug")
end)

-- Standard link anchor detection

test("standard link [text](#anchor) has anchor URL", function()
  local _, _, links = Markdown.render("[click here](#some-heading)")
  assert_eq(#links, 1, "standard anchor: one link")
  assert_eq(links[1].url, "#some-heading", "standard anchor: URL preserved")
end)

test("standard link [text](https://...) has external URL", function()
  local _, _, links = Markdown.render("[click](https://example.com)")
  assert_eq(#links, 1, "external link: one link")
  assert_match(links[1].url, "^https://", "external link: URL is https")
end)

-- Highlight tests for wikilinks

test("wikilink [[#heading]] uses MdRenderLinkAnchor highlight", function()
  local _, highlights = Markdown.render("[[#Heading]]")
  local found = false
  for _, hl in ipairs(highlights) do
    if hl.hl == "MdRenderLinkAnchor" then found = true end
  end
  assert_eq(found, true, "anchor wikilink highlight is MdRenderLinkAnchor")
end)

test("wikilink [[page]] uses MdRenderLinkObsidian highlight", function()
  local _, highlights = Markdown.render("[[SomePage]]")
  local found = false
  for _, hl in ipairs(highlights) do
    if hl.hl == "MdRenderLinkObsidian" then found = true end
  end
  assert_eq(found, true, "obsidian wikilink highlight is MdRenderLinkObsidian")
end)

-- heading_anchors in content_builder

test("content_builder registers heading anchors", function()
  local ContentBuilder = require("md-render.content_builder").ContentBuilder
  local b = ContentBuilder.new()
  b:set_source_line(1)
  b:add_markdown_line("## Test Heading", "", 80)
  local result = b:result()
  assert_eq(result.heading_anchors["test-heading"] ~= nil, true, "heading anchor registered")
  assert_eq(type(result.heading_anchors["test-heading"]), "number", "heading anchor is line number")
end)

test("content_builder heading anchor line is correct", function()
  local ContentBuilder = require("md-render.content_builder").ContentBuilder
  local b = ContentBuilder.new()
  b:set_source_line(1)
  b:add_line("first line")
  b:set_source_line(2)
  b:add_markdown_line("## Second Heading", "", 80)
  local result = b:result()
  assert_eq(result.heading_anchors["second-heading"], 1, "heading anchor points to correct line")
end)

-- Summary
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
