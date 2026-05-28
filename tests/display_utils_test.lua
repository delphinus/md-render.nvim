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
  assert_eq(
    display_utils._resolve_lang "custom_md_lang",
    "markdown",
    "registered alias custom_md_lang -> markdown"
  )
end)

print(string.format("display_utils_test: %d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
