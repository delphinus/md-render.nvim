--- Kitty text sizing protocol (OSC 66) support for md-render.nvim.
---
--- Draws selected buffer lines at an integer multiple of the base font size by
--- writing OSC 66 sequences straight to the terminal, the same way
--- `md-render.image` writes Kitty graphics escapes.
---
---     OSC 66 ; s=<scale> ; <text> ST
---
--- Unlike graphics placements, OSC 66 text lives in the terminal's *text*
--- layer, so Neovim destroys it as soon as it repaints those cells. There is no
--- equivalent of `a=p` (re-place an already transmitted image) either: the whole
--- string has to be sent again. This module therefore keeps the plain-size text
--- in the buffer and only paints over it, so that every repaint degrades to the
--- normal heading instead of to a blank line, and re-paints on a 50 ms debounce
--- after scroll / cursor movement.
---
--- Support is gated on a positive XTVERSION answer from Kitty >= 0.40. This is
--- deliberately strict: WezTerm swallows an OSC 66 sequence *including its
--- payload text*, so a wrong guess deletes content rather than degrading to
--- unscaled text.

local M = {}

-- ============================================================================
-- Configuration
-- ============================================================================

--- Heading level → integer scale (`s=`). Fixed, not user-configurable: `s=2`
--- doubles the width as well as the height, so anything deeper than `##` stops
--- fitting into a preview window, and a larger scale stops fitting at all.
local LEVEL_SCALES = { [1] = 2, [2] = 2 }

---@class MdRender.TextSize.Config
---@field enabled boolean master switch (default false — opt-in)

---@type MdRender.TextSize.Config
local config = {
  enabled = false,
}

--- Configure text scaling.
---@param opts? MdRender.TextSize.Config
function M.setup(opts)
  opts = opts or {}
  if opts.enabled ~= nil then config.enabled = opts.enabled end
end

---@return MdRender.TextSize.Config
function M.config()
  return config
end

-- ============================================================================
-- Terminal support detection
-- ============================================================================

local _supported = nil

--- How long to wait for the terminal to identify itself.
---
--- Only paid in full by a terminal that never answers; a reply short-circuits
--- the wait. Kitty answers in ~120 ms on a warm desktop but was measured at
--- ~260 ms inside a container under Xvfb, so a tight bound silently disables
--- the feature on slow machines — which is indistinguishable, from the user's
--- side, from the terminal not supporting it.
local PROBE_TIMEOUT_MS = 1000

--- Ask the terminal to identify itself (XTVERSION) and accept only Kitty >= 0.40.
--- Returns nil when the terminal stays silent, which is treated as "no".
---
--- Implemented directly on `TermResponse` + `nvim_ui_send` rather than through
--- `vim.tty.request`, which does not exist before Neovim 0.13 — on 0.12
--- `vim.tty` only carries `query`. Depending on it made the whole feature a
--- silent no-op on the oldest Neovim this plugin supports.
---@return boolean?
local function probe_xtversion()
  if type(vim.api.nvim_ui_send) ~= "function" then return nil end

  local result = nil
  local ok_au, id = pcall(vim.api.nvim_create_autocmd, "TermResponse", {
    nested = true,
    callback = function(ev)
      -- `ev.data` is a table carrying `sequence` on 0.12 and 0.13; accept a
      -- bare string too in case that ever changes back.
      local resp = ev.data
      if type(resp) == "table" then resp = resp.sequence end
      if type(resp) ~= "string" then return end

      local major, minor = resp:match "kitty%((%d+)%.(%d+)"
      if major then
        result = (tonumber(major) > 0) or (tonumber(minor) >= 40)
        return true
      end
      -- Some other terminal answered XTVERSION. Do not retry, do not guess.
      if resp:match "^\27P>|" then
        result = false
        return true
      end
      -- Anything else is an unrelated response (cursor position, colours, the
      -- primary device attributes that follow); keep listening.
    end,
  })
  if not ok_au then return nil end

  vim.api.nvim_ui_send "\27[>0q"
  vim.wait(PROBE_TIMEOUT_MS, function()
    return result ~= nil
  end, 10)
  pcall(vim.api.nvim_del_autocmd, id)
  return result
