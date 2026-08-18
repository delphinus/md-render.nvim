-- display_utils tests
-- Run: nvim --headless -u NONE --noplugin -l tests/display_utils_test.lua

package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local display_utils = require "md-render.display_utils"

local pass_count = 0
local fail_count = 0

local function assert_eq(actual, expected, msg)
  if actual == expected then
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
-- resolve_lang: map fenced info-string to treesitter parser name
-- ============================================================================

test("resolve_lang maps sh-family aliases to bash", function()
  assert_eq(display_utils._resolve_lang "sh", "bash", "sh -> bash")
  assert_eq(display_utils._resolve_lang "zsh", "bash", "zsh -> bash")
  assert_eq(display_utils._resolve_lang "shell", "bash", "shell -> bash")
  assert_eq(display_utils._resolve_lang "shellscript", "bash", "shellscript -> bash")
end)

test("resolve_lang maps common short forms", function()
  assert_eq(display_utils._resolve_lang "js", "javascript", "js -> javascript")
  assert_eq(display_utils._resolve_lang "jsx", "javascript", "jsx -> javascript")
  assert_eq(display_utils._resolve_lang "ts", "typescript", "ts -> typescript")
  assert_eq(display_utils._resolve_lang "py", "python", "py -> python")
  assert_eq(display_utils._resolve_lang "rb", "ruby", "rb -> ruby")
  assert_eq(display_utils._resolve_lang "rs", "rust", "rs -> rust")
  assert_eq(display_utils._resolve_lang "yml", "yaml", "yml -> yaml")
  assert_eq(display_utils._resolve_lang "md", "markdown", "md -> markdown")
  assert_eq(display_utils._resolve_lang "ps1", "powershell", "ps1 -> powershell")
end)

test("resolve_lang is case-insensitive", function()
  assert_eq(display_utils._resolve_lang "SH", "bash", "SH -> bash")
  assert_eq(display_utils._resolve_lang "Bash", "bash", "Bash -> bash (passthrough)")
end)

test("resolve_lang passes through names with no alias", function()
  assert_eq(display_utils._resolve_lang "bash", "bash", "bash stays bash")
  assert_eq(display_utils._resolve_lang "lua", "lua", "lua stays lua")
  assert_eq(display_utils._resolve_lang "go", "go", "go stays go")
  assert_eq(display_utils._resolve_lang "unknown_xyz", "unknown_xyz", "unknown stays unknown")
end)

test("resolve_lang honors vim.treesitter.language.register", function()
  -- Simulate a user-registered alias and confirm it wins over the literal name.
  vim.treesitter.language.register("markdown", "custom_md_lang")
  assert_eq(display_utils._resolve_lang "custom_md_lang", "markdown", "registered alias custom_md_lang -> markdown")
end)

-- ============================================================================
-- build_footer_chunks: status info drawn on a float's bottom border
-- ============================================================================

--- Concatenate the text of a chunk list, ignoring highlight groups.
local function footer_text(chunks)
  local parts = {}
  for _, chunk in ipairs(chunks) do
    table.insert(parts, chunk[1])
  end
  return table.concat(parts)
end

test("build_footer_chunks renders name, position, and progress bar", function()
  local chunks = display_utils.build_footer_chunks({ name = "README.md", line = 25, total = 100 }, 60)
  assert_eq(footer_text(chunks), " README.md   25/100  ━━╾─────── ", "all segments present")
  assert_eq(chunks[2][2], "MdRenderFooterName", "file name uses its own highlight group")
  assert_eq(chunks[4][2], "MdRenderFooter", "position uses the plain footer group")
  assert_eq(chunks[6][2], "MdRenderFooterBar", "filled part of the bar")
  assert_eq(chunks[7][2], "MdRenderFooterBarEmpty", "unfilled part blends into the border")
end)

test("build_footer_chunks fills the bar in half-cell steps", function()
  local function bar(line, total)
    return footer_text(display_utils.build_footer_chunks({ line = line, total = total }, 60))
  end
  assert_eq(bar(1, 100), "   1/100  ────────── ", "1% rounds down to an empty bar")
  assert_eq(bar(5, 100), "   5/100  ╾───────── ", "5% is one half cell")
  assert_eq(bar(50, 100), "  50/100  ━━━━━───── ", "half way")
  assert_eq(bar(100, 100), " 100/100  ━━━━━━━━━━ ", "end of file fills the bar")
  assert_eq(bar(1, 1), " 1/1  ━━━━━━━━━━ ", "single-line file is complete at line 1")
end)

test("build_footer_chunks keeps a fixed width as the line number grows", function()
  local function width_of(line)
    return vim.api.nvim_strwidth(footer_text(display_utils.build_footer_chunks({ line = line, total = 120 }, 60)))
  end
  assert_eq(width_of(1), width_of(9), "1 and 9 are the same width")
  assert_eq(width_of(9), width_of(10), "crossing ten does not resize the footer")
  assert_eq(width_of(99), width_of(120), "crossing a hundred does not resize the footer")
end)

test("build_footer_chunks omits missing info", function()
  assert_eq(footer_text(display_utils.build_footer_chunks({ name = "a.md" }, 40)), " a.md ", "name only")
  assert_eq(
    footer_text(display_utils.build_footer_chunks({ line = 1, total = 4 }, 40)),
    " 1/4  ━━╾─────── ",
    "position only"
  )
  assert_eq(#display_utils.build_footer_chunks({}, 40), 0, "no info -> no chunks")
  assert_eq(#display_utils.build_footer_chunks({ name = "" }, 40), 0, "empty name -> no chunks")
  assert_eq(#display_utils.build_footer_chunks({ line = 3, total = 0 }, 40), 0, "empty buffer -> no chunks")
end)

test("build_footer_chunks shrinks the bar, then drops segments", function()
  local info = { name = "README.md", line = 25, total = 100 }
  local function fit(width)
    return footer_text(display_utils.build_footer_chunks(info, width))
  end
  assert_eq(fit(32), " README.md   25/100  ━━╾─────── ", "exact fit")
  assert_eq(fit(31), " README.md   25/100  ━━╾────── ", "bar shrinks")
  assert_eq(fit(26), " README.md   25/100  ━─── ", "bar hits its floor at four cells")
  assert_eq(fit(25), " README.md   25/100 ", "bar dropped next")
  assert_eq(fit(19), " README.md ", "position dropped next")
  assert_eq(#display_utils.build_footer_chunks(info, 10), 0, "nothing fits -> no chunks")
end)

test("build_footer_chunks measures display width, not bytes", function()
  local chunks = display_utils.build_footer_chunks({ name = "設計メモ.md" }, 16)
  assert_eq(footer_text(chunks), " 設計メモ.md ", "CJK name fits its display width")
  assert_eq(
    #display_utils.build_footer_chunks({ name = "設計メモ.md" }, 12),
    0,
    "same name does not fit a 12-cell float"
  )
end)

test("build_footer_chunks clamps an out-of-range line", function()
  local chunks = display_utils.build_footer_chunks({ line = 999, total = 40 }, 40)
  assert_eq(footer_text(chunks), " 40/40  ━━━━━━━━━━ ", "line beyond total clamps to total")
end)

print(string.format("display_utils_test: %d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
