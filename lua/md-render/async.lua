--- Coroutine-style async over whichever runtime this Neovim build carries.
---
--- 0.13 exposes `vim.async`. 0.12 — the floor this plugin supports — carries an
--- earlier, private cut of the same idea in `runtime/lua/vim/_async.lua`. That
--- one is not registered in `vim._submodules`, so the field `vim._async` is nil
--- and `require` is the only way in; on 0.13 the file is gone and `require`
--- fails, so both directions have to be tried.
---
--- What the two overlap on is small: `await`, and a `run` that starts a task
--- you can `:wait()` on. Everything else diverges — 0.12's `run` takes an
--- `on_finish` where 0.13's takes the function's arguments and returns a much
--- richer Task, `join` is 0.12-only, and `wrap` / `sleep` / `iter` / `timeout` /
--- `semaphore` / `pawait` / cancellation are 0.13-only. Worse, the two disagree
--- on when a task resumes (see `await` below). So this module exports that
--- overlap plus the few things the plugin needs on top, written once so both
--- runtimes behave the same. Nothing here works on only one of them.

local M = {}

--- @type table
local runtime = vim.async or require "vim._async"

--- Which runtime backs this module. Exposed for tests and `:checkhealth`.
---@type "vim.async"|"vim._async"
M.backend = vim.async and "vim.async" or "vim._async"

--- Suspend until a callback-style function calls back.
---
--- `argc` is the position the callback occupies in `fn`'s argument list, so
--- `await(3, vim.system, cmd, opts)` is `vim.system(cmd, opts, callback)`. The
--- callback's arguments come back as return values.
---
--- The splicing is done here rather than handed to the runtime because the two
--- disagree about a callback that fires before `fn` has returned: 0.13 queues
--- the resume, 0.12 runs it inline, from inside the callback. Inline means the
--- rest of the awaiting function runs before `fn` finishes its own bookkeeping,
--- so `fn`'s return value and anything it assigns on the way out are not there
--- yet. Queue on both. An asynchronous callback — every subprocess, every
--- timer — is untouched and costs nothing extra.
---
--- It also lets `fn` raising stand for the work failing. `vim.system` raises
--- when the executable is not on PATH, and a raise from inside the yielded
--- function reaches neither the task nor anyone waiting on it: both runtimes
--- end the task there, quietly. Hand it to the task instead, so the awaiting
--- code sees a normal error at the point it was waiting.
---@async
---@param argc integer position of the callback in `fn`'s arguments
---@param fn function
---@param ... any arguments before the callback
---@return any ... whatever the callback was called with
function M.await(argc, fn, ...)
  local args = vim.F.pack_len(...)
  args.n = math.max(args.n, argc)
  local failed, failure = false, nil

  local answer = vim.F.pack_len(runtime.await(1, function(callback)
    local answered, returned = false, false
    args[argc] = function(...)
      answered = true
      if returned then
        callback(...)
        return
      end
      local early = vim.F.pack_len(...)
      vim.schedule(function()
        callback(vim.F.unpack_len(early))
      end)
    end

    local ok, err = pcall(fn, vim.F.unpack_len(args))
    returned = true
    -- Having called back and then raised means the work did happen; the
    -- callback's answer is the better one, and resuming twice is not an option.
    if not ok and not answered then
      failed, failure = true, err
      vim.schedule(callback)
    end
  end))

  if failed then error(failure, 0) end
  return vim.F.unpack_len(answer)
end

--- Run `fn` as a task, starting it immediately.
---
--- Neither runtime says anything about a task nobody waited on that threw, so
--- an unobserved failure would disappear without a trace — the failure mode the
--- old callback code did not have, because an error inside a `vim.schedule`
--- callback is reported by Neovim itself. Report it here, then re-raise so a
--- caller that does wait still sees it.
---@param fn async fun(): any
---@return { wait: fun(self: any, timeout?: integer): any } task
function M.run(fn)
  return runtime.run(function()
    local ret = vim.F.pack_len(pcall(fn))
    if not ret[1] then
      local err = ret[2]
      vim.schedule(function()
        vim.notify("md-render: " .. tostring(err), vim.log.levels.ERROR)
      end)
      error(err, 0)
    end
    return unpack(ret, 2, ret.n)
  end)
end

--- Run a command and wait for it to exit.
---
--- Resumes on the main loop, because `vim.system` calls back in a |api-fast|
--- context where most of the API is off limits. `vim.system` is read at call
--- time so a test can stand in for it.
---@async
---@param cmd string[]
---@param opts? table options for `vim.system`
---@return vim.SystemCompleted
function M.system(cmd, opts)
  local result = M.await(3, vim.system, cmd, opts or {})
  M.schedule()
  return result
end

--- Yield to the main loop, so the API is safe to call again.
---@async
function M.schedule()
  M.await(1, vim.schedule)
end

--- Yield for `ms` milliseconds.
---
--- 0.13 has `vim.async.sleep`, 0.12 does not; `vim.defer_fn` is the same timer
--- underneath and behaves identically on both.
---@async
---@param ms integer
function M.sleep(ms)
  M.await(1, function(callback)
    vim.defer_fn(callback, ms)
  end)
end

return M
