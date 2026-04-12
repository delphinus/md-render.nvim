local M = {}

--- Build a minimal content object to display a single image/video file.
---@param filepath string
---@param winid integer
---@return MdRender.Content?
local function build_image_content(filepath, winid)
  local image = require "md-render.image"
  if not image.supports_kitty() then return nil end

  local img_w, img_h = image.image_dimensions(filepath)
  local is_video = not img_w and (image.is_video_file(filepath) or image.is_video_content(filepath))

  if not img_w and not is_video then return nil end

  local win_width = vim.api.nvim_win_get_width(winid)
  local win_height = vim.api.nvim_win_get_height(winid)
  local max_cols = math.max(10, win_width - 2)
  local max_rows = math.max(5, win_height - 2)
  local cols, rows
  if img_w and img_h then
    cols, rows = image.calc_display_size(img_w, img_h, max_cols, max_rows)
  else
    cols = math.floor(max_cols * 0.8)
    rows = math.min(15, max_rows)
  end

  local filename = filepath:match "([^/]+)$" or filepath
  local header = "  " .. filename
  if img_w and img_h then
    header = header .. "  (" .. img_w .. "×" .. img_h .. ")"
  end

  local lines = { header }
  for _ = 1, rows do
    table.insert(lines, "")
  end

  return {
    lines = lines,
    highlights = { { line = 0, groups = { { col = 0, end_col = #header, hl = "Comment" } } } },
    link_metadata = {},
    image_placements = { {
      path = filepath,
      line = 1,
      col = math.max(0, math.floor((win_width - cols) / 2)),
      rows = rows,
      cols = cols,
      img_w = img_w,
      img_h = img_h,
      video = is_video,
    } },
  }
end

--- Create a telescope buffer previewer that renders Markdown via md-render.nvim.
--- For image/video files, displays them via Kitty graphics protocol.
--- For other non-Markdown files, falls back to telescope's default previewer.
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

      local is_markdown = filepath:match "%.md$" or filepath:match "%.markdown$"
      local display_utils = require "md-render.display_utils"
      local bufnr = self.state.bufnr
      local winid = self.state.winid

      if not is_markdown then
        -- Try to display as image/video
        local img_content = build_image_content(filepath, winid)
        if img_content then
          local file_changed = filepath ~= last_filepath
          if file_changed then
            if image_state then
              display_utils.cleanup_images(image_state)
              image_state = nil
            end
            last_filepath = filepath
          end
          vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, img_content.lines)
          vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
          display_utils.apply_content_to_buffer(bufnr, ns, img_content)
          if file_changed then
            image_state = display_utils.setup_images(winid, img_content, ns)
          end
          return
        end

        -- Fall back to telescope's default file previewer
        if image_state then
          display_utils.cleanup_images(image_state)
          image_state = nil
        end
        last_filepath = nil
        local conf = require("telescope.config").values
        conf.buffer_previewer_maker(filepath, bufnr, {
          bufname = self.state.bufname,
          winid = winid,
          callback = function(buf)
            if entry.lnum then
              pcall(vim.api.nvim_buf_call, buf, function()
                pcall(vim.api.nvim_win_set_cursor, 0, { entry.lnum, 0 })
                vim.cmd "normal! zz"
              end)
            end
          end,
        })
        return
      end

      -- Markdown rendering
      local file_changed = filepath ~= last_filepath
      if file_changed then
        if image_state then
          display_utils.cleanup_images(image_state)
          image_state = nil
        end
        last_filepath = filepath
      end

      -- Limit source lines to prevent UI freeze on very large Markdown files.
      -- The telescope preview window only shows a few dozen lines, so
      -- rendering the entire document is wasteful and can block the UI.
      local MAX_PREVIEW_LINES = 500
      local lines = vim.fn.readfile(filepath, "", MAX_PREVIEW_LINES)
      if not lines or #lines == 0 then return end

      -- If the target line is beyond the rendered range, fall back to
      -- telescope's default previewer (raw markdown with line navigation).
      if entry.lnum and entry.lnum > MAX_PREVIEW_LINES then
        if image_state then
          display_utils.cleanup_images(image_state)
          image_state = nil
        end
        last_filepath = nil
        local conf = require("telescope.config").values
        conf.buffer_previewer_maker(filepath, bufnr, {
          bufname = self.state.bufname,
          winid = winid,
          callback = function(buf)
            pcall(vim.api.nvim_buf_call, buf, function()
              pcall(vim.api.nvim_win_set_cursor, 0, { entry.lnum, 0 })
              vim.cmd "normal! zz"
            end)
          end,
        })
        return
      end

      require("md-render").setup_highlights()
      local preview = require "md-render.preview"
      local max_width = math.max(40, vim.api.nvim_win_get_width(winid) - 4)
      local content = preview.build_content(lines, { max_width = max_width })
      vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
      display_utils.apply_content_to_buffer(bufnr, ns, content)

      -- Scroll to the matched source line
      if entry.lnum and content.source_line_map then
        local target = #content.source_line_map
        for i, sl in ipairs(content.source_line_map) do
          if sl >= entry.lnum then
            target = i
            break
          end
        end
        vim.schedule(function()
          if not vim.api.nvim_win_is_valid(winid) then return end
          local win_buf = vim.api.nvim_win_get_buf(winid)
          local buf_lines = vim.api.nvim_buf_line_count(win_buf)
          target = math.max(1, math.min(target, buf_lines))
          local win_height = vim.api.nvim_win_get_height(winid)
          local top = math.max(0, target - 1 - math.floor(win_height / 2))
          vim.api.nvim_win_call(winid, function()
            vim.fn.winrestview { topline = top + 1 }
          end)
          vim.api.nvim_win_set_cursor(winid, { target, 0 })
        end)
      end

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
