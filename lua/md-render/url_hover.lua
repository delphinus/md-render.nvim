--- Show the full URL in a small floating window at the bottom-right of the
--- editor while the mouse hovers over a link in a md-render preview.
---
--- The same float says how to enlarge an image while the mouse or the cursor
--- is on one. The image itself cannot be highlighted: the terminal draws it
--- over the cells, so any color given to them stays hidden.

local M = {}

local DEBOUNCE_MS = 100
local WINBLEND = 15
local AUGROUP = "md_render_url_hover"

--- What the float says over an image that can be enlarged.
local IMAGE_HINT = "<CR> / click: zoom"

---@type table<integer, { buf: integer, ns: integer, get_placements?: fun(): MdRender.ImagePlacement[]? }>
local registered = {}

local state = {
  ---@type integer?
  hover_win = nil,
  ---@type integer?
  hover_buf = nil,
  ---@type string?
  current_url = nil,
  ---@type integer?
  current_win = nil,
  ---@type string?
  pending_url = nil,
  ---@type table?
  pending_token = nil,
}

local augroup_initialized = false

local function ensure_hover_buf()
  if state.hover_buf and vim.api.nvim_buf_is_valid(state.hover_buf) then return state.hover_buf end
  state.hover_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.hover_buf].bufhidden = "hide"
  return state.hover_buf
end

---@param url string
---@param max_width integer
---@return string
local function truncate_url(url, max_width)
  if max_width <= 0 then return "" end
  if vim.api.nvim_strwidth(url) <= max_width then return url end
  if max_width == 1 then return "…" end

  local result_width = 0
  local pieces = {}
  local len = vim.fn.strchars(url)
  for i = 0, len - 1 do
    local ch = vim.fn.strcharpart(url, i, 1)
    local w = vim.api.nvim_strwidth(ch)
    if result_width + w + 1 > max_width then break end
    pieces[#pieces + 1] = ch
    result_width = result_width + w
  end
  return table.concat(pieces) .. "…"
end

local function cancel_pending()
  state.pending_token = nil
  state.pending_url = nil
end

local function close_hover()
  if state.hover_win and vim.api.nvim_win_is_valid(state.hover_win) then
    pcall(vim.api.nvim_win_close, state.hover_win, true)
  end
  state.hover_win = nil
  state.current_url = nil
  state.current_win = nil
end

--- How many rows at the bottom of the editor are occupied by cmdline +
--- statusline. The hover is placed just above this band so it doesn't
--- overlap either.
---@return integer
local function bottom_reserved_rows()
  local rows = vim.o.cmdheight
  local ls = vim.o.laststatus
  if ls == 2 or ls == 3 then
    rows = rows + 1
  elseif ls == 1 and #vim.api.nvim_tabpage_list_wins(0) > 1 then
    rows = rows + 1
  end
  return rows
end

---@param url string
---@param source_win integer
local function show_hover(url, source_win)
  if state.current_url == url and state.current_win == source_win then return end

  local max_width = math.max(1, math.floor(vim.o.columns / 2))
  local display = truncate_url(url, max_width)
  local width = math.max(1, vim.api.nvim_strwidth(display))
  local row = math.max(0, vim.o.lines - bottom_reserved_rows() - 1)
  local col = math.max(0, vim.o.columns - width)

  if state.hover_win and vim.api.nvim_win_is_valid(state.hover_win) then
    local buf = vim.api.nvim_win_get_buf(state.hover_win)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { display })
    vim.api.nvim_win_set_config(state.hover_win, {
      relative = "editor",
      width = width,
      height = 1,
      row = row,
      col = col,
    })
  else
    local buf = ensure_hover_buf()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { display })
    state.hover_win = vim.api.nvim_open_win(buf, false, {
      relative = "editor",
      width = width,
      height = 1,
      row = row,
      col = col,
      style = "minimal",
      border = "none",
      focusable = false,
      zindex = 250,
      noautocmd = true,
    })
    vim.wo[state.hover_win].winblend = WINBLEND
    vim.wo[state.hover_win].winhighlight = "Normal:Comment,NormalFloat:Comment"
  end

  state.current_url = url
  state.current_win = source_win
end

---@param mouse { winid: integer, line: integer, column: integer }
---@param buf integer
---@param ns integer
---@return string?
local function url_at_mouse(mouse, buf, ns)
  if mouse.line < 1 or mouse.column < 1 then return nil end
  local line = mouse.line - 1
  local col = mouse.column - 1

  if not vim.api.nvim_buf_is_valid(buf) then return nil end
  local line_count = vim.api.nvim_buf_line_count(buf)
  if line >= line_count then return nil end

  local ok, marks = pcall(vim.api.nvim_buf_get_extmarks, buf, ns, { line, 0 }, { line + 1, 0 }, { details = true })
  if not ok then return nil end

  for _, mark in ipairs(marks) do
    local _, _, start_col, details = unpack(mark)
    if details and details.url then
      local end_col = details.end_col or (start_col + 1)
      if col >= start_col and col < end_col then return details.url end
    end
  end
  return nil
