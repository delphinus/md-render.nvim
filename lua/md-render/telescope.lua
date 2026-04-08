local M = {}

--- Create a telescope buffer previewer that renders Markdown via md-render.nvim
---@param opts? { namespace?: string }
---@return table previewer A telescope-compatible buffer previewer
function M.previewer(opts)
  opts = opts or {}
  local previewers = require "telescope.previewers"
  local ns = vim.api.nvim_create_namespace(opts.namespace or "md_render_telescope")

  ---@type MdRender.ImageState?
  local image_state = nil
  local last_filepath = nil

  return previewers.new_buffer_previewer {
    title = "Markdown Preview",
    define_preview = function(self, entry)
      local filepath = entry.path or entry.filename
      if not filepath then return end

      local file_changed = filepath ~= last_filepath
      local display_utils = require "md-render.display_utils"

      -- Different file: clean up previous images
      if file_changed then
        if image_state then
          display_utils.cleanup_images(image_state)
          image_state = nil
        end
        last_filepath = filepath
      end

      local lines = vim.fn.readfile(filepath)
      if not lines or #lines == 0 then return end

      require("md-render").setup_highlights()
      local preview = require "md-render.preview"
      local bufnr = self.state.bufnr
      local winid = self.state.winid
      local max_width = math.max(40, vim.api.nvim_win_get_width(winid) - 4)
      local content = preview.build_content(lines, { max_width = max_width })
      vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
      display_utils.apply_content_to_buffer(bufnr, ns, content)

      -- Only set up images when the file changes
      if file_changed then
        image_state = display_utils.setup_images(winid, content, ns, {
          buf = bufnr,
          build_content = function()
            return preview.build_content(lines, { max_width = max_width })
          end,
        })
      end
    end,
    teardown = function()
      if image_state then
        require("md-render.display_utils").cleanup_images(image_state)
        image_state = nil
      end
      last_filepath = nil
    end,
  }
end

return M
