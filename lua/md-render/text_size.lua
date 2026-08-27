--- Kitty text sizing protocol (OSC 66) support for md-render.nvim.
---
--- Draws selected buffer lines at a multiple of the base font size by writing
--- OSC 66 sequences straight to the terminal, the same way `md-render.image`
--- writes Kitty graphics escapes. Every heading level `#` … `######` gets its
--- own multiplier, from 2x down to about 1.17x.
---
---     OSC 66 ; s=<scale>:n=<num>:d=<den>:w=<cells> ; <text> ST
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

--- The largest `w=` the protocol allows, i.e. how many scaled cells one run
--- may cover. This is what bounds the ladder below: a run has to carry enough
--- source cells to be worth splitting on, and `w <= 7` puts a floor on how
--- close to plain size a level can get (roughly 7/6).
local MAX_W = 7

--- Heading level → how `#` … `######` are scaled. Fixed, not user-configurable.
---
--- `s` is Kitty's *cell* scale: the run is drawn in a block `s` cells high and
--- `s * w` cells wide, so raising it costs a rendered row and halves (thirds,
--- …) the width the heading may wrap at. Every level therefore stays at
--- `s = 2` — one extra row, no more — and the ladder from `#` to `######`
--- comes from the fractional scale instead. `n` / `d` shrink the *font* inside
--- the block without changing the cells it occupies, giving an effective size
--- of `s * n / d`.
---
--- Because the fraction does not shrink the cells, `w` has to: it says how
--- many cells the run's text is rendered in, so a level at 1.5x sends four
--- source cells' worth of text in a six-cell run. `split_run` does that
--- splitting; `chunk` below is how many source cells one run may carry.
---
--- Both protocol keys are bounded — `d <= 15` and `w <= 7` — which is why the
--- deepest level lands on 7/12 rather than a rounder ratio.
---@type table<integer, { s: integer, n: integer?, d: integer? }>
local LEVEL_SCALES = {
  [1] = { s = 2 }, -- 2.00x
  [2] = { s = 2, n = 7, d = 8 }, -- 1.75x
  [3] = { s = 2, n = 3, d = 4 }, -- 1.50x
  [4] = { s = 2, n = 7, d = 10 }, -- 1.40x
  [5] = { s = 2, n = 5, d = 8 }, -- 1.25x
  [6] = { s = 2, n = 7, d = 12 }, -- 1.17x
}

---@class MdRender.TextSize.Spec
---@field level integer heading level this spec belongs to
---@field s integer Kitty's cell scale (`s=`)
---@field n integer? fractional numerator (`n=`), nil at plain `s` scaling
---@field d integer? fractional denominator (`d=`)
---@field ratio number effective size multiplier, `s * n / d`
---@field chunk integer? source cells one run may carry, nil when `w` is unused

local function gcd(a, b)
  while b ~= 0 do
    a, b = b, a % b
  end
  return a
end

--- How many source cells one run may carry at this fraction.
---
--- A run covers `s * w` cells and `w` is capped at `MAX_W`, so the chunk has to
--- be the largest source width whose scaled width still fits. It also has to be
--- a multiple of the reduced denominator, or `w` would not come out an integer
--- and the run would be a fraction of a cell too wide; and it has to be even,
--- so that a two-cell CJK character can never straddle a chunk boundary.
---@param n integer
---@param d integer
---@return integer?
local function chunk_for(n, d)
  local g = gcd(n, d)
  local p, q = n / g, d / g
  local unit = (q % 2 == 0) and q or (2 * q) -- even → CJK can land on it
  local w_unit = unit * p / q
  local k = math.floor(MAX_W / w_unit)
  if k < 1 then return nil end
  return k * unit
end

---@type table<integer, MdRender.TextSize.Spec>
local SPECS = {}
for level, base in pairs(LEVEL_SCALES) do
  local spec = { level = level, s = base.s, n = base.n, d = base.d, ratio = base.s }
  if base.n and base.d then
    spec.ratio = base.s * base.n / base.d
    spec.chunk = chunk_for(base.n, base.d)
  end
  SPECS[level] = spec
end

---@class MdRender.TextSize.Config
---@field enabled boolean master switch (default true)

