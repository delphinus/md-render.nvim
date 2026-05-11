local FloatWin = require "md-render.float_win"
local TabWin = require "md-render.tab_win"
local cb = require "md-render.content_builder"
local display_utils = require "md-render.display_utils"
local ContentBuilder = cb.ContentBuilder

local float_win = FloatWin.new "md_render_preview_float"
local demo_float_win = FloatWin.new "md_render_demo_float"
local tab_win = TabWin.new "md_render_preview_tab"

local MdPreview = {}

--- Upper bound on render width when not explicitly overridden by the user.
--- Long lines hurt readability even in wide windows, so we cap auto-sized
--- render windows here while still adapting downward in narrow splits.
local DEFAULT_MAX_WIDTH = 80

--- Usable text-area width of a window, excluding the gutter (signcolumn,
--- number column, foldcolumn, statuscolumn). `nvim_win_get_width` returns the
--- full window width including these, which would mis-size content centered
--- against the visible text area.
---@param win integer
---@return integer
local function usable_win_width(win)
  local total = vim.api.nvim_win_get_width(win)
  local wininfo = vim.fn.getwininfo(win)[1]
  local textoff = (wininfo and wininfo.textoff) or 0
  return math.max(1, total - textoff)
end

--- Parse simple YAML frontmatter lines into key-value pairs
---@param fm_lines string[]
---@return {key: string, value: string}[]
local function parse_frontmatter(fm_lines)
  local entries = {}
  local current_key = nil
  local current_list = {}

  local function flush_list()
    if current_key and #current_list > 0 then
      table.insert(entries, {
        key = current_key,
        value = table.concat(current_list, ", "),
      })
      current_key = nil
      current_list = {}
    end
  end

  for _, line in ipairs(fm_lines) do
    local list_value = line:match "^%s+%-%s+(.+)$"
    if list_value and current_key then
      table.insert(current_list, list_value)
    else
      flush_list()
      local key, value = line:match "^([%w_%-]+):%s*(.*)$"
      if key then
        if value and value ~= "" then
          table.insert(entries, { key = key, value = value })
          current_key = nil
        else
          current_key = key
          current_list = {}
        end
      end
    end
  end
  flush_list()

  return entries
end

