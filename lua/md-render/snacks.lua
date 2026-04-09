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

--- Scroll the preview window to the rendered line matching the given source line.
---@param winid integer
---@param pos? snacks.picker.Pos
---@param source_line_map? integer[]
local function scroll_to_source_line(winid, pos, source_line_map)
  if not pos or not source_line_map then return end
  local lnum = pos[1]
  local target = #source_line_map
  for i, sl in ipairs(source_line_map) do
    if sl >= lnum then
      target = i
      break
    end
  end
  vim.schedule(function()
    if not vim.api.nvim_win_is_valid(winid) then return end
    local buf_lines = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(winid))
    target = math.max(1, math.min(target, buf_lines))
    local win_height = vim.api.nvim_win_get_height(winid)
    local top = math.max(0, target - 1 - math.floor(win_height / 2))
    vim.api.nvim_win_call(winid, function()
      vim.fn.winrestview { topline = top + 1 }
    end)
    vim.api.nvim_win_set_cursor(winid, { target, 0 })
  end)
end

--- Create a snacks.nvim picker preview function that renders Markdown via md-render.nvim.
--- For image/video files, displays them via Kitty graphics protocol.
--- For other non-Markdown files, falls back to snacks' default file previewer.
---
--- Usage:
---   Snacks.picker.files({ preview = require("md-render.snacks").preview() })
---
--- Or configure globally:
---   require("snacks").setup({
---     picker = { preview = require("md-render.snacks").preview() },
---   })
---
---@param opts? { namespace?: string }
---@return snacks.picker.preview
function M.preview(opts)
  opts = opts or {}
  local ns = vim.api.nvim_create_namespace(opts.namespace or "md_render_snacks")

  ---@type MdRender.ImageState?
  local image_state = nil
  local last_filepath = nil
  ---@type integer[]?
  local last_source_line_map = nil
  local cleanup_autocmd_id = nil

  local function cleanup_images()
    if image_state then
      require("md-render.display_utils").cleanup_images(image_state)
      image_state = nil
    end
  end

  local function ensure_win_cleanup(winid)
    if cleanup_autocmd_id then return end
    cleanup_autocmd_id = vim.api.nvim_create_autocmd("WinClosed", {
      pattern = tostring(winid),
      once = true,
      callback = function()
        cleanup_images()
        last_filepath = nil
        last_source_line_map = nil
        cleanup_autocmd_id = nil
      end,
    })
  end

  ---@param ctx snacks.picker.preview.ctx
  return function(ctx)
    local path = Snacks.picker.util.path(ctx.item)
    if not path then
      cleanup_images()
      last_filepath = nil
      last_source_line_map = nil
      return require("snacks.picker.preview").file(ctx)
    end

    local is_markdown = path:match "%.md$" or path:match "%.markdown$"
    local display_utils = require "md-render.display_utils"

    if not is_markdown then
      last_source_line_map = nil

      -- Try to display as image/video
      local img_content = build_image_content(path, ctx.win)
      if img_content then
        local file_changed = path ~= last_filepath
        if file_changed then
          cleanup_images()
          last_filepath = path
          ctx.preview:reset()
          ctx.preview:set_title(vim.fn.fnamemodify(path, ":t"))
          ctx.preview:minimal()
          vim.bo[ctx.buf].modifiable = true
          display_utils.apply_content_to_buffer(ctx.buf, ns, img_content)
          vim.bo[ctx.buf].modifiable = false
          ensure_win_cleanup(ctx.win)
          image_state = display_utils.setup_images(ctx.win, img_content, ns)
        end
        return
      end

      -- Fall back to snacks' default file previewer
      cleanup_images()
      last_filepath = nil
      return require("snacks.picker.preview").file(ctx)
    end

    -- Markdown rendering: only re-render on file change
    local file_changed = path ~= last_filepath
    if file_changed then
      cleanup_images()
      last_filepath = path

      ctx.preview:reset()
      ctx.preview:set_title(vim.fn.fnamemodify(path, ":t"))
      ctx.preview:minimal()

      local lines = vim.fn.readfile(path)
      if not lines or #lines == 0 then return end

      require("md-render").setup_highlights()
      local preview_mod = require "md-render.preview"
      local max_width = math.max(40, vim.api.nvim_win_get_width(ctx.win) - 4)
      local content = preview_mod.build_content(lines, { max_width = max_width })
      last_source_line_map = content.source_line_map

      vim.bo[ctx.buf].modifiable = true
      display_utils.apply_content_to_buffer(ctx.buf, ns, content)
      vim.bo[ctx.buf].modifiable = false

      ensure_win_cleanup(ctx.win)
      image_state = display_utils.setup_images(ctx.win, content, ns, {
        buf = ctx.buf,
        build_content = function()
          return preview_mod.build_content(lines, { max_width = max_width })
        end,
      })
    end

    -- Scroll to matched source line (always, even for same file with different position)
    scroll_to_source_line(ctx.win, ctx.item.pos, last_source_line_map)
  end
end

return M