end

--- Whether the zoom float can show this image, which is what the hint offers.
---@param placement MdRender.ImagePlacement?
---@return boolean
local function zoomable(placement)
  return require("md-render.image_zoom").can_zoom(placement)
end

---@param mouse { winid: integer, line: integer, screencol: integer }
---@param entry { get_placements?: fun(): MdRender.ImagePlacement[]? }
---@return boolean
local function image_at_mouse(mouse, entry)
  if not entry.get_placements or mouse.line < 1 then return false end
  local display_utils = require "md-render.display_utils"
  local p = display_utils.image_at(entry.get_placements(), mouse.line - 1, display_utils.mouse_display_col(mouse))
  return zoomable(p)
end

--- Show the hint while the cursor is on an image in the current window, and
--- take down a hint that no longer applies. A URL hover is left alone.
local function update_cursor_hint()
  local win = vim.api.nvim_get_current_win()
  local entry = registered[win]
  local on_image = false
  if entry and entry.get_placements and not require("md-render.image_zoom").is_open() then
    local line = vim.api.nvim_win_get_cursor(win)[1] - 1
    local display_utils = require "md-render.display_utils"
    on_image = zoomable(display_utils.image_at(entry.get_placements(), line, vim.fn.virtcol "." - 1, true))
  end
  if on_image then
    show_hover(IMAGE_HINT, win)
  elseif state.current_url == IMAGE_HINT then
    close_hover()
  end
end

local function handle_mouse_move()
  local mouse = vim.fn.getmousepos()
  local entry = registered[mouse.winid]

  if not entry then
    cancel_pending()
    close_hover()
    update_cursor_hint()
    return
  end

  local url = url_at_mouse(mouse, entry.buf, entry.ns)
  if not url and image_at_mouse(mouse, entry) then url = IMAGE_HINT end

  if not url then
    cancel_pending()
    close_hover()
    update_cursor_hint()
    return
  end

  if state.current_url == url and state.current_win == mouse.winid then
    cancel_pending()
    return
  end

  if state.pending_url == url then return end

  local token = {}
  state.pending_token = token
  state.pending_url = url
  local source_win = mouse.winid

  vim.defer_fn(function()
    if state.pending_token ~= token then return end
    state.pending_token = nil
    state.pending_url = nil
    if not registered[source_win] then return end
    show_hover(url, source_win)
  end, DEBOUNCE_MS)
end

local function ensure_initialized()
  if augroup_initialized then return end
  augroup_initialized = true
  vim.o.mousemoveevent = true
  -- <MouseMove> is a keycode, not an autocmd event. The mapping below fires
  -- whenever 'mousemoveevent' is on and the mouse moves; the global handler
  -- checks the current mouse position against the registered windows.
  vim.keymap.set({ "n", "i", "v" }, "<MouseMove>", function()
    handle_mouse_move()
  end, { silent = true, desc = "md-render: URL hover" })
end

--- Start showing URL hovers for the given preview window.
---@param buf integer
---@param ns integer
---@param win integer
---@param get_placements? fun(): MdRender.ImagePlacement[]? the window's images, for the zoom hint
function M.attach(buf, ns, win, get_placements)
  ensure_initialized()
  registered[win] = { buf = buf, ns = ns, get_placements = get_placements }
  if get_placements then
    vim.api.nvim_create_autocmd({ "CursorMoved", "BufEnter", "WinLeave" }, {
      group = vim.api.nvim_create_augroup(AUGROUP, { clear = false }),
      buffer = buf,
      callback = function(ev)
        -- On WinLeave the window being left is still current; the hint is
        -- about to be stale, so take it down.
        if ev.event == "WinLeave" then
          if state.current_url == IMAGE_HINT and state.current_win == win then close_hover() end
          return
        end
        update_cursor_hint()
      end,
    })
  end
  vim.api.nvim_create_autocmd("WinClosed", {
    group = vim.api.nvim_create_augroup(AUGROUP, { clear = false }),
    pattern = tostring(win),
    once = true,
    callback = function()
      registered[win] = nil
      cancel_pending()
      if state.current_win == win then close_hover() end
    end,
  })
end

--- Exposed for tests.
function M._internal()
  return {
    state = state,
    registered = registered,
    truncate_url = truncate_url,
    url_at_mouse = url_at_mouse,
    handle_mouse_move = handle_mouse_move,
    show_hover = show_hover,
    close_hover = close_hover,
    update_cursor_hint = update_cursor_hint,
    IMAGE_HINT = IMAGE_HINT,
    bottom_reserved_rows = bottom_reserved_rows,
    DEBOUNCE_MS = DEBOUNCE_MS,
  }
end

return M