--- Build rendered content from markdown lines
---@param lines string[]
---@param opts? { max_width?: integer, fold_state?: table<integer, boolean>, expand_state?: table<integer, boolean>, autolinks?: MdRender.Autolink[] }
---@return MdRender.Content
MdPreview.build_content = function(lines, opts)
  opts = opts or {}
  local max_width = opts.max_width or DEFAULT_MAX_WIDTH

  local b = ContentBuilder.new()

  -- Detect and extract frontmatter
  local body_start = 1
  if lines[1] and lines[1]:match "^%-%-%-$" then
    local frontmatter_lines = {}
    for i = 2, #lines do
      if lines[i]:match "^%-%-%-$" then
        body_start = i + 1
        break
      end
      table.insert(frontmatter_lines, lines[i])
    end
    if body_start > 1 and #frontmatter_lines > 0 then
      local entries = parse_frontmatter(frontmatter_lines)
      if #entries > 0 then
        b:set_source_line(1)
        b:add_line("  Properties", {
          { col = 2, end_col = 2 + #"Properties", hl = "Title" },
        })
        for _, entry in ipairs(entries) do
          local label = "  " .. entry.key
          local full_line = label .. ": " .. entry.value
          local display_width = vim.api.nvim_strwidth(full_line)
          if display_width > max_width then
            local target = max_width - vim.api.nvim_strwidth("…")
            local current_width = 0
            local byte_pos = 0
            for char in full_line:gmatch "[%z\1-\127\194-\253][\128-\191]*" do
              local char_width = vim.api.nvim_strwidth(char)
              if current_width + char_width > target then
                break
              end
              current_width = current_width + char_width
              byte_pos = byte_pos + #char
            end
            local truncated = full_line:sub(1, byte_pos) .. "…"
            b:add_line(truncated, {
              { col = 0, end_col = #label, hl = "Comment" },
              { col = #label + 2, end_col = byte_pos, hl = "String" },
              { col = byte_pos, end_col = #truncated, hl = "Underlined" },
            })
          else
            b:add_labeled(label, entry.value, "String")
          end
        end
        b:add_line ""
      end
    end
  end

  -- Render the document body using the shared rendering loop
  local body_lines = {}
  for i = body_start, #lines do
    table.insert(body_lines, lines[i])
  end

  b:render_document(body_lines, {
    max_width = max_width,
    indent = opts.indent,
    fold_state = opts.fold_state,
    expand_state = opts.expand_state,
    autolinks = opts.autolinks,
    source_line_offset = body_start - 1,
    buf_dir = opts.buf_dir,
  })

  return b:result()
end

-- =====================================================================
-- Session: encapsulates a render buffer's content, state, and lifecycle.
-- One Session per (source buffer, namespace) — the render buffer is
-- reused across windows that show it. show / show_tab / show_pager and
-- :MdRenderToggle all build on top of this.
-- =====================================================================

---@class MdRender.Session
---@field source_bufnr integer        -- source markdown buffer
---@field source_lines string[]       -- snapshot of source buffer
---@field opts table                  -- options passed to build_content
---@field buf integer                 -- render buffer (scratch)
---@field ns integer                  -- highlight namespace
---@field fold_state table<integer, boolean>
---@field expand_state table<integer, boolean>
---@field content MdRender.Content    -- current rendered content
---@field win? integer                -- bound render window (if any)
---@field image_state? MdRender.ImageState
---@field dirty boolean               -- true when source changed while render was hidden
---@field _debounce_timer? table      -- libuv timer handle for live-update debounce
local Session = {}
Session.__index = Session

--- Build a fresh Session from a source buffer.
---@param source_bufnr integer
---@param ns_name string
---@param opts? table
---@return MdRender.Session
function Session.new(source_bufnr, ns_name, opts)
  local effective_opts = vim.tbl_extend("force", {}, opts or {})
  local source_name = vim.api.nvim_buf_get_name(source_bufnr)
  effective_opts.buf_dir = effective_opts.buf_dir or vim.fn.fnamemodify(source_name, ":h")

  local self = setmetatable({}, Session)
  self.source_bufnr = source_bufnr
  self.source_lines = vim.api.nvim_buf_get_lines(source_bufnr, 0, -1, false)
  self.opts = effective_opts
  self.fold_state = {}
  self.expand_state = {}
  self.buf = vim.api.nvim_create_buf(false, true)
  self.ns = vim.api.nvim_create_namespace(ns_name)
  self.dirty = false
  self._debounce_timer = nil
  self._explicit_max_width = (effective_opts.max_width ~= nil)

  -- Give the render buffer a recognisable name so statuslines, pickers,
  -- and bufferline plugins can show what's being viewed. The "[render]"
  -- suffix avoids colliding with the source name.
  --
  -- Suppress autocmds while we change the name and filetype: user-configured
  -- handlers (markdown ftplugins, treesitter, lualine, etc.) would otherwise
  -- treat this scratch buffer as a real markdown file and clobber our
  -- pre-rendered content (conceallevel, readonly, syntax overlays, ...).
  -- A non-empty filetype ("md-render") prevents external hacks that run
  -- `:edit` on filetype="" buffers from clearing the rendered content.
  if source_name ~= "" then
    local saved_ei = vim.o.eventignore
    vim.o.eventignore = "all"
    pcall(vim.api.nvim_buf_set_name, self.buf, source_name .. " [render]")
    vim.bo[self.buf].filetype = "md-render"
    vim.o.eventignore = saved_ei
    -- nvim_buf_set_name can flip readonly when it thinks the file already
    -- exists on disk; defend so apply_content_to_buffer doesn't W10-warn.
    vim.bo[self.buf].readonly = false
    vim.bo[self.buf].modified = false
  end

  require("md-render").setup_highlights()

  self.opts.fold_state = self.fold_state
  self.opts.expand_state = self.expand_state
  self.content = MdPreview.build_content(self.source_lines, self.opts)
  -- Defensive: nvim_buf_set_name above can leave the buffer modifiable=false
  -- on some setups (third-party autocmds firing even with eventignore=all).
  vim.bo[self.buf].modifiable = true
  display_utils.apply_content_to_buffer(self.buf, self.ns, self.content)
  vim.bo[self.buf].modified = false

  -- Initialize fold_state from default fold states (e.g. `> [!TIP]-`)
  for _, fold in ipairs(self.content.callout_folds) do
    self.fold_state[fold.source_line] = fold.collapsed
  end

  return self
end

--- Refresh source_lines from the source buffer (call before rebuild when
--- the source may have changed).
function Session:refresh_source()
  if vim.api.nvim_buf_is_valid(self.source_bufnr) then
    self.source_lines = vim.api.nvim_buf_get_lines(self.source_bufnr, 0, -1, false)
  end
end

--- Rebuild render content from the current source_lines and apply it.
--- Preserves the view (topline/cursor) of every window currently displaying
--- the render buffer, since `apply_content_to_buffer` replaces all lines and
--- would otherwise reset topline.
function Session:rebuild()
  self.opts.fold_state = self.fold_state
  self.opts.expand_state = self.expand_state
  local new_content = MdPreview.build_content(self.source_lines, self.opts)

  local wins = vim.fn.win_findbuf(self.buf)
  local saved_views = {}
  for _, w in ipairs(wins) do
    if vim.api.nvim_win_is_valid(w) then
      saved_views[w] = vim.api.nvim_win_call(w, function() return vim.fn.winsaveview() end)
    end
  end

  vim.api.nvim_set_option_value("modifiable", true, { buf = self.buf })
  vim.api.nvim_buf_clear_namespace(self.buf, self.ns, 0, -1)
  display_utils.apply_content_to_buffer(self.buf, self.ns, new_content)
  vim.api.nvim_set_option_value("modifiable", false, { buf = self.buf })
  -- acwrite buftype tracks 'modified'; our internal rebuild shouldn't
  -- count as a user edit.
  vim.bo[self.buf].modified = false

  for w, view in pairs(saved_views) do
    if vim.api.nvim_win_is_valid(w) then
      vim.api.nvim_win_call(w, function() vim.fn.winrestview(view) end)
    end
  end

  if self.win and vim.api.nvim_win_is_valid(self.win) then
    local any_expanded = false
    for _, v in pairs(self.expand_state) do
      if v then any_expanded = true; break end
    end
    vim.api.nvim_set_option_value("wrap", not any_expanded, { win = self.win })
  end
  self.content = new_content
  self.dirty = false
end

--- Lazily build sync points from `content.source_line_map`. A sync point
--- marks the first rendered line of each source-line "run" in the map,
--- plus a terminal sentinel for past-the-end interpolation.
---
--- For map = [5, 5, 5, 7, 7, 10], sync_points becomes:
---   [{src=5, render=1}, {src=7, render=4}, {src=10, render=6}, {src=11, render=7}]
---
--- The final sentinel lets `source_to_rendered_f` interpolate past the
--- last point without degenerating, matching the VS Code preview's
--- "interpolate between previous and next markers" approach.
---@return { src: integer, render: integer }[]
function Session:get_sync_points()
  local content = self.content
  if content._sync_points then return content._sync_points end
  local map = content.source_line_map
  local points = {}
  if map and #map > 0 then
    local prev = nil
    for render_idx, src in ipairs(map) do
      if src ~= prev then
        table.insert(points, { src = src, render = render_idx })
        prev = src
      end
    end
    if #points > 0 then
      local last = points[#points]
      table.insert(points, { src = last.src + 1, render = #map + 1 })
    end
  end
  content._sync_points = points
  return points
end

--- Find the largest `i` such that `pts[i][key] <= value` (binary search).
--- Returns `i = 1` if `value` is below all entries.
local function bracket_index(pts, key, value)
  local lo, hi = 1, #pts
  if value < pts[1][key] then return 1 end
  if value >= pts[hi][key] then return hi end
  while lo + 1 < hi do
    local mid = math.floor((lo + hi) / 2)
    if pts[mid][key] <= value then lo = mid else hi = mid end
  end
  return lo
end

--- Float version of `source_to_rendered`. Linearly interpolates between
--- adjacent sync points so a source line that sits "between" two known
--- markers maps to a fractional rendered line, rather than snapping to
--- the next marker.
---@param src number 1-indexed source line (may be fractional)
---@return number 1-indexed rendered line (float)
function Session:source_to_rendered_f(src)
  local pts = self:get_sync_points()
  if #pts == 0 then return 1 end
  if src <= pts[1].src then return pts[1].render end
  if src >= pts[#pts].src then return pts[#pts].render end
  local i = bracket_index(pts, "src", src)
  local p1 = pts[i]
  local p2 = pts[i + 1]
  if not p2 or p2.src == p1.src then return p1.render end
  local frac = (src - p1.src) / (p2.src - p1.src)
  return p1.render + frac * (p2.render - p1.render)
end

--- Float version of `rendered_to_source`. Symmetric counterpart of
--- `source_to_rendered_f`.
---@param r number 1-indexed rendered line (may be fractional)
---@return number 1-indexed source line (float)
function Session:rendered_to_source_f(r)
  local pts = self:get_sync_points()
  if #pts == 0 then return 1 end
  if r <= pts[1].render then return pts[1].src end
  if r >= pts[#pts].render then return pts[#pts].src end
  local i = bracket_index(pts, "render", r)
  local p1 = pts[i]
  local p2 = pts[i + 1]
  if not p2 or p2.render == p1.render then return p1.src end
  local frac = (r - p1.render) / (p2.render - p1.render)
  return p1.src + frac * (p2.src - p1.src)
end

--- Integer-rounded `source_to_rendered_f`. Used by callers that need a
--- concrete render line (cursor placement, initial scroll).
---@param src_line integer 1-indexed source line
---@return integer  1-indexed rendered line
function Session:source_to_rendered(src_line)
  return math.max(1, math.floor(self:source_to_rendered_f(src_line) + 0.5))
end

--- Integer-rounded `rendered_to_source_f`. Returns nil when the
--- underlying map is empty, preserving the previous contract.
---@param rendered_line integer 1-indexed rendered line
---@return integer? 1-indexed source line, or nil if no map exists
function Session:rendered_to_source(rendered_line)
  local pts = self:get_sync_points()
  if #pts == 0 then return nil end
  return math.max(1, math.floor(self:rendered_to_source_f(rendered_line) + 0.5))
end

--- Place cursor on the rendered line corresponding to a source line,
--- centering it within the bound window.
---@param source_cursor_line integer 1-indexed source line
function Session:scroll_to_source_line(source_cursor_line)
  if not self.win or not vim.api.nvim_win_is_valid(self.win) then return end
  local target = self:source_to_rendered(source_cursor_line)
  local buf_lines = vim.api.nvim_buf_line_count(self.buf)
  target = math.max(1, math.min(target, buf_lines))
  local win_height = vim.api.nvim_win_get_height(self.win)
  local top = math.max(0, target - 1 - math.floor(win_height / 2))
  vim.api.nvim_win_call(self.win, function()
    vim.fn.winrestview { topline = top + 1 }
  end)
  vim.api.nvim_win_set_cursor(self.win, { target, 0 })
end

--- Bind a window to this session and start displaying images in it.
---@param win integer
function Session:bind_window(win)
  self.win = win
  if not self._explicit_max_width then
    local win_width = math.min(usable_win_width(win), DEFAULT_MAX_WIDTH)
    if win_width ~= (self.opts.max_width or DEFAULT_MAX_WIDTH) then
      self.opts.max_width = win_width
      self:rebuild()
    end
  end
  self.image_state = display_utils.setup_images(win, self.content, self.ns, {
    buf = self.buf,
    build_content = function()
      self.opts.fold_state = self.fold_state
      self.opts.expand_state = self.expand_state
      self.content = MdPreview.build_content(self.source_lines, self.opts)
      return self.content
    end,
  })
end

--- True when the render buffer is displayed in at least one window.
---@return boolean
function Session:is_visible()
  return #vim.fn.win_findbuf(self.buf) > 0
end

--- Update images after a rebuild.
function Session:refresh_images()
  if self.win and vim.api.nvim_win_is_valid(self.win) then
    self.image_state = display_utils.update_images(self.image_state, self.win, self.content)
  end
end

--- Tear down image state (does not destroy the buffer).
function Session:cleanup_images()
  if self.image_state then
    display_utils.cleanup_images(self.image_state)
    self.image_state = nil
  end
end

--- Install the standard click/keymap handlers on a window-managed close handle
--- (FloatWin or TabWin). Used by show / show_tab. Pass `keymap_opts.close_keys = {}`
--- and a nil close_handle for toggle-mode buffers that must not self-close.
---@param close_handle MdRender.FloatWin|MdRender.TabWin|nil
---@param keymap_opts? { close_keys?: string[], close_line_idx?: integer }
function Session:install_float_keymaps(close_handle, keymap_opts)
  keymap_opts = keymap_opts or {}
  display_utils.setup_float_keymaps(self.buf, self.ns, self.win, self.content, close_handle, {
    close_keys = keymap_opts.close_keys,
    close_line_idx = keymap_opts.close_line_idx,
    get_content = function() return self.content end,
    on_fold_toggle = function(source_line, collapsed)
      self.fold_state[source_line] = collapsed
      self:rebuild()
      self:refresh_images()
    end,
    on_expand_toggle = function(block_id, expanded)
      self.expand_state[block_id] = expanded
      self:rebuild()
      self:refresh_images()
    end,
  })
end

--- Track preview cursor and sync source cursor back when the window closes.
--- Used by show / show_tab (not pager — pager replaces the buffer in place).
function Session:install_cursor_sync()
  if not self.win or not vim.api.nvim_win_is_valid(self.win) then return end
  local last_preview_line = vim.api.nvim_win_get_cursor(self.win)[1]
  local win = self.win
  local source_bufnr = self.source_bufnr

  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = self.buf,
    callback = function()
      if vim.api.nvim_win_is_valid(win) then
        last_preview_line = vim.api.nvim_win_get_cursor(win)[1]
      end
    end,
  })

  local content_ref = self.content  -- captured at install time; updated by rebuild via self.content
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      local source_line_map = self.content.source_line_map or content_ref.source_line_map
      if source_line_map and last_preview_line <= #source_line_map then
        local target_source_line = source_line_map[last_preview_line]
        if target_source_line and target_source_line > 0
          and vim.api.nvim_buf_is_valid(source_bufnr) then
          local total_lines = vim.api.nvim_buf_line_count(source_bufnr)
          target_source_line = math.min(target_source_line, total_lines)
          for _, w in ipairs(vim.api.nvim_list_wins()) do
            if vim.api.nvim_win_is_valid(w)
              and vim.api.nvim_win_get_buf(w) == source_bufnr then
              vim.api.nvim_win_set_cursor(w, { target_source_line, 0 })
              vim.api.nvim_win_call(w, function()
                vim.cmd "normal! zz"
              end)
              break
            end
          end
        end
      end
    end,
  })
end

-- =====================================================================
-- Helpers shared by user-facing entry points
-- =====================================================================

--- Verify that a buffer holds Markdown content.
---@param bufnr integer
---@return boolean ok, string? warning_msg
local function check_markdown_buffer(bufnr)
  local ft = vim.bo[bufnr].filetype
  local name = vim.api.nvim_buf_get_name(bufnr)
  if ft == "markdown" or name:match "%.md$" or name:match "%.markdown$" then
    return true
  end
  return false, "md-render: current buffer is not a Markdown file"
end

-- =====================================================================
-- show: floating preview window (existing behavior)
-- =====================================================================

--- Show a floating window previewing the current buffer's markdown content
---@param opts? { max_width?: integer }
MdPreview.show = function(opts)
  if float_win:close_if_valid() then
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local ok, warn = check_markdown_buffer(bufnr)
  if not ok then
    vim.notify(warn, vim.log.levels.WARN)
    return
  end

  local source_cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local session = Session.new(bufnr, "md_render_preview", opts)

  local win = display_utils.open_float_window(session.buf, session.content, float_win, {
    title = " Markdown Preview ",
    position = "center",
    enter = true,
  })

  session:bind_window(win)
  session:scroll_to_source_line(source_cursor_line)
  session:install_cursor_sync()
  session:install_float_keymaps(float_win)
end

-- =====================================================================
-- show_tab: tab-based preview (existing behavior)
-- =====================================================================

--- Show a tab previewing the current buffer's markdown content
---@param opts? { max_width?: integer }
MdPreview.show_tab = function(opts)
  if tab_win:close_if_valid() then
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local ok, warn = check_markdown_buffer(bufnr)
  if not ok then
    vim.notify(warn, vim.log.levels.WARN)
    return
  end

  local source_cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local session = Session.new(bufnr, "md_render_preview_tab", opts)

  vim.cmd "tabnew"
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, session.buf)

  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].statuscolumn = ""
  vim.wo[win].cursorline = true
  vim.wo[win].wrap = true
  vim.wo[win].spell = false
  vim.wo[win].list = false
  vim.wo[win].statusline = " Markdown Preview "

  vim.bo[session.buf].modifiable = false
  vim.bo[session.buf].bufhidden = "wipe"
  vim.bo[session.buf].buftype = "nofile"

  tab_win:setup(win)

  session:bind_window(win)
  session:scroll_to_source_line(source_cursor_line)
  session:install_cursor_sync()
  session:install_float_keymaps(tab_win)
end

-- =====================================================================
-- show_pager: full-screen pager mode (existing behavior)
-- =====================================================================

--- Show markdown in pager mode (full-screen, minimal UI, q to quit Neovim)
---@param opts? { max_width?: integer }
MdPreview.show_pager = function(opts)
  local bufnr = vim.api.nvim_get_current_buf()
  local ok, warn = check_markdown_buffer(bufnr)
  if not ok then
    vim.notify(warn, vim.log.levels.WARN)
    return
  end

  local session = Session.new(bufnr, "md_render_pager", opts)

  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, session.buf)

  -- Hide all chrome for pager feel
  vim.o.showtabline = 0
  vim.o.laststatus = 0
  vim.o.cmdheight = 0
  vim.o.ruler = false
  vim.o.showcmd = false

  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].statuscolumn = ""
  vim.wo[win].cursorline = true
  vim.wo[win].wrap = true
  vim.wo[win].spell = false
  vim.wo[win].list = false

  vim.bo[session.buf].modifiable = false
  vim.bo[session.buf].bufhidden = "wipe"
  vim.bo[session.buf].buftype = "nofile"

  session:bind_window(win)

  -- q quits Neovim (pager behavior)
  vim.keymap.set("n", "q", function()
    session:cleanup_images()
    vim.cmd "qa!"
  end, { buffer = session.buf, noremap = true, silent = true })

  -- Click handling (links, folds, expand)
  vim.keymap.set("n", "<LeftRelease>", function()
    local mouse = vim.fn.getmousepos()
    if mouse.winid ~= win then return end

    local click_line = mouse.line - 1
    local click_col = mouse.column - 1

    local function try_open_url()
      local extmarks =
        vim.api.nvim_buf_get_extmarks(session.buf, session.ns, { click_line, 0 }, { click_line + 1, 0 }, { details = true })
      for _, mark in ipairs(extmarks) do
        local _, _, start_col, details = unpack(mark)
        if details.url then
          local end_col = details.end_col or (start_col + 1)
          if click_col >= start_col and click_col < end_col then
            local anchor = details.url:match "^#(.+)$"
            if anchor then
              if session.content.footnote_anchors then
                local target_line = session.content.footnote_anchors[anchor]
                if target_line then
                  vim.api.nvim_win_set_cursor(win, { target_line + 1, 0 })
                  return true
                end
              end
              if session.content.heading_anchors then
                local target_line = session.content.heading_anchors[anchor]
                if target_line then
                  vim.api.nvim_win_set_cursor(win, { target_line + 1, 0 })
                  return true
                end
              end
              return true
            end
            if details.url:match "^obsidian://" then
              vim.notify("Opening: " .. details.url, vim.log.levels.INFO)
              vim.ui.open(details.url)
              return true
            end
            if display_utils.supports_osc8() then return false end
            vim.notify("Opening: " .. details.url, vim.log.levels.INFO)
            vim.ui.open(details.url)
            return true
          end
        end
      end
      return false
    end

    if session.content.callout_folds then
      for _, fold in ipairs(session.content.callout_folds) do
        if fold.header_line == click_line then
          session.fold_state[fold.source_line] = not fold.collapsed
          session:rebuild()
          session:refresh_images()
          return
        end
      end
    end

    if session.content.expandable_regions then
      for _, region in ipairs(session.content.expandable_regions) do
        if click_line >= region.start_line and click_line <= region.end_line then
          if try_open_url() then return end
          session.expand_state[region.block_id] = not region.expanded
          session:rebuild()
          session:refresh_images()
          return
        end
      end
    end

    try_open_url()
  end, { buffer = session.buf, noremap = true, silent = true })
end

-- =====================================================================
-- toggle: same-window source ↔ render swap
-- =====================================================================

-- One Session per source buffer, shared across windows showing the same source.
---@type table<integer, MdRender.Session>
local _toggle_sessions = {}

-- Window-local options that get overridden while a window is showing a
-- render buffer. The originals are stashed in `md_render_state.source_wo`
-- on the source->render transition and restored on the render->source
-- transition. The BufEnter guard re-applies these to any window that
-- happens to display the render buffer (covers manual `:b` / picker
-- entries in addition to the toggle / split entry points).
local RENDER_WIN_OPTS = {
  { "number", false },
  { "relativenumber", false },
  { "list", false },
  { "signcolumn", "no" },
  { "foldcolumn", "0" },
  { "statuscolumn", "" },
}

local function save_render_win_opts(win)
  local saved = {}
  for _, entry in ipairs(RENDER_WIN_OPTS) do
    saved[entry[1]] = vim.api.nvim_get_option_value(entry[1], { win = win })
  end
  return saved
end

local function apply_render_win_opts(win)
  for _, entry in ipairs(RENDER_WIN_OPTS) do
    vim.api.nvim_set_option_value(entry[1], entry[2], { win = win })
  end
end

local function restore_render_win_opts(win, saved)
  if not saved then return end
  for _, entry in ipairs(RENDER_WIN_OPTS) do
    if saved[entry[1]] ~= nil then
      vim.api.nvim_set_option_value(entry[1], saved[entry[1]], { win = win })
    end
  end
end

local function toggle_buf_augroup(buf)
  return "md_render_toggle_buf_" .. buf
end

local function toggle_src_augroup(bufnr)
  return "md_render_toggle_src_" .. bufnr
end

local function live_update_augroup(bufnr)
  return "md_render_toggle_live_" .. bufnr
end

local function scroll_sync_augroup(bufnr)
  return "md_render_toggle_sync_" .. bufnr
end

local function win_resize_augroup(bufnr)
  return "md_render_toggle_resize_" .. bufnr
end

local function shadow_augroup(bufnr)
  return "md_render_shadow_" .. bufnr
end

-- Dedicated namespace for MdRenderSplit shadow-cursor extmarks. Kept
-- separate from session.ns so Session:rebuild's clear of session.ns does
-- not wipe the shadow. nvim_create_namespace returns the same ID for
-- the same name, so source and render buffers can safely share it.
local SHADOW_NS = vim.api.nvim_create_namespace "md_render_shadow"

-- Auto-toggle state declared up here so install_source_watcher's BufWipeout
-- callback can clean it up. The auto_on / auto_off implementations live
-- further down with the rest of the auto-toggle logic.
---@type table<integer, { in_timer?: table, leave_timer?: table }>
local _auto_state = {}

local function auto_augroup(bufnr)
  return "md_render_auto_" .. bufnr
end

--- Schedule a debounced live rebuild of the render buffer.
--- When the render buffer is hidden, just mark dirty and return; the next
--- toggle back to render will rebuild in `get_or_create_toggle_session`.
---@param session MdRender.Session
local function schedule_live_rebuild(session)
  if not vim.api.nvim_buf_is_valid(session.source_bufnr) then return end
  if not vim.api.nvim_buf_is_valid(session.buf) then return end

  if not session:is_visible() then
    session.dirty = true
    return
  end

  if session._debounce_timer then
    session._debounce_timer:stop()
  end
  session._debounce_timer = vim.defer_fn(function()
    session._debounce_timer = nil
    if not vim.api.nvim_buf_is_valid(session.source_bufnr) then return end
    if not vim.api.nvim_buf_is_valid(session.buf) then return end
    if not session:is_visible() then
      session.dirty = true
      return
    end
    session:refresh_source()
    session:rebuild()
    session:refresh_images()
  end, 150)
end

--- Listen for source buffer changes and trigger debounced live rebuilds.
---@param session MdRender.Session
local function install_live_update(session)
  local augroup = vim.api.nvim_create_augroup(
    live_update_augroup(session.source_bufnr), { clear = true })

  vim.api.nvim_create_autocmd({
    "TextChanged",
    "TextChangedI",
    "BufWritePost",
    "BufReadPost",          -- :e reload
    "FileChangedShellPost", -- external change detected via :checktime / autoread
  }, {
    group = augroup,
    buffer = session.source_bufnr,
    callback = function() schedule_live_rebuild(session) end,
  })
end

--- Bidirectional cursor + scroll sync between source and render windows.
---
--- Triggers:
---   - CursorMoved / CursorMovedI on source -> sync render windows
---   - CursorMoved on render -> sync source windows
---   - WinScrolled on either -> sync the other side (covers Ctrl+E / Ctrl+Y
---     / mouse-wheel scrolling that doesn't move the cursor)
---
--- Sync target: edge-aware. When the source is anchored to the file's
--- start or end, snap the destination to its own start or end (this
--- guarantees "I scrolled to the bottom, the other side did too" even
--- when source has hidden lines like footnote/link reference defs that
--- produce no render output and would otherwise leave the mapped end
--- short of the file). Otherwise map the source's visible range (top,
--- center, bottom) through `source_to_rendered_f` /
--- `rendered_to_source_f` and center on the mapped center, clamped to
--- stay inside the source's visible range. The destination cursor is
--- set independently from the originating cursor.
---
--- Mapping is done in floating point so a source line that sits between
--- two sync points yields a fractional render position rather than
--- snapping to the next marker. The final topline is then rounded to an
--- integer (Vim cannot scroll by fractional rows). This mirrors the way
--- VS Code's preview interpolates between `data-line` markers.
---
--- An even earlier design tried to align the cursor's winrow directly,
--- which jittered: pressing `j` on a source line whose mapped render
--- line did not advance forced the render view *up* by one row to keep
--- the cursor at the new winrow. Centering on a buffer-derived anchor
--- decouples scroll from cursor motion — pressing `j` only moves the
--- cursor unless the source view actually scrolls.
---
--- Both topline and cursor are written through a single `winrestview`
--- call. Using `nvim_win_set_cursor` instead would re-apply 'scrolloff'
--- and silently override the topline we just set.
---
--- Loop prevention: a single `_syncing` flag, released after 30 ms via
--- vim.defer_fn. Each sync action fires both CursorMoved and WinScrolled
--- on the destination windows; the timer-based unlock suppresses the
--- whole cascade without the brittleness of trying to count events.
---@param session MdRender.Session
local function install_scroll_sync(session)
  local augroup = vim.api.nvim_create_augroup(
    scroll_sync_augroup(session.source_bufnr), { clear = true })

  local SYNC_UNLOCK_MS = 30

  local function with_sync_lock(fn)
    session._syncing = true
    local ok, err = pcall(fn)
    if session._sync_unlock_timer then
      session._sync_unlock_timer:stop()
    end
    session._sync_unlock_timer = vim.defer_fn(function()
      session._syncing = false
      session._sync_unlock_timer = nil
    end, SYNC_UNLOCK_MS)
    if not ok then error(err) end
  end

  --- Apply a per-window scroll + cursor under the sync lock.
  ---
  --- For interior scrolls a single `winrestview` writes both topline
  --- and lnum so 'scrolloff' cannot shift the topline as a side effect
  --- of placing the cursor.
  ---
  --- For edge scrolls (`"top"` / `"bot"`) we cannot just compute
  --- `topline = dest_lines - height + 1`: when the destination has
  --- 'wrap' on (Vim's default), buffer lines that wrap occupy more
  --- screen rows than buffer rows, so a row-arithmetic topline leaves
  --- the file's last line off the bottom of the window. We instead
  --- park the cursor at the file boundary and use `zt` / `zb` so Vim
  --- itself computes a topline that respects 'wrap'.
  ---
  --- After applying the action, position the cursor and let Vim
  --- auto-scroll for visibility — without this, a topline computed
  --- from buffer rows can leave the cursor's row outside the visible
  --- screen rows when the destination has many wrapped or
  --- image-occupied buffer lines (e.g. README with kitty image
  --- placeholders), causing the shadow highlight to disappear past
  --- the bottom of the window.
  local function fan_out(wins, from_win, compute_action, target_cursor)
    if #wins == 0 then return end
    local cursor = math.max(1, math.floor(target_cursor + 0.5))
    with_sync_lock(function()
      for _, w in ipairs(wins) do
        if w ~= from_win and vim.api.nvim_win_is_valid(w) then
          pcall(function()
            local action = compute_action(w)
            vim.api.nvim_win_call(w, function()
              if action == "top" then
                vim.fn.cursor(1, 1)
                vim.cmd "normal! zt"
              elseif action == "bot" then
                local last = vim.api.nvim_buf_line_count(0)
                vim.fn.cursor(last, 1)
                vim.cmd "normal! zb"
              else
                vim.fn.winrestview { topline = action, col = 0 }
              end
              -- Final cursor placement: vim.fn.cursor() respects
              -- 'wrap' / image-row layout when deciding whether to
              -- scroll, unlike a row-arithmetic topline. We keep the
              -- intended topline action above, then let Vim adjust if
              -- placing the cursor would push it off-screen.
              vim.fn.cursor(cursor, 1)
            end)
          end)
        end
      end
    end)
  end

  --- Decide what to do with one destination window.
  ---
  --- Returns either:
  ---   * the literal string `"top"` — fan_out will scroll the window
  ---     to its first line via `gg` + `zt` (handles 'wrap' correctly).
  ---   * the literal string `"bot"` — fan_out will scroll the window
  ---     to its last line via `G` + `zb` (handles 'wrap' correctly).
  ---   * an integer topline for the interior (mid-scroll) case, where
  ---     center alignment plus the [mapped_top, mapped_bot_end -
  ---     dest_height + 1] clamp keeps the destination inside the
  ---     source's visible range.
  ---
  --- For interior scrolls the topline is rounded and clamped to the
  --- destination buffer's valid range, then post-adjusted so the
  --- cursor's mapped position never sits outside the destination
  --- viewport. Without that adjustment a wide source window
  --- (1 source line ~ many render rows because of images / tables)
  --- can leave the mapped cursor pinned to the bottom edge so a
  --- single `j` flicks it off-screen.
  local function pick_action(dest_height, dest_lines, mapped_top, mapped_center, mapped_bot_end, src_top_at_edge, src_bot_at_edge, target_cursor)
    -- Edge snap only when the mapped cursor still fits in the window
    -- from that edge. Otherwise the snap pins topline=1 / botline=last
    -- but the cursor (and shadow) sit beyond the visible rows — common
    -- when the source is short but the render is much taller (images,
    -- tables, wrap). Fall through to the cursor-anchored interior path
    -- in that case.
    local cursor = target_cursor and math.max(1, math.floor(target_cursor + 0.5)) or nil
    if src_top_at_edge and (not cursor or cursor <= dest_height) then return "top" end
    if src_bot_at_edge and (not cursor or cursor >= dest_lines - dest_height + 1) then return "bot" end
    local topline = mapped_center - dest_height / 2
    if topline < mapped_top then topline = mapped_top end
    local max_top_in_range = mapped_bot_end - dest_height + 1
    if topline > max_top_in_range then topline = max_top_in_range end
    topline = math.floor(topline + 0.5)
    local buf_max_top = math.max(1, dest_lines - dest_height + 1)
    if topline < 1 then topline = 1 end
    if topline > buf_max_top then topline = buf_max_top end

    -- Keep the mapped cursor inside the destination viewport with a
    -- small margin so a one-line move on the source side doesn't
    -- immediately push it off-screen on the render side.
    if target_cursor then
      local cursor = math.max(1, math.floor(target_cursor + 0.5))
      local margin = math.min(3, math.floor(dest_height / 4))
      if cursor < topline + margin then
        topline = cursor - margin
      elseif cursor > topline + dest_height - 1 - margin then
        topline = cursor - dest_height + 1 + margin
      end
      if topline < 1 then topline = 1 end
      if topline > buf_max_top then topline = buf_max_top end
    end
    return topline
  end

  --- Read a window's actual visible buffer-line range. `line('w0')` /
  --- `line('w$')` honour 'wrap', folds, and 'diff' filler lines, unlike
  --- `topline + nvim_win_get_height() - 1` which counts screen rows and
  --- would over- or under-shoot when a single buffer line spans
  --- multiple screen rows.
  ---
  --- Returned as a 3-element array because `nvim_win_call` only
  --- preserves the first return value of its callback.
  ---@return integer[] # `{ topline, botline, cursor_line }`
  local function visible_range(win)
    return vim.api.nvim_win_call(win, function()
      return { vim.fn.line("w0"), vim.fn.line("w$"), vim.fn.line(".") }
    end)
  end

  local function sync_from_source(source_win)
    if not vim.api.nvim_win_is_valid(source_win) then return end
    if vim.api.nvim_win_get_buf(source_win) ~= session.source_bufnr then return end
    local render_wins = vim.fn.win_findbuf(session.buf)
    if #render_wins == 0 then return end

    local source_lines = vim.api.nvim_buf_line_count(session.source_bufnr)
    local sv = visible_range(source_win)
    local source_topline, source_botline, source_cursor_line = sv[1], sv[2], sv[3]
    source_topline = math.max(1, math.min(source_topline, source_lines))
    source_botline = math.max(source_topline, math.min(source_botline, source_lines))
    local source_center = (source_topline + source_botline) / 2
    local src_top_at_edge = source_topline <= 1
    local src_bot_at_edge = source_botline >= source_lines

    local render_lines = vim.api.nvim_buf_line_count(session.buf)
    local function clamp(v) return math.min(math.max(v, 1), render_lines) end
    local mapped_top = clamp(session:source_to_rendered_f(source_topline))
    local mapped_center = clamp(session:source_to_rendered_f(source_center))
    -- Use the *next* source line's mapped start, then step back one render
    -- line, to capture where source.botline's render block actually ends.
    -- The sync_points sentinel makes this safe past EOF.
    local mapped_bot_end = clamp(session:source_to_rendered_f(source_botline + 1) - 1)
    if mapped_bot_end < mapped_top then mapped_bot_end = mapped_top end
    local target_cursor = clamp(session:source_to_rendered_f(source_cursor_line))

    fan_out(render_wins, source_win, function(w)
      local dest_height = vim.api.nvim_win_get_height(w)
      return pick_action(dest_height, render_lines, mapped_top, mapped_center, mapped_bot_end,
        src_top_at_edge, src_bot_at_edge, target_cursor)
    end, target_cursor)
  end

  local function sync_from_render(render_win)
    if not vim.api.nvim_win_is_valid(render_win) then return end
    if vim.api.nvim_win_get_buf(render_win) ~= session.buf then return end
    local source_wins = vim.fn.win_findbuf(session.source_bufnr)
    if #source_wins == 0 then return end

    if #session:get_sync_points() == 0 then return end
    local render_lines = vim.api.nvim_buf_line_count(session.buf)
    local rv = visible_range(render_win)
    local render_topline, render_botline, render_cursor_line = rv[1], rv[2], rv[3]
    render_topline = math.max(1, math.min(render_topline, render_lines))
    render_botline = math.max(render_topline, math.min(render_botline, render_lines))
    local render_center = (render_topline + render_botline) / 2
    local src_top_at_edge = render_topline <= 1
    local src_bot_at_edge = render_botline >= render_lines

    local source_lines = vim.api.nvim_buf_line_count(session.source_bufnr)
    local function clamp(v) return math.min(math.max(v, 1), source_lines) end
    local mapped_top = clamp(session:rendered_to_source_f(render_topline))
    local mapped_center = clamp(session:rendered_to_source_f(render_center))
    local mapped_bot_end = clamp(session:rendered_to_source_f(render_botline + 1) - 1)
    if mapped_bot_end < mapped_top then mapped_bot_end = mapped_top end
    local target_cursor = clamp(session:rendered_to_source_f(render_cursor_line))

    fan_out(source_wins, render_win, function(w)
      local dest_height = vim.api.nvim_win_get_height(w)
      return pick_action(dest_height, source_lines, mapped_top, mapped_center, mapped_bot_end,
        src_top_at_edge, src_bot_at_edge, target_cursor)
    end, target_cursor)
  end

  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = augroup,
    buffer = session.source_bufnr,
    callback = function()
      if session._syncing then return end
      sync_from_source(vim.api.nvim_get_current_win())
    end,
  })

  vim.api.nvim_create_autocmd("CursorMoved", {
    group = augroup,
    buffer = session.buf,
    callback = function()
      if session._syncing then return end
      sync_from_render(vim.api.nvim_get_current_win())
    end,
  })

  -- WinScrolled has no `buffer = ...` filter, so we register globally and
  -- dispatch via vim.v.event which carries { [winid_str] = {...}, ... }
  -- for every window whose view changed in the current tick.
  vim.api.nvim_create_autocmd("WinScrolled", {
    group = augroup,
    callback = function()
      if session._syncing then return end
      local event = vim.v.event
      if type(event) ~= "table" then return end
      for key in pairs(event) do
        if key ~= "all" then
          local win = tonumber(key)
          if win and vim.api.nvim_win_is_valid(win) then
            local buf = vim.api.nvim_win_get_buf(win)
            if buf == session.source_bufnr then
              sync_from_source(win)
              return
            elseif buf == session.buf then
              sync_from_render(win)
              return
            end
          end
        end
      end
    end,
  })
