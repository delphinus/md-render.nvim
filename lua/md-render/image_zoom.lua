--- Show one image, video or diagram as large as the editor allows, in a float
--- over everything else. Opened with <CR> or a click on the image; closed with
--- q, <Esc>, <CR> or a click.
---
--- The document fits every image into its width and at most 25 rows, so a
--- wide diagram ends up with text too small to read. The float drops both
--- limits and enlarges the image to fill the editor. A Mermaid diagram is
--- drawn again at a larger scale rather than blown up, so it stays sharp.

local M = {}

local NS = vim.api.nvim_create_namespace "md_render_image_zoom"
local AUGROUP = "md_render_image_zoom"

--- mmdc's `-s` grows the PNG with the square of the scale; past this the file
--- is large and slow to produce for no visible gain on any real screen.
local MAX_MERMAID_SCALE = 8

M.CLOSE_KEYS = { "q", "<Esc>", "<CR>", "<C-c>" }

---@class MdRender.ZoomView
---@field win integer
---@field buf integer
---@field state MdRender.ImageState?
---@field width integer
---@field height integer

---@type MdRender.ZoomView?
local current = nil

--- Rows at the bottom of the editor the float leaves alone: the command line,
--- and the statusline when there is one.
---@return integer
local function bottom_rows()
  local rows = vim.o.cmdheight
  if vim.o.laststatus >= 2 or (vim.o.laststatus == 1 and #vim.api.nvim_tabpage_list_wins(0) > 1) then
    rows = rows + 1
  end
  return rows
end

--- The text area of the zoom float: the whole editor above the statusline,
--- less the border. A margin would let the text underneath show at the edges.
---@return integer width, integer height
local function zoom_area()
  local width = math.max(1, vim.o.columns - 2)
  local height = math.max(1, vim.o.lines - bottom_rows() - 2)
  return width, height
end

M._zoom_area = zoom_area

--- The scale to draw a Mermaid diagram at so that, fitted into the zoom area,
--- it needs no enlarging. `img_w`/`img_h` are its size at the default scale.
---@param img_w integer
---@param img_h integer
---@param width integer zoom area in cells
---@param height integer
---@param cell { cell_w: number, cell_h: number }?
---@return number
local function mermaid_scale(img_w, img_h, width, height, cell)
  local image = require "md-render.image"
  local default = image.MERMAID_DEFAULT_SCALE
  if not cell then return default end
  local ratio = math.min(width * cell.cell_w / img_w, height * cell.cell_h / img_h)
  return math.max(default, math.min(MAX_MERMAID_SCALE, math.ceil(default * ratio)))
end

M._mermaid_scale = mermaid_scale

--- The size of a file in pixels, read from the file itself.
---@param path string
---@param video boolean?
---@return integer? w, integer? h
local function dimensions(path, video)
  local image = require "md-render.image"
  if video or image.is_video_content(path) then return image.video_dimensions(path) end
  return image.image_dimensions(path)
end

--- A content table holding nothing but one image, centered in the zoom area.
---@param view MdRender.ZoomView
---@param path string
---@param img_w integer
---@param img_h integer
---@param video boolean?
---@return MdRender.Content
local function content_for(view, path, img_w, img_h, video)
  local image = require "md-render.image"
  local cols, rows = image.calc_display_size(img_w, img_h, view.width, view.height, true)
  return {
    lines = {},
    image_placements = {
      {
        path = path,
        line = math.floor((view.height - rows) / 2),
        col = math.floor((view.width - cols) / 2),
        rows = rows,
        cols = cols,
        -- Set up front so the image is sized to fill the float rather than
        -- shrunk back to the file's own size when it is shown.
        img_w = img_w,
        img_h = img_h,
        video = video,
      },
    },
  }
end

--- Put `path` in the zoom float, replacing whatever it showed before.
---@param view MdRender.ZoomView
---@param path string
---@param video boolean?
local function show(view, path, video)
  if current ~= view or not vim.api.nvim_win_is_valid(view.win) then return end
  local img_w, img_h = dimensions(path, video)
  if not (img_w and img_h) then return end
  local display_utils = require "md-render.display_utils"
  local content = content_for(view, path, img_w, img_h, video)
  -- The placeholder text, if any, sits under the image; clear it.
  vim.bo[view.buf].modifiable = true
  vim.api.nvim_buf_set_lines(view.buf, 0, -1, false, vim.split(string.rep("\n", view.height - 1), "\n"))
  vim.bo[view.buf].modifiable = false
  if view.state then
    view.state = display_utils.update_images(view.state, view.win, content)
  else
    view.state = display_utils.setup_images(view.win, content, NS)
  end
end

--- Write a one-line message in the middle of the zoom float.
---@param view MdRender.ZoomView
---@param msg string
local function show_message(view, msg)
  local lines = vim.split(string.rep("\n", view.height - 1), "\n")
  local pad = math.max(0, math.floor((view.width - vim.api.nvim_strwidth(msg)) / 2))
  lines[math.floor(view.height / 2) + 1] = string.rep(" ", pad) .. msg
  vim.bo[view.buf].modifiable = true
  vim.api.nvim_buf_set_lines(view.buf, 0, -1, false, lines)
  vim.bo[view.buf].modifiable = false
end

--- Show a Mermaid diagram: the PNG the document already has right away, then
--- the same diagram drawn at the scale the float needs once mmdc is done.
---@param view MdRender.ZoomView
---@param source string
---@param base_path string?
local function show_mermaid(view, source, base_path)
  local image = require "md-render.image"

  ---@param path string
  local function sharpen(path)
    local w, h = image.image_dimensions(path)
    if not (w and h) then return end
    local scale = mermaid_scale(w, h, view.width, view.height, image.get_cell_size())
    if scale <= image.MERMAID_DEFAULT_SCALE then return end
    image.render_mermaid_async(source, function(hi_path)
      vim.schedule(function()
        if hi_path then show(view, hi_path) end
      end)
    end, scale)
  end

  if base_path then
    show(view, base_path)
    sharpen(base_path)
    return
  end
  show_message(view, "Rendering mermaid diagram...")
  image.render_mermaid_async(source, function(path)
    vim.schedule(function()
      if not path then return end
      show(view, path)
      sharpen(path)
    end)
  end)
end

--- Close the zoom float, if one is open.
function M.close()
  local view = current
  if not view then return end
  if vim.api.nvim_win_is_valid(view.win) then pcall(vim.api.nvim_win_close, view.win, true) end
end

--- Whether a zoom float is open.
---@return boolean
function M.is_open()
  return current ~= nil and vim.api.nvim_win_is_valid(current.win)
end

--- Whether `placement` has something the zoom float can show.
---@param placement MdRender.ImagePlacement?
---@return boolean
function M.can_zoom(placement)
  if not placement then return false end
  return placement.path ~= nil or placement.mermaid_text ~= nil
end

--- Open the zoom float on `placement`.
---@param placement MdRender.ImagePlacement
---@return boolean opened
function M.open(placement)
  local image = require "md-render.image"
  local display_utils = require "md-render.display_utils"
  if not image.supports_kitty() or not M.can_zoom(placement) then return false end

  M.close()

  local width, height = zoom_area()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  local title = placement.title and placement.title ~= "" and placement.title or "Image"
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = 0,
    col = 0,
    style = "minimal",
    border = "rounded",
    title = " " .. title .. " ",
    title_pos = "center",
    footer = " q / <Esc> / <CR> / click: close ",
    footer_pos = "right",
    -- Above the document's own float (50) so it covers it.
    zindex = 60,
  })
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = false

  -- The cursor would sit in the float's top-left corner, over nothing. Hide
  -- it with a highlight that blends away entirely, and restore it on close.
  local saved_guicursor = vim.o.guicursor
  vim.api.nvim_set_hl(0, "MdRenderZoomCursor", { blend = 100, nocombine = true })
  vim.o.guicursor = "a:MdRenderZoomCursor"

  ---@type MdRender.ZoomView
  local view = { win = win, buf = buf, width = width, height = height }
  current = view

  -- The other windows' images are drawn by the terminal on top of every cell,
  -- this float's included. Take them down while the float is open.
  display_utils.suspend_images()

  local opts = { buffer = buf, noremap = true, silent = true, nowait = true }
  for _, key in ipairs(M.CLOSE_KEYS) do
    vim.keymap.set("n", key, M.close, opts)
  end
  vim.keymap.set("n", "<LeftRelease>", M.close, opts)

  local group = vim.api.nvim_create_augroup(AUGROUP, { clear = true })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    pattern = tostring(win),
    once = true,
    callback = function()
      vim.o.guicursor = saved_guicursor
      if current == view then current = nil end
      pcall(vim.api.nvim_del_augroup_by_name, AUGROUP)
      -- Let the images' own WinClosed handler release this float's images
      -- first, then put the others back — unless this float was closed to
      -- open another one on a different image.
      vim.schedule(function()
        if not M.is_open() then display_utils.resume_images() end
      end)
    end,
  })
  -- The float is sized for the editor it opened in, and is not much use
  -- behind another window: close it rather than leave it stale.
  vim.api.nvim_create_autocmd({ "VimResized", "WinLeave" }, {
    group = group,
    callback = function(ev)
      if ev.event == "WinLeave" and vim.api.nvim_get_current_win() ~= win then return end
      vim.schedule(M.close)
    end,
  })

  if placement.mermaid_text then
    show_mermaid(view, placement.mermaid_text, placement.path)
  else
    show(view, placement.path, placement.video)
  end
  return true
end

return M