end

--- True when the host terminal implements the text sizing protocol.
---@return boolean
function M.supports()
  if _supported ~= nil then return _supported end
  -- The TUI must be able to receive raw bytes at all.
  if type(vim.api.nvim_ui_send) ~= "function" then
    _supported = false
    return false
  end
  _supported = probe_xtversion() == true
  return _supported
end

--- Clear the cached probe result (for tests, or after `:restart`).
function M.reset_cache()
  _supported = nil
end

--- Integer scale to use for a heading level, or nil when it must stay plain.
---
--- The terminal check belongs here, not only at paint time: the extra rows a
--- scaled heading needs are reserved while the content is built, so a terminal
--- that can never paint them must not get them reserved either.
---@param level integer 1-6
---@return integer?
function M.scale_for(level)
  if not config.enabled then return nil end
  local scale = LEVEL_SCALES[level]
  if not scale then return nil end
  if not M.supports() then return nil end
  return scale
end

-- ============================================================================
-- SGR for a highlight group
-- ============================================================================

local _sgr_cache = {}

--- Resolve a highlight group to an SGR prefix. OSC 66 text bypasses Neovim's
--- own cell attributes, so fg/bg have to be re-stated explicitly — including
--- the background, or the scaled block would show the terminal's default
--- background instead of the float's.
---@param hl_name string
---@return string
local function sgr_for(hl_name)
  local cached = _sgr_cache[hl_name]
  if cached then return cached end

  local hl = vim.api.nvim_get_hl(0, { name = hl_name, link = false })
  local bg = hl.bg
  if not bg then
    local float = vim.api.nvim_get_hl(0, { name = "NormalFloat", link = false })
    bg = float.bg or (vim.api.nvim_get_hl(0, { name = "Normal", link = false }) or {}).bg
  end

  local parts = { "\x1b[0m" }
  if hl.bold then table.insert(parts, "\x1b[1m") end
  if hl.italic then table.insert(parts, "\x1b[3m") end
  if hl.fg then
    table.insert(
      parts,
      string.format(
        "\x1b[38;2;%d;%d;%dm",
        bit.rshift(hl.fg, 16),
        bit.band(bit.rshift(hl.fg, 8), 0xFF),
        bit.band(hl.fg, 0xFF)
      )
    )
  end
  if bg then
    table.insert(
      parts,
      string.format("\x1b[48;2;%d;%d;%dm", bit.rshift(bg, 16), bit.band(bit.rshift(bg, 8), 0xFF), bit.band(bg, 0xFF))
    )
  end

  local sgr = table.concat(parts)
  _sgr_cache[hl_name] = sgr
  return sgr
end

--- Drop cached SGR strings (call on ColorScheme).
function M.reset_sgr_cache()
  _sgr_cache = {}
end

-- ============================================================================
-- Drawing
-- ============================================================================

---@class MdRender.TextPlacement
---@field line integer 0-indexed buffer line the scaled text is painted over
---@field col integer 0-indexed byte column where the scaled text starts
---@field text string text to draw (already includes the heading icon)
---@field scale integer integer scale passed as `s=`
---@field hl string highlight group the SGR prefix is derived from

---@class MdRender.TextSizeState
---@field placements MdRender.TextPlacement[]
---@field win integer
---@field redraw_timer any?
---@field autocmd_ids integer[]
---@field augroup integer?
---@field last_layout string? screen positions of the previous paint
---@field last_drawn integer? how many placements the previous paint drew
---@field last_event_at integer? loop time of the last repaint request

