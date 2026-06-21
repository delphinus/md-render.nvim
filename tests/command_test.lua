-- Test the :MdRender subcommand dispatcher (lua/md-render/command.lua)
-- Run: nvim --headless -u NONE --noplugin -l tests/command_test.lua

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
    print("ERROR: " .. name .. ": " .. tostring(err))
  end
end

--- Replace `require("md-render").preview` with a recording table for one test.
--- Returns (calls, restore) where `calls` is a list of {fn, args} entries and
--- `restore` puts the previous module back.
local function with_preview_stub()
  local calls = {}
  local function rec(name)
    return function(...)
      table.insert(calls, { fn = name, args = { ... } })
    end
  end
  local stub_preview = {
    show = rec "show",
    show_tab = rec "show_tab",
    show_pager = rec "show_pager",
    show_demo = rec "show_demo",
    toggle = rec "toggle",
    split = rec "split",
    auto_on = rec "auto_on",
    auto_off = rec "auto_off",
    auto_toggle = rec "auto_toggle",
  }
  local prev = package.loaded["md-render"]
  package.loaded["md-render"] = { preview = stub_preview }
  -- Fresh require of the dispatcher so it captures the stub via require("md-render").preview
  package.loaded["md-render.command"] = nil
  local cmd = require "md-render.command"
  local function restore()
    package.loaded["md-render"] = prev
    package.loaded["md-render.command"] = nil
  end
  return cmd, calls, restore
end

--- Replace vim.notify / vim.notify_once with a recorder for one test.
local function with_notify_stub()
  local calls = {}
  local prev_notify = vim.notify
  local prev_notify_once = vim.notify_once
  vim.notify = function(msg, level)
    table.insert(calls, { kind = "notify", msg = msg, level = level })
  end
  -- Re-implement notify_once with our own dedup so the test is hermetic
  -- (the real vim.notify_once dedups per Neovim session, which would leak
  -- across tests).
  local seen = {}
  vim.notify_once = function(msg, level)
    if seen[msg] then return false end
    seen[msg] = true
    table.insert(calls, { kind = "notify_once", msg = msg, level = level })
    return true
  end
  local function restore()
    vim.notify = prev_notify
    vim.notify_once = prev_notify_once
  end
  return calls, restore
end

