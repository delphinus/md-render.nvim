---@class MdRender.FloatWin
---@field private augroup string
---@field private win? integer
local FloatWin = {}

---@param augroup_name? string
FloatWin.new = function(augroup_name)
  return setmetatable({ augroup = augroup_name or "md_render_float" }, { __index = FloatWin })
end

function FloatWin:setup(win)
  self.win = win
  vim.api.nvim_create_autocmd({ "WinEnter", "CursorMoved" }, {
    group = vim.api.nvim_create_augroup(self.augroup, { clear = false }),
    callback = function()
      if self.win ~= vim.api.nvim_get_current_win() then
        self:close_if_valid()
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = vim.api.nvim_create_augroup(self.augroup, { clear = false }),
    pattern = tostring(win),
    once = true,
    callback = function()
      self:close_if_valid()
    end,
  })
end

---@return boolean
function FloatWin:close_if_valid()
  if self.win and vim.api.nvim_win_is_valid(self.win) then
    vim.api.nvim_win_close(self.win, true)
    pcall(vim.api.nvim_del_augroup_by_name, self.augroup)
    return true
  end
  return false
end

return FloatWin