--- Force the TUI to physically repaint the screen, erasing any scaled text
--- still on it.
---
--- `:mode` is the only thing that does this. Neither `nvim__redraw` (with
--- `valid = false`, with or without a window/range) nor `:redraw!` works,
--- because our writes never went through Neovim: it recomputes a grid that
--- matches its shadow copy, diffs to nothing, and sends nothing. Writing
--- spaces ourselves is no good either — the cells would go blank and Neovim,
--- still believing it had already drawn the heading there, would never restore
--- it. `:mode` clears and re-sends the whole screen, which is heavy, so callers
--- must only reach for it when the layout actually moved.
local function invalidate()
  vim.cmd "mode"
end

--- Screen bounds (1-indexed, inclusive) of a window's text area.
---
--- `wininfo.wincol` / `wininfo.winrow` are the window *frame*, so for a
--- bordered float they point at the border, one cell outside the text — using
--- them directly makes the right and bottom edges one cell too small and
--- rejects headings that do in fact fit. Derive the area the way
--- `md-render.image.put_image` does instead: window position plus border,
--- gutter and winbar.
---@param win integer
---@return integer? left
---@return integer? right
---@return integer? top
---@return integer? bottom
local function text_area(win)
  local wininfo = vim.fn.getwininfo(win)[1]
  if not wininfo then return nil end

  local border_left, border_top = 0, 0
  local ok_cfg, cfg = pcall(vim.api.nvim_win_get_config, win)
  if ok_cfg and cfg.border then
    local border = cfg.border
    if type(border) == "table" then
      local left_char = border[8] -- 8th element = left border char
      if type(left_char) == "table" then left_char = left_char[1] end
      if left_char and left_char ~= "" then border_left = vim.api.nvim_strwidth(left_char) end
      local top_char = border[2] -- 2nd element = top border char
      if type(top_char) == "table" then top_char = top_char[1] end
      if top_char and top_char ~= "" then border_top = 1 end
    elseif border ~= "none" and border ~= "" then
      border_left = 1
      border_top = 1
    end
  end

  local winbar = 0
  local ok_wb, wb = pcall(function()
    return vim.wo[win].winbar
  end)
  if ok_wb and wb and wb ~= "" then winbar = 1 end

  local textoff = wininfo.textoff or 0
  local left = vim.api.nvim_win_get_position(win)[2] + border_left + textoff + 1
  local right = left + (vim.api.nvim_win_get_width(win) - textoff) - 1
  -- `wininfo.winrow` covers the winbar when there is one, and `wininfo.height`
  -- excludes it.
  local top = wininfo.winrow + border_top + winbar
  return left, right, top, top + wininfo.height - 1
end

