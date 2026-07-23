--- Presenter mode: slide segmentation, directive parsing, layout persistence,
--- slide rendering, and the full-screen slideshow orchestration.
local PL = require "md-render.presenter_layout"

local M = {}

--- Thematic-break test (matches content_builder's rule): >=3 of -, *, or _.
---@param line string
---@return boolean
local function is_thematic_break(line)
  local stripped = line:gsub("%s", "")
  if #stripped < 3 then return false end
  local ch = stripped:sub(1, 1)
  if ch ~= "-" and ch ~= "*" and ch ~= "_" then return false end
  return stripped == string.rep(ch, #stripped)
end

--- Is this line a `[//]: # (...)` hidden link-label comment? Returns inner text.
---@param line string
---@return string|nil inner
local function comment_inner(line)
  return line:match "^%s*%[//%]:%s*#%s*%((.-)%)%s*$"
end

M._is_thematic_break = is_thematic_break
M._comment_inner = comment_inner

--- Split lines into slides at top-level thematic breaks. Breaks inside fenced
--- code blocks and inside `[//]: #` comments do not split.
---@param lines string[]
---@return {start: integer, stop: integer, lines: string[]}[]
function M.segment(lines)
  local slides = {}
  local in_fence = false
  local fence_marker = nil
  local cur = {}
  local cur_start = 1

  local function flush(stop_row)
    local all_blank = true
    for _, l in ipairs(cur) do
      if l:gsub("%s", "") ~= "" then
        all_blank = false
        break
      end
    end
    if not all_blank then
      table.insert(slides, { start = cur_start, stop = stop_row, lines = cur })
    end
  end

  for i, line in ipairs(lines) do
    local trimmed = line:gsub("^%s+", "")
    local marker = trimmed:match "^(```+)" or trimmed:match "^(~~~+)"
    if in_fence then
      table.insert(cur, line)
      if marker and fence_marker and marker:sub(1, #fence_marker) == fence_marker then
        in_fence = false
        fence_marker = nil
      end
    elseif marker then
      fence_marker = marker
      in_fence = true
      table.insert(cur, line)
    elseif is_thematic_break(line) and not comment_inner(line) then
      flush(i - 1)
      cur = {}
      cur_start = i + 1
    else
      table.insert(cur, line)
    end
  end
  flush(#lines)
  return slides
end

--- Discover mermaid diagrams in a slide, with absolute source rows and any
--- explicitly-declared layout from a directive directly above the fence.
---@param slide {start: integer, stop: integer, lines: string[]}
---@return {open_row, close_row, directive_row, source, layout}[]
function M.find_diagrams(slide)
  local diagrams = {}
  local lines = slide.lines
  local i = 1
  while i <= #lines do
    local lang = lines[i]:match "^%s*```+%s*(%w+)" or lines[i]:match "^%s*~~~+%s*(%w+)"
    if lang and lang:lower() == "mermaid" then
      local open_row = slide.start + i - 1
      local open_marker = lines[i]:match "^%s*(```+)" or lines[i]:match "^%s*(~~~+)"
      local fence_char = open_marker:sub(1, 1)
      local body = {}
      local j = i + 1
      while j <= #lines do
        local run = lines[j]:match("^%s*(" .. fence_char .. "+)%s*$")
        if run and #run >= #open_marker then break end
        table.insert(body, lines[j])
        j = j + 1
      end
      local close_row = slide.start + j - 1
      -- Layout directive on the line directly above the opening fence.
      local directive_row, layout = nil, nil
      if i > 1 then
        local inner = comment_inner(lines[i - 1])
        if inner then
          local scope, value = inner:match "^%s*(%w+)%s*:%s*(.-)%s*$"
          if scope and scope:lower() == "diagram" then
            layout = PL.parse_layout(value)
            if layout then directive_row = slide.start + i - 2 end
          end
        end
      end
      table.insert(diagrams, {
        open_row = open_row,
        close_row = close_row,
        directive_row = directive_row,
        source = table.concat(body, "\n"),
        layout = layout,
      })
      i = j + 1
    else
      i = i + 1
    end
  end
  return diagrams
end

--- Parse the first `[//]: # (deck: k=v ...)` comment in the document.
---@param lines string[]
---@return table<string,string>
function M.parse_deck_options(lines)
  for _, line in ipairs(lines) do
    local inner = comment_inner(line)
    if inner then
      local scope, value = inner:match "^%s*(%w+)%s*:%s*(.-)%s*$"
      if scope and scope:lower() == "deck" then
        local opts = {}
        for k, v in value:gmatch "([%w%-_]+)=([^%s]+)" do
          opts[k] = v
        end
        return opts
      end
    end
  end
  return {}
end

--- Is a slide's only meaningful content a single mermaid diagram?
---@param slide {start, stop, lines}
---@return {kind: string}
function M.default_layout(slide)
  local diagrams = M.find_diagrams(slide)
  if #diagrams ~= 1 then return { kind = "fit" } end
  local d = diagrams[1]
  -- Any non-blank line outside the fence (and not a comment) counts as text.
  for idx, line in ipairs(slide.lines) do
    local abs = slide.start + idx - 1
    local inside = abs > d.open_row and abs < d.close_row
    local is_fence = abs == d.open_row or abs == d.close_row
    local is_directive = abs == d.directive_row
    if not inside and not is_fence and not is_directive then
      if line:gsub("%s", "") ~= "" and not comment_inner(line) then return { kind = "fit" } end
    end
  end
  return { kind = "full" }
end

--- The layout to use for a diagram: explicit directive, else slide default.
---@param slide {start, stop, lines}
---@param diagram {layout: {kind,pct?}?}
---@return {kind: string, pct: integer?}
function M.effective_layout(slide, diagram)
  return diagram.layout or M.default_layout(slide)
end

--- Persist a diagram's layout as a `[//]: # (diagram: ...)` comment above its
--- opening fence. Replaces an existing directive line, else inserts one.
---@param bufnr integer
---@param diagram {open_row: integer, directive_row: integer?}
---@param layout {kind: string, pct: integer?}
---@return integer|nil new_open_row  nil if buffer is not modifiable
function M.write_diagram_layout(bufnr, diagram, layout)
  if not vim.bo[bufnr].modifiable then return nil end
  local comment = "[//]: # (diagram: " .. PL.serialize_layout(layout) .. ")"
  if diagram.directive_row then
    local row0 = diagram.directive_row - 1
    vim.api.nvim_buf_set_lines(bufnr, row0, row0 + 1, false, { comment })
    return diagram.open_row
  end
  local insert_at = diagram.open_row - 1
  vim.api.nvim_buf_set_lines(bufnr, insert_at, insert_at, false, { comment })
  return diagram.open_row + 1
end

--- Diagram whose opening fence is nearest the cursor source row.
---@param diagrams {open_row: integer}[]
---@param cursor_src_row integer
---@return table|nil
function M.nearest_diagram(diagrams, cursor_src_row)
  local best, best_dist = nil, math.huge
  for _, d in ipairs(diagrams) do
    local dist = math.abs(d.open_row - cursor_src_row)
    if dist < best_dist then
      best, best_dist = d, dist
    end
  end
  return best
end

--- Slice out a diagram's fence (and its directive line) from a slide's lines,
--- returning the remaining text-only lines.
---@param slide {start, stop, lines}
---@param diagram {open_row, close_row, directive_row}
---@return string[]
local function text_only_lines(slide, diagram)
  local out = {}
  for idx, line in ipairs(slide.lines) do
    local abs = slide.start + idx - 1
    local in_fence = abs >= diagram.open_row and abs <= diagram.close_row
    local is_directive = abs == diagram.directive_row
    if not in_fence and not is_directive then table.insert(out, line) end
  end
  return out
end

--- Fit an image into a cell box, preserving aspect. Falls back to 80% width.
local function fit_image(img_w, img_h, max_cols, max_rows)
  local image = require "md-render.image"
  if img_w and img_h then
    local c, r = image.calc_display_size(img_w, img_h, max_cols, max_rows)
    if c and r then return c, r end
  end
  return math.max(1, math.floor(max_cols * 0.8)), math.min(max_rows, 15)
end

--- Build the rendered content for one slide under the given layouts.
---@param slide {start, stop, lines}
---@param opts {slide_w: integer, slide_h: integer, gap: integer?, layouts: table<integer, {kind,pct?}>?}
---@return table content
function M.build_slide_content(slide, opts)
  local preview = require "md-render.preview"
  local image = require "md-render.image"
  local gap = opts.gap or 2
  local layouts = opts.layouts or {}
  local diagrams = M.find_diagrams(slide)

  -- Choose the primary (non-fit) diagram, if any. v1 gives special layout to a
  -- single diagram per slide; the rest render inline (fit).
  local primary, primary_layout
  for _, d in ipairs(diagrams) do
    local layout = layouts[d.open_row] or M.effective_layout(slide, d)
    if layout.kind ~= "fit" then
      primary, primary_layout = d, layout
      break
    end
  end

  -- No special layout, or graphics unavailable: render the whole slide inline.
  if not primary or not (image.supports_kitty() and image.has_mmdc()) then
    return preview.build_content(slide.lines, { max_width = opts.slide_w })
  end

  local cached = image.get_mermaid_cached(primary.source)
  local img_w, img_h
  if cached then img_w, img_h = image.image_dimensions(cached) end

  local body = text_only_lines(slide, primary)

  if primary_layout.kind == "full" then
    local content = preview.build_content(body, { max_width = opts.slide_w })
    local rows_used = #content.lines
    local box_rows = math.max(1, opts.slide_h - rows_used)
    local cols, rows = fit_image(img_w, img_h, opts.slide_w, box_rows)
    local col = math.max(0, math.floor((opts.slide_w - cols) / 2))
    local img_line = rows_used
    for _ = 1, rows do
      table.insert(content.lines, "")
    end
    table.insert(content.image_placements, {
      path = cached,
      line = img_line,
      col = col,
      rows = rows,
      cols = cols,
      img_w = img_w,
      img_h = img_h,
      mermaid_source = not cached and primary.source or nil,
    })
    return content
  end

  -- left / right split.
  local bands = PL.compute_bands(primary_layout.kind, primary_layout.pct or 50, opts.slide_w, gap)
  local content = preview.build_content(body, {
    max_width = bands.text.max_width,
    indent = string.rep(" ", bands.text.indent),
  })
  local cols, rows = fit_image(img_w, img_h, bands.diagram.max_cols, opts.slide_h)
  -- Ensure the buffer has enough rows for the image to overlay.
  while #content.lines < rows do
    table.insert(content.lines, "")
  end
  table.insert(content.image_placements, {
    path = cached,
    line = 0,
    col = bands.diagram.col,
    rows = rows,
    cols = cols,
    img_w = img_w,
    img_h = img_h,
    mermaid_source = not cached and primary.source or nil,
  })
  return content
end

--- Navigation state over `count` slides. idx is 1-indexed, clamped.
---@param count integer
---@return table nav
function M.new_nav(count)
  local nav = { idx = 1, count = math.max(1, count) }
  function nav:goto(i)
    self.idx = math.max(1, math.min(self.count, i))
    return self.idx
  end
  function nav:next()
    return self:goto(self.idx + 1)
  end
  function nav:prev()
    return self:goto(self.idx - 1)
  end
  function nav:first()
    return self:goto(1)
  end
  function nav:last()
    return self:goto(self.count)
  end
  return nav
end

--- Save the editor chrome globals and window-local options the presenter
--- overwrites, so quit can restore them.
local function snapshot_chrome(win)
  local wo = vim.wo[win]
  return {
    showtabline = vim.o.showtabline,
    laststatus = vim.o.laststatus,
    cmdheight = vim.o.cmdheight,
    ruler = vim.o.ruler,
    showcmd = vim.o.showcmd,
    number = wo.number,
    relativenumber = wo.relativenumber,
    signcolumn = wo.signcolumn,
    foldcolumn = wo.foldcolumn,
    statuscolumn = wo.statuscolumn,
    cursorline = wo.cursorline,
    wrap = wo.wrap,
    spell = wo.spell,
    list = wo.list,
    winbar = wo.winbar,
  }
end

local function restore_chrome(win, s)
  vim.o.showtabline = s.showtabline
  vim.o.laststatus = s.laststatus
  vim.o.cmdheight = s.cmdheight
  vim.o.ruler = s.ruler
  vim.o.showcmd = s.showcmd
  if vim.api.nvim_win_is_valid(win) then
    local wo = vim.wo[win]
    wo.number = s.number
    wo.relativenumber = s.relativenumber
    wo.signcolumn = s.signcolumn
    wo.foldcolumn = s.foldcolumn
    wo.statuscolumn = s.statuscolumn
    wo.cursorline = s.cursorline
    wo.wrap = s.wrap
    wo.spell = s.spell
    wo.list = s.list
    wo.winbar = s.winbar
  end
end

M._snapshot_chrome = snapshot_chrome
M._restore_chrome = restore_chrome

--- Start the full-screen slideshow for the current buffer.
---@param _opts? table
function M.start(_opts)
  local preview = require "md-render.preview"
  local display_utils = require "md-render.display_utils"

  local source_buf = vim.api.nvim_get_current_buf()
  local source_win = vim.api.nvim_get_current_win()
  if vim.b[source_buf].md_render_present then
    vim.notify("md-render present: already presenting", vim.log.levels.INFO)
    return
  end
  local source_lines = vim.api.nvim_buf_get_lines(source_buf, 0, -1, false)
  local slides = M.segment(source_lines)
  if #slides == 0 then
    vim.notify("md-render present: no slides", vim.log.levels.WARN)
    return
  end

  local nav = M.new_nav(#slides)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.b[buf].md_render_present = true
  local ns = vim.api.nvim_create_namespace "md_render_present"
  local layout_overrides = {} -- keyed by diagram open_row -> layout
  local image_state = nil

  local win = source_win
  local chrome = snapshot_chrome(win)
  vim.api.nvim_win_set_buf(win, buf)
  preview.apply_pager_chrome(win, buf)

  local function slide_dims()
    local w = vim.api.nvim_win_get_width(win)
    local info = vim.fn.getwininfo(win)[1]
    local h = (info and info.height) or vim.api.nvim_win_get_height(win)
    return w, h
  end

  local function render()
    display_utils.cleanup_images(image_state) -- no-op on nil; deletes prior slide's images
    local slide = slides[nav.idx]
    local w, h = slide_dims()
    local content = M.build_slide_content(slide, { slide_w = w, slide_h = h, layouts = layout_overrides })
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    display_utils.apply_content_to_buffer(buf, ns, content)
    vim.bo[buf].modifiable = false
    vim.wo[win].winbar = string.format("  %d / %d", nav.idx, #slides)
    image_state = display_utils.setup_images(win, content, ns, {})
    -- Prefetch neighbor mermaid renders so transitions are instant.
    for _, j in ipairs { nav.idx - 1, nav.idx + 1 } do
      if slides[j] then
        for _, d in ipairs(M.find_diagrams(slides[j])) do
          -- render_mermaid_async(source, callback) requires a callback; a no-op
          -- is fine — we only want the cache populated for the neighbor slide.
          pcall(function()
            require("md-render.image").render_mermaid_async(d.source, function() end)
          end)
        end
      end
    end
  end

  local function quit()
    display_utils.cleanup_images(image_state) -- no-op on nil; deletes prior slide's images
    restore_chrome(win, chrome)
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_buf_is_valid(source_buf) then
      vim.api.nvim_win_set_buf(win, source_buf)
    end
    if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
  end

  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true })
  end
  for _, k in ipairs { "n", "<Right>", "<Space>", "<PageDown>" } do
    map(k, function()
      nav:next()
      render()
    end)
  end
  for _, k in ipairs { "p", "<Left>", "<PageUp>" } do
    map(k, function()
      nav:prev()
      render()
    end)
  end
  map("gg", function()
    nav:first()
    render()
  end)
  map("G", function()
    nav:last()
    render()
  end)
  for _, k in ipairs { "q", "<Esc>", "<C-c>" } do
    map(k, quit)
  end

  -- Layout toggle keys (Task 10 fills in toggle_current / nudge_current).
  map("L", function()
    M.toggle_current(slides, nav, source_buf, layout_overrides, render)
  end)
  map("<", function()
    M.nudge_current(slides, nav, source_buf, layout_overrides, render, -5)
  end)
  map(">", function()
    M.nudge_current(slides, nav, source_buf, layout_overrides, render, 5)
  end)

  render()
end

--- Resolve the nearest diagram on the current slide, transform its layout,
--- record the override, and persist the directive to the source buffer.
---@param slides table[]
---@param nav {idx: integer}
---@param source_buf integer
---@param overrides table<integer, {kind,pct?}>
---@param cursor_row integer  1-indexed source row
---@param transform fun(layout: {kind,pct?}): {kind,pct?}
---@return {kind: string, pct: integer?}|nil
function M.apply_layout_change(slides, nav, source_buf, overrides, cursor_row, transform)
  local slide = slides[nav.idx]
  local diagrams = M.find_diagrams(slide)
  local d = M.nearest_diagram(diagrams, cursor_row)
  if not d then return nil end
  local current = overrides[d.open_row] or M.effective_layout(slide, d)
  local new_layout = transform(current)
  local new_open = M.write_diagram_layout(source_buf, d, new_layout)
  if new_open then
    -- Persistence shifted source rows; re-segment and re-key by the new row.
    overrides[new_open] = new_layout
    local fresh = M.segment(vim.api.nvim_buf_get_lines(source_buf, 0, -1, false))
    for k in pairs(slides) do
      slides[k] = fresh[k]
    end
  else
    -- Read-only / non-file source: keep it ephemeral.
    overrides[d.open_row] = new_layout
    vim.notify("md-render present: layout not persisted (buffer is read-only)", vim.log.levels.INFO)
  end
  return new_layout
end

--- Window-bound wrappers used by the presenter keymaps.
function M.toggle_current(slides, nav, source_buf, overrides, rerender)
  local cursor_row = vim.api.nvim_win_get_cursor(0)[1]
  M.apply_layout_change(slides, nav, source_buf, overrides, cursor_row, PL.cycle)
  rerender()
end

function M.nudge_current(slides, nav, source_buf, overrides, rerender, delta)
  local cursor_row = vim.api.nvim_win_get_cursor(0)[1]
  M.apply_layout_change(slides, nav, source_buf, overrides, cursor_row, function(l)
    return PL.nudge(l, delta)
  end)
  rerender()
end

return M
