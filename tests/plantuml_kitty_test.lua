-- PlantUML → Kitty graphics escape sequence tests
--
-- Verifies the two-phase handoff for a rendered PlantUML diagram:
--   1. transmit_image (a=t) stores the PNG under an image ID
--   2. put_image (a=p) places that same ID with the right cell dimensions
-- This is the part that can't be checked without a graphics-capable terminal
-- otherwise, so it is asserted at the escape-sequence level instead.
--
-- Run: nvim --headless -u NONE --noplugin -l tests/plantuml_kitty_test.lua

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

local function assert_true(val, msg)
  if val then
    pass_count = pass_count + 1
  else
    fail_count = fail_count + 1
    print("FAIL: " .. msg)
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
-- Capture helpers (mirrors tests/image_test.lua)
-- ============================================================================

local captured = {}
local _orig_ui_send = nil
local _orig_ghostty_dir = nil
local _orig_term_program = nil

local function setup_capture()
  captured = {}
  _orig_ui_send = vim.api.nvim_ui_send
  vim.api.nvim_ui_send = function(data)
    table.insert(captured, data)
  end
  -- put_image falls back to a one-shot a=T re-transmit on Ghostty, which would
  -- mask the a=t/a=p handoff under test. Neutralize the detection so these
  -- assertions describe the protocol, not the developer's terminal.
  _orig_ghostty_dir = vim.env.GHOSTTY_RESOURCES_DIR
  _orig_term_program = vim.env.TERM_PROGRAM
  vim.env.GHOSTTY_RESOURCES_DIR = nil
  vim.env.TERM_PROGRAM = "xterm"
  image.reset_cache()
  image._set_kitty_supported(true)
  image._reset_image_id()
end

local function teardown()
  if _orig_ui_send then
    vim.api.nvim_ui_send = _orig_ui_send
    _orig_ui_send = nil
  end
  vim.env.GHOSTTY_RESOURCES_DIR = _orig_ghostty_dir
  vim.env.TERM_PROGRAM = _orig_term_program
  image._set_kitty_supported(nil)
  image.reset_cache()
end

local function captured_output()
  return table.concat(captured)
end

--- Parse Kitty APC sequences: ESC _ G <params> [; <payload>] ESC \
local function parse_kitty_sequences(data)
  local seqs = {}
  local pos = 1
  while pos <= #data do
    local s, e, content = data:find("\x1b_G(.-)\x1b\\", pos)
    if not s then break end
    local params, payload = content:match "^([^;]*);(.*)$"
    if not params then
      params = content
      payload = ""
    end
    table.insert(seqs, { params = params, payload = payload })
    pos = e + 1
  end
  return seqs
end

local function parse_params(params_str)
  local t = {}
  for k, v in params_str:gmatch "([%w_]+)=([^,]*)" do
    t[k] = v
  end
  return t
end

--- Find the first sequence whose action matches.
local function find_action(seqs, action)
  for _, seq in ipairs(seqs) do
    local p = parse_params(seq.params)
    if p.a == action then return p, seq end
  end
  return nil
end

--- Open a scratch float big enough to hold an image placement.
local function open_test_win(width, height)
  local buf = vim.api.nvim_create_buf(false, true)
  local lines = {}
  for i = 1, height do
    lines[i] = string.rep(" ", width)
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    row = 0,
    col = 0,
    width = width,
    height = height,
    border = "none",
  })
  return win, buf
end

local function close_test_win(win, buf)
  vim.api.nvim_win_close(win, true)
  vim.api.nvim_buf_delete(buf, { force = true })
end

-- ============================================================================
-- Fixture: render a PlantUML diagram once, reuse across tests.
--
-- Requires a local plantuml binary or network access to the remote server.
-- When neither is available the rendering tests are skipped rather than
-- failed, matching how the rest of the suite treats absent external tools.
-- ============================================================================

local diagram_source = "@startuml\nAlice -> Bob: kitty protocol test\n@enduml"

local function render_fixture()
  local done, result = false, nil
  image.render_plantuml_async(diagram_source, function(path)
    result = path
    done = true
  end)
  vim.wait(30000, function()
    return done
  end, 100)
  return result
end

local plantuml_png = render_fixture()

if not plantuml_png then
  print "SKIP: no local PlantUML renderer and no reachable remote server"
  print "\n0 passed, 0 failed (skipped)"
  return
end

-- ============================================================================
-- transmit (a=t): the rendered PNG is stored under an image ID
-- ============================================================================

test("transmit: rendered PlantUML PNG produces an a=t sequence", function()
  setup_capture()

  local id = image.transmit_image(plantuml_png)
  assert_true(id ~= nil, "transmit_image should return an image ID")

  local seqs = parse_kitty_sequences(captured_output())
  local p = find_action(seqs, "t")
  assert_true(p ~= nil, "should emit an a=t (transmit) sequence")
  if p then
    assert_eq(p.i, tostring(id), "transmit image ID matches the returned ID")
    assert_eq(p.f, "100", "f=100 marks the payload as PNG")
    assert_eq(p.q, "2", "q=2 suppresses terminal responses")
  end

  teardown()
end)

