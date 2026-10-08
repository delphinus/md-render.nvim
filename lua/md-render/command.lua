--- Subcommand dispatcher for the unified `:MdRender <sub>` user command.
--- See `:help :MdRender` and issue #11 for the design rationale.

local M = {}

local SUBCOMMANDS = { "float", "tab", "pager", "toggle", "split", "auto", "demo", "textsize" }
local AUTO_ARGS = { "on", "off", "toggle" }
local TEXTSIZE_ARGS = { "on", "off", "toggle" }

local function preview()
  return require("md-render").preview
end

--- Subcommands that open a preview, and so take `width=N`.
local WIDTH_SUBCOMMANDS = { float = true, tab = true, pager = true, toggle = true, split = true }

--- Parse the `key=value` options after a preview subcommand.
---@param sub string
---@param rest string[] the arguments after the subcommand
---@return { max_width?: integer }? opts nil when an argument was rejected
local function parse_opts(sub, rest)
  local opts = {}
  for _, arg in ipairs(rest) do
    local width = arg:match "^width=(.*)$"
    if width then
      local n = tonumber(width)
      if not n or n < 1 or n ~= math.floor(n) then
        vim.notify(
          "MdRender " .. sub .. ": width must be a positive integer, got '" .. width .. "'",
          vim.log.levels.WARN
        )
        return nil
      end
      opts.max_width = n
    else
      vim.notify("MdRender " .. sub .. ": unknown argument '" .. arg .. "' (expected width=N)", vim.log.levels.WARN)
      return nil
    end
  end
  return opts
end

--- Dispatch a `:MdRender <sub> [args...]` invocation to the right `MdPreview.*` call.
---@param args table The command args table from `nvim_create_user_command`.
function M.dispatch(args)
  local fargs = args.fargs or {}
  local sub = fargs[1] or "float"
  local p = preview()

  local opts
  if WIDTH_SUBCOMMANDS[sub] then
    opts = parse_opts(sub, vim.list_slice(fargs, 2))
    if not opts then return end
  end

  if sub == "float" then
    p.show(opts)
  elseif sub == "tab" then
    p.show_tab(opts)
  elseif sub == "pager" then
    p.show_pager(opts)
  elseif sub == "toggle" then
    p.toggle(opts)
  elseif sub == "split" then
    p.split { mods = args.smods, max_width = opts.max_width }
  elseif sub == "demo" then
    p.show_demo()
  elseif sub == "textsize" then
    local text_size = require "md-render.text_size"
    local a = (fargs[2] or "toggle"):lower()
    local cur = text_size.config().enabled
    local want
    if a == "on" then
      want = true
    elseif a == "off" then
      want = false
    elseif a == "toggle" then
      want = not cur
    else
      vim.notify("MdRender textsize: unknown argument '" .. a .. "' (expected on|off|toggle)", vim.log.levels.WARN)
      return
    end
    if want and not text_size.supports() then
      vim.notify(
        "MdRender textsize: this terminal does not implement OSC 66 (needs Kitty >= 0.40)",
        vim.log.levels.WARN
      )
      return
    end
    text_size.setup { enabled = want }
    vim.notify("MdRender textsize: " .. (want and "on" or "off"))
    -- Heading rows are reserved at build time, so the content has to be rebuilt.
    p.rebuild_visible()
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

--- Two-level completion. First arg = subcommand list; after `auto` = on/off/toggle;
--- after a preview subcommand = `width=`.
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
  elseif n == 1 and before:match "^%s*textsize%s+$" then
    list = TEXTSIZE_ARGS
  elseif n >= 1 and WIDTH_SUBCOMMANDS[before:match "^%s*(%S+)"] and not before:match "%swidth=" then
    list = { "width=" }
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
M._parse_opts = parse_opts

return M
