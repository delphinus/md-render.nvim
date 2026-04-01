-- PTY integration test: verify Kitty Graphics Protocol sequences in terminal output
-- Run: nvim --headless -u NONE --noplugin -l tests/pty_image_test.lua
--
-- This test launches a Neovim instance inside a pty (via pty_capture.py),
-- captures the raw terminal output, and verifies that Kitty Graphics Protocol
-- APC sequences are present and well-formed.

local pass_count = 0
local fail_count = 0

local function assert_true(val, msg)
  if val then
    pass_count = pass_count + 1
  else
    fail_count = fail_count + 1
    print("FAIL: " .. msg)
  end
end

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

-- ============================================================================
-- Helpers
-- ============================================================================

--- Parse Kitty graphics APC sequences from raw terminal output.
--- Returns a list of { params = {key=val,...}, payload = "..." }
local function parse_kitty_sequences(data)
  local seqs = {}
  local pos = 1
  while pos <= #data do
    local s, e, content = data:find("\x1b_G(.-)\x1b\\", pos)
    if not s then break end
    local params_str, payload = content:match("^([^;]*);(.*)$")
    if not params_str then
      params_str = content
      payload = ""
    end
    local params = {}
    for k, v in params_str:gmatch("([%w_]+)=([^,]*)") do
      params[k] = v
    end
    table.insert(seqs, { params = params, payload = payload })
    pos = e + 1
  end
  return seqs
end

-- ============================================================================
-- Run pty capture
-- ============================================================================

local cwd = vim.fn.getcwd()
local scenario = cwd .. "/tests/pty_image_scenario.lua"
local capture_script = cwd .. "/tests/pty_capture.py"

-- Check prerequisites
local function check_prerequisites()
  if vim.fn.executable("python3") ~= 1 then
    print("SKIP: python3 not found")
    os.exit(0)
  end
  if vim.fn.filereadable(capture_script) ~= 1 then
    print("SKIP: pty_capture.py not found")
    os.exit(0)
  end
  if vim.fn.filereadable(scenario) ~= 1 then
    print("SKIP: pty_image_scenario.lua not found")
    os.exit(0)
  end
end

check_prerequisites()

print("Running pty capture (this may take a few seconds)...")
local result = vim.system({
  "python3", capture_script, scenario, "15",
}, { text = false, timeout = 20000 }):wait()

local raw_output = result.stdout or ""
-- Convert to string if needed
if type(raw_output) ~= "string" then
  raw_output = tostring(raw_output)
end

print(string.format("Captured %d bytes of terminal output", #raw_output))

-- ============================================================================
-- Tests
-- ============================================================================

test("pty: scenario completed successfully", function()
  assert_true(raw_output:find("__SCENARIO_DONE__") ~= nil,
    "scenario should complete (found __SCENARIO_DONE__ marker)")
end)

test("pty: transmit succeeded", function()
  assert_true(raw_output:find("__TRANSMIT_OK:%d+__") ~= nil,
    "transmit_image should succeed (found __TRANSMIT_OK marker)")
end)

test("pty: output contains Kitty Graphics Protocol sequences", function()
  local seqs = parse_kitty_sequences(raw_output)
  assert_true(#seqs > 0,
    string.format("should contain APC sequences (found %d)", #seqs))
end)

test("pty: contains transmit (a=t) sequence", function()
  local seqs = parse_kitty_sequences(raw_output)
  local found = false
  for _, seq in ipairs(seqs) do
    if seq.params.a == "t" then
      found = true
      assert_eq(seq.params.f, "100", "transmit format should be PNG (100)")
      assert_true(seq.payload ~= "", "transmit should have base64 payload")
      assert_true(seq.params.i ~= nil, "transmit should have image ID")
      break
    end
  end
  assert_true(found, "should contain at least one transmit sequence")
end)

test("pty: contains delete (a=d, d=i) sequence", function()
  local seqs = parse_kitty_sequences(raw_output)
  local found = false
  for _, seq in ipairs(seqs) do
    if seq.params.a == "d" and seq.params.d == "i" then
      found = true
      assert_true(seq.params.i ~= nil, "delete should specify image ID")
      break
    end
  end
  assert_true(found, "should contain single-image delete sequence")
end)

test("pty: contains delete-all (a=d, d=A) sequence", function()
  local seqs = parse_kitty_sequences(raw_output)
  local found = false
  for _, seq in ipairs(seqs) do
    if seq.params.a == "d" and seq.params.d == "A" then
      found = true
      break
    end
  end
  assert_true(found, "should contain delete-all sequence")
end)

test("pty: transmit ID matches delete ID", function()
  local seqs = parse_kitty_sequences(raw_output)
  local transmit_id = nil
  local delete_id = nil
  for _, seq in ipairs(seqs) do
    if seq.params.a == "t" and not transmit_id then
      transmit_id = seq.params.i
    end
    if seq.params.a == "d" and seq.params.d == "i" and not delete_id then
      delete_id = seq.params.i
    end
  end
  assert_true(transmit_id ~= nil, "should find transmit ID")
  assert_true(delete_id ~= nil, "should find delete ID")
  if transmit_id and delete_id then
    assert_eq(transmit_id, delete_id, "transmit and delete should use same image ID")
  end
end)

test("pty: all APC sequences are well-formed", function()
  local seqs = parse_kitty_sequences(raw_output)
  for i, seq in ipairs(seqs) do
    assert_true(seq.params.a ~= nil,
      string.format("sequence %d should have action (a=) parameter", i))
  end
end)

-- ============================================================================
-- Summary
-- ============================================================================

print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
