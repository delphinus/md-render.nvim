--- Show the full URL in a small floating window at the bottom-right of the
--- editor while the mouse hovers over a link in a md-render preview.

local M = {}

local DEBOUNCE_MS = 100
local WINBLEND = 15
local AUGROUP = "md_render_url_hover"

---@type table<integer, { buf: integer, ns: integer }>
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
  if state.hover_buf and vim.api.nvim_buf_is_valid(state.hover_buf) then
    return state.hover_buf
  end
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
  if state.current_url == url and state.current_win == source_win then
    return
  end

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

  local ok, marks = pcall(
    vim.api.nvim_buf_get_extmarks,
    buf, ns, { line, 0 }, { line + 1, 0 }, { details = true }
  )
  if not ok then return nil end

  for _, mark in ipairs(marks) do
    local _, _, start_col, details = unpack(mark)
    if details and details.url then
      local end_col = details.end_col or (start_col + 1)
      if col >= start_col and col < end_col then
        return details.url
      end
    end
  end
  return nil
end

local function handle_mouse_move()
  local mouse = vim.fn.getmousepos()
  local entry = registered[mouse.winid]

  if not entry then
    cancel_pending()
    close_hover()
    return
  end

  local url = url_at_mouse(mouse, entry.buf, entry.ns)

  if not url then
    cancel_pending()
    close_hover()
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
function M.attach(buf, ns, win)
  ensure_initialized()
  registered[win] = { buf = buf, ns = ns }
  vim.api.nvim_create_autocmd("WinClosed", {
    group = vim.api.nvim_create_augroup(AUGROUP, { clear = false }),
    pattern = tostring(win),
    once = true,
    callback = function()
      registered[win] = nil
      cancel_pending()
      if state.current_win == win then
        close_hover()
      end
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
    bottom_reserved_rows = bottom_reserved_rows,
    DEBOUNCE_MS = DEBOUNCE_MS,
  }
end

return M
