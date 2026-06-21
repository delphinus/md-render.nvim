-- Telescope extension that wraps any builtin picker with the md-render previewer.
--
-- Usage:
--   :Telescope md_render find_files
--   :Telescope md_render live_grep cwd=~/notes
--   :Telescope md_render grep_string search=TODO
--
-- All arguments are passed through to the underlying telescope.builtin picker.

local previewer_cache = nil

local function get_previewer()
  if not previewer_cache then previewer_cache = require("md-render.telescope").previewer() end
  return previewer_cache
end

local exports = setmetatable({}, {
  __index = function(_, picker_name)
    return function(opts)
      opts = opts or {}
      opts.previewer = get_previewer()
      local builtin = require "telescope.builtin"
      local picker_fn = builtin[picker_name]
      if not picker_fn then
        vim.notify("md_render: unknown picker '" .. picker_name .. "'", vim.log.levels.ERROR)
        return
      end
      picker_fn(opts)
    end
  end,
})

return require("telescope").register_extension {
  exports = exports,
}