end

--- Shadow cursor for MdRenderSplit: highlight the matching line(s) on
--- the unfocused side so the user can see where the focused cursor maps
--- to in the counterpart buffer.
---
--- - source -> render: highlight the contiguous render-line block that
---   the source cursor's line expands into (a heading or paragraph that
---   produces multiple render lines is shown as a block).
--- - render -> source: highlight the single source line the render
---   cursor's line maps back to (the map is 1:1 in this direction).
---
--- The focused side is always cleared so the shadow never overlaps with
--- the real cursor + cursorline. When source and render are not both
--- visible at once (toggle mode, split closed), no shadow is placed.
---
--- This handler intentionally ignores `_syncing`: scroll_sync moves the
--- counterpart cursor under the lock, and we want shadow to follow the
--- focused side's cursor regardless. Flicker is suppressed by a no-op
--- early return when the new line set equals the existing one — the
--- two sides converge on a fixpoint within one tick.
---@param session MdRender.Session
local function install_shadow_cursor(session)
  local augroup = vim.api.nvim_create_augroup(
    shadow_augroup(session.source_bufnr), { clear = true })

  -- Map source line -> [start, end] render line range (inclusive).
  --
  -- Walks source_line_map directly instead of going through the
  -- linear-interpolation `source_to_rendered_f`. The interpolation path
  -- mis-sizes blocks whenever consecutive source lines collapse:
  --   - headings followed by blanks that map to the heading itself
  --   - <img>/<details>/callout/table whose body source lines never
  --     appear in the map (the renderer attributes the entire rendered
  --     block to the opening source line)
  -- For those cases we want the *whole rendered block* of the cursor's
  -- source line, including any orphan rows (map entry == 0) that are
  -- structurally part of it.
  --
  -- Owner fallback: if `source_line` itself isn't in the map (e.g. the
  -- cursor sits inside a callout/details body whose lines don't emit
  -- their own render rows), we fall back to the largest mapped source
  -- line `<= source_line` whose rendered block extends past the cursor
  -- — i.e. the container that swallowed the body. This makes the shadow
  -- track the visible block instead of disappearing mid-container.
  local function compute_render_range(source_line)
    local map = session.content.source_line_map
    if not map or #map == 0 then return nil end

    -- Direct hit: source_line is in the map.
    local first = nil
    for i = 1, #map do
      if map[i] == source_line then
        first = i
        break
      end
    end

    -- Owner fallback: pick the closest mapped source line <= source_line.
    if not first then
      local owner_src = nil
      local owner_first = nil
      for i = 1, #map do
        local m = map[i]
        if m > 0 and m <= source_line and (not owner_src or m > owner_src) then
          owner_src = m
          owner_first = i
        end
      end
      if not owner_src then return nil end
      -- Only use the owner's block when it actually swallows source_line:
      -- the next mapped source line must be strictly greater than
      -- source_line. Otherwise the cursor sits past the container.
      local next_src = nil
      for i = owner_first + 1, #map do
        if map[i] > owner_src then
          next_src = map[i]
          break
        end
      end
      if next_src and source_line >= next_src then return nil end
      first = owner_first
      source_line = owner_src
    end

    -- Extend forward to include consecutive rows that belong to the
    -- same block: the source line itself, smaller source lines (rare),
    -- and orphan rows (0). Stop at the first row mapped to a strictly
    -- greater source line — that's the next semantic block.
    local last = first
    for i = first + 1, #map do
      if map[i] > source_line then break end
      last = i
    end

    local render_lines = vim.api.nvim_buf_line_count(session.buf)
    if first < 1 then first = 1 end
    if last > render_lines then last = render_lines end
    if last < first then return nil end
    return first, last
  end

  -- Map render line -> single source line.
  local function compute_source_line(render_line)
    local map = session.content.source_line_map
    if not map or render_line < 1 or render_line > #map then return nil end
    local src = map[render_line]
    if not src or src < 1 then return nil end
    local source_lines = vim.api.nvim_buf_line_count(session.source_bufnr)
    if src > source_lines then src = source_lines end
    return src
  end

  -- Read existing shadow extmark line numbers (1-based, sorted) so we
  -- can no-op when nothing changed.
  local function current_shadow_lines(buf)
    if not vim.api.nvim_buf_is_valid(buf) then return {} end
    local marks = vim.api.nvim_buf_get_extmarks(buf, SHADOW_NS, 0, -1, {})
    local lines = {}
    for _, m in ipairs(marks) do table.insert(lines, m[2] + 1) end
    table.sort(lines)
    return lines
  end

  local function lines_equal(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do
      if a[i] ~= b[i] then return false end
    end
    return true
  end

  local function clear_shadow(buf)
    if not vim.api.nvim_buf_is_valid(buf) then return end
    if #current_shadow_lines(buf) == 0 then return end
    vim.api.nvim_buf_clear_namespace(buf, SHADOW_NS, 0, -1)
  end

  local function set_shadow(buf, lines)
    if not vim.api.nvim_buf_is_valid(buf) then return end
    if lines_equal(current_shadow_lines(buf), lines) then return end
    vim.api.nvim_buf_clear_namespace(buf, SHADOW_NS, 0, -1)
    for _, l in ipairs(lines) do
      pcall(vim.api.nvim_buf_set_extmark, buf, SHADOW_NS, l - 1, 0, {
        line_hl_group = "MdRenderShadowCursor",
      })
    end
  end

  -- Active win drives direction. Guard with win_findbuf so we only
  -- place a shadow when both sides are simultaneously visible.
  local function recompute()
    if not vim.api.nvim_buf_is_valid(session.source_bufnr) then return end
    if not vim.api.nvim_buf_is_valid(session.buf) then return end

    local active_win = vim.api.nvim_get_current_win()
    if not vim.api.nvim_win_is_valid(active_win) then return end
    local active_buf = vim.api.nvim_win_get_buf(active_win)

    local source_visible = #vim.fn.win_findbuf(session.source_bufnr) > 0
    local render_visible = #vim.fn.win_findbuf(session.buf) > 0
    if not (source_visible and render_visible) then
      clear_shadow(session.source_bufnr)
      clear_shadow(session.buf)
      return
    end

    if active_buf == session.source_bufnr then
      clear_shadow(session.source_bufnr)
      local cursor_line = vim.api.nvim_win_get_cursor(active_win)[1]
      local s, e = compute_render_range(cursor_line)
      if not s then
        clear_shadow(session.buf)
        return
      end
      -- Skip image-overlay rows: setting line_hl_group on a line that
      -- carries a Kitty Graphics placement causes the terminal to repaint
      -- those cells with the new background, wiping the image overlay.
      -- The image redraw autocmd in display_utils only fires for
      -- CursorMoved/WinScrolled inside the render window, so source-side
      -- cursor moves leave the image gone until something else forces a
      -- redraw. image_placements use 0-indexed `line`; shadow tracks
      -- 1-indexed render lines.
      local image_rows = {}
      local placements = session.content and session.content.image_placements or {}
      for _, p in ipairs(placements) do
        for r = p.line + 1, p.line + (p.rows or 1) do
          image_rows[r] = true
        end
      end
      local lines = {}
      for l = s, e do
        if not image_rows[l] then table.insert(lines, l) end
      end
      set_shadow(session.buf, lines)
    elseif active_buf == session.buf then
      clear_shadow(session.buf)
      local cursor_line = vim.api.nvim_win_get_cursor(active_win)[1]
      local src = compute_source_line(cursor_line)
      if not src then
        clear_shadow(session.source_bufnr)
        return
      end
      set_shadow(session.source_bufnr, { src })
    end
    -- If the active window shows neither side, leave existing shadows
    -- alone — focus may return shortly without disturbing the user.
  end

  -- Stash so MdPreview.split can trigger the initial paint.
  session._shadow_recompute = recompute

  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = augroup,
    buffer = session.source_bufnr,
    callback = recompute,
  })

  vim.api.nvim_create_autocmd("CursorMoved", {
    group = augroup,
    buffer = session.buf,
    callback = recompute,
  })

  vim.api.nvim_create_autocmd("WinEnter", {
    group = augroup,
    callback = function()
      local win = vim.api.nvim_get_current_win()
      if not vim.api.nvim_win_is_valid(win) then return end
      local buf = vim.api.nvim_win_get_buf(win)
      if buf == session.source_bufnr or buf == session.buf then
        recompute()
      end
    end,
  })

  vim.api.nvim_create_autocmd("WinClosed", {
    group = augroup,
    callback = function(ev)
      local closed_win = tonumber(ev.match)
      if not closed_win then return end
      -- Re-evaluate after the close so win_findbuf reflects the new state.
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(session.source_bufnr) then return end
        if not vim.api.nvim_buf_is_valid(session.buf) then return end
        local source_visible = #vim.fn.win_findbuf(session.source_bufnr) > 0
        local render_visible = #vim.fn.win_findbuf(session.buf) > 0
        if not (source_visible and render_visible) then
          clear_shadow(session.source_bufnr)
          clear_shadow(session.buf)
        else
          recompute()
        end
      end)
    end,
  })
