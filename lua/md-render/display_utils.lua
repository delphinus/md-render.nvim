local FloatWin = require "md-render.float_win"

local M = {}

local _osc8_supported = nil

--- Check if the terminal supports OSC 8 hyperlinks
---@return boolean
function M.supports_osc8()
  if _osc8_supported ~= nil then
    return _osc8_supported
  end

  local term = vim.env.TERM_PROGRAM
  if term then
    local osc8_terminals = {
      ["iTerm.app"] = true,
      ["WezTerm"] = true,
      ["kitty"] = true,
      ["foot"] = true,
      ["contour"] = true,
      ["rio"] = true,
      ["alacritty"] = true,
      ["ghostty"] = true,
    }
    if osc8_terminals[term] then
      _osc8_supported = true
      return true
    end
  end

  -- VTE-based terminals (GNOME Terminal, etc.)
  if vim.env.VTE_VERSION then
    _osc8_supported = true
    return true
  end

  -- Windows Terminal
  if vim.env.WT_SESSION then
    _osc8_supported = true
    return true
  end

  _osc8_supported = false
  return false
end

function M.reset_osc8_cache()
  _osc8_supported = nil
end

--- Apply treesitter syntax highlighting to code blocks
---@param buf integer
---@param ns integer
---@param content MdRender.Content
function M.apply_treesitter_highlights(buf, ns, content)
  for _, block in ipairs(content.code_blocks or {}) do
    local prefix_len = block.prefix_len or 2
    local code_lines
    if block.source_lines then
      -- Use original non-truncated lines for accurate treesitter parsing
      code_lines = block.source_lines
    else
      code_lines = {}
      for i = block.start_line, block.end_line do
        local line = content.lines[i + 1] or ""
        table.insert(code_lines, line:sub(prefix_len + 1))
      end
    end
    local code_text = table.concat(code_lines, "\n")

    local ok, parser = pcall(vim.treesitter.get_string_parser, code_text, block.language)
    if not ok or not parser then goto continue end

    local trees = parser:parse()
    if not trees or #trees == 0 then goto continue end

    local query = vim.treesitter.query.get(block.language, "highlights")
    if not query then goto continue end

    for id, node in query:iter_captures(trees[1]:root(), code_text) do
      local name = query.captures[id]
      local sr, sc, er, ec = node:range()
      local buf_sr = block.start_line + sr
      local buf_sc = sc + prefix_len
      local buf_er = block.start_line + er
      local buf_ec = ec + prefix_len

      -- Clamp to actual line lengths to handle truncated lines correctly.
      local start_line_text = content.lines[buf_sr + 1]
      if start_line_text and buf_sc > #start_line_text then
        if buf_sr == buf_er then
          goto skip_capture
        end
        buf_sr = buf_sr + 1
        buf_sc = prefix_len
      end

      local end_line_text = content.lines[buf_er + 1]
      if end_line_text and buf_ec > #end_line_text then
        buf_ec = #end_line_text
      end

      pcall(vim.api.nvim_buf_set_extmark, buf, ns, buf_sr, buf_sc, {
        end_row = buf_er,
        end_col = buf_ec,
        hl_group = "@" .. name .. "." .. block.language,
        priority = 4200,
      })
      ::skip_capture::
    end

    ::continue::
  end
end

--- Apply highlights, link extmarks, and optional title extmark to a buffer
---@param buf integer
---@param ns integer
---@param content MdRender.Content
---@param opts? { title_url?: string }
function M.apply_content_to_buffer(buf, ns, content, opts)
  opts = opts or {}
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, content.lines)

  for _, hl_info in ipairs(content.highlights) do
    local line_text = content.lines[hl_info.line + 1]
    if line_text then
      for _, group in ipairs(hl_info.groups) do
        local end_col = group.end_col
        if end_col == -1 or end_col > #line_text then
          end_col = #line_text
        end
        local extmark_opts = {
          end_col = end_col,
          hl_group = group.hl,
        }
        if group.hl_eol then
          extmark_opts.hl_eol = true
        end
        vim.api.nvim_buf_set_extmark(buf, ns, hl_info.line, group.col, extmark_opts)
      end
    end
  end

  for _, link in ipairs(content.link_metadata) do
    vim.api.nvim_buf_set_extmark(buf, ns, link.line, link.col_start, {
      end_col = link.col_end,
      hl_group = "Underlined",
      url = link.url,
    })
  end

  if opts.title_url and content.title_line and content.title_text then
    vim.api.nvim_buf_set_extmark(buf, ns, content.title_line, 0, {
      end_col = #content.title_text,
      url = opts.title_url,
    })
  end

  M.apply_treesitter_highlights(buf, ns, content)