-- ----------------------------------------------------------------------
-- dispatch: subcommand routing
-- ----------------------------------------------------------------------
test("dispatch with no args calls preview.show (float default)", function()
  local cmd, calls, restore = with_preview_stub()
  cmd.dispatch { fargs = {} }
  assert_eq(#calls, 1, "exactly one preview call")
  assert_eq(calls[1].fn, "show", "should route to show")
  restore()
end)

test("dispatch float -> preview.show", function()
  local cmd, calls, restore = with_preview_stub()
  cmd.dispatch { fargs = { "float" } }
  assert_eq(calls[1].fn, "show", "float -> show")
  restore()
end)

test("dispatch tab -> preview.show_tab", function()
  local cmd, calls, restore = with_preview_stub()
  cmd.dispatch { fargs = { "tab" } }
  assert_eq(calls[1].fn, "show_tab", "tab -> show_tab")
  restore()
end)

test("dispatch pager -> preview.show_pager", function()
  local cmd, calls, restore = with_preview_stub()
  cmd.dispatch { fargs = { "pager" } }
  assert_eq(calls[1].fn, "show_pager", "pager -> show_pager")
  restore()
end)

test("dispatch toggle -> preview.toggle", function()
  local cmd, calls, restore = with_preview_stub()
  cmd.dispatch { fargs = { "toggle" } }
  assert_eq(calls[1].fn, "toggle", "toggle -> toggle")
  restore()
end)

test("dispatch demo -> preview.show_demo", function()
  local cmd, calls, restore = with_preview_stub()
  cmd.dispatch { fargs = { "demo" } }
  assert_eq(calls[1].fn, "show_demo", "demo -> show_demo")
  restore()
end)

test("dispatch split forwards smods to preview.split", function()
  local cmd, calls, restore = with_preview_stub()
  local fake_smods = { vertical = true, tab = -1 }
  cmd.dispatch { fargs = { "split" }, smods = fake_smods }
  assert_eq(calls[1].fn, "split", "split -> split")
  assert_eq(calls[1].args[1], { mods = fake_smods }, "split args carry smods as mods")
  restore()
end)

test("dispatch auto (no second arg) -> auto_toggle", function()
  local cmd, calls, restore = with_preview_stub()
  cmd.dispatch { fargs = { "auto" } }
  assert_eq(calls[1].fn, "auto_toggle", "bare auto -> auto_toggle")
  restore()
end)

test("dispatch auto on -> auto_on", function()
  local cmd, calls, restore = with_preview_stub()
  cmd.dispatch { fargs = { "auto", "on" } }
  assert_eq(calls[1].fn, "auto_on", "auto on -> auto_on")
  restore()
end)

test("dispatch auto off -> auto_off", function()
  local cmd, calls, restore = with_preview_stub()
  cmd.dispatch { fargs = { "auto", "off" } }
  assert_eq(calls[1].fn, "auto_off", "auto off -> auto_off")
  restore()
end)

test("dispatch auto toggle -> auto_toggle", function()
  local cmd, calls, restore = with_preview_stub()
  cmd.dispatch { fargs = { "auto", "toggle" } }
  assert_eq(calls[1].fn, "auto_toggle", "auto toggle -> auto_toggle")
  restore()
end)

test("dispatch auto bogus -> warn, no preview call", function()
  local cmd, calls, restore = with_preview_stub()
  local notif, restore_n = with_notify_stub()
  cmd.dispatch { fargs = { "auto", "bogus" } }
  assert_eq(#calls, 0, "no preview call on bogus auto arg")
  assert_eq(#notif, 1, "one warning emitted")
  assert_eq(notif[1].level, vim.log.levels.WARN, "warn level")
  assert_true(notif[1].msg:match "auto", "warning mentions auto")
  restore_n()
  restore()
end)

test("dispatch unknown subcommand -> warn, no preview call", function()
  local cmd, calls, restore = with_preview_stub()
  local notif, restore_n = with_notify_stub()
  cmd.dispatch { fargs = { "wibble" } }
  assert_eq(#calls, 0, "no preview call on unknown subcommand")
  assert_eq(#notif, 1, "one warning emitted")
  assert_eq(notif[1].level, vim.log.levels.WARN, "warn level")
  assert_true(notif[1].msg:match "wibble", "warning includes the bad subcommand")
  restore_n()
  restore()
end)

-- ----------------------------------------------------------------------
-- complete: two-level completion
-- ----------------------------------------------------------------------
test("complete first arg empty -> all subcommands", function()
  local cmd, _, restore = with_preview_stub()
  local out = cmd.complete("", "MdRender ", #"MdRender ")
  -- Order matches the SUBCOMMANDS table
  assert_eq(
    out,
    { "float", "tab", "pager", "toggle", "split", "auto", "demo" },
    "all subcommands returned for empty arglead"
  )
  restore()
end)

test("complete first arg 't' -> tab, toggle", function()
  local cmd, _, restore = with_preview_stub()
  local out = cmd.complete("t", "MdRender t", #"MdRender t")
  assert_eq(out, { "tab", "toggle" }, "t-prefix narrows to tab,toggle")
  restore()
end)

test("complete after 'auto ' -> on, off, toggle", function()
  local cmd, _, restore = with_preview_stub()
  local out = cmd.complete("", "MdRender auto ", #"MdRender auto ")
  assert_eq(out, { "on", "off", "toggle" }, "auto's second-arg list")
  restore()
end)

test("complete after 'auto o' -> on, off", function()
  local cmd, _, restore = with_preview_stub()
  local out = cmd.complete("o", "MdRender auto o", #"MdRender auto o")
  assert_eq(out, { "on", "off" }, "auto + o-prefix narrows to on,off")
  restore()
end)

test("complete tolerates :vert mod prefix", function()
  local cmd, _, restore = with_preview_stub()
  local out = cmd.complete("", "vert MdRender ", #"vert MdRender ")
  assert_eq(
    out,
    { "float", "tab", "pager", "toggle", "split", "auto", "demo" },
    "leading :vert mod still yields full subcommand list"
  )
  restore()
end)

test("complete returns empty after a non-auto subcommand's second slot", function()
  local cmd, _, restore = with_preview_stub()
  local out = cmd.complete("", "MdRender split ", #"MdRender split ")
  assert_eq(out, {}, "no completion after split")
  restore()
end)

-- ----------------------------------------------------------------------
-- deprecated wrapper
-- ----------------------------------------------------------------------
test("deprecated wrapper warns once and forwards args", function()
  local cmd, _, restore = with_preview_stub()
  local notif, restore_n = with_notify_stub()
  local seen_args = {}
  local handler = cmd.deprecated("MdRenderToggle", "MdRender toggle", function(args)
    table.insert(seen_args, args)
  end)
  handler { fargs = { "x" } }
  handler { fargs = { "y" } }
  handler { fargs = { "z" } }
  assert_eq(#seen_args, 3, "handler runs every time")
  assert_eq(seen_args[1].fargs, { "x" }, "first call args forwarded")
  assert_eq(seen_args[3].fargs, { "z" }, "third call args forwarded")
  assert_eq(#notif, 1, "warning fires only once across calls")
  assert_eq(notif[1].kind, "notify_once", "uses notify_once")
  assert_eq(notif[1].level, vim.log.levels.WARN, "warn level")
  assert_true(notif[1].msg:match "MdRenderToggle", "warning names the deprecated command")
  assert_true(notif[1].msg:match "MdRender toggle", "warning suggests the new form")
  restore_n()
  restore()
end)

print(string.format("command_test: %d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
