--- `vim.async`, on every Neovim this plugin supports.
---
--- 0.13 has it built in. 0.12 — the floor here — does not, and its private
--- predecessor `vim._async` is too small to build on: no cancellation, no
--- semaphore, no awaiting a task, and it disagrees about when a task resumes.
--- So 0.12 gets a copy of the real thing instead (`vendor/async`, see the
--- README there), and both versions run the same code. Once 0.13 is the floor,
--- drop the fallback and this module can become `local async = vim.async`.
---
--- Everything `vim.async` exports is reachable from here — `await`, `pawait`,
--- `sleep`, `timeout`, `iter`, `wrap`, `semaphore`, `checkpoint`. See
--- |lua-async|. What this module adds is the two things the plugin wants at
--- almost every call site and `vim.async` has no opinion on: running a command,
--- and getting back to a context where the API is usable.

--- @class md-render.async: vim.async
local M = {}

--- @type vim.async
local async = vim.async or require "md-render.vendor.async"

setmetatable(M, { __index = async })

--- Which copy is in use. Exposed for tests and `:checkhealth`.
---@type "vim.async"|"vendored"
M.backend = vim.async and "vim.async" or "vendored"

--- Start `fn` as a task, and say so if it fails.
---
--- A task that fails with nobody waiting on it is silent — the plugin's async
--- work is all started and forgotten, so without this a broken image pipeline
--- would simply produce no image and no explanation. Cancelling a task is not
--- failing: `close()` finishes it with `"closed"`, which is the caller getting
--- what it asked for.
---
--- Waiting on the returned task still raises as usual; the report is then
--- redundant but harmless.
---@param fn async fun(...): any
---@param ... any arguments for `fn`
---@return vim.async.Task
function M.run(fn, ...)
  local task = async.run(fn, ...)
  task:on_complete(function(err)
    if err == nil or err == "closed" then return end
    vim.notify("md-render: " .. tostring(err), vim.log.levels.ERROR)
  end)
  return task
end

--- Run a command and wait for it to exit.
---
--- Resumes on the main loop, because `vim.system` calls back in a |api-fast|
--- context where most of the API is off limits and every caller here touches
--- the API straight afterwards. `vim.system` is read at call time so a test can
--- stand in for it.
---@async
---@param cmd string[]
---@param opts? table options for `vim.system`
---@return vim.SystemCompleted
function M.system(cmd, opts)
  local result = async.await(3, vim.system, cmd, opts or {})
  M.schedule()
  return result
end

--- Yield to the main loop, so the API is safe to call again.
---@async
function M.schedule()
  async.await(1, vim.schedule)
end

return M
