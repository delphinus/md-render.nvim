local FloatWin = require "md-render.float_win"

local M = {}

local _osc8_supported = nil

local function is_wezterm()
  return vim.env.TERM_PROGRAM == "WezTerm" or vim.env.WEZTERM_EXECUTABLE ~= nil
end

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

  -- Fallback: detect via terminal-specific env vars
  if vim.env.KITTY_WINDOW_ID
    or vim.env.GHOSTTY_RESOURCES_DIR
    or vim.env.WEZTERM_EXECUTABLE then
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
    local line_text = content.lines[link.line + 1]
    if line_text then
      local col_start = link.col_start
      local col_end = link.col_end
      if col_start > #line_text then
        goto next_link
      end
      if col_end > #line_text then
        col_end = #line_text
      end
      local hl
      if link.url:match "^#" then
        hl = "MdRenderLinkAnchor"
      elseif link.url:match "^obsidian://" then
        hl = "MdRenderLinkObsidian"
      else
        hl = "Underlined"
      end
      vim.api.nvim_buf_set_extmark(buf, ns, link.line, col_start, {
        end_col = col_end,
        hl_group = hl,
        url = link.url,
      })
    end
    ::next_link::
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
    width = math.max(width, vim.api.nvim_strwidth(line))
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
              -- Handle internal anchor links by scrolling
              local anchor = details.url:match "^#(.+)$"
              if anchor then
                -- Footnote anchors
                if cur_content.footnote_anchors then
                  local target_line = cur_content.footnote_anchors[anchor]
                  if target_line then
                    vim.api.nvim_win_set_cursor(win, { target_line + 1, 0 })
                    return true
                  end
                end
                -- Heading anchors
                if cur_content.heading_anchors then
                  local target_line = cur_content.heading_anchors[anchor]
                  if target_line then
                    vim.api.nvim_win_set_cursor(win, { target_line + 1, 0 })
                    return true
                  end
                end
                return true
              end
              -- Obsidian links: always open via system handler
              if details.url:match "^obsidian://" then
                vim.notify("Opening: " .. details.url, vim.log.levels.INFO)
                vim.ui.open(details.url)
                return true
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
---@param ns integer?
---@param opts? { buf?: integer, build_content?: fun(): MdRender.Content }
---@return MdRender.ImageState?
function M.setup_images(win, content, ns, opts)
  if not content.image_placements or #content.image_placements == 0 then
    return nil
  end

  local image = require "md-render.image"
  if not image.supports_kitty() then return nil end

  -- Clear all stale images from terminal on first use per Neovim session.
  -- Previous sessions may have left image data in terminal memory (IDs persist
  -- across Neovim restarts but cleanup commands may not have been processed).
  image.clear_all()

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

  -- When opts.buf and opts.build_content are provided, automatically rebuild
  -- content after URL image downloads so that layout reflects actual image
  -- dimensions. Debounced to avoid cascading rebuilds.
  local on_download
  if opts and opts.buf and opts.build_content then
    on_download = function()
      if state._rebuild_timer then
        state._rebuild_timer:stop()
      end
      state._rebuild_timer = vim.defer_fn(function()
        state._rebuild_timer = nil
        if not vim.api.nvim_win_is_valid(win) then return end
        local buf = opts.buf
        if not vim.api.nvim_buf_is_valid(buf) then return end
        local new_content = opts.build_content()
        local was_modifiable = vim.bo[buf].modifiable
        vim.bo[buf].modifiable = true
        vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
        M.apply_content_to_buffer(buf, ns, new_content)
        vim.bo[buf].modifiable = was_modifiable
        M.update_images(state, win, new_content)
      end, 150)
    end
  end

  -- Forward declaration (process_placement is defined after redraw_images
  -- but referenced from the retry logic inside redraw_images)
  local process_placement

  -- Redraw all images (called after redraw! to re-place all at once)
  local MAX_RETRIES = 3

  local function place_images()
    if not vim.api.nvim_win_is_valid(state.win) then return end

    -- Retry transmit for images that have a path but no ID (up to MAX_RETRIES)
    for _, placement in ipairs(state.placements) do
      if placement.path
        and not state.image_ids[placement.path]
        and not state.anims[placement.path]
        and (not placement._retries or placement._retries < MAX_RETRIES)
      then
        placement._retries = (placement._retries or 0) + 1
        process_placement(placement)
      end
    end

    -- Batch all image placement commands into a single term_write to
    -- avoid per-image TTY open/close overhead and ensure atomicity.
    image.begin_batch()
    local ok, err = pcall(function()
      -- Clear existing placements before re-placing.
      for _, id in pairs(state.image_ids) do
        image.clear_placements(id)
      end
      -- Clear only the currently displayed animation frame (not all frames).
      -- Previous frames have no active placement, so clearing them is unnecessary.
      for _, anim in pairs(state.anims) do
        local current_id = anim.frame_ids[anim.current]
        if current_id then
          image.clear_placements(current_id)
        end
      end
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
    end)
    image.flush_batch()
    if not ok then
      vim.notify("md-render: image redraw error: " .. tostring(err), vim.log.levels.WARN)
    end
  end

  -- Single shared animation timer for all animated images.
  -- Having one timer (instead of per-animation timers) avoids redundant
  -- place_images() calls that cause flickering when multiple animations
  -- are visible at the same time.
  local anim_timer = (vim.uv or vim.loop).new_timer()
  state.anim_timer = anim_timer

  local function start_anim_timer()
    -- Check if any animation has multiple frames
    local has_multi = false
    for _, anim in pairs(state.anims) do
      if #anim.frame_ids > 1 then
        has_multi = true
        break
      end
    end
    if not has_multi then
      anim_timer:stop()
      return
    end
    if anim_timer:is_active() then return end
    anim_timer:start(200, 200, vim.schedule_wrap(function()
      if not vim.api.nvim_win_is_valid(state.win) then
        anim_timer:stop()
        return
      end
      -- Clear only animation previous frames, then re-place ALL images.
      -- - Animation frames must be cleared for the new frame to show
      --   (WezTerm doesn't visually replace overlapping placements).
      -- - Static images are NOT cleared but still re-placed every tick
      --   because WezTerm removes placements when TUI rewrites cells.
      -- - Clearing must happen BEFORE placing (clear after put causes
      --   WezTerm to remove the just-placed images too).
      for _, anim in pairs(state.anims) do
        if #anim.frame_ids > 1 then
          local prev_id = anim.frame_ids[anim.current]
          anim.current = anim.current % #anim.frame_ids + 1
          if prev_id then
            image.clear_placements(prev_id)
          end
        end
      end
      image.begin_batch()
      local ok, err = pcall(function()
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
      end)
      image.flush_batch()
      if not ok then
        vim.notify("md-render: animation error: " .. tostring(err), vim.log.levels.WARN)
      end
    end))
  end

  -- Pause all animation timers (during scroll/redraw to avoid racing with redraw!)
  local function pause_anim_timers()
    anim_timer:stop()
  end

  -- Resume all animation timers
  local function resume_anim_timers()
    start_anim_timer()
  end

  local function redraw_images()
    state.redraw_timer = nil
    if not vim.api.nvim_win_is_valid(state.win) then return end
    -- Pause animation during redraw! to prevent concurrent placement writes
    pause_anim_timers()
    if is_wezterm() then
      -- WezTerm clears all Kitty Graphics placements on redraw!.
      -- Skip redraw! (screen is already up-to-date after WinScrolled)
      -- and wrap clear+place in a synchronized update (DEC mode 2026)
      -- so the terminal renders the transition atomically — no flash.
      -- Note: we cannot wrap redraw! itself because Neovim's TUI uses
      -- its own ?2026 sequences that would end our sync block prematurely.
      image.begin_sync_update()
      place_images()
      image.end_sync_update()
      resume_anim_timers()
    else
      vim.cmd("redraw!")
      vim.schedule(function()
        place_images()
        resume_anim_timers()
      end)
    end
  end

  local function schedule_redraw()
    if state.redraw_timer then
      state.redraw_timer:stop()
    end
    -- Pause animations immediately on scroll to stop terminal writes
    pause_anim_timers()
    state.redraw_timer = vim.defer_fn(function()
      redraw_images()
    end, 50)
  end

  --- Clear placeholder text from buffer lines for a given placement.
  --- Replaces the image area lines with spaces so the text doesn't show through
  --- the Kitty graphics overlay.
  ---@param placement MdRender.ImagePlacement
  local function clear_placeholder_text(placement, num_rows)
    if not ns then return end
    if not vim.api.nvim_win_is_valid(state.win) then return end
    local buf = vim.api.nvim_win_get_buf(state.win)
    if not vim.api.nvim_buf_is_valid(buf) then return end
    local line_count = vim.api.nvim_buf_line_count(buf)
    local start_line = placement.line
    local end_line = math.min(placement.line + num_rows - 1, line_count - 1)
    -- Find lines that have MdRenderImagePlaceholder extmarks
    local placeholder_lines = {}
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, { start_line, 0 }, { end_line, -1 }, { details = true })
    for _, mark in ipairs(marks) do
      if mark[4] and mark[4].hl_group == "MdRenderImagePlaceholder" then
        placeholder_lines[mark[2]] = true  -- mark[2] is the line number
        vim.api.nvim_buf_del_extmark(buf, ns, mark[1])
      end
    end
    -- Only replace text on lines that had placeholder extmarks
    if next(placeholder_lines) then
      local was_modifiable = vim.bo[buf].modifiable
      vim.bo[buf].modifiable = true
      for line_idx in pairs(placeholder_lines) do
        if line_idx < line_count then
          local old_line = vim.api.nvim_buf_get_lines(buf, line_idx, line_idx + 1, false)[1]
          if old_line then
            local replacement = string.rep(" ", #old_line)
            vim.api.nvim_buf_set_lines(buf, line_idx, line_idx + 1, false, { replacement })
          end
        end
      end
      vim.bo[buf].modifiable = was_modifiable
    end
  end

  --- Transmit animated frames and set up animation timer.
  --- Shared by both animated GIF and video processing paths.
  --- If the same path was already transmitted, reuses frame IDs and
  --- animation state (avoids duplicate frame transmission).
  ---@param path string
  ---@param placement MdRender.ImagePlacement
  ---@param placeholder_rows integer
  -- Track pending transmit_animated_async calls to avoid duplicate
  -- frame extraction for the same path (e.g. same video in English
  -- and Japanese sections of the README).
  local pending_anims = {} -- path -> { {placement, placeholder_rows}, ... }

  local function setup_animation(path, placement, placeholder_rows)
    -- Reuse already-transmitted frames for the same path
    local existing = state.anims[path]
    if existing then
      if existing.frame_w then placement.img_w = existing.frame_w end
      if existing.frame_h then placement.img_h = existing.frame_h end
      clear_placeholder_text(placement, placeholder_rows)
      schedule_redraw()
      return
    end

    -- If transmit is already in progress for this path, queue this
    -- placement to be set up when the transmit completes.
    if pending_anims[path] then
      table.insert(pending_anims[path], { placement, placeholder_rows })
      return
    end

    pending_anims[path] = { { placement, placeholder_rows } }

    image.transmit_animated_async(path, function(frame_ids, tmp_dir, frame_w, frame_h)
      if not frame_ids or not vim.api.nvim_win_is_valid(state.win) then
        pending_anims[path] = nil
        return
      end
      state.image_ids[path] = frame_ids[1]
      local anim = {
        frame_ids = frame_ids,
        current = 1,
        tmp_dir = tmp_dir,
        frame_w = frame_w,
        frame_h = frame_h,
      }
      state.anims[path] = anim

      -- Apply to all queued placements for this path
      for _, entry in ipairs(pending_anims[path]) do
        local p, ph_rows = entry[1], entry[2]
        if frame_w and frame_h then
          p.img_w = frame_w
          p.img_h = frame_h
        end
        clear_placeholder_text(p, ph_rows)
      end
      pending_anims[path] = nil

      -- Only start animation timer for multi-frame sequences
      if #frame_ids > 1 then
        -- Ensure all images (including static) get an initial full placement
        schedule_redraw()
        start_anim_timer()
      else
        -- Single frame: just display it like a static image
        schedule_redraw()
      end
    end)
  end

  --- Process a single placement: download (if URL), convert, transmit, and display.
  ---@param placement MdRender.ImagePlacement
  process_placement = function(placement)
    local function on_path_ready(path)
      if not path then return end
      if not vim.api.nvim_win_is_valid(state.win) then return end

      placement.path = path

      -- Save original placeholder row count before recalculation
      local placeholder_rows = placement.rows

      -- Auto-detect video content when not already flagged (e.g. URL without extension)
      if not placement.video and image.is_video_content(path) then
        placement.video = true
      end

      if placement.video then
        -- Video: always animated, get dimensions via ffprobe
        placement.animated = true
        image.video_dimensions_async(path, function(img_w, img_h)
          if not vim.api.nvim_win_is_valid(state.win) then return end
          if img_w and img_h then
            if not placement.img_w then
              placement.cols, placement.rows = image.calc_display_size(img_w, img_h, placement.cols, placement.rows)
            end
            placement.img_w = img_w
            placement.img_h = img_h
          end
          setup_animation(path, placement, placeholder_rows)
        end)
        return
      end

      placement.animated = image.is_animated_gif(path)

      -- Recalculate display size with real dimensions (skip if table renderer
      -- already pre-computed them — recalculating would undo symmetric centering).
      local img_w, img_h = image.image_dimensions(path)
      if img_w and img_h then
        if not placement.img_w then
          placement.cols, placement.rows = image.calc_display_size(img_w, img_h, placement.cols, placement.rows)
        end
        placement.img_w = img_w
        placement.img_h = img_h
      end

      if placement.animated then
        setup_animation(path, placement, placeholder_rows)
      else
        image.transmit_image_async(path, function(id, tx_w, tx_h)
          if not id or not vim.api.nvim_win_is_valid(state.win) then return end
          -- Update dimensions to match the actually transmitted image
          -- (conversion may have resized it, e.g. large JPEG → 2000px PNG)
          if tx_w and tx_h then
            placement.img_w = tx_w
            placement.img_h = tx_h
          end
          -- Clear all placeholder lines (using original count before recalculation)
          clear_placeholder_text(placement, placeholder_rows)
          state.image_ids[path] = id
          -- Use schedule_redraw to re-place ALL images together after redraw!
          schedule_redraw()
        end)
      end
    end

    if placement.path then
      on_path_ready(placement.path)
    elseif placement.mermaid_source then
      image.render_mermaid_async(placement.mermaid_source, function(path)
        if path then
          placement.mermaid_source = nil
          on_path_ready(path)
        end
      end)
    elseif placement.src_url then
      if placement.video then
        image.download_video_async(placement.src_url, function(path)
          if path and on_download then
            on_download()
          else
            on_path_ready(path)
          end
        end)
      else
        image.download_async(placement.src_url, function(path)
          if path and on_download then
            on_download()
          else
            on_path_ready(path)
          end
        end)
      end
    end
  end

  -- Expose internal functions so update_images can reuse transmitted data
  -- instead of tearing down and re-transmitting everything.
  state.schedule_redraw = schedule_redraw
  state.process_placement = process_placement
  state.clear_placeholder_text = clear_placeholder_text
  state.start_anim_timer = start_anim_timer

  -- Phase 1: Kick off async processing for all placements.
  -- Batch transmit commands so that synchronous transmits (local PNG files)
  -- are sent in a single TTY write, preventing TUI output from interleaving.
  image.begin_batch()
  local ok, err = pcall(function()
    for _, placement in ipairs(state.placements) do
      process_placement(placement)
    end
  end)
  image.flush_batch()
  if not ok then
    vim.notify("md-render: image setup error: " .. tostring(err), vim.log.levels.WARN)
  end

  -- Initial display of already-cached images
  schedule_redraw()

  -- Re-display on scroll and cursor movement; clean up on window close
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

  vim.api.nvim_create_autocmd("WinClosed", {
    group = augroup,
    pattern = tostring(win),
    once = true,
    callback = function()
      M.cleanup_images(state)
    end,
  })

  return state
end

--- Update image state with new content (after fold/expand toggle).
--- Preserves already-transmitted images to avoid flickering; only updates
--- placement positions and transmits genuinely new images.
---@param state MdRender.ImageState?
---@param win integer
---@param content MdRender.Content
---@return MdRender.ImageState?
function M.update_images(state, win, content)
  -- No previous state: full setup from scratch
  if not state then
    return M.setup_images(win, content, nil)
  end

  -- No images in new content: full cleanup
  if not content.image_placements or #content.image_placements == 0 then
    M.cleanup_images(state)
    return nil
  end

  local image = require "md-render.image"

  -- Build set of paths present in new placements
  local new_paths = {}
  for _, p in ipairs(content.image_placements) do
    if p.path then new_paths[p.path] = true end
  end

  -- Remove images no longer in placements
  for path, id in pairs(state.image_ids) do
    if not new_paths[path] then
      image.delete_image(id)
      state.image_ids[path] = nil
    end
  end
  for path, anim in pairs(state.anims) do
    if not new_paths[path] then
      for _, fid in ipairs(anim.frame_ids) do
        image.delete_image(fid)
      end
      if anim.tmp_dir then vim.fn.delete(anim.tmp_dir, "rf") end
      state.anims[path] = nil
    end
  end
  -- Restart or stop shared timer based on remaining animations
  state.start_anim_timer()

  -- Update placements to new positions
  state.placements = content.image_placements

  -- For each placement: clear placeholder text for already-transmitted images,
  -- transmit genuinely new images via the original process_placement closure.
  image.begin_batch()
  for _, placement in ipairs(state.placements) do
    if placement.path then
      if state.image_ids[placement.path] or state.anims[placement.path] then
        -- Already transmitted — just clear placeholder text so it doesn't
        -- show through the graphics overlay.
        state.clear_placeholder_text(placement, placement.rows)
      else
        -- New image: transmit, clear placeholder, and register in state
        state.process_placement(placement)
      end
    end
  end
  image.flush_batch()

  -- Re-place all images at their updated positions
  state.schedule_redraw()

  return state
end

--- Clean up all images and autocmds
---@param state MdRender.ImageState?
function M.cleanup_images(state)
  if not state then return end
  local image = require "md-render.image"

  -- Stop download-rebuild timer
  if state._rebuild_timer then
    state._rebuild_timer:stop()
  end

  -- Delete static images from terminal
  local ids = {}
  for _, id in pairs(state.image_ids) do
    table.insert(ids, id)
  end

  -- Stop shared animation timer, delete frame images, clean up temp dirs
  if state.anim_timer then
    state.anim_timer:stop()
    if not state.anim_timer:is_closing() then state.anim_timer:close() end
  end
  for _, anim in pairs(state.anims or {}) do
    for _, fid in ipairs(anim.frame_ids) do
      table.insert(ids, fid)
    end
    if anim.tmp_dir then
      vim.fn.delete(anim.tmp_dir, "rf")
    end
  end

  image.delete_images(ids)
  -- Robust fallback: some terminals (Ghostty) may not support per-ID deletion
  image.delete_all()

  -- Stop redraw timer
  if state.redraw_timer then
    state.redraw_timer:stop()
  end

  -- Remove autocmds
  pcall(vim.api.nvim_del_augroup_by_name, "md_render_images_" .. state.win)
end

return M