end

--- Rebuild render content when a render window is resized and max_width is
--- not explicitly set, so that text wrapping and image sizing adapt to the
--- new window dimensions.
---@param session MdRender.Session
local function install_win_resize_handler(session)
  local augroup = vim.api.nvim_create_augroup(
    win_resize_augroup(session.source_bufnr), { clear = true })

  vim.api.nvim_create_autocmd("WinResized", {
    group = augroup,
    callback = function()
      if session._explicit_max_width then return end
      local render_wins = vim.fn.win_findbuf(session.buf)
      if #render_wins == 0 then return end

      local win = render_wins[1]
      if not vim.api.nvim_win_is_valid(win) then return end
      local win_width = math.min(usable_win_width(win), DEFAULT_MAX_WIDTH)
      if win_width == (session.opts.max_width or DEFAULT_MAX_WIDTH) then return end

      session.opts.max_width = win_width
      schedule_live_rebuild(session)
    end,
  })
end

--- Apply read-only buffer options used by toggle-mode render buffers.
--- - buftype = `acwrite` so `:w` reaches the BufWriteCmd handler installed
---   in install_render_buf_guards (instead of E382 from Vim itself).
--- - modifiable = false to block editing keys.
--- - readonly is intentionally left false: Vim checks readonly *before*
---   firing BufWriteCmd, so a true readonly would short-circuit `:w` with
---   E45 and prevent us from forwarding the write to the source.
---@param session MdRender.Session
local function apply_render_buf_options(session)
  vim.bo[session.buf].buftype = "acwrite"
  vim.bo[session.buf].bufhidden = "hide"
  vim.bo[session.buf].swapfile = false
  vim.bo[session.buf].modifiable = false
  vim.bo[session.buf].readonly = false
  vim.bo[session.buf].modified = false
