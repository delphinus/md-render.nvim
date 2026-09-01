-- Run: nvim --headless -u NONE --noplugin -l tests/presenter_test.lua
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

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

local PL = require "md-render.presenter_layout"

test("parse_layout: forms", function()
  assert_eq(PL.parse_layout "full", { kind = "full" }, "full")
  assert_eq(PL.parse_layout "fit", { kind = "fit" }, "fit")
  assert_eq(PL.parse_layout "left", { kind = "left", pct = 50 }, "left defaults 50")
  assert_eq(PL.parse_layout "left:40", { kind = "left", pct = 40 }, "left:40")
  assert_eq(PL.parse_layout "RIGHT:35", { kind = "right", pct = 35 }, "case-insensitive")
  assert_eq(PL.parse_layout "bogus", nil, "unknown -> nil")
end)

test("serialize_layout: round-trip", function()
  assert_eq(PL.serialize_layout { kind = "full" }, "full", "full")
  assert_eq(PL.serialize_layout { kind = "left", pct = 40 }, "left:40", "left:40")
  assert_eq(PL.serialize_layout { kind = "fit" }, "fit", "fit")
end)

test("cycle: fit -> left:50 -> right:50 -> full -> fit", function()
  assert_eq(PL.cycle { kind = "fit" }, { kind = "left", pct = 50 }, "fit->left")
  assert_eq(PL.cycle { kind = "left", pct = 40 }, { kind = "right", pct = 50 }, "left->right")
  assert_eq(PL.cycle { kind = "right", pct = 50 }, { kind = "full" }, "right->full")
  assert_eq(PL.cycle { kind = "full" }, { kind = "fit" }, "full->fit")
end)

test("nudge: only left/right, clamped", function()
  assert_eq(PL.nudge({ kind = "left", pct = 50 }, 5), { kind = "left", pct = 55 }, "nudge +5")
  assert_eq(PL.nudge({ kind = "left", pct = 80 }, 5), { kind = "left", pct = 80 }, "clamp high")
  assert_eq(PL.nudge({ kind = "right", pct = 20 }, -5), { kind = "right", pct = 20 }, "clamp low")
  assert_eq(PL.nudge({ kind = "full" }, 5), { kind = "full" }, "full unaffected")
end)

test("compute_bands: left:40 slide_w=100 gap=2", function()
  local b = PL.compute_bands("left", 40, 100, 2)
  assert_eq(b.diagram, { col = 0, max_cols = 40 }, "left diagram at col 0 width 40")
  assert_eq(b.text, { indent = 42, max_width = 58 }, "left text indent 42 width 58")
end)

test("compute_bands: right:40 slide_w=100 gap=2", function()
  local b = PL.compute_bands("right", 40, 100, 2)
  assert_eq(b.diagram, { col = 60, max_cols = 40 }, "right diagram at col 60 width 40")
  assert_eq(b.text, { indent = 0, max_width = 58 }, "right text indent 0 width 58")
end)

local P = require "md-render.presenter"

