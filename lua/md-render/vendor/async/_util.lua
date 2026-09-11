-- Extracted from runtime/lua/vim/_core/util.lua; see ../README.md.

local M = {}

-- Generated from async.nvim/lua/async/_errors.lua: start
local nil_error = 'error(nil)'

--- Normalize a failed Lua operation for error slots where `nil` means success.
--- @param err any
--- @return any
--- @private
function M._normalize_error(err)
  return err == nil and nil_error or err
end

--- Convert an error to a string without letting its metamethod interrupt cleanup.
--- @param err any
--- @return string
--- @private
function M._stringify_error(err)
  local ok, message = pcall(tostring, err)
  return ok and message or '<unprintable error>'
end
-- Generated from async.nvim/lua/async/_errors.lua: end

return M