end

--- Re-assert read-only on entry; revert on accidental edit.
---@param session MdRender.Session
local function install_render_buf_guards(session)
  local augroup = vim.api.nvim_create_augroup(toggle_buf_augroup(session.buf), { clear = true })

  vim.api.nvim_create_autocmd("BufEnter", {
    group = augroup,
    buffer = session.buf,
    callback = function()
      if vim.api.nvim_buf_is_valid(session.buf) then
        vim.bo[session.buf].modifiable = false
        -- Don't set readonly = true here: Vim's :w checks readonly before
        -- firing BufWriteCmd, so doing so would break our :w forwarding.
      end
      local win = vim.api.nvim_get_current_win()
      if vim.api.nvim_win_get_buf(win) == session.buf then
        apply_render_win_opts(win)
      end
    end,
  })

  -- Reset 'modified' after our own internal writes. The buffer is
  -- modifiable=false (re-asserted by BufEnter), so user edits are blocked
  -- at the Vim level (E21) and never reach TextChanged. Any TextChanged
  -- that fires here is from internal writes (apply_content_to_buffer in
  -- Session:rebuild, clear_placeholder_text during async image placement,
  -- the on_download rebuild in display_utils.setup_images), and acwrite
  -- buftype tracks 'modified' which would otherwise leave the render
  -- buffer marked dirty and block :qa with E162.
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = augroup,
    buffer = session.buf,
    callback = function()
      if vim.api.nvim_buf_is_valid(session.buf) then
        vim.bo[session.buf].modified = false
      end
    end,
  })

  -- Forward `:w` / `:w!` on the render buffer to a `:write` on the source.
  -- :saveas / :w other-name is rejected with a warning (use :MdRenderToggle
  -- to switch to source first).
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = augroup,
    buffer = session.buf,
    callback = function(ev)
      if not vim.api.nvim_buf_is_valid(session.source_bufnr) then
        vim.notify("md-render: source buffer is gone; cannot save", vim.log.levels.ERROR)
        return
      end
      local render_name = vim.api.nvim_buf_get_name(session.buf)
      if ev.file ~= "" and ev.file ~= render_name then
        vim.notify(
          "md-render: writing to a different file from render mode is not supported; "
            .. "use :MdRenderToggle and save from source",
          vim.log.levels.WARN
        )
        return
      end
      local bang = vim.v.cmdbang == 1 and "!" or ""
      -- nvim_buf_call doesn't reliably switch the curbuf for the `:write`
      -- ex command (it ends up writing the actual current window's
      -- buffer — i.e. the render buffer — and triggers E45). Swap the
      -- current window's buffer to source for the write, then restore.
      -- eventignore=all around the swaps suppresses BufLeave/Enter side
      -- effects; the write itself runs with autocmds enabled so
      -- BufWritePre/Post (formatter on save, etc.) fire normally.
      local win = vim.api.nvim_get_current_win()
      local saved_buf = vim.api.nvim_win_get_buf(win)
      local saved_ei = vim.o.eventignore
      vim.o.eventignore = "all"
      vim.api.nvim_win_set_buf(win, session.source_bufnr)
      vim.o.eventignore = saved_ei
      local ok, err = pcall(vim.api.nvim_command, "write" .. bang)
      vim.o.eventignore = "all"
      if vim.api.nvim_win_is_valid(win) and vim.api.nvim_buf_is_valid(saved_buf) then
        vim.api.nvim_win_set_buf(win, saved_buf)
      end
      vim.o.eventignore = saved_ei
      -- The render buffer's 'modified' flag was set by Vim when :w was
      -- invoked; clear it so the user doesn't see [+] linger.
      if vim.api.nvim_buf_is_valid(session.buf) then
        vim.bo[session.buf].modified = false
      end
      if not ok then error(err) end
    end,
  })