--- Compute where every placement would be drawn right now.
---@param state MdRender.TextSizeState
---@return { p: MdRender.TextPlacement, row: integer, col: integer }[]
local function visible_placements(state)
  local win = state.win
  if not vim.api.nvim_win_is_valid(win) then return {} end
  local left, right, top, bottom = text_area(win)
  if not left then return {} end
  local buf = vim.api.nvim_win_get_buf(win)

  local out = {}
  for _, p in ipairs(state.placements) do
    -- Guard against a layout that moved without us being told. Placements are
    -- anchored to rendered line numbers, and anything that rebuilds the content
    -- (an image finishing its download and changing height, a fold, a live
    -- update) shifts every line below it. Painting a stale placement would put
    -- a heading somewhere it does not belong, which is far worse than not
    -- scaling it, so verify the text is still where the placement says before
    -- drawing. A skipped placement changes the layout key, which triggers the
    -- cleanup path and lets the next paint recover.
    local line = vim.api.nvim_buf_get_lines(buf, p.line, p.line + 1, false)[1]
    local anchored = line ~= nil and line:sub(p.col + 1, p.col + #p.text) == p.text

    local pos = anchored and vim.fn.screenpos(win, p.line + 1, p.col + 1) or { row = 0 }
    -- row 0 = the line is not currently displayed (scrolled off or folded).
    if pos.row and pos.row > 0 then
      local width = vim.api.nvim_strwidth(p.text) * p.scale
      local fits_vertically = pos.row >= top and pos.row + p.scale - 1 <= bottom
      local fits_horizontally = pos.col >= left and pos.col + width - 1 <= right
      -- Partially visible placements are skipped rather than clipped: the
      -- plain-size text underneath stays on screen, which is the graceful
      -- fallback. OSC 66 has no source-rectangle crop like graphics do.
      if fits_vertically and fits_horizontally then table.insert(out, { p = p, row = pos.row, col = pos.col }) end
    end
  end
  return out
end

--- Identify a layout so two paints can be compared. Only the screen positions
--- matter: same positions means whatever we drew last time is still where it
--- belongs, so the stale-glyph cleanup can be skipped.
---@param drawn { p: MdRender.TextPlacement, row: integer, col: integer }[]
---@return string
local function layout_key(drawn)
  local parts = {}
  for _, d in ipairs(drawn) do
    table.insert(parts, string.format("%d:%d:%d", d.row, d.col, d.p.line))
  end
  return table.concat(parts, ";")
end

--- Repaint counters, for measuring how costly a given navigation pattern is.
--- `invalidations` is the one that matters: each is a full-screen repaint.
M._stats = { paints = 0, invalidations = 0, skipped = 0 }

--- Paint all visible placements now.
---
--- When the layout moved since the last paint, the screen is invalidated first.
--- Neovim's shadow grid does not know we ever wrote to those cells, and a
--- scaled run is twice as wide as the plain text Neovim thinks is there, so the
--- right-hand half of the old run survives a scroll and shows through as
--- garbage next to the new one.
---
--- That invalidation is a full-screen repaint, so the clear, Neovim's repaint
--- and our own writes are bracketed in synchronized output (DEC 2026, the same
--- mechanism `md-render.image` uses for batched placements). The terminal then
--- presents all three as a single frame instead of showing the cleared screen
--- and the plain-size heading in between.
---@param state MdRender.TextSizeState
function M.paint(state)
  if not state or not M.supports() then return end

  local drawn = visible_placements(state)
  local key = layout_key(drawn)
  local moved = key ~= state.last_layout
  if not moved and #drawn == 0 then
    M._stats.skipped = M._stats.skipped + 1
    return
  end

  -- Only worth cleaning up after a paint that actually drew something; there
  -- can be no stale glyphs otherwise.
  local cleanup = moved and (state.last_drawn or 0) > 0

  if cleanup then vim.api.nvim_ui_send "\x1b[?2026h" end
  local ok, err = pcall(function()
    if cleanup then
      M._stats.invalidations = M._stats.invalidations + 1
      invalidate()
      -- Positions can shift while Neovim repaints, so recompute afterwards.
      drawn = visible_placements(state)
    end
    if moved then state.last_layout = layout_key(drawn) end
    state.last_drawn = #drawn
    if #drawn == 0 then return end

    local out = {}
    for _, d in ipairs(drawn) do
      table.insert(out, string.format("\x1b[%d;%dH", d.row, d.col))
      table.insert(out, sgr_for(d.p.hl))
      table.insert(out, string.format("\x1b]66;s=%d;%s\x1b\\", d.p.scale, d.p.text))
    end
    -- DECSC/DECRC rather than CSI s/u: the cursor *and* the pending SGR state
    -- have to survive, since we change colors in between.
    vim.api.nvim_ui_send("\x1b7" .. table.concat(out) .. "\x1b[0m\x1b8")
    M._stats.paints = M._stats.paints + 1
  end)
  -- Never leave synchronized output open: the terminal would freeze the frame
  -- until its own timeout.
  if cleanup then vim.api.nvim_ui_send "\x1b[?2026l" end
  if not ok then error(err) end
end

--- Repaint delay for an isolated movement. Matches the 50 ms the image redraw
--- uses, so both land in the same frame after a single scroll.
local SETTLED_MS = 50
--- Repaint delay while events keep arriving (a held `<C-e>`, a mouse wheel
--- spin). Each layout change costs a full-screen repaint, so waiting for the
--- scroll to stop turns a burst into one repaint instead of one per step. The
--- headings stay plain-size while scrolling, which reads as scrolling normally
--- rather than as strobing.
local BURST_MS = 180
--- Two events closer together than this count as one burst.
local BURST_WINDOW_MS = 130

--- Schedule a debounced repaint, backing off while a scroll is in flight.
---@param state MdRender.TextSizeState
local function schedule_paint(state)
  local now = vim.uv.now()
  local streaming = state.last_event_at and (now - state.last_event_at) < BURST_WINDOW_MS
  state.last_event_at = now

  if state.redraw_timer then state.redraw_timer:stop() end
  state.redraw_timer = vim.defer_fn(function()
    state.redraw_timer = nil
    M.paint(state)
  end, streaming and BURST_MS or SETTLED_MS)
end

-- ============================================================================
-- Lifecycle
-- ============================================================================

--- Start painting a content's text placements in a window.
---@param win integer
---@param content MdRender.Content
---@return MdRender.TextSizeState?
function M.attach(win, content)
  if not config.enabled then return nil end
  if not content.text_placements or #content.text_placements == 0 then return nil end
  if not M.supports() then return nil end
  if not vim.api.nvim_win_is_valid(win) then return nil end

  ---@type MdRender.TextSizeState
  local state = {
    placements = content.text_placements,
    win = win,
    redraw_timer = nil,
    autocmd_ids = {},
  }

  local augroup = vim.api.nvim_create_augroup("md_render_text_size_" .. win, { clear = true })
  state.augroup = augroup

  -- Deliberately unfiltered. Filtering on the event's window is wrong here:
  --   * `WinScrolled` matches only "the window-ID of the *first* window that
  --     scrolled" (`:help WinScrolled`), so in split / toggle layouts — where
  --     cursor sync scrolls the source and the render window together — our
  --     window is frequently not the one reported, and the repaint was lost.
  --   * Cursor movement in the *source* window repaints the render window too
  --     (shadow cursor, cursor sync), so `CursorMoved` in another window still
  --     concerns us.
  -- `M.paint` is a single debounced write that no-ops when nothing is visible,
  -- so reacting to every event is cheaper than getting the filter wrong.
  for _, event in ipairs { "WinScrolled", "WinResized", "CursorMoved", "CursorMovedI" } do
    local id = vim.api.nvim_create_autocmd(event, {
      group = augroup,
      callback = function()
        schedule_paint(state)
      end,
    })
    table.insert(state.autocmd_ids, id)
  end

  -- Colors can change under us; drop the SGR cache and repaint.
  table.insert(
    state.autocmd_ids,
    vim.api.nvim_create_autocmd("ColorScheme", {
      group = augroup,
      callback = function()
        M.reset_sgr_cache()
        schedule_paint(state)
      end,
    })
  )

  vim.api.nvim_create_autocmd("WinClosed", {
    group = augroup,
    pattern = tostring(win),
    once = true,
    callback = function()
      M.detach(state)
    end,
  })

  schedule_paint(state)
  return state
end

--- Swap in placements from a rebuilt content and repaint.
---@param state MdRender.TextSizeState?
---@param win integer
---@param content MdRender.Content
---@return MdRender.TextSizeState?
function M.refresh(state, win, content)
  if not state then return M.attach(win, content) end
  if not content.text_placements or #content.text_placements == 0 then
    M.detach(state)
    return nil
  end
  state.placements = content.text_placements
  state.win = win
  -- Old blocks may sit where the new layout has none, so force the next paint
  -- through the invalidate path even if the positions happen to line up.
  state.last_layout = nil
  schedule_paint(state)
  return state
end

--- Stop painting and erase whatever is still on screen.
---@param state MdRender.TextSizeState?
function M.detach(state)
  if not state then return end
  if state.redraw_timer then
    state.redraw_timer:stop()
    state.redraw_timer = nil
  end
  for _, id in ipairs(state.autocmd_ids or {}) do
    pcall(vim.api.nvim_del_autocmd, id)
  end
  state.autocmd_ids = {}
  if state.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
    state.augroup = nil
  end
  invalidate()
end

return M
