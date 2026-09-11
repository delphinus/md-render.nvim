-- Async tests.
--
-- Two jobs. First, pin what `md-render.async` adds on top of `vim.async`.
-- Second, and more important: run the same behaviour suite against both the
-- built-in `vim.async` and the vendored copy 0.12 falls back to, so the copy is
-- exercised on every Neovim the CI matrix covers rather than only the oldest
-- one. On 0.12 the two are the same object and the suite simply runs twice.
--
-- Run: nvim --headless -u NONE --noplugin -l tests/async_test.lua

package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local async = require "md-render.async"
local vendored = require "md-render.vendor.async"

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
  vim.wait(2000, done, 5)
end

-- ============================================================================
-- The same suite against both copies
-- ============================================================================

--- @param label string
--- @param a vim.async
local function behaviour_suite(label, a)
  local function name(what)
    return label .. ": " .. what
  end

  test(name "run and await round trip", function()
    local task = a.run(function()
      local result = a.await(3, vim.system, { "sh", "-c", "printf md-render" }, { text = true })
      return result.code, result.stdout
    end)
    assert_eq({ task:wait(3000) }, { 0, "md-render" }, name "a command's result comes back through the task")
  end)

  test(name "a task is a value several awaiters can share", function()
    -- This is the whole reason for the copy: 0.12's `vim._async` has tasks you
    -- can start but not results you can share, so the plugin's own in-flight
    -- deduplication had nothing to build on.
    local runs = 0
    local shared = a.run(function()
      runs = runs + 1
      a.sleep(20)
      return "computed once"
    end)
    local got = {}
    for i = 1, 3 do
      a.run(function()
        got[i] = a.await(shared)
      end)
    end
    pump(function()
      return got[3] ~= nil
    end)
    -- One that turns up after it already finished.
    local late = a.run(function()
      return a.await(shared)
    end)

    assert_eq(runs, 1, name "the work ran once")
    assert_eq(got, { "computed once", "computed once", "computed once" }, name "and every awaiter got the result")
    assert_eq(late:wait(2000), "computed once", name "including one that arrived after it settled")
  end)

  test(name "close cancels a suspended task and runs its cleanup", function()
    local cleaned, reason = false, nil
    local victim = a.run(function()
      local ok, err = pcall(function()
        a.sleep(5000)
      end)
      cleaned, reason = true, err
    end)
    pump(function()
      return victim:status() == "suspended"
    end)
    victim:close()
    pump(function()
      return cleaned
    end)

    assert_true(cleaned, name "the task woke up instead of sitting on its timer")
    assert_eq(tostring(reason), "closed", name "and was told why")
  end)

  test(name "semaphore caps how many run at once", function()
    local sem = a.semaphore(2)
    local live, peak = 0, 0
    local tasks = {}
    for i = 1, 6 do
      tasks[i] = a.run(function()
        sem:with(function()
          live = live + 1
          peak = math.max(peak, live)
          a.sleep(10)
          live = live - 1
        end)
      end)
    end
    for _, task in ipairs(tasks) do
      task:wait(3000)
    end
    assert_eq(peak, 2, name "never more than the permit count")
  end)

  test(name "iter hands back tasks in completion order", function()
    local slow = a.run(function()
      a.sleep(60)
      return "slow"
    end)
    local fast = a.run(function()
      a.sleep(10)
      return "fast"
    end)
    local order = {}
    a.run(function()
      for task in a.iter { slow, fast } do
        order[#order + 1] = a.await(task)
      end
    end):wait(3000)
    assert_eq(order, { "fast", "slow" }, name "finished first comes back first, not listed first")
  end)

  test(name "timeout raises and cancels the task that lost", function()
    local cancelled = false
    local victim = a.run(function()
      pcall(function()
        a.sleep(5000)
      end)
      cancelled = true
    end)
    local raised = a.run(function()
      local ok, err = pcall(function()
        return a.timeout(30, victim)
      end)
      return ok, tostring(err)
    end):wait(3000)
    pump(function()
      return cancelled
    end)

    assert_eq(raised, false, name "the deadline raises")
    assert_true(cancelled, name "and the work it was waiting on is actually stopped")
  end)

  test(name "pawait reports a failure instead of raising", function()
    local got = {
      a.run(function()
        return a.pawait(a.run(function()
          error("nope", 0)
        end))
      end):wait(2000),
    }
    assert_eq(got, { false, "nope" }, name "ok is false and the error comes back as a value")
  end)

  test(name "a callback that fires at once does not resume inline", function()
    -- 0.12's `vim._async` resumed from inside the callback, so the awaiting
    -- code ran on before the awaited function had returned. `image.lua` reads
    -- what `set_download_fn` returned right after awaiting its callback.
    local order = {}
    a.run(function()
      a.await(1, function(callback)
        order[#order + 1] = "enter"
        callback()
        order[#order + 1] = "leave"
      end)
      order[#order + 1] = "resumed"
    end)
    pump(function()
      return #order >= 3
    end)
    assert_eq(order, { "enter", "leave", "resumed" }, name "the awaited function finishes first")
  end)

  test(name "await surfaces a raise from the awaited function", function()
    -- `vim.system` raises when the command is not on PATH.
    local got = {
      a.run(function()
        return pcall(function()
          a.await(1, function()
            error("ENOENT", 0)
          end)
        end)
      end):wait(2000),
    }
    assert_eq(got, { false, "ENOENT" }, name "it arrives where the code was waiting")
  end)
end

behaviour_suite("built-in", vim.async or vendored)
behaviour_suite("vendored", vendored)

-- ============================================================================
-- Picking a copy
-- ============================================================================

test("backend matches what this Neovim carries", function()
  if vim.async then
    assert_eq(async.backend, "vim.async", "0.13 and later use the built-in one")
  else
    assert_eq(async.backend, "vendored", "0.12 falls back to the copy")
    assert_true(rawequal(getmetatable(async).__index, vendored), "and that copy is what the module forwards to")
  end
end)

test("the whole vim.async surface is reachable through the module", function()
  -- Call sites should never have to know which copy answered.
  for _, fn in ipairs { "await", "pawait", "checkpoint", "is_closing", "iter", "sleep", "timeout", "wrap" } do
    assert_true(vim.is_callable(async[fn]), fn .. " is callable")
  end
  assert_true(vim.is_callable(async.semaphore), "semaphore is callable")
end)

-- ============================================================================
-- What this module adds
-- ============================================================================

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

  assert_eq(#notified, 1, "an unobserved failure is surfaced instead of vanishing")
  assert_true(notified[1] and notified[1]:match "kaboom", "and the message names it")
end)

test("run stays quiet about a task that was cancelled on purpose", function()
  local real_notify = vim.notify
  local notified = {}
  vim.notify = function(msg)
    table.insert(notified, msg)
  end

  local task = async.run(function()
    async.sleep(5000)
  end)
  pump(function()
    return task:status() == "suspended"
  end)
  task:close()
  pump(function()
    return task:status() == "completed"
  end)
  vim.wait(50)
  vim.notify = real_notify

  assert_eq(notified, {}, "closing a task is the caller getting what it asked for")
end)

test("run passes arguments and returns the task", function()
  local task = async.run(function(a, b)
    async.schedule()
    return a + b
  end, 2, 3)
  assert_eq(task:wait(2000), 5, "arguments reach the function and the result comes back")
end)

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
    vim.schedule(function()
      on_exit { code = 7, stdout = "", stderr = "" }
    end)
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

test("schedule leaves a fast event context", function()
  local before, after
  async.run(function()
    async.await(3, vim.system, { "sh", "-c", "true" }, { text = true })
    before = vim.in_fast_event()
    async.schedule()
    after = vim.in_fast_event()
  end)
  pump(function()
    return after ~= nil
  end)

  assert_eq(before, true, "vim.system resumes in a fast context")
  assert_eq(after, false, "and schedule() gets out of it")
end)

print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