end

--- When the source buffer is wiped, drop the cached session and its render buf.
---@param session MdRender.Session
local function install_source_watcher(session)
  local source_bufnr = session.source_bufnr
  local augroup = vim.api.nvim_create_augroup(toggle_src_augroup(source_bufnr), { clear = true })

  vim.api.nvim_create_autocmd("BufWipeout", {
    group = augroup,
    buffer = source_bufnr,
    once = true,
    callback = function()
      if session._debounce_timer then
        session._debounce_timer:stop()
        session._debounce_timer = nil
      end
      local astate = _auto_state[source_bufnr]
      if astate then
        if astate.in_timer then astate.in_timer:stop() end
        if astate.leave_timer then astate.leave_timer:stop() end
        _auto_state[source_bufnr] = nil
      end
      session:cleanup_images()
      if vim.api.nvim_buf_is_valid(session.buf) then
        pcall(vim.api.nvim_buf_delete, session.buf, { force = true })
      end
      _toggle_sessions[source_bufnr] = nil
      pcall(vim.api.nvim_del_augroup_by_name, toggle_buf_augroup(session.buf))
      pcall(vim.api.nvim_del_augroup_by_name, toggle_src_augroup(source_bufnr))
      pcall(vim.api.nvim_del_augroup_by_name, live_update_augroup(source_bufnr))
      pcall(vim.api.nvim_del_augroup_by_name, scroll_sync_augroup(source_bufnr))
      pcall(vim.api.nvim_del_augroup_by_name, shadow_augroup(source_bufnr))
      pcall(vim.api.nvim_del_augroup_by_name, win_resize_augroup(source_bufnr))
      pcall(vim.api.nvim_del_augroup_by_name, auto_augroup(source_bufnr))
    end,
  })
end

---@param source_bufnr integer
---@param opts? table
---@return MdRender.Session
local function get_or_create_toggle_session(source_bufnr, opts)
  local session = _toggle_sessions[source_bufnr]
  if session and not vim.api.nvim_buf_is_valid(session.buf) then
    -- Render buf was wiped externally; drop and rebuild.
    pcall(vim.api.nvim_del_augroup_by_name, toggle_buf_augroup(session.buf))
    session = nil
  end

  if session then
    -- Keep render content in sync with the latest source state.
    -- Live-update normally clears `dirty`, but fall back to a content
    -- comparison so that direct `nvim_buf_set_lines` (which may not fire
    -- TextChanged in headless contexts) is still picked up here.
    local current = vim.api.nvim_buf_get_lines(session.source_bufnr, 0, -1, false)
    if session.dirty or not vim.deep_equal(current, session.source_lines) then
      session.source_lines = current
      session:rebuild()
    end
    return session
  end

  session = Session.new(source_bufnr, "md_render_toggle_" .. source_bufnr, opts)
  apply_render_buf_options(session)
  install_render_buf_guards(session)
  install_source_watcher(session)
  install_live_update(session)
  install_scroll_sync(session)
  install_shadow_cursor(session)
  install_win_resize_handler(session)
  _toggle_sessions[source_bufnr] = session
  return session
end

--- Read window-local toggle state. Returns nil when the window has never
--- been toggled or when the recorded buffers are no longer valid.
---@param win integer
---@return { source_buf: integer, render_buf: integer, mode: "source"|"render", source_view?: vim.fn.winsaveview.ret }?
local function get_win_state(win)
  local ok, state = pcall(vim.api.nvim_win_get_var, win, "md_render_state")
  if not ok or type(state) ~= "table" then return nil end
  if not state.source_buf or not vim.api.nvim_buf_is_valid(state.source_buf) then
    return nil
  end
  return state
end

local function set_win_state(win, state)
  vim.api.nvim_win_set_var(win, "md_render_state", state)
end

