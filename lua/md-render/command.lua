--- Subcommand dispatcher for the unified `:MdRender <sub>` user command.
--- See `:help :MdRender` and issue #11 for the design rationale.

local M = {}

local SUBCOMMANDS = { "float", "tab", "pager", "toggle", "split", "auto", "demo" }
local AUTO_ARGS = { "on", "off", "toggle" }

local function preview()
  return require("md-render").preview
end

--- Dispatch a `:MdRender <sub> [args...]` invocation to the right `MdPreview.*` call.
---@param args table The command args table from `nvim_create_user_command`.
function M.dispatch(args)
  local fargs = args.fargs or {}
  local sub = fargs[1] or "float"
  local p = preview()

  if sub == "float" then
    p.show()
  elseif sub == "tab" then
    p.show_tab()
  elseif sub == "pager" then
    p.show_pager()
  elseif sub == "toggle" then
    p.toggle()
  elseif sub == "split" then
    p.split { mods = args.smods }
  elseif sub == "demo" then
    p.show_demo()
  elseif sub == "auto" then
    local a = (fargs[2] or "toggle"):lower()
    if a == "on" then
      p.auto_on()
    elseif a == "off" then
      p.auto_off()
    elseif a == "toggle" then
      p.auto_toggle()
    else
      vim.notify("MdRender auto: unknown argument '" .. a .. "' (expected on|off|toggle)", vim.log.levels.WARN)
    end
  else
    vim.notify(
      "MdRender: unknown subcommand '" .. sub .. "' (expected " .. table.concat(SUBCOMMANDS, "|") .. ")",
      vim.log.levels.WARN
    )
  end
end

--- Two-level completion. First arg = subcommand list; after `auto` = on/off/toggle.
--- Tolerates command modifiers (`:vert MdRender ...`, `:tab MdRender ...`).
---@param arglead string The current word being typed.
---@param cmdline string The full command line so far.
---@return string[]
function M.complete(arglead, cmdline, _cursorpos)
  local tail = cmdline:match "MdRender%s+(.*)$" or ""
  local before = tail:sub(1, #tail - #arglead)
  local n = 0
  for _ in before:gmatch "%S+" do
    n = n + 1
  end
  local list
  if n == 0 then
    list = SUBCOMMANDS
  elseif n == 1 and before:match "^%s*auto%s+$" then
    list = AUTO_ARGS
  else
    return {}
  end
  return vim.tbl_filter(function(s)
    return vim.startswith(s, arglead)
  end, list)
end

--- Wrap a callback so the first invocation per session prints a deprecation warning.
--- Uses `vim.notify_once`, which dedups by message body.
---@param old_name string The deprecated command name (without leading colon).
---@param new_form string The replacement command users should switch to.
---@param run fun(args: table) The actual handler.
function M.deprecated(old_name, new_form, run)
  return function(args)
    vim.notify_once(
      string.format(
        ":%s is deprecated and will be removed in a future major version; use `:%s` instead.",
        old_name,
        new_form
      ),
      vim.log.levels.WARN
    )
    run(args)
  end
end

M._SUBCOMMANDS = SUBCOMMANDS
M._AUTO_ARGS = AUTO_ARGS

return M
