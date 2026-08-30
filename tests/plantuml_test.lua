-- PlantUML module unit tests: source encoding for the remote "~h" URL scheme
-- Run: nvim --headless -u NONE --noplugin -l tests/plantuml_test.lua

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

-- ============================================================================
-- plantuml_encode_hex
-- ============================================================================

test("encodes empty source", function()
  assert_eq(image._plantuml_encode_hex "", "", "empty source yields empty hex")
end)

test("encodes ASCII source", function()
  assert_eq(image._plantuml_encode_hex "AB", "4142", "'AB' encodes to 4142")
  assert_eq(image._plantuml_encode_hex "@startuml", "407374617274756d6c", "'@startuml' encodes correctly")
end)

test("encodes newlines and spaces", function()
  assert_eq(image._plantuml_encode_hex "a b\nc", "6120620a63", "space is 20, newline is 0a")
end)

test("uses lowercase hex digits", function()
  assert_eq(image._plantuml_encode_hex "\255", "ff", "byte 255 encodes as lowercase ff")
end)

test("encodes byte-wise, not codepoint-wise", function()
  -- U+00E9 (é) is two bytes in UTF-8: 0xC3 0xA9
  assert_eq(image._plantuml_encode_hex "é", "c3a9", "multi-byte UTF-8 encodes each byte")
  -- U+65E5 (日) is three bytes: 0xE6 0x97 0xA5
  assert_eq(image._plantuml_encode_hex "日", "e697a5", "three-byte UTF-8 encodes each byte")
end)

test("produces two hex chars per byte", function()
  local source = "@startuml\nAlice -> Bob: hello\n@enduml"
  assert_eq(#image._plantuml_encode_hex(source), #source * 2, "output length is twice the byte length")
end)

-- ============================================================================
-- Where a diagram is allowed to be rendered
-- ============================================================================

local function assert_true(val, msg)
  if val then
    pass_count = pass_count + 1
  else
    fail_count = fail_count + 1
    print("FAIL: " .. msg)
  end
end

--- Run `fn` with only the named executables on the PATH, and with the PlantUML
--- probe forced to re-run so the stub is what it sees.
---@param present table<string, true>
---@param fn fun()
local function with_executables(present, fn)
  local real = vim.fn.executable
  vim.fn.executable = function(name)
    return present[name] and 1 or 0
  end
  image.reset_cache()
  local ok, err = pcall(fn)
  vim.fn.executable = real
  image.reset_cache()
  if not ok then error(err) end
end

test("no local renderer and no server: PlantUML is not available", function()
  image.setup { plantuml_server = "" }
  with_executables({ curl = true }, function()
    assert_eq(image.config().plantuml_server, nil, "no server is configured by default")
    assert_eq(
      image.has_plantuml(),
      false,
      "curl alone does not make it available — that would mean sending the diagram somewhere nobody asked for"
    )
  end)
end)

test("a local renderer is enough on its own", function()
  image.setup { plantuml_server = "" }
  with_executables({ plantuml = true }, function()
    assert_true(image.has_plantuml(), "a `plantuml` on the PATH renders locally, no server needed")
  end)
end)

test("naming a server opts into rendering on it", function()
  image.setup { plantuml_server = "https://plantuml.example.com/plantuml" }
  with_executables({ curl = true }, function()
    assert_true(image.has_plantuml(), "a configured server plus curl is enough")
  end)
  with_executables({}, function()
    assert_eq(image.has_plantuml(), false, "but the server still needs curl to reach it")
  end)
  image.setup { plantuml_server = "" }
  assert_eq(image.config().plantuml_server, nil, "an empty server string clears the setting")
end)

-- ============================================================================
-- Summary
-- ============================================================================

print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