test("segment: splits on top-level ---", function()
  local slides = P.segment { "# A", "x", "---", "# B", "y" }
  assert_eq(#slides, 2, "two slides")
  assert_eq(slides[1].lines, { "# A", "x" }, "slide 1 lines")
  assert_eq(slides[2].lines, { "# B", "y" }, "slide 2 lines")
  assert_eq(slides[2].start, 4, "slide 2 starts at source row 4")
end)

test("segment: --- inside code fence is not a split", function()
  local slides = P.segment { "# A", "```", "---", "```", "done" }
  assert_eq(#slides, 1, "fence-internal --- ignored")
end)

test("segment: --- inside a [//]: # comment is not a split", function()
  local slides = P.segment { "a", "[//]: # (---)", "b" }
  assert_eq(#slides, 1, "comment --- ignored")
end)

test("find_diagrams: captures source, directive, layout", function()
  local slide = P.segment({
    "# Title",
    "[//]: # (diagram: left:40)",
    "```mermaid",
    "flowchart LR",
    "  A --> B",
    "```",
    "notes",
  })[1]
  local ds = P.find_diagrams(slide)
  assert_eq(#ds, 1, "one diagram")
  assert_eq(ds[1].source, "flowchart LR\n  A --> B", "mermaid source captured")
  assert_eq(ds[1].open_row, 3, "open fence row")
  assert_eq(ds[1].directive_row, 2, "directive row")
  assert_eq(ds[1].layout, { kind = "left", pct = 40 }, "explicit layout parsed")
end)

test("find_diagrams: no directive -> layout nil", function()
  local slide = P.segment({ "```mermaid", "graph TD", "```" })[1]
  local ds = P.find_diagrams(slide)
  assert_eq(ds[1].layout, nil, "no explicit layout")
end)

test("find_diagrams: stray fence of other type does not truncate body", function()
  local slide = P.segment({ "```mermaid", "graph TD", "~~~", "A-->B", "```" })[1]
  local ds = P.find_diagrams(slide)
  assert_eq(#ds, 1, "one diagram")
  assert_eq(ds[1].source, "graph TD\n~~~\nA-->B", "stray ~~~ kept in body")
  assert_eq(ds[1].close_row, 5, "closes at matching backtick fence")
end)

test("parse_deck_options: first deck comment wins", function()
  local opts = P.parse_deck_options { "[//]: # (deck: max-width=90 theme=fit)", "# A" }
  assert_eq(opts["max-width"], "90", "max-width parsed")
  assert_eq(opts["theme"], "fit", "theme parsed")
end)

test("parse_deck_options: none -> empty", function()
  assert_eq(P.parse_deck_options { "# A" }, {}, "no deck comment")
end)

test("default_layout: solo diagram -> full", function()
  local slide = P.segment({ "```mermaid", "graph TD", "```" })[1]
  assert_eq(P.default_layout(slide), { kind = "full" }, "solo -> full")
end)

test("default_layout: diagram + text -> fit", function()
  local slide = P.segment({ "# Title", "```mermaid", "graph TD", "```", "body text" })[1]
  assert_eq(P.default_layout(slide), { kind = "fit" }, "mixed -> fit")
end)

test("effective_layout: explicit beats default", function()
  local slide = P.segment({ "[//]: # (diagram: right:30)", "```mermaid", "g", "```" })[1]
  local d = P.find_diagrams(slide)[1]
  assert_eq(P.effective_layout(slide, d), { kind = "right", pct = 30 }, "explicit wins")
end)

local function scratch_buf(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

test("write_diagram_layout: inserts a new directive above the fence", function()
  local buf = scratch_buf { "# Title", "```mermaid", "g", "```" }
  local slide = P.segment(vim.api.nvim_buf_get_lines(buf, 0, -1, false))[1]
  local d = P.find_diagrams(slide)[1]
  local new_open = P.write_diagram_layout(buf, d, { kind = "left", pct = 40 })
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  assert_eq(lines[2], "[//]: # (diagram: left:40)", "directive inserted at row 2")
  assert_eq(new_open, 3, "fence shifted down to row 3")
end)

test("write_diagram_layout: replaces an existing directive", function()
  local buf = scratch_buf { "[//]: # (diagram: left:40)", "```mermaid", "g", "```" }
  local slide = P.segment(vim.api.nvim_buf_get_lines(buf, 0, -1, false))[1]
  local d = P.find_diagrams(slide)[1]
  local new_open = P.write_diagram_layout(buf, d, { kind = "right", pct = 25 })
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  assert_eq(lines[1], "[//]: # (diagram: right:25)", "directive replaced in place")
  assert_eq(new_open, 2, "fence row unchanged")
  assert_eq(#lines, 4, "no line added on replace")
end)

test("write_diagram_layout: read-only buffer returns nil", function()
  local buf = scratch_buf { "```mermaid", "g", "```" }
  vim.bo[buf].modifiable = false
  local slide = P.segment({ "```mermaid", "g", "```" })[1]
  local d = P.find_diagrams(slide)[1]
  assert_eq(P.write_diagram_layout(buf, d, { kind = "full" }), nil, "nil on read-only")
end)

local function with_image_stub(cached_path, img_w, img_h, fn)
  local image = require "md-render.image"
  local saved = {
    supports_kitty = image.supports_kitty,
    has_mmdc = image.has_mmdc,
    get_mermaid_cached = image.get_mermaid_cached,
    image_dimensions = image.image_dimensions,
  }
  image.supports_kitty = function()
    return true
  end
  image.has_mmdc = function()
    return true
  end
  image.get_mermaid_cached = function()
    return cached_path
  end
  image.image_dimensions = function()
    return img_w, img_h
  end
  local ok, err = pcall(fn)
  for k, v in pairs(saved) do
    image[k] = v
  end
  if not ok then error(err) end
end

test("build_slide_content: left:40 places image left, text indented", function()
  with_image_stub("/tmp/fake.png", 400, 300, function()
    local slide = P.segment({
      "[//]: # (diagram: left:40)",
      "```mermaid",
      "flowchart LR",
      "```",
      "some explanatory body text that should wrap into the right column band",
    })[1]
    local content = P.build_slide_content(slide, { slide_w = 100, slide_h = 30, gap = 2 })
    assert_eq(#content.image_placements, 1, "one image placement")
    assert_eq(content.image_placements[1].col, 0, "diagram in left band at col 0")
    -- text lines are prefixed by the 42-cell indent (diagram 40 + gap 2)
    local indented = false
    for _, l in ipairs(content.lines) do
      if l:match "%S" then
        indented = l:match "^%s%s+" ~= nil and (#l:match "^ *") >= 42
        if indented then break end
      end
    end
    assert_eq(indented, true, "body text indented into the right column")
  end)
end)

test("build_slide_content: fit passes through inline rendering", function()
  with_image_stub("/tmp/fake.png", 400, 300, function()
    local slide = P.segment({ "# T", "text", "[//]: # (diagram: fit)", "```mermaid", "g", "```" })[1]
    local content = P.build_slide_content(slide, { slide_w = 80, slide_h = 24 })
    -- inline mermaid emits a placement centered (col > 0 for an 80-wide slide)
    assert_eq(#content.image_placements >= 1, true, "inline placement present")
  end)
end)

test("new_nav: clamps and moves", function()
  local nav = P.new_nav(3)
  assert_eq(nav.idx, 1, "starts at 1")
  assert_eq(nav:next(), 2, "next -> 2")
  assert_eq(nav:next(), 3, "next -> 3")
  assert_eq(nav:next(), 3, "next clamps at count")
  assert_eq(nav:prev(), 2, "prev -> 2")
  assert_eq(nav:last(), 3, "last -> 3")
  assert_eq(nav:first(), 1, "first -> 1")
  assert_eq(nav:go(99), 3, "go clamps high")
  assert_eq(nav:go(-1), 1, "go clamps low")
end)

test("apply_pager_chrome: sets buffer nofile + non-modifiable", function()
  local preview = require "md-render.preview"
  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_get_current_win()
  preview.apply_pager_chrome(win, buf)
  assert_eq(vim.bo[buf].buftype, "nofile", "buftype nofile")
  assert_eq(vim.bo[buf].modifiable, false, "not modifiable")
end)

test("snapshot/restore chrome round-trips window-local options + winbar", function()
  local win = vim.api.nvim_get_current_win()
  vim.wo[win].number = true
  vim.wo[win].winbar = "orig"
  vim.wo[win].cursorline = false
  local snap = P._snapshot_chrome(win)
  -- mutate as presenter would
  vim.wo[win].number = false
  vim.wo[win].winbar = "2 / 8"
  vim.wo[win].cursorline = true
  P._restore_chrome(win, snap)
  assert_eq(vim.wo[win].number, true, "number restored")
  assert_eq(vim.wo[win].winbar, "orig", "winbar restored")
  assert_eq(vim.wo[win].cursorline, false, "cursorline restored")
end)

local store = require "md-render.presenter_store"
local cycle = require("md-render.presenter_layout").cycle

--- Point the layout cache at a throwaway root for the duration of `fn`.
local function with_cache_root(fn)
  local saved = store.root
  store.root = vim.fn.tempname()
  local ok, err = pcall(fn)
  vim.fn.delete(store.root, "rf")
  store.root = saved
  if not ok then error(err) end
end

test("deck_sources: collects every diagram in the deck, in slide order", function()
  local slides = P.segment {
    "# One",
    "```mermaid",
    "A --> B",
    "```",
    "---",
    "# Two",
    "text only",
    "---",
    "# Three",
    "```mermaid",
    "X --> Y",
    "```",
  }
  assert_eq(P.deck_sources(slides), { "A --> B", "X --> Y" }, "both diagrams, slide order, no gaps")
end)

test("deck_sources: a deck with no diagrams yields nothing", function()
  assert_eq(P.deck_sources(P.segment { "# One", "text" }), {}, "empty")
end)

test("effective_layout: a cached layout beats the directive in the document", function()
  local slide = P.segment({ "[//]: # (diagram: full)", "```mermaid", "g", "```" })[1]
  local d = P.find_diagrams(slide)[1]
  local cache = { [store.key(d.source)] = { kind = "left", pct = 40 } }
  assert_eq(P.effective_layout(slide, d, cache), { kind = "left", pct = 40 }, "the cache is the working override")
end)

test("effective_layout: the directive is used when the cache has nothing to say", function()
  local slide = P.segment({ "[//]: # (diagram: full)", "```mermaid", "g", "```" })[1]
  local d = P.find_diagrams(slide)[1]
  assert_eq(P.effective_layout(slide, d, {}), { kind = "full" }, "falls back to the committed default")
end)

test("effective_layout: no cache and no directive falls back to the slide default", function()
  local slide = P.segment({ "# T", "```mermaid", "g", "```", "text" })[1]
  local d = P.find_diagrams(slide)[1]
  assert_eq(P.effective_layout(slide, d, {}), { kind = "fit" }, "a slide with text defaults to fit")
end)

test("apply_layout_change: cycles the layout without touching the source buffer", function()
  with_cache_root(function()
    local lines = { "# T", "```mermaid", "g", "```", "text" }
    local buf = scratch_buf(lines)
    local slides = P.segment(lines)
    local nav = P.new_nav(#slides)
    local overrides = {}
    -- default for a mixed slide is "fit"; cycle -> left:50
    local new_layout = P.apply_layout_change(slides, nav, "/home/me/deck.md", overrides, cycle)
    assert_eq(new_layout, { kind = "left", pct = 50 }, "fit cycles to left:50")
    assert_eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), lines, "the document is left exactly as it was")

    local key = store.key(P.find_diagrams(slides[1])[1].source)
    assert_eq(overrides[key], { kind = "left", pct = 50 }, "recorded under the diagram's content key")
    assert_eq(store.load "/home/me/deck.md", overrides, "and persisted to the cache")
  end)
end)

test("apply_layout_change: a slide with no diagram changes nothing", function()
  with_cache_root(function()
    local slides = P.segment { "just text", "more" }
    local nav = P.new_nav(#slides)
    assert_eq(P.apply_layout_change(slides, nav, "/home/me/deck.md", {}, cycle), nil, "nil")
  end)
end)

test("apply_layout_change: a buffer with no file on disk keeps the layout in memory", function()
  with_cache_root(function()
    local slides = P.segment { "# T", "```mermaid", "g", "```", "text" }
    local overrides = {}
    local layout = P.apply_layout_change(slides, P.new_nav(#slides), nil, overrides, cycle)
    assert_eq(layout, { kind = "left", pct = 50 }, "the layout still applies for this session")
    assert_eq(vim.tbl_count(overrides), 1, "and is recorded in memory")
  end)
end)

test("commit_layout: writes the directive into the document and drops the cache entry", function()
  with_cache_root(function()
    local buf = scratch_buf { "# T", "```mermaid", "g", "```", "text" }
    local slides = P.segment(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    local nav = P.new_nav(#slides)
    local overrides = {}
    P.apply_layout_change(slides, nav, "/home/me/deck.md", overrides, cycle)

    assert_eq(P.commit_layout(slides, nav, buf, "/home/me/deck.md", overrides), true, "commit reports success")
    assert_eq(
      vim.api.nvim_buf_get_lines(buf, 0, -1, false),
      { "# T", "[//]: # (diagram: left:50)", "```mermaid", "g", "```", "text" },
      "the directive is now in the document"
    )
    assert_eq(overrides, {}, "the cache entry is redundant and is dropped")
    assert_eq(store.load "/home/me/deck.md", {}, "including on disk")
  end)
end)

test("commit_layout: re-segments so the shifted source rows stay usable", function()
  with_cache_root(function()
    local buf = scratch_buf { "# T", "```mermaid", "g", "```", "text" }
    local slides = P.segment(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    local nav = P.new_nav(#slides)
    local overrides = {}
    P.apply_layout_change(slides, nav, "/home/me/deck.md", overrides, cycle)
    P.commit_layout(slides, nav, buf, "/home/me/deck.md", overrides)

    local d = P.find_diagrams(slides[1])[1]
    assert_eq(d.open_row, 3, "the fence moved down a row and slides know it")
    assert_eq(d.layout, { kind = "left", pct = 50 }, "the committed directive reads back")
  end)
end)

test("commit_layout: a read-only document is reported, not written", function()
  with_cache_root(function()
    local lines = { "# T", "```mermaid", "g", "```", "text" }
    local buf = scratch_buf(lines)
    local slides = P.segment(lines)
    local nav = P.new_nav(#slides)
    local overrides = {}
    P.apply_layout_change(slides, nav, "/home/me/deck.md", overrides, cycle)
    vim.bo[buf].modifiable = false

    assert_eq(P.commit_layout(slides, nav, buf, "/home/me/deck.md", overrides), false, "commit reports failure")
    assert_eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), lines, "the document is untouched")
    assert_eq(vim.tbl_count(overrides), 1, "the cached layout is kept, since it is all we have")
  end)
end)

test("commit_layout: nothing to commit on a slide with no diagram", function()
  with_cache_root(function()
    local buf = scratch_buf { "just text" }
    local slides = P.segment { "just text" }
    assert_eq(P.commit_layout(slides, P.new_nav(#slides), buf, "/home/me/deck.md", {}), false, "no diagram")
  end)
end)

test("segment: drops all-blank slides from leading/trailing/consecutive ---", function()
  local slides = P.segment { "---", "# A", "---", "---", "# B", "---" }
  assert_eq(#slides, 2, "only two non-blank slides")
  assert_eq(slides[1].lines, { "# A" }, "slide 1 is # A")
  assert_eq(slides[2].lines, { "# B" }, "slide 2 is # B")
end)

test("build_slide_content: right:40 places image in the right band", function()
  with_image_stub("/tmp/fake.png", 400, 300, function()
    local slide = P.segment({
      "[//]: # (diagram: right:40)",
      "```mermaid",
      "flowchart LR",
      "```",
      "body text on the left half of the slide",
    })[1]
    local content = P.build_slide_content(slide, { slide_w = 100, slide_h = 30, gap = 2 })
    assert_eq(#content.image_placements, 1, "one image placement")
    assert_eq(content.image_placements[1].col, 60, "diagram in right band at col 60")
  end)
end)

test("build_slide_content: full (solo diagram) places one centered image at line 0", function()
  with_image_stub("/tmp/fake.png", 400, 300, function()
    local slide = P.segment({ "```mermaid", "graph TD", "```" })[1]
    local content = P.build_slide_content(slide, { slide_w = 80, slide_h = 24 })
    assert_eq(#content.image_placements, 1, "one image placement")
    assert_eq(content.image_placements[1].line, 0, "solo full: image at line 0 (empty body)")
  end)
end)

test("_reset_view puts a scrolled window back at the top of the buffer", function()
  local buf = vim.api.nvim_create_buf(false, true)
  local lines = {}
  for i = 1, 200 do
    lines[i] = "line " .. i
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local win = vim.api.nvim_get_current_win()
  local prev = vim.api.nvim_win_get_buf(win)
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_win_set_cursor(win, { 150, 0 })
  vim.api.nvim_win_call(win, function()
    vim.cmd "normal! zt"
  end)
  assert_eq(vim.fn.getwininfo(win)[1].topline > 1, true, "precondition: the window is scrolled")

  P._reset_view(win)
  assert_eq(vim.fn.getwininfo(win)[1].topline, 1, "topline is back at the first line")
  assert_eq(vim.api.nvim_win_get_cursor(win)[1], 1, "cursor is back on the first line")

  vim.api.nvim_win_set_buf(win, prev)
  vim.api.nvim_buf_delete(buf, { force = true })
end)

-- Summary footer — MUST stay the last two lines of this file. Later tasks
-- insert their test(...) blocks ABOVE this footer (see Global Constraints).
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
