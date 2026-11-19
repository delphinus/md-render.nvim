-- Mermaid module unit tests: how long mmdc may run, and what a failure reports
-- Run: nvim --headless -u NONE --noplugin -l tests/mermaid_test.lua

package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

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
    print("ERROR in " .. name .. ": " .. tostring(err))
  end
end

--- Collect what `fn` passes to vim.notify.
---@param fn fun()
---@return { msg: string, level: integer }[]
local function capture_notify(fn)
  local seen = {}
  local orig = vim.notify
  vim.notify = function(msg, level)
    table.insert(seen, { msg = msg, level = level })
  end
  local ok, err = pcall(fn)
  vim.notify = orig
  if not ok then error(err, 0) end
  return seen
end

-- ============================================================================
-- mmdc_timeout
-- ============================================================================

test("an mmdc on PATH keeps the short timeout", function()
  assert_eq(image._mmdc_timeout { "mmdc" }, 30000, "mmdc only renders, so 30 seconds is plenty")
end)

test("npx gets time to install mermaid-cli and its browser", function()
  local timeout = image._mmdc_timeout { "npx", "-y", "@mermaid-js/mermaid-cli" }
  assert_eq(timeout >= 300000, true, "npx may download for minutes before rendering")
end)

-- ============================================================================
-- notify_mmdc_failure
-- ============================================================================

test("a timeout is reported as a timeout", function()
  local seen = capture_notify(function()
    image._notify_mmdc_failure({ code = 124, stderr = "" }, 30000)
  end)
  assert_eq(#seen, 1, "one notification")
  assert_eq(seen[1].msg:find("timed out after 30 seconds", 1, true) ~= nil, true, "names the timeout")
  assert_eq(seen[1].level, vim.log.levels.WARN, "as a warning")
end)

test("an mmdc error reports its first stderr line", function()
  local stderr = "\nError: Parse error on line 2:\n    at Object.parseError\n"
  local seen = capture_notify(function()
    image._notify_mmdc_failure({ code = 1, stderr = stderr }, 30000)
  end)
  assert_eq(#seen, 1, "one notification")
  assert_eq(seen[1].msg:find("Error: Parse error on line 2:", 1, true) ~= nil, true, "shows the error line")
  assert_eq(seen[1].msg:find("parseError", 1, true), nil, "leaves the stack trace out")
end)

test("a failure without stderr falls back to the exit code", function()
  local seen = capture_notify(function()
    image._notify_mmdc_failure({ code = 3, stderr = nil }, 30000)
  end)
  assert_eq(seen[1].msg:find("exit code 3", 1, true) ~= nil, true, "shows the exit code")
end)

-- ============================================================================
-- Summary
-- ============================================================================

print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