---@type MdRender.TextSize.Config
local config = {
  enabled = true,
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

--- `$TERM_PROGRAM` values that are certainly not Kitty.
---
--- Worth short-circuiting on now that the feature is on by default: the probe
--- above is only cheap for a terminal that answers XTVERSION, and one that
--- answers nothing costs the full `PROBE_TIMEOUT_MS` on the first preview.
--- Apple Terminal is exactly that case. This never turns Kitty *off* — none of
--- these strings is one Kitty sets — so the strict "positive answer only" rule
--- still stands.
local NOT_KITTY = {
  ["Apple_Terminal"] = true,
  ["ghostty"] = true,
  ["Hyper"] = true,
  ["iTerm.app"] = true,
  ["rio"] = true,
  ["tmux"] = true, -- a multiplexer would have to forward OSC 66 itself
  ["vscode"] = true,
  ["WarpTerminal"] = true,
  ["WezTerm"] = true,
}

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
  -- No UI attached (`--headless`, `-l`): nothing would receive the bytes, and
  -- the probe would sit out its whole timeout waiting for an answer.
  if #vim.api.nvim_list_uis() == 0 or NOT_KITTY[vim.env.TERM_PROGRAM or ""] then
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

--- How a heading level is scaled, or nil when it must stay plain.
---
--- The terminal check belongs here, not only at paint time: the extra rows a
--- scaled heading needs are reserved while the content is built, so a terminal
--- that can never paint them must not get them reserved either.
---@param level integer 1-6
---@return MdRender.TextSize.Spec?
function M.spec_for(level)
  if not config.enabled then return nil end
  local spec = SPECS[level]
  if not spec then return nil end
  if not M.supports() then return nil end
  return spec
end

--- Split a heading's text into the runs one OSC 66 escape code may carry, and
--- report how many cells the painted result covers.
---
--- At plain `s` scaling the terminal splits the text into cells itself (`w=0`)
--- and one run is enough. With a fractional scale the cells do not shrink with
--- the font, so each run has to state the width it wants in `w=` — see
--- `LEVEL_SCALES` — and that width is a whole number of cells while the text
--- inside it is not.
---
--- `w` is therefore rounded *up*, never to nearest: given less room than its
--- text needs, Kitty drops the overflowing characters outright (measured —
--- `w=6` with seven characters of 1.75x text renders six of them). The cost of
--- rounding up is slack at the right-hand end of the run, which paints as
--- heading background and reads as a gap in the middle of a word.
---
--- Where the run ends is picked to hide that slack. A run that lands exactly on
--- a whole number of cells has none, so that is preferred; failing that the run
--- is cut after the last space it contains, which turns the slack into a
--- slightly wider word gap. Only a word longer than one run can force a visible
--- gap. Text of a single cell width — plain ASCII, or plain CJK — always lands
--- exactly and never reaches the fallback.
--- Hiding the slack costs cells, because a run cut short of the chunk carries
--- its own rounding. `budget` lets the caller say how many cells are actually
--- free; over that, the pretty split is dropped for the compact one.
---@param text string
---@param spec MdRender.TextSize.Spec
---@param budget? integer cells available for the painted runs
---@return { text: string, w: integer }[] runs
---@return integer width cells the painted runs cover in total
function M.split_run(text, spec, budget)
  if not spec.chunk then return { { text = text, w = 0 } }, vim.api.nvim_strwidth(text) * spec.s end

  local chars = vim.fn.split(text, "\\zs")
  local widths = {}
  for i, ch in ipairs(chars) do
    widths[i] = vim.api.nvim_strwidth(ch)
  end

  local function split(hide_slack)
    local runs, cells = {}, 0
    local i = 1
    while i <= #chars do
      -- Fill up to the chunk, remembering the last place a word ended.
      local j, filled = i, 0
      local space_end, space_w
      while j <= #chars and filled + widths[j] <= spec.chunk do
        filled = filled + widths[j]
        if chars[j] == " " and chars[j + 1] ~= " " then
          space_end, space_w = j, filled
        end
        j = j + 1
      end

      local cut, cut_w = j - 1, filled
      -- Slack past the end of the heading is invisible, so the final run keeps
      -- whatever it filled.
      if hide_slack and j <= #chars and (filled * spec.n) % spec.d ~= 0 and space_end then
        cut, cut_w = space_end, space_w
      end

      local w = math.max(1, math.min(MAX_W, math.ceil(cut_w * spec.n / spec.d)))
      table.insert(runs, { text = table.concat(chars, "", i, cut), w = w })
      cells = cells + w
      i = cut + 1
    end
    return runs, cells * spec.s
  end

  local runs, width = split(true)
  if budget and width > budget then
    local compact, compact_width = split(false)
    if compact_width < width then return compact, compact_width end
  end
  return runs, width
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
---@field text string the plain-size text underneath, used to verify the anchor
---@field runs { text: string, w: integer }[] `split_run` output for `text`
---@field width integer cells the painted runs cover
---@field scale integer cell scale passed as `s=`
---@field num integer? fractional numerator passed as `n=`
---@field den integer? fractional denominator passed as `d=`
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
      local fits_vertically = pos.row >= top and pos.row + p.scale - 1 <= bottom
      local fits_horizontally = pos.col >= left and pos.col + p.width - 1 <= right
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
      local sgr = sgr_for(d.p.hl)
      -- One escape code per run, each positioned explicitly. A fractionally
      -- scaled heading is several runs (see `split_run`) and the cursor is not
      -- a reliable way to chain them: `w=` decides how wide a run lands, not
      -- the text in it.
      local col = d.col
      for _, run in ipairs(d.p.runs) do
        local meta = "s=" .. d.p.scale
        if d.p.num then meta = meta .. string.format(":n=%d:d=%d:w=%d", d.p.num, d.p.den, run.w) end
        table.insert(out, string.format("\x1b[%d;%dH", d.row, col))
        table.insert(out, sgr)
        table.insert(out, string.format("\x1b]66;%s;%s\x1b\\", meta, run.text))
        col = col + d.p.scale * (run.w > 0 and run.w or vim.api.nvim_strwidth(run.text))
      end
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
