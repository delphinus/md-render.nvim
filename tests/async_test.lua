-- Async shim unit tests: the contract md-render.async promises on both the
-- 0.13 `vim.async` runtime and the 0.12 `vim._async` one.
-- Run: nvim --headless -u NONE --noplugin -l tests/async_test.lua

package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local async = require "md-render.async"

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

--- Pump the event loop until `done` or the budget runs out.
---@param done fun(): boolean
local function pump(done)
  vim.wait(2000, done, 10)
end

-- ============================================================================
-- Which runtime is in use
-- ============================================================================

test("backend matches what this Neovim carries", function()
  if vim.async then
    assert_eq(async.backend, "vim.async", "0.13 and later use the public vim.async")
  else
    assert_eq(async.backend, "vim._async", "0.12 falls back to the private vim._async")
    assert_eq(vim._async, nil, "vim._async is reachable only through require, not as a field")
  end
end)

-- ============================================================================
-- run
-- ============================================================================

test("run starts the task synchronously", function()
  -- Several callers depend on this: `download_async` has to have spawned its
  -- curl by the time it returns, or a second request for the same URL would
  -- not find any work to join.
  local reached = false
  async.run(function()
    reached = true
    async.schedule()
  end)
  assert_true(reached, "the body runs up to its first await before run() returns")
end)

test("run hands return values to wait", function()
  local task = async.run(function()
    async.schedule()
    return "one", 2
  end)
  assert_eq({ task:wait(2000) }, { "one", 2 }, "every return value survives the round trip")
end)

test("run reports a failure nobody waited on", function()
  local real_notify = vim.notify
  local notified = {}
  vim.notify = function(msg)
    table.insert(notified, msg)
  end

  async.run(function()
    async.schedule()
    error("kaboom", 0)
  end)
  pump(function()
    return #notified > 0
  end)
  vim.notify = real_notify

  assert_eq(#notified, 1, "an unobserved error is surfaced instead of vanishing")
  assert_true(notified[1] and notified[1]:match "kaboom", "and the message names the failure")
end)

test("run still raises for a caller that waits", function()
  local real_notify = vim.notify
  local notified = false
  vim.notify = function()
    notified = true
  end
  local task = async.run(function()
    error("waited-on boom", 0)
  end)
  local ok, err = pcall(function()
    return task:wait(2000)
  end)
  -- The report is scheduled, so let it land before putting vim.notify back;
  -- otherwise it fires against the real one and prints during the run.
  pump(function()
    return notified
  end)
  vim.notify = real_notify

  assert_true(not ok, "wait() re-raises")
  assert_true(tostring(err):match "waited%-on boom", "with the original message")
end)

-- ============================================================================
-- await
-- ============================================================================

test("await splices the callback at argc and returns its arguments", function()
  local seen
  local got
  local function takes_callback_third(a, b, callback)
    seen = { a, b }
    vim.schedule(function()
      callback("x", "y")
    end)
  end

  async.run(function()
    got = { async.await(3, takes_callback_third, "first", "second") }
  end)
  pump(function()
    return got ~= nil
  end)

  assert_eq(seen, { "first", "second" }, "the leading arguments are passed through untouched")
  assert_eq(got, { "x", "y" }, "and the callback's arguments come back as return values")
end)

test("await never resumes from inside the callback", function()
  -- 0.12 resumes inline where 0.13 queues, so on 0.12 the awaiting task would
  -- run on before `fn` had finished — before its return value existed, and
  -- before anything it assigns on the way out was assigned. The shim exists
  -- partly to hide that, and callers rely on it: `image.custom_download` reads
  -- what the user's download function returned right after awaiting its
  -- callback, and the two can arrive in either order.
  local order = {}
  local returned_value
  async.run(function()
    async.await(1, function(callback)
      order[#order + 1] = "enter"
      callback "at once"
      returned_value = "assigned on the way out"
      order[#order + 1] = "leave"
    end)
    order[#order + 1] = "resumed"
  end)
  pump(function()
    return #order >= 3
  end)

  assert_eq(order, { "enter", "leave", "resumed" }, "fn runs to completion before the task continues")
  assert_eq(returned_value, "assigned on the way out", "so what it assigned last is visible")
end)

test("await turns a raise from the awaited function into a normal error", function()
  -- `vim.system` raises when the command is not on PATH. Raised from inside the
  -- yielded function, neither runtime hands that to anybody: the task just
  -- stops. The awaiting code has to be able to catch it where it waited.
  local caught
  local task = async.run(function()
    local ok, err = pcall(function()
      async.await(1, function()
        error("ENOENT: no such file or directory", 0)
      end)
    end)
    caught = { ok, err }
    return "kept going"
  end)

  assert_eq(task:wait(2000), "kept going", "the task survives and finishes")
  assert_eq(caught and caught[1], false, "the await raised")
  assert_eq(caught and caught[2], "ENOENT: no such file or directory", "with the original message")
end)

test("await keeps the answer when the function calls back and then raises", function()
  local got
  local task = async.run(function()
    got = async.await(1, function(callback)
      callback "answered"
      error("noise on the way out", 0)
    end)
    return "kept going"
  end)

  assert_eq(task:wait(2000), "kept going", "the task is not derailed")
  assert_eq(got, "answered", "the callback's answer wins over the later raise")
end)

test("await passes nils through without losing the ones after them", function()
  local got
  async.run(function()
    got = vim.F.pack_len(async.await(3, function(a, b, callback)
      vim.schedule(function()
        callback(nil, "after a nil")
      end)
      got = { a, b }
    end, nil, "second"))
  end)
  pump(function()
    return got ~= nil and got.n ~= nil
  end)

  assert_eq(got.n, 2, "the callback was called with two arguments")
  assert_eq(got[1], nil, "the first is nil")
  assert_eq(got[2], "after a nil", "and the one behind it survived")
end)

-- ============================================================================
-- system
-- ============================================================================

test("system returns the completed result on the main loop", function()
  local result, fast
  async.run(function()
    result = async.system({ "sh", "-c", "printf md-render" }, { text = true })
    fast = vim.in_fast_event()
  end)
  pump(function()
    return result ~= nil
  end)

  assert_eq(result and result.code, 0, "the exit code comes back")
  assert_eq(result and result.stdout, "md-render", "so does stdout")
  -- vim.system calls back in a fast event context where most of the API is off
  -- limits. Every caller in this plugin touches the API right afterwards.
  assert_eq(fast, false, "and the task resumes somewhere the API is safe to call")
end)

test("system reads vim.system at call time so tests can stand in for it", function()
  local real = vim.system
  local spawned
  vim.system = function(cmd, _, on_exit)
    spawned = cmd
    on_exit { code = 7, stdout = "", stderr = "" }
  end
  local code
  async.run(function()
    code = async.system({ "does-not-exist" }, { text = true }).code
  end)
  pump(function()
    return code ~= nil
  end)
  vim.system = real

  assert_eq(spawned, { "does-not-exist" }, "the stub sees the command")
  assert_eq(code, 7, "and its result reaches the task")
end)

-- ============================================================================
-- sleep
-- ============================================================================

test("sleep yields and resumes", function()
  local resumed = false
  local before = vim.uv.now()
  async.run(function()
    async.sleep(20)
    resumed = true
  end)
  assert_true(not resumed, "the task is suspended, not spinning")
  pump(function()
    return resumed
  end)
  assert_true(resumed, "and it comes back")
  assert_true(vim.uv.now() - before >= 20, "no earlier than it was told to")
end)

print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