test("transmit: payload is the base64-encoded PNG path", function()
  setup_capture()

  local id = image.transmit_image(plantuml_png)
  local seqs = parse_kitty_sequences(captured_output())
  local _, seq = find_action(seqs, "t")
  assert_true(seq ~= nil and seq.payload ~= "", "a=t sequence carries a payload")
  if seq and seq.payload ~= "" then
    local decoded = vim.base64.decode(seq.payload)
    assert_eq(decoded, plantuml_png, "payload decodes to the rendered PNG path")
    assert_true(vim.fn.filereadable(decoded) == 1, "decoded path is readable")
  end
  assert_true(id ~= nil, "image ID returned")

  teardown()
end)

-- ============================================================================
-- place (a=p): the transmitted image is displayed by ID, not re-sent
-- ============================================================================

test("place: a=p references the transmitted ID with correct cell size", function()
  setup_capture()

  local id = image.transmit_image(plantuml_png)
  local win, buf = open_test_win(60, 24)

  captured = {} -- isolate the placement from the transmit
  image.put_image(id, win, 2, 3, 20, 10)

  local seqs = parse_kitty_sequences(captured_output())
  local p = find_action(seqs, "p")
  assert_true(p ~= nil, "should emit an a=p (place) sequence")
  if p then
    assert_eq(p.i, tostring(id), "placement references the transmitted image ID")
    assert_eq(p.c, "20", "c= matches requested display columns")
    assert_eq(p.r, "10", "r= matches requested display rows")
    assert_eq(p.C, "1", "C=1 keeps the cursor from moving")
    assert_eq(p.q, "2", "q=2 suppresses terminal responses")
  end

  close_test_win(win, buf)
  teardown()
end)

test("place: payload is empty (image data is not re-sent)", function()
  setup_capture()

  local id = image.transmit_image(plantuml_png)
  local win, buf = open_test_win(60, 24)

  captured = {}
  image.put_image(id, win, 0, 0, 12, 6)

  local seqs = parse_kitty_sequences(captured_output())
  local _, seq = find_action(seqs, "p")
  assert_true(seq ~= nil, "a=p sequence present")
  if seq then assert_eq(seq.payload, "", "placement carries no payload — data was already transmitted") end

  close_test_win(win, buf)
  teardown()
end)

test("place: cursor is saved and restored around the placement", function()
  setup_capture()

  local id = image.transmit_image(plantuml_png)
  local win, buf = open_test_win(60, 24)

  captured = {}
  image.put_image(id, win, 4, 2, 15, 8)
  local output = captured_output()

  assert_true(output:find "^\x1b%[s" ~= nil, "output starts with cursor save (CSI s)")
  assert_true(output:find "\x1b%[u$" ~= nil, "output ends with cursor restore (CSI u)")
  assert_true(output:find "\x1b%[%d+;%d+H" ~= nil, "output positions the cursor before placing")

  close_test_win(win, buf)
  teardown()
end)

-- ============================================================================
-- Full handoff: transmit then place, in order, sharing one ID
-- ============================================================================

test("handoff: a=t precedes a=p and both use the same image ID", function()
  setup_capture()

  local win, buf = open_test_win(60, 24)
  local id = image.transmit_image(plantuml_png)
  image.put_image(id, win, 1, 1, 18, 9)

  local seqs = parse_kitty_sequences(captured_output())
  local t_index, p_index
  for i, seq in ipairs(seqs) do
    local params = parse_params(seq.params)
    if params.a == "t" and not t_index then t_index = i end
    if params.a == "p" and not p_index then p_index = i end
  end

  assert_true(t_index ~= nil, "a=t sequence emitted")
  assert_true(p_index ~= nil, "a=p sequence emitted")
  if t_index and p_index then
    assert_true(t_index < p_index, "transmit is emitted before placement")
    local tp = parse_params(seqs[t_index].params)
    local pp = parse_params(seqs[p_index].params)
    assert_eq(pp.i, tp.i, "placement reuses the transmitted image ID")
    assert_eq(pp.i, tostring(id), "both match the ID returned by transmit_image")
  end

  close_test_win(win, buf)
  teardown()
end)

test("handoff: one transmit supports repeated placements", function()
  setup_capture()

  local id = image.transmit_image(plantuml_png)
  local win, buf = open_test_win(60, 24)

  captured = {}
  image.put_image(id, win, 0, 0, 10, 5)
  image.put_image(id, win, 8, 0, 10, 5)

  local seqs = parse_kitty_sequences(captured_output())
  local places = 0
  for _, seq in ipairs(seqs) do
    local p = parse_params(seq.params)
    if p.a == "p" then
      places = places + 1
      assert_eq(p.i, tostring(id), "each placement reuses the same image ID")
      assert_eq(seq.payload, "", "no re-transmission of image data")
    end
  end
  assert_eq(places, 2, "both placements emitted")

  close_test_win(win, buf)
  teardown()
end)

-- ============================================================================
-- Summary
-- ============================================================================

print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