--- Toggle between source and render mode in the current window.
---@param opts? { max_width?: integer }
MdPreview.toggle = function(opts)
  local win = vim.api.nvim_get_current_win()
  local cur_buf = vim.api.nvim_win_get_buf(win)
  local state = get_win_state(win)

  -- ---- render → source ----
  if state and state.mode == "render" and cur_buf == state.render_buf then
    local session = _toggle_sessions[state.source_buf]
    local rendered_line = vim.api.nvim_win_get_cursor(win)[1]
    local source_line = session and session:rendered_to_source(rendered_line) or nil

    if not vim.api.nvim_buf_is_valid(state.source_buf) then
      vim.notify("md-render: source buffer is no longer valid", vim.log.levels.WARN)
      return
    end

    if session and session.win == win then
      session:cleanup_images()
      session.win = nil
    end

    vim.api.nvim_win_set_buf(win, state.source_buf)
    restore_render_win_opts(win, state.source_wo)

    if state.source_view then
      vim.api.nvim_win_call(win, function()
        vim.fn.winrestview(state.source_view)
      end)
    end
    if source_line and source_line > 0 then
      local total = vim.api.nvim_buf_line_count(state.source_buf)
      source_line = math.min(source_line, total)
      vim.api.nvim_win_set_cursor(win, { source_line, 0 })
    end

    set_win_state(win, vim.tbl_extend("force", state, { mode = "source" }))
    return
  end

  -- ---- source → render ----
  -- If we're on a render buf belonging to a session whose state is stale
  -- (e.g. user manually :buffer'd here), bail out cleanly.
  if state and cur_buf == state.render_buf then
    vim.notify("md-render: window state is inconsistent; please reopen the source buffer", vim.log.levels.WARN)
    return
  end

  local source_bufnr = cur_buf
  local ok, warn = check_markdown_buffer(source_bufnr)
  if not ok then
    vim.notify(warn, vim.log.levels.WARN)
    return
  end

  local source_cursor_line = vim.api.nvim_win_get_cursor(win)[1]
  local source_view = vim.api.nvim_win_call(win, function()
    return vim.fn.winsaveview()
  end)
  local source_wo = save_render_win_opts(win)

  local session = get_or_create_toggle_session(source_bufnr, opts)

  -- Restore content indent when toggling into a full-width window (may have
  -- been cleared by a prior MdRenderSplit).
  local default_indent = "  "
  if (session.opts.indent or default_indent) ~= default_indent then
    session.opts.indent = default_indent
    session:rebuild()
  end

  -- Rebind the session's image state if it was attached to a different window.
  if session.win and session.win ~= win and vim.api.nvim_win_is_valid(session.win) then
    session:cleanup_images()
    session.win = nil
  end

  vim.api.nvim_win_set_buf(win, session.buf)
  session:bind_window(win)
  session:scroll_to_source_line(source_cursor_line)

  -- Click handlers on the render buf — no close keys (toggle owns lifecycle).
  session:install_float_keymaps(nil, { close_keys = {} })

  set_win_state(win, {
    source_buf = source_bufnr,
    render_buf = session.buf,
    mode = "render",
    source_view = source_view,
    source_wo = source_wo,
  })
end

-- =====================================================================
-- split: open a side-by-side split with source on one side, render on
-- the other. From source -> new split shows render. From a render
-- window (created by toggle) -> new split shows source. Direction is
-- driven by the user's command modifiers (:vert, :topleft, :tab, ...).
-- =====================================================================

--- Open a split showing the counterpart of the current window's mode.
---@param opts? { mods?: table, max_width?: integer }
MdPreview.split = function(opts)
  opts = opts or {}
  local cur_win = vim.api.nvim_get_current_win()
  local cur_buf = vim.api.nvim_win_get_buf(cur_win)
  local state = get_win_state(cur_win)

  -- ---- render-mode window -> split shows the SOURCE ----
  if state and state.mode == "render" and cur_buf == state.render_buf then
    if not vim.api.nvim_buf_is_valid(state.source_buf) then
      vim.notify("md-render: source buffer is no longer valid", vim.log.levels.WARN)
      return
    end
    vim.cmd { cmd = "split", mods = opts.mods or {} }
    local new_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(new_win, state.source_buf)
    -- The new split inherited render-mode window options from cur_win;
    -- restore the source view's options from the originals stashed on
    -- cur_win when it first went source -> render.
    restore_render_win_opts(new_win, state.source_wo)
    -- New split now shows the source while cur_win still shows render;
    -- both sides are visible, so paint the shadow immediately.
    local session = _toggle_sessions[state.source_buf]
    if session and session._shadow_recompute then session._shadow_recompute() end
    return
  end

  -- ---- source-mode window -> split shows the RENDER ----
  local source_bufnr = cur_buf
  local ok, warn = check_markdown_buffer(source_bufnr)
  if not ok then
    vim.notify(warn, vim.log.levels.WARN)
    return
  end

  local source_cursor_line = vim.api.nvim_win_get_cursor(cur_win)[1]
  -- Snapshot source-window options BEFORE :split, since the new split
  -- inherits them. Stashed on the new split's md_render_state so a later
  -- :MdRenderToggle on the split restores them on the render -> source
  -- transition.
  local source_wo = save_render_win_opts(cur_win)
  local session = get_or_create_toggle_session(source_bufnr, opts)

  -- Split windows have no border — remove content indent for space efficiency.
  if (session.opts.indent or "  ") ~= "" then
    session.opts.indent = ""
    session:rebuild()
  end

  vim.cmd { cmd = "split", mods = opts.mods or {} }
  local new_win = vim.api.nvim_get_current_win()

  -- Image binding: Session.win is single-window. Hand off images from a
  -- previously bound window (e.g. a prior toggle) to the new split.
  if session.win and session.win ~= new_win and vim.api.nvim_win_is_valid(session.win) then
    session:cleanup_images()
    session.win = nil
  end

  vim.api.nvim_win_set_buf(new_win, session.buf)
  session:bind_window(new_win)
  session:scroll_to_source_line(source_cursor_line)
  session:install_float_keymaps(nil, { close_keys = {} })
  vim.wo[new_win].winbar = " Markdown Preview"

  set_win_state(new_win, {
    source_buf = source_bufnr,
    render_buf = session.buf,
    mode = "render",
    source_wo = source_wo,
  })

  -- Return focus to the source window — the render split is a preview,
  -- not an editing target.
  vim.cmd.wincmd "p"

  -- Initial shadow paint. Neither WinEnter nor CursorMoved fires
  -- reliably from the :split + wincmd p sequence, so call directly.
  if session._shadow_recompute then session._shadow_recompute() end
end

-- =====================================================================
-- Auto-toggle: render outside Insert mode, source while editing.
-- (`_auto_state` and `auto_augroup` are declared earlier so install_source_watcher
--  can reference them in its BufWipeout cleanup.)
-- =====================================================================

-- Insert-entry keys that, when pressed on a render buffer in auto mode,
-- toggle to source and then re-fire so the user lands in Insert mode at
-- the corresponding spot. (Visual-mode and operator-pending keys are
-- intentionally left alone.)
local AUTO_INSERT_KEYS = { "i", "I", "a", "A", "o", "O" }

local function install_auto_insert_keymaps(render_buf)
  for _, key in ipairs(AUTO_INSERT_KEYS) do
    vim.keymap.set("n", key, function()
      MdPreview.toggle()
      vim.schedule(function()
        vim.api.nvim_feedkeys(key, "n", false)
      end)
    end, {
      buffer = render_buf,
      noremap = true,
      silent = true,
      desc = "md-render auto: switch to source then " .. key,
    })
  end
end

local function uninstall_auto_insert_keymaps(render_buf)
  if not vim.api.nvim_buf_is_valid(render_buf) then return end
  for _, key in ipairs(AUTO_INSERT_KEYS) do
    pcall(vim.keymap.del, "n", key, { buffer = render_buf })
  end
end

--- Resolve the source buffer that auto_on/off/toggle should act on.
--- When the current window is showing a render buffer, follow back to its
--- source so the user can call auto_off / auto_toggle without first
--- swapping back to source mode.
---@return integer
local function get_auto_target_buf()
  local win = vim.api.nvim_get_current_win()
  local win_state = get_win_state(win)
  if win_state and win_state.mode == "render"
    and vim.api.nvim_buf_is_valid(win_state.source_buf) then
    return win_state.source_buf
  end
  return vim.api.nvim_get_current_buf()
end

--- Schedule a debounced auto-transition for `bufnr` toward `target_mode`.
--- 50ms debounce coalesces rapid Insert-mode boundary events
--- (e.g. `i<Esc>i<Esc>` or `<C-o>` round-trips).
---@param bufnr integer
---@param target_mode "source"|"render"
local function schedule_auto_transition(bufnr, target_mode)
  local state = _auto_state[bufnr]
  if not state then return end
  local key = (target_mode == "source") and "in_timer" or "leave_timer"
  if state[key] then state[key]:stop() end
  state[key] = vim.defer_fn(function()
    state[key] = nil
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    if not vim.b[bufnr].md_render_auto then return end

    local win = vim.api.nvim_get_current_win()
    local cur_buf = vim.api.nvim_win_get_buf(win)
    local win_state = get_win_state(win)

    if target_mode == "source" then
      if win_state and win_state.mode == "render" and win_state.source_buf == bufnr then
        MdPreview.toggle()
      end
    else  -- "render"
      if cur_buf == bufnr and (not win_state or win_state.mode ~= "render") then
        MdPreview.toggle()
      end
    end
  end, 50)
end

--- Enable auto-toggle for the current buffer and immediately swap to render.
---@param opts? { max_width?: integer }
function MdPreview.auto_on(opts)
  local bufnr = get_auto_target_buf()
  local ok, warn = check_markdown_buffer(bufnr)
  if not ok then
    vim.notify(warn, vim.log.levels.WARN)
    return
  end
  if vim.b[bufnr].md_render_auto then return end

  vim.b[bufnr].md_render_auto = true
  _auto_state[bufnr] = { in_timer = nil, leave_timer = nil }

  -- Only InsertLeave is needed: the InsertEnter side is driven by buffer-local
  -- keymaps on the render buffer (see install_auto_insert_keymaps), since the
  -- render buffer is nomodifiable and would never fire InsertEnter on its own.
  local augroup = vim.api.nvim_create_augroup(auto_augroup(bufnr), { clear = true })
  vim.api.nvim_create_autocmd("InsertLeave", {
    group = augroup,
    buffer = bufnr,
    callback = function() schedule_auto_transition(bufnr, "render") end,
  })

  local win = vim.api.nvim_get_current_win()
  local win_state = get_win_state(win)
  if not win_state or win_state.mode ~= "render" then
    MdPreview.toggle(opts)
  end

  -- Install Insert-entry keymaps on the render buffer (now created by toggle).
  local session = _toggle_sessions[bufnr]
  if session and vim.api.nvim_buf_is_valid(session.buf) then
    install_auto_insert_keymaps(session.buf)
  end
end

--- Disable auto-toggle for the current buffer; leave the displayed mode untouched.
function MdPreview.auto_off()
  local bufnr = get_auto_target_buf()
  if not vim.b[bufnr].md_render_auto then return end

  vim.b[bufnr].md_render_auto = nil
  local state = _auto_state[bufnr]
  if state then
    if state.in_timer then state.in_timer:stop() end
    if state.leave_timer then state.leave_timer:stop() end
    _auto_state[bufnr] = nil
  end
  pcall(vim.api.nvim_del_augroup_by_name, auto_augroup(bufnr))

  local session = _toggle_sessions[bufnr]
  if session then uninstall_auto_insert_keymaps(session.buf) end
end

--- Flip auto-toggle state for the current buffer.
---@param opts? { max_width?: integer }
function MdPreview.auto_toggle(opts)
  local bufnr = get_auto_target_buf()
  if vim.b[bufnr].md_render_auto then
    MdPreview.auto_off()
  else
    MdPreview.auto_on(opts)
  end
end

-- Expose for tests
MdPreview._toggle_sessions = _toggle_sessions
MdPreview._schedule_live_rebuild = schedule_live_rebuild
MdPreview._live_update_augroup = live_update_augroup
MdPreview._auto_state = _auto_state
MdPreview._auto_augroup = auto_augroup
MdPreview._schedule_auto_transition = schedule_auto_transition

-- =====================================================================
-- show_demo: demo floating window (existing behavior)
-- =====================================================================

--- Show a demo floating window with all supported Markdown notations
MdPreview.show_demo = function()
  -- Resolve plugin root for demo image paths
  local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h")
  local demo_img_dir = plugin_root .. "/assets/demo"

  local demo_lines = vim.split(table.concat({
    "## Markdown Rendering Features",
    "",
    "**Bold**, ~~strikethrough~~, `inline code`, and [links](https://neovim.io) — all rendered inline. Bare URLs like https://neovim.io stay clickable. Long ones like https://github.com/neovim/neovim/blob/master/src/nvim/api/buffer.c#L123-L456 are truncated. Obsidian ==highlight== and `%%comments%%` also work.",
    "",
    "### Code & Tables",
    "",
    "```lua",
    'local function greet(name) return "Hello, " .. name end',
    "-- This line is intentionally long to demonstrate that code lines exceeding the max width are truncated with an ellipsis indicator",
    "```",
    "",
    "| Feature | Description | Syntax |",
    "|---------|-------------|--------|",
    "| **Bold** / ~~strike~~ | Inline formatting is rendered inside table cells | `**text**` / `~~text~~` |",
    "| Truncation | Cells that exceed the available width are automatically truncated with an ellipsis | Long content is gracefully handled |",
    "",
    "### Lists",
    "",
    "- First item",
    "- Second item with **bold** and `code`",
    "  - Nested item",
    "  - Another nested",
    "    - Deeply nested",
    "      - Back to level 0 style",
    "- Back to top level",
    "",
    "1. Ordered first",
    "2. Ordered second",
    "  1. Nested ordered",
    "  2. Nested second",
    "3. Back to top",
    "",
    "- [ ] Unchecked task",
    "- [x] Completed task",
    "- [-] In-progress task",
    "",
    "### Callouts & Folds",
    "",
    "> [!NOTE]",
    "> Standard callout. Five types: `NOTE`, `TIP`, `IMPORTANT`, `WARNING`, `CAUTION`.",
    "",
    "> [!TIP]- Foldable (collapsed)",
    "> Hidden until you click the header. Supports **multiple lines**.",
    "> Click the fold indicator to toggle.",
    "",
    "> [!WARNING]+ Foldable (expanded)",
    "> Visible by default, click to collapse.",
    "> ```lua",
    "> local msg = 'Code blocks inside callouts get treesitter highlighting!'",
    "> ```",
    "",
    "> [!custom] Custom types work too",
    "> Any `[!type]` is rendered as a callout.",
    "> - Lists inside callouts",
    "> - Also get bullet symbols",
    ">   - Including nested ones",
    "> 1. Ordered lists too",
    "> 2. Work just fine",
    "",
    "### Expandable Content",
    "",
    "```bash",
    "# This line is intentionally very long to demonstrate the expandable code block feature — click the underlined … to see the full content and scroll horizontally",
    "echo 'Click the … on truncated lines to expand, click again to collapse'",
    "```",
    "",
    "### Collapsible Details",
    "",
    "<details>",
    "<summary>Click to expand this section</summary>",
    "",
    "This content is hidden by default. It supports **bold**, `code`, and [links](https://neovim.io).",
    "",
    "</details>",
    "",
    "<details open>",
    "<summary>Open by default</summary>",
    "",
    "The `open` attribute makes it expanded initially. Click to collapse.",
    "",
    "</details>",
    "",
    "### 日本語テキストの折り返し",
    "",
    "budoux.luaがインストールされていれば、BudouXによる自然な分節処理で日本語テキストを文節の区切りで改行します。未インストールの場合は1文字ずつ分割して折り返します。",
    "",
    "句読点「、」や閉じ括弧「)」が行頭に来ないよう禁則処理(JIS X 4051)を適用。開き括弧「(」は行末に残さず次の行へ送ります。",
    "",
    "> [!NOTE] 日本語コールアウト",
    "> コールアウト内でも禁則処理は有効。budoux.luaがあればBudouXの分節処理も適用され、長い文章を自然な位置で折り返します。",
    "",
    "### Qiita Extensions",
    "",
    "```ruby:app/models/user.rb",
    "class User < ApplicationRecord",
    "  validates :name, presence: true",
    "end",
    "```",
    "",
    ":::note info",
    "Qiitaのノート記法(info)です。`:::note info` で始まり `:::` で閉じます。",
    ":::",
    "",
    ":::note warn",
    "警告メッセージを表示できます。",
    ":::",
    "",
    ":::note alert",
    "重要な注意事項を強調できます。",
    ":::",
    "",
    "### Images",
    "",
    "| PNG | JPEG | WebP | GIF | Animated GIF |",
    "|-----|------|------|-----|--------------|",
    "| ![PNG](" .. demo_img_dir .. "/test.png) | ![JPEG](" .. demo_img_dir .. "/test.jpg) | ![WebP](" .. demo_img_dir .. "/test.webp) | ![GIF](" .. demo_img_dir .. "/test.gif) | ![Animated GIF](" .. demo_img_dir .. "/test_animated.gif) |",
    "",
    "### Web Images",
    "",
    "| Static (http.cat) | Animated GIF (Nyan Cat) |",
    "|--------------------|-----------------------|",
    "| ![HTTP 200](https://http.cat/200.jpg) | ![Nyan Cat](https://media.giphy.com/media/sIIhZliB2McAo/giphy.gif) |",
    "",
    "### Video",
    "",
    '<video src="' .. demo_img_dir .. '/test.mp4" controls></video>',
    "",
    "### Mermaid Diagram",
    "",
    "```mermaid",
    "graph LR",
    "    A[Markdown] --> B[Parser]",
    "    B --> C[ContentBuilder]",
    "    C --> D[FloatWin]",
    "    D --> E[Display]",
    "```",
  }, "\n"), "\n")

  if demo_float_win:close_if_valid() then
    return
  end

  local fold_state = {}
  local expand_state = {}
  local opts = { buf_dir = plugin_root }
  local image_state = nil

  local buf = vim.api.nvim_create_buf(false, true)
  local ns = vim.api.nvim_create_namespace "md_render_demo"

  require("md-render").setup_highlights()

  local content
  local win

  local function rebuild()
    opts.fold_state = fold_state
    opts.expand_state = expand_state
    opts.autolinks = {
      { key_prefix = "JIRA-", url_template = "https://jira.example.com/browse/JIRA-<num>" },
    }
    local new_content = MdPreview.build_content(demo_lines, opts)
    vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    display_utils.apply_content_to_buffer(buf, ns, new_content)
    vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
    local any_expanded = false
    for _, v in pairs(expand_state) do
      if v then any_expanded = true; break end
    end
    vim.api.nvim_set_option_value("wrap", not any_expanded, { win = win })
    content = new_content
    image_state = display_utils.update_images(image_state, win, content)
  end

  opts.autolinks = {
    { key_prefix = "JIRA-", url_template = "https://jira.example.com/browse/JIRA-<num>" },
  }
  content = MdPreview.build_content(demo_lines, opts)
  display_utils.apply_content_to_buffer(buf, ns, content)
  win = display_utils.open_float_window(buf, content, demo_float_win, {
    title = " Markdown Rendering Demo ",
    position = "center",
    enter = true,
  })

  for _, fold in ipairs(content.callout_folds) do
    fold_state[fold.source_line] = fold.collapsed
  end

  image_state = display_utils.setup_images(win, content, ns, {
    buf = buf,
    build_content = function()
      opts.fold_state = fold_state
      opts.expand_state = expand_state
      opts.autolinks = {
        { key_prefix = "JIRA-", url_template = "https://jira.example.com/browse/JIRA-<num>" },
      }
      content = MdPreview.build_content(demo_lines, opts)
      return content
    end,
  })

  display_utils.setup_float_keymaps(buf, ns, win, content, demo_float_win, {
    get_content = function()
      return content
    end,
    on_fold_toggle = function(source_line, collapsed)
      fold_state[source_line] = collapsed
      rebuild()
    end,
    on_expand_toggle = function(block_id, expanded)
      expand_state[block_id] = expanded
      rebuild()
    end,
  })
end

-- Expose Session for tests and toggle implementation
MdPreview._Session = Session

return MdPreview