end

--- Calculate window size and position, open the floating window
---@param buf integer
---@param content MdRender.Content
---@param float_win MdRender.FloatWin
---@param opts? { title?: string, position?: "mouse"|"center", enter?: boolean }
---@return integer win
function M.open_float_window(buf, content, float_win, opts)
  opts = opts or {}
  local title = opts.title or " Markdown "
  local position = opts.position or "mouse"
  local enter = opts.enter or false

  local width = 0
  for _, line in ipairs(content.lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  width = math.min(width + 2, math.floor(vim.o.columns * 0.8))
  local height = math.min(#content.lines, math.floor(vim.o.lines * 0.8))

  local row, col
  if position == "center" then
    row = math.floor((vim.o.lines - height) / 2) - 1
    col = math.floor((vim.o.columns - width) / 2)
  else
    local mouse_pos = vim.fn.getmousepos()
    row = mouse_pos.screenrow
    col = mouse_pos.screencol
  end

  local total_height = height + 2
  local max_row = vim.o.lines - vim.o.cmdheight - 1

  if row + total_height > max_row then
    row = math.max(0, max_row - total_height)
  end
  if col + width > vim.o.columns then
    col = math.max(0, vim.o.columns - width)
  end

  local win = vim.api.nvim_open_win(buf, enter, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = title,
    title_pos = "center",
  })

  float_win:setup(win, { auto_close = not enter })

  vim.api.nvim_set_option_value("wrap", true, { win = win })
  vim.api.nvim_set_option_value("cursorline", true, { win = win })
  vim.wo[win].statusline = " "
  vim.api.nvim_buf_set_option(buf, "modifiable", false)
  vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")

  return win
end

--- Set up keymaps and mouse click handlers for the floating window
---@param buf integer
---@param ns integer
---@param win integer
---@param content MdRender.Content
---@param float_win MdRender.FloatWin
---@param opts? { close_line_idx?: integer, on_fold_toggle?: fun(source_line: integer, collapsed: boolean), on_expand_toggle?: fun(block_id: integer, expanded: boolean), get_content?: fun(): MdRender.Content }
function M.setup_float_keymaps(buf, ns, win, content, float_win, opts)
  opts = opts or {}
  local close_line_idx = opts.close_line_idx
  local on_fold_toggle = opts.on_fold_toggle
  local on_expand_toggle = opts.on_expand_toggle
  local get_content = opts.get_content or function()
    return content
  end

  local close_keys = { "q", "<Esc>", "<CR>" }
  for _, key in ipairs(close_keys) do
    vim.api.nvim_buf_set_keymap(buf, "n", key, ":close<CR>", { noremap = true, silent = true })
  end

  vim.keymap.set("n", "<LeftRelease>", function()
    local mouse = vim.fn.getmousepos()
    if mouse.winid == win then
      if close_line_idx and mouse.line == close_line_idx + 1 then
        float_win:close_if_valid()
        return
      end

      local cur_content = get_content()
      local click_line = mouse.line - 1 -- 0-indexed
      local click_col = mouse.column - 1

      -- Helper: check if click is on an internal anchor or URL extmark
      local function try_open_url()
        local extmarks =
          vim.api.nvim_buf_get_extmarks(buf, ns, { click_line, 0 }, { click_line + 1, 0 }, { details = true })
        for _, mark in ipairs(extmarks) do
          local _, _, start_col, details = unpack(mark)
          if details.url then
            local end_col = details.end_col or (start_col + 1)
            if click_col >= start_col and click_col < end_col then
              -- Handle internal footnote anchors by scrolling
              local anchor = details.url:match("^#(footnote%-.+)$")
              if anchor and cur_content.footnote_anchors then
                local target_line = cur_content.footnote_anchors[anchor]
                if target_line then
                  vim.api.nvim_win_set_cursor(win, { target_line + 1, 0 })
                  return true
                end
              end
              -- External URLs: skip if OSC8 terminal handles them natively
              if M.supports_osc8() then return false end
              vim.notify("Opening: " .. details.url, vim.log.levels.INFO)
              vim.ui.open(details.url)
              return true
            end
          end
        end
        return false
      end

      -- Check for foldable callout header click
      if on_fold_toggle and cur_content.callout_folds then
        for _, fold in ipairs(cur_content.callout_folds) do
          if fold.header_line == click_line then
            on_fold_toggle(fold.source_line, not fold.collapsed)
            return
          end
        end
      end

      -- Check for expandable region click (code blocks / tables)
      if on_expand_toggle and cur_content.expandable_regions then
        for _, region in ipairs(cur_content.expandable_regions) do
          if click_line >= region.start_line and click_line <= region.end_line then
            -- If click is on a URL, open it instead of toggling expansion
            if try_open_url() then return end
            on_expand_toggle(region.block_id, not region.expanded)
            return
          end
        end
      end

      -- In OSC 8 terminals, the terminal handles link clicks natively.
      try_open_url()
    end
  end, { buffer = buf, noremap = true, silent = true })
end

---@class MdRender.AnimState
---@field frame_ids integer[]  Kitty image IDs for each frame
---@field current integer  current frame index (1-based)
---@field timer any  uv timer for frame cycling
---@field tmp_dir string  temp directory to clean up

---@class MdRender.ImageState
---@field placements MdRender.ImagePlacement[]
---@field image_ids table<string, integer>  path -> Kitty image ID (transmitted)
---@field anims table<string, MdRender.AnimState>  path -> animation state
---@field win integer
---@field redraw_timer any?
---@field autocmd_ids integer[]

--- Transmit all images and display them. Returns state for re-display and cleanup.
---@param win integer
---@param content MdRender.Content
---@return MdRender.ImageState?
function M.setup_images(win, content)
  if not content.image_placements or #content.image_placements == 0 then
    return nil
  end

  local image = require "md-render.image"
  if not image.supports_kitty() then return nil end

  local uv = vim.uv or vim.loop

  ---@type MdRender.ImageState
  local state = {
    placements = content.image_placements,
    image_ids = {},
    anims = {},
    win = win,
    redraw_timer = nil,
    autocmd_ids = {},
  }

  -- Redraw all images (called after redraw! to re-place all at once)
  local function redraw_images()
    if not vim.api.nvim_win_is_valid(state.win) then return end
    vim.cmd("redraw!")
    for _, placement in ipairs(state.placements) do
      local anim = state.anims[placement.path]
      if anim then
        local id = anim.frame_ids[anim.current]
        if id then
          image.put_image(id, state.win, placement.line, placement.col, placement.cols, placement.rows, nil, placement.img_w, placement.img_h)
        end
      else
        local id = state.image_ids[placement.path]
        if id then
          image.put_image(id, state.win, placement.line, placement.col, placement.cols, placement.rows, nil, placement.img_w, placement.img_h)
        end
      end
    end
  end

  local function schedule_redraw()
    if state.redraw_timer then
      state.redraw_timer:stop()
    end
    state.redraw_timer = vim.defer_fn(function()
      redraw_images()
    end, 50)
  end

  --- Process a single placement: download (if URL), convert, transmit, and display.
  ---@param placement MdRender.ImagePlacement
  local function process_placement(placement)
    local function on_path_ready(path)
      if not path then return end
      if not vim.api.nvim_win_is_valid(state.win) then return end

      placement.path = path
      placement.animated = image.is_animated_gif(path)

      -- Recalculate display size with real dimensions
      local img_w, img_h = image.image_dimensions(path)
      if img_w and img_h then
        placement.cols, placement.rows = image.calc_display_size(img_w, img_h, placement.cols, placement.rows)
        placement.img_w = img_w
        placement.img_h = img_h
      end

      if placement.animated then
        image.transmit_animated_async(path, function(frame_ids, tmp_dir)
          if not frame_ids or not vim.api.nvim_win_is_valid(state.win) then return end
          state.image_ids[path] = frame_ids[1]
          local anim = {
            frame_ids = frame_ids,
            current = 1,
            tmp_dir = tmp_dir,
          }
          state.anims[path] = anim
          -- Start animation timer
          local timer = (vim.uv or vim.loop).new_timer()
          anim.timer = timer
          timer:start(0, 200, vim.schedule_wrap(function()
            if not vim.api.nvim_win_is_valid(state.win) then
              timer:stop()
              return
            end
            anim.current = anim.current % #anim.frame_ids + 1
            image.put_image(anim.frame_ids[anim.current], state.win,
              placement.line, placement.col, placement.cols, placement.rows, nil, placement.img_w, placement.img_h)
          end))
        end)
      else
        image.transmit_image_async(path, function(id)
          if not id or not vim.api.nvim_win_is_valid(state.win) then return end
          state.image_ids[path] = id
          -- Use schedule_redraw to re-place ALL images together after redraw!
          schedule_redraw()
        end)
      end
    end

    if placement.path then
      on_path_ready(placement.path)
    elseif placement.src_url then
      image.download_async(placement.src_url, function(path)
        on_path_ready(path)
      end)
    end
  end

  -- Phase 1: Kick off async processing for all placements
  for _, placement in ipairs(state.placements) do
    process_placement(placement)
  end

  -- Initial display of already-cached images
  schedule_redraw()

  -- Re-display on scroll and cursor movement
  local augroup = vim.api.nvim_create_augroup("md_render_images_" .. win, { clear = true })
  for _, event in ipairs({ "WinScrolled", "CursorMoved", "CursorMovedI" }) do
    local id = vim.api.nvim_create_autocmd(event, {
      group = augroup,
      callback = function(ev)
        -- WinScrolled: check if it's our window
        if event == "WinScrolled" then
          if tostring(ev.match) ~= tostring(state.win) then return end
        else
          -- CursorMoved: check if cursor is in our window
          if vim.api.nvim_get_current_win() ~= state.win then return end
        end
        schedule_redraw()
      end,
    })
    table.insert(state.autocmd_ids, id)
  end

  return state
end

--- Update image state with new content (after fold/expand toggle)
---@param state MdRender.ImageState?
---@param win integer
---@param content MdRender.Content
---@return MdRender.ImageState?
function M.update_images(state, win, content)
  -- Clean up old images that are no longer in placements
  if state then
    local image = require "md-render.image"
    local new_paths = {}
    if content.image_placements then
      for _, p in ipairs(content.image_placements) do
        new_paths[p.path] = true
      end
    end
    for path, id in pairs(state.image_ids) do
      if not new_paths[path] then
        image.delete_image(id)
        state.image_ids[path] = nil
      end
    end
  end

  M.cleanup_images(state)
  return M.setup_images(win, content)
end

--- Clean up all images and autocmds
---@param state MdRender.ImageState?
function M.cleanup_images(state)
  if not state then return end
  local image = require "md-render.image"

  -- Delete static images from terminal
  local ids = {}
  for _, id in pairs(state.image_ids) do
    table.insert(ids, id)
  end

  -- Stop animation timers, delete frame images, clean up temp dirs
  for _, anim in pairs(state.anims or {}) do
    if anim.timer then
      anim.timer:stop()
      anim.timer:close()
    end
    for _, fid in ipairs(anim.frame_ids) do
      table.insert(ids, fid)
    end
    if anim.tmp_dir then
      vim.fn.delete(anim.tmp_dir, "rf")
    end
  end

  image.delete_images(ids)

  -- Stop redraw timer
  if state.redraw_timer then
    state.redraw_timer:stop()
  end

  -- Remove autocmds
  pcall(vim.api.nvim_del_augroup_by_name, "md_render_images_" .. state.win)
end

return M
