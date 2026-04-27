local FloatWin = require "md-render.float_win"
local TabWin = require "md-render.tab_win"
local cb = require "md-render.content_builder"
local display_utils = require "md-render.display_utils"
local ContentBuilder = cb.ContentBuilder

local float_win = FloatWin.new "md_render_preview_float"
local demo_float_win = FloatWin.new "md_render_demo_float"
local tab_win = TabWin.new "md_render_preview_tab"

local MdPreview = {}

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
  local max_width = opts.max_width or 80

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

  require("md-render").setup_highlights()

  self.opts.fold_state = self.fold_state
  self.opts.expand_state = self.expand_state
  self.content = MdPreview.build_content(self.source_lines, self.opts)
  display_utils.apply_content_to_buffer(self.buf, self.ns, self.content)

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

--- Map a source-buffer line to the corresponding rendered line.
---@param src_line integer 1-indexed source line
---@return integer  1-indexed rendered line
function Session:source_to_rendered(src_line)
  local map = self.content.source_line_map
  if not map or #map == 0 then return 1 end
  for i, sl in ipairs(map) do
    if sl >= src_line then return i end
  end
  return #map
end

--- Map a rendered line back to the source-buffer line.
---@param rendered_line integer 1-indexed rendered line
---@return integer? 1-indexed source line, or nil if out of range
function Session:rendered_to_source(rendered_line)
  local map = self.content.source_line_map
  if map and rendered_line <= #map then
    return map[rendered_line]
  end
  return nil
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

local function toggle_buf_augroup(buf)
  return "md_render_toggle_buf_" .. buf
end

local function toggle_src_augroup(bufnr)
  return "md_render_toggle_src_" .. bufnr
end

local function live_update_augroup(bufnr)
  return "md_render_toggle_live_" .. bufnr
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

--- Apply read-only buffer options used by toggle-mode render buffers.
---@param session MdRender.Session
local function apply_render_buf_options(session)
  vim.bo[session.buf].buftype = "nofile"
  vim.bo[session.buf].bufhidden = "hide"
  vim.bo[session.buf].swapfile = false
  vim.bo[session.buf].modifiable = false
  vim.bo[session.buf].readonly = true
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
        vim.bo[session.buf].readonly = true
      end
    end,
  })

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = augroup,
    buffer = session.buf,
    callback = function()
      vim.notify(
        "md-render: render buffer is read-only; reverting. Use :MdRenderToggle to edit the source.",
        vim.log.levels.WARN
      )
      session:rebuild()
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
      session:cleanup_images()
      if vim.api.nvim_buf_is_valid(session.buf) then
        pcall(vim.api.nvim_buf_delete, session.buf, { force = true })
      end
      _toggle_sessions[source_bufnr] = nil
      pcall(vim.api.nvim_del_augroup_by_name, toggle_buf_augroup(session.buf))
      pcall(vim.api.nvim_del_augroup_by_name, toggle_src_augroup(source_bufnr))
      pcall(vim.api.nvim_del_augroup_by_name, live_update_augroup(source_bufnr))
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

  local session = get_or_create_toggle_session(source_bufnr, opts)

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
  })
end

-- Expose for tests
MdPreview._toggle_sessions = _toggle_sessions
MdPreview._schedule_live_rebuild = schedule_live_rebuild
MdPreview._live_update_augroup = live_update_augroup

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
