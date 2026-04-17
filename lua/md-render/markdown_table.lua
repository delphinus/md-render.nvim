---@class MdRender.MarkdownTable.ParsedCell
---@field text string rendered text (inline markdown processed)
---@field highlights MdRender.Markdown.Highlight[] highlights from markdown.render()
---@field links MdRender.Markdown.Link[] links from markdown.render()

---@class MdRender.MarkdownTable.ParsedTable
---@field headers MdRender.MarkdownTable.ParsedCell[]
---@field alignments string[] "left"|"center"|"right" per column
---@field rows MdRender.MarkdownTable.ParsedCell[][] each row is an array of cells
---@field col_widths integer[] display width per column

local MarkdownTable = {}
local wrap_mod = require "md-render.wrap"

--- Split a table row into cell strings (trim leading/trailing whitespace)
---@param line string
---@return string[]|nil cells or nil if not a valid table row
local function split_row(line)
  -- Strip leading whitespace, then expect |
  local stripped = line:match "^%s*(.*)" or line
  if stripped:sub(1, 1) ~= "|" then
    return nil
  end
  -- Remove leading and trailing |
  local inner = stripped:match "^|(.*)$"
  if not inner then
    return nil
  end
  -- Remove trailing | if present (but not escaped \|)
  if inner:sub(-1) == "|" and inner:sub(-2, -2) ~= "\\" then
    inner = inner:sub(1, -2)
  end
  local cells = {}
  local pos = 1
  while pos <= #inner do
    local cell_parts = {}
    while pos <= #inner do
      local c = inner:sub(pos, pos)
      if c == "\\" and pos + 1 <= #inner and inner:sub(pos + 1, pos + 1) == "|" then
        -- Escaped pipe: keep the literal |
        table.insert(cell_parts, "|")
        pos = pos + 2
      elseif c == "|" then
        pos = pos + 1
        break
      else
        table.insert(cell_parts, c)
        pos = pos + 1
      end
    end
    local cell = table.concat(cell_parts)
    -- Trim whitespace
    cell = cell:match "^%s*(.-)%s*$"
    table.insert(cells, cell)
  end
  return cells
end

--- Check if a line is a separator row (e.g., |---|:---:|---:|)
---@param line string
---@return string[]|nil alignments array or nil if not a separator
local function parse_separator(line)
  local cells = split_row(line)
  if not cells or #cells == 0 then
    return nil
  end
  local alignments = {}
  for _, cell in ipairs(cells) do
    -- Must match pattern: optional :, one or more -, optional :
    if not cell:match "^:?%-+:?$" then
      return nil
    end
    local left = cell:sub(1, 1) == ":"
    local right = cell:sub(-1) == ":"
    if left and right then
      table.insert(alignments, "center")
    elseif right then
      table.insert(alignments, "right")
    else
      table.insert(alignments, "left")
    end
  end
  return alignments
end

--- Process a cell's text through markdown.render() for inline formatting
---@param text string
---@param repo_base_url? string
---@param autolinks? MdRender.Autolink[]
---@return MdRender.MarkdownTable.ParsedCell
local function process_cell(text, repo_base_url, autolinks)
  local markdown = require "md-render.markdown"
  local rendered, highlights, links = markdown.render(text, repo_base_url, autolinks)
  return {
    text = rendered,
    highlights = highlights,
    links = links,
  }
end

--- Wrap cell text into multiple lines fitting within max_display_width.
--- Uses BudouX and kinsoku rules from wrap module for proper line breaking.
--- When a wrapped line still overflows (single word wider than column),
--- tries syllable-level V|C splitting as a last resort before truncation.
--- Returns a list of {text, byte_start} entries for each wrapped line.
---@param text string
---@param max_display_width integer
---@return {text: string, byte_start: integer}[]
local function wrap_cell_text(text, max_display_width)
  if vim.api.nvim_strwidth(text) <= max_display_width then
    return { { text = text, byte_start = 0 } }
  end

  local wrapped_lines, line_starts = wrap_mod.wrap_words(text, max_display_width)
  local result = {}
  for i, line in ipairs(wrapped_lines) do
    if vim.api.nvim_strwidth(line) > max_display_width then
      -- Single word wider than column: try syllable-level V|C splitting
      local sub_segs = wrap_mod.split_ascii_syllables(line, 0, false)
      if #sub_segs > 1 then
        -- Pack syllable segments into lines fitting max_display_width
        local current_text = ""
        local current_byte = 0
        for _, seg in ipairs(sub_segs) do
          if current_text ~= "" and vim.api.nvim_strwidth(current_text .. seg.text) > max_display_width then
            table.insert(result, { text = current_text, byte_start = line_starts[i] + current_byte })
            current_byte = seg.byte_pos
            current_text = seg.text
          else
            if current_text == "" then
              current_byte = seg.byte_pos
            end
            current_text = current_text .. seg.text
          end
        end
        if current_text ~= "" then
          table.insert(result, { text = current_text, byte_start = line_starts[i] + current_byte })
        end
      else
        -- CJK emergency splitting: break into individual characters,
        -- grouping NO_BREAK_START characters (small kana, ー, punctuation)
        -- with their preceding character to respect kinsoku rules.
        local cjk_groups = {}
        for c in line:gmatch "[%z\1-\127\194-\253][\128-\191]*" do
          if wrap_mod.NO_BREAK_START[c] and #cjk_groups > 0 then
            cjk_groups[#cjk_groups] = cjk_groups[#cjk_groups] .. c
          else
            cjk_groups[#cjk_groups + 1] = c
          end
        end
        if #cjk_groups > 1 then
          local current_text = ""
          local current_byte = 0
          local byte_offset = 0
          for _, g in ipairs(cjk_groups) do
            if current_text ~= "" and vim.api.nvim_strwidth(current_text .. g) > max_display_width then
              table.insert(result, { text = current_text, byte_start = line_starts[i] + current_byte })
              current_byte = byte_offset
              current_text = g
            else
              if current_text == "" then
                current_byte = byte_offset
              end
              current_text = current_text .. g
            end
            byte_offset = byte_offset + #g
          end
          if current_text ~= "" then
            table.insert(result, { text = current_text, byte_start = line_starts[i] + current_byte })
          end
        else
          -- Single character wider than column; add as-is (build_wrapped_row will truncate)
          table.insert(result, { text = line, byte_start = line_starts[i] })
        end
      end
    else
      table.insert(result, { text = line, byte_start = line_starts[i] })
    end
  end
  return result
end

--- Truncate text to fit within a display width, appending "…" if truncated.
--- Handles multi-byte (CJK) characters correctly.
---@param text string
---@param max_display_width integer
---@return string truncated text
---@return integer byte_length of the kept portion (before "…")
local function truncate_to_width(text, max_display_width)
  local text_width = vim.api.nvim_strwidth(text)
  if text_width <= max_display_width then
    return text, #text
  end
  local ellipsis_width = vim.api.nvim_strwidth("…")
  local target = max_display_width - ellipsis_width
  if target <= 0 then
    return "…", 0
  end
  local current_width = 0
  local byte_pos = 0
  for char in text:gmatch "[%z\1-\127\194-\253][\128-\191]*" do
    local char_width = vim.api.nvim_strwidth(char)
    if current_width + char_width > target then
      break
    end
    current_width = current_width + char_width
    byte_pos = byte_pos + #char
  end
  return text:sub(1, byte_pos) .. "…", byte_pos
end

--- Pad text to a given display width according to alignment
---@param text string
---@param width integer target display width
---@param align string "left"|"center"|"right"
---@return string padded text
---@return integer left_pad number of spaces added on the left
local function pad_cell(text, width, align)
  local text_width = vim.api.nvim_strwidth(text)
  local total_pad = width - text_width
  if total_pad <= 0 then
    return text, 0
  end
  if align == "right" then
    return string.rep(" ", total_pad) .. text, total_pad
  elseif align == "center" then
    local left = math.floor(total_pad / 2)
    local right = total_pad - left
    return string.rep(" ", left) .. text .. string.rep(" ", right), left
  else
    return text .. string.rep(" ", total_pad), 0
  end
end

--- Parse consecutive lines as a Markdown table
---@param lines string[]
---@param repo_base_url? string
---@param autolinks? MdRender.Autolink[]
---@return MdRender.MarkdownTable.ParsedTable|nil
function MarkdownTable.parse(lines, repo_base_url, autolinks)
  if #lines < 2 then
    return nil
  end

  -- Line 1: header row
  local header_cells = split_row(lines[1])
  if not header_cells or #header_cells == 0 then
    return nil
  end

  -- Line 2: separator row
  local alignments = parse_separator(lines[2])
  if not alignments then
    return nil
  end

  -- Column count must match
  if #header_cells ~= #alignments then
    return nil
  end

  -- Process header cells
  local headers = {}
  for _, cell_text in ipairs(header_cells) do
    table.insert(headers, process_cell(cell_text, repo_base_url, autolinks))
  end

  -- Process data rows (line 3+)
  local rows = {}
  for i = 3, #lines do
    local cells = split_row(lines[i])
    if not cells then
      break
    end
    local row = {}
    for col = 1, #alignments do
      local cell_text = cells[col] or ""
      table.insert(row, process_cell(cell_text, repo_base_url, autolinks))
    end
    table.insert(rows, row)
  end

  -- Calculate column widths (display width)
  local col_widths = {}
  for col = 1, #alignments do
    local w = vim.api.nvim_strwidth(headers[col].text)
    for _, row in ipairs(rows) do
      if row[col] then
        w = math.max(w, vim.api.nvim_strwidth(row[col].text))
      end
    end
    col_widths[col] = w
  end

  -- Detect empty header (all cells are blank) — used by HTML table conversion
  local empty_header = true
  for _, h in ipairs(headers) do
    if h.text:match "%S" then
      empty_header = false
      break
    end
  end

  return {
    headers = headers,
    alignments = alignments,
    rows = rows,
    col_widths = col_widths,
    _raw_lines = lines,
    empty_header = empty_header,
  }
end

--- Render a parsed table into lines with highlights and links
---@param parsed_table MdRender.MarkdownTable.ParsedTable
---@param indent string
---@param max_width? integer Maximum display width (default: no limit)
---@param expanded? boolean When true, wrap cell content instead of truncating
---@return string[] lines
---@return MdRender.Highlight.Group[][] per_line_highlights
---@return {line: integer, col_start: integer, col_end: integer, url: string}[][] per_line_links
function MarkdownTable.render(parsed_table, indent, max_width, expanded, buf_dir)
  local out_lines = {}
  local out_highlights = {}
  local out_links = {}
  local num_cols = #parsed_table.col_widths
  local col_widths = vim.deepcopy(parsed_table.col_widths)
  local sep_width = vim.api.nvim_strwidth("│") -- border char display width (varies with ambiwidth)

  --- Strip leading HTML comments from text
  ---@param text string
  ---@return string
  local function strip_html_comments(text)
    return text:gsub("<!%-%-.-%-%->" , ""):match "^%s*(.-)%s*$"
  end

  --- Check if a cell contains only an image reference ![alt](url), <img>, or <video> tag
  --- Also handles cells with leading HTML comments like <!-- ... -->![alt](url)
  ---@param _cell MdRender.MarkdownTable.ParsedCell
  ---@param raw_text string original cell text before markdown rendering
  ---@return string? alt, string? url, boolean? is_video
  local function cell_image(_cell, raw_text)
    local stripped = strip_html_comments(raw_text)
    local alt, url = stripped:match "^!%[(.-)%]%((.-)%)$"
    if alt and url then
      local image_mod = require "md-render.image"
      return alt, url, image_mod.is_video_file(url)
    end
    -- Try <img src="..." alt="..."> tag
    local img_tag = stripped:match "^(<img%s[^>]*>)%s*$"
    if img_tag then
      local src = img_tag:match 'src="([^"]*)"' or img_tag:match "src='([^']*)'"
      if src then
        alt = img_tag:match 'alt="([^"]*)"' or img_tag:match "alt='([^']*)'" or ""
        local image_mod = require "md-render.image"
        return alt, src, image_mod.is_video_file(src)
      end
    end
    -- Try <video src="...">...</video> or <video><source src="...">...</video>
    local video_tag = stripped:match "^(<video[%s>].-</video>)%s*$"
    if video_tag then
      local src = video_tag:match 'src="([^"]*)"' or video_tag:match "src='([^']*)'"
      if not src then
        src = video_tag:match '<source[^>]*src="([^"]*)"'
          or video_tag:match "<source[^>]*src='([^']*)'>"
      end
      if src then
        alt = src:match "([^/]+)$" or src
        return alt, src, true
      end
    end
    return nil, nil, nil
  end

  -- Collect raw cell texts for image detection
  local raw_rows = {}
  for i = 3, #(parsed_table._raw_lines or {}) do
    local cells = split_row(parsed_table._raw_lines[i])
    if cells then
      local row = {}
      for col = 1, #parsed_table.alignments do
        local cell_text = cells[col] or ""
        cell_text = cell_text:match "^%s*(.-)%s*$"
        table.insert(row, cell_text)
      end
      table.insert(raw_rows, row)
    end
  end

  -- Pre-detect images and calculate display sizes for column width fitting
  local has_image_cells = false
  local row_images_cache = {} -- row_idx -> col -> {alt, url, resolved, src_url, img_w, img_h}
  local col_image_widths = {} -- col -> max display_cols across all image rows
  do
    local image_mod = require "md-render.image"
    if image_mod.supports_kitty() then
      buf_dir = buf_dir or vim.fn.expand("%:p:h")
      local indent_width = vim.api.nvim_strwidth(indent)
      local overhead = indent_width + num_cols * (sep_width + 2) + sep_width
      local effective_max = max_width and max_width < 1e6 and max_width or 1e6
      local total_budget = effective_max - overhead
      local initial_max_per_col = math.max(1, math.floor(total_budget / num_cols))

      for row_idx, row in ipairs(parsed_table.rows) do
        if #raw_rows >= row_idx then
          for col = 1, num_cols do
            local raw = raw_rows[row_idx][col]
            if raw then
              local alt, url, is_video = cell_image(row[col], raw)
              if alt and url and not image_mod.is_badge_url(url) then
                local resolved, src_url, img_w, img_h
                if is_video then
                  src_url = image_mod.is_url(url) and url or nil
                  if src_url then
                    resolved = image_mod.get_video_cached(src_url)
                  else
                    local video_path = vim.fn.expand(url)
                    if video_path:sub(1, 1) ~= "/" and buf_dir then
                      video_path = buf_dir .. "/" .. video_path
                    end
                    if vim.fn.filereadable(video_path) == 1 then
                      resolved = video_path
                    end
                    -- Fallback: try Obsidian vault resolution for local video files
                    if not resolved and buf_dir then
                      local obsidian = require "md-render.obsidian"
                      resolved = obsidian.resolve(url, buf_dir)
                    end
                  end
                  if resolved then
                    img_w, img_h = image_mod.video_dimensions(resolved)
                  end
                else
                  resolved = image_mod.resolve(url, buf_dir)
                  src_url = image_mod.is_url(url) and url or nil
                  if resolved then
                    img_w, img_h = image_mod.image_dimensions(resolved)
                    if not img_w and image_mod.is_video_content(resolved) then
                      is_video = true
                      img_w, img_h = image_mod.video_dimensions(resolved)
                    end
                  end
                end
                if resolved and img_w and img_h then
                  local display_cols = image_mod.calc_display_size(img_w, img_h, initial_max_per_col, 15)
                  if not row_images_cache[row_idx] then row_images_cache[row_idx] = {} end
                  row_images_cache[row_idx][col] = {
                    alt = alt, url = url, resolved = resolved,
                    img_w = img_w, img_h = img_h, video = is_video,
                  }
                  col_image_widths[col] = math.max(col_image_widths[col] or 0, display_cols)
                  has_image_cells = true
                elseif resolved and is_video then
                  -- Auto-detected video with resolved path but no dimensions yet
                  if not row_images_cache[row_idx] then row_images_cache[row_idx] = {} end
                  row_images_cache[row_idx][col] = {
                    alt = alt, url = url, resolved = resolved, video = true,
                  }
                  col_image_widths[col] = math.max(col_image_widths[col] or 0, initial_max_per_col)
                  has_image_cells = true
                elseif src_url then
                  if not row_images_cache[row_idx] then row_images_cache[row_idx] = {} end
                  row_images_cache[row_idx][col] = {
                    alt = alt, url = url, resolved = nil, src_url = src_url, video = is_video,
                  }
                  col_image_widths[col] = math.max(col_image_widths[col] or 0, initial_max_per_col)
                  has_image_cells = true
                end
              end
            end
          end
        end
      end
    else
      -- Non-kitty: just check for image presence
      if parsed_table._raw_lines then
        for i = 3, #parsed_table._raw_lines do
          local cells = split_row(parsed_table._raw_lines[i])
          if cells then
            for _, cell_text in ipairs(cells) do
              local trimmed = strip_html_comments(cell_text)
              if trimmed and (trimmed:match "^!%[.-%]%(.-%)" or trimmed:match "^<img%s" or trimmed:match "^<video[%s>]") then
                has_image_cells = true
                break
              end
            end
          end
          if has_image_cells then break end
        end
      end
    end
  end

  -- Adjust column widths to fit max_width
  if max_width then
    local indent_width = vim.api.nvim_strwidth(indent)
    -- Total = indent + num_cols * ("│ " + col_width + " ") + "│"
    --       = indent + num_cols * (sep_width + 2) + sum(col_widths) + sep_width
    local overhead = indent_width + num_cols * (sep_width + 2) + sep_width
    local content_sum = 0
    for _, w in ipairs(col_widths) do
      content_sum = content_sum + w
    end
    local total = overhead + content_sum

    if has_image_cells then
      -- Ensure columns are wide enough for actual image display sizes
      for col = 1, num_cols do
        if col_image_widths[col] then
          col_widths[col] = math.max(col_widths[col], col_image_widths[col])
        end
      end
      if expanded then
        -- Expanded: also ensure columns fit full image labels (no truncation)
        for _, imgs in pairs(row_images_cache) do
          for col, img in pairs(imgs) do
            local icons_mod = require "md-render.icons"
            local raw_icon = icons_mod.get_image_icon(img.url or "")
            local label_width = vim.api.nvim_strwidth(icons_mod.pad_icon(raw_icon) .. " " .. img.alt)
            col_widths[col] = math.max(col_widths[col], label_width)
          end
        end
      end
    end

    -- Shrink if table still exceeds max_width
    content_sum = 0
    for _, w in ipairs(col_widths) do
      content_sum = content_sum + w
    end
    total = overhead + content_sum
    if total > max_width then
      local budget = max_width - overhead
      if budget < num_cols then
        budget = num_cols
      end
      -- In expanded mode, content wraps so no column needs more than the full
      -- budget.  Cap each column's width for proportion calculation to prevent
      -- columns with very long content from starving shorter columns.
      local capped_sum = 0
      local capped_widths = {}
      for col = 1, num_cols do
        local cap = expanded and math.min(col_widths[col], budget) or col_widths[col]
        capped_widths[col] = cap
        capped_sum = capped_sum + cap
      end
      local new_widths = {}
      local assigned = 0
      for col = 1, num_cols do
        local proportion = capped_widths[col] / capped_sum
        local w = math.max(1, math.floor(proportion * budget))
        new_widths[col] = w
        assigned = assigned + w
      end
      local remaining = budget - assigned
      while remaining > 0 do
        local best_col = 1
        local best_deficit = 0
        for col = 1, num_cols do
          local deficit = col_widths[col] - new_widths[col]
          if deficit > best_deficit then
            best_deficit = deficit
            best_col = col
          end
        end
        if best_deficit <= 0 then break end
        new_widths[best_col] = new_widths[best_col] + 1
        remaining = remaining - 1
      end
      col_widths = new_widths
    end
  end

  -- When expanded, ensure minimum column width of 2 to prevent CJK character overflow
  if expanded then
    for col = 1, num_cols do
      if col_widths[col] < 2 then
        col_widths[col] = 2
      end
    end
  end

  --- Build a data row line (header or body)
  ---@param cells MdRender.MarkdownTable.ParsedCell[]
  ---@param is_header boolean
  ---@param col_align_overrides? table<integer, string> per-column alignment overrides
  ---@return string line
  ---@return MdRender.Highlight.Group[] highlights
  ---@return {col_start: integer, col_end: integer, url: string}[] links
  local function build_row(cells, is_header, col_align_overrides)
    local parts = {}
    local hls = {}
    local lnks = {}
    local byte_pos = #indent

    for col = 1, num_cols do
      local cell = cells[col]
      local display_text = cell.text
      local cell_hls = cell.highlights
      local cell_links = cell.links
      local truncated_byte_len = #display_text

      -- Truncate cell text if it exceeds the (possibly shrunk) column width
      if vim.api.nvim_strwidth(display_text) > col_widths[col] then
        display_text, truncated_byte_len = truncate_to_width(display_text, col_widths[col])
        -- Clip highlights to the kept portion
        local clipped_hls = {}
        for _, hl in ipairs(cell_hls) do
          if hl.col < truncated_byte_len then
            table.insert(clipped_hls, {
              col = hl.col,
              end_col = math.min(hl.end_col, truncated_byte_len),
              hl = hl.hl,
            })
          end
        end
        -- Add Underlined highlight on the "…" to indicate clickable
        table.insert(clipped_hls, {
          col = truncated_byte_len,
          end_col = truncated_byte_len + #"…",
          hl = "Underlined",
        })
        cell_hls = clipped_hls
        -- Clip links to the kept portion
        local clipped_links = {}
        for _, link in ipairs(cell_links) do
          if link.col_start < truncated_byte_len then
            table.insert(clipped_links, {
              col_start = link.col_start,
              col_end = math.min(link.col_end, truncated_byte_len),
              url = link.url,
            })
          end
        end
        cell_links = clipped_links
      end

      local col_align = (col_align_overrides and col_align_overrides[col]) or parsed_table.alignments[col]
      local padded, left_pad = pad_cell(display_text, col_widths[col], col_align)

      -- "│ " before cell
      local sep = "│ "
      table.insert(hls, { col = byte_pos, end_col = byte_pos + #sep, hl = "FloatBorder" })
      byte_pos = byte_pos + #sep

      local cell_start = byte_pos + left_pad

      -- Add cell highlights (shifted by byte_pos + left_pad)
      for _, hl in ipairs(cell_hls) do
        table.insert(hls, {
          col = cell_start + hl.col,
          end_col = cell_start + hl.end_col,
          hl = hl.hl,
        })
      end

      -- Add header Bold highlight
      if is_header then
        table.insert(hls, {
          col = cell_start,
          end_col = cell_start + #display_text,
          hl = "Bold",
        })
      end

      -- Add cell links (shifted)
      for _, link in ipairs(cell_links) do
        table.insert(lnks, {
          col_start = cell_start + link.col_start,
          col_end = cell_start + link.col_end,
          url = link.url,
        })
      end

      byte_pos = byte_pos + #padded
      table.insert(parts, sep .. padded)

      -- " " after cell (before next separator)
      byte_pos = byte_pos + 1
      table.insert(parts, " ")
    end

    -- Trailing "│"
    local trailing = "│"
    table.insert(hls, { col = byte_pos, end_col = byte_pos + #trailing, hl = "FloatBorder" })
    table.insert(parts, trailing)

    return indent .. table.concat(parts), hls, lnks
  end

  --- Build a multi-line data row by wrapping cell content instead of truncating
  ---@param cells MdRender.MarkdownTable.ParsedCell[]
  ---@param is_header boolean
  ---@param col_align_overrides? table<integer, string> per-column alignment overrides
  ---@return string[] lines
  ---@return MdRender.Highlight.Group[][] per_line_highlights
  ---@return {col_start: integer, col_end: integer, url: string}[][] per_line_links
  local function build_wrapped_row(cells, is_header, col_align_overrides)
    -- Wrap each cell's text into multiple lines
    local wrapped_cells = {}
    local max_wrap_lines = 1
    for col = 1, num_cols do
      local cell = cells[col]
      local wraps = wrap_cell_text(cell.text, col_widths[col])
      wrapped_cells[col] = wraps
      max_wrap_lines = math.max(max_wrap_lines, #wraps)
    end

    -- If everything fits in one line, delegate to build_row
    if max_wrap_lines == 1 then
      local line, hls, lnks = build_row(cells, is_header, col_align_overrides)
      return { line }, { hls }, { lnks }
    end

    local all_lines = {}
    local all_hls = {}
    local all_lnks = {}

    for wrap_idx = 1, max_wrap_lines do
      local parts = {}
      local hls = {}
      local lnks = {}
      local byte_pos = #indent

      for col = 1, num_cols do
        local cell = cells[col]
        local wrap = wrapped_cells[col][wrap_idx]
        local display_text = wrap and wrap.text or ""
        local wrap_byte_start = wrap and wrap.byte_start or 0

        local col_align = (col_align_overrides and col_align_overrides[col]) or parsed_table.alignments[col]
        local padded, left_pad = pad_cell(display_text, col_widths[col], col_align)

        -- "│ " before cell
        local sep = "│ "
        table.insert(hls, { col = byte_pos, end_col = byte_pos + #sep, hl = "FloatBorder" })
        byte_pos = byte_pos + #sep

        local cell_start = byte_pos + left_pad

        -- If a wrapped line still exceeds column width (single word wider
        -- than column), truncate it to prevent border misalignment
        local kept_byte_len = #display_text
        if wrap and vim.api.nvim_strwidth(display_text) > col_widths[col] then
          display_text, kept_byte_len = truncate_to_width(display_text, col_widths[col])
          padded, left_pad = pad_cell(display_text, col_widths[col], col_align)
          cell_start = byte_pos + left_pad
        end

        -- Distribute highlights for this wrapped line
        if wrap then
          local wrap_byte_end = wrap_byte_start + kept_byte_len
          for _, hl in ipairs(cell.highlights) do
            if hl.end_col > wrap_byte_start and hl.col < wrap_byte_end then
              local local_start = math.max(0, hl.col - wrap_byte_start)
              local local_end = math.min(kept_byte_len, hl.end_col - wrap_byte_start)
              table.insert(hls, {
                col = cell_start + local_start,
                end_col = cell_start + local_end,
                hl = hl.hl,
              })
            end
          end

          -- Distribute links
          for _, link in ipairs(cell.links) do
            if link.col_end > wrap_byte_start and link.col_start < wrap_byte_end then
              local local_start = math.max(0, link.col_start - wrap_byte_start)
              local local_end = math.min(kept_byte_len, link.col_end - wrap_byte_start)
              table.insert(lnks, {
                col_start = cell_start + local_start,
                col_end = cell_start + local_end,
                url = link.url,
              })
            end
          end
        end

        -- Add header Bold highlight
        if is_header and wrap then
          table.insert(hls, {
            col = cell_start,
            end_col = cell_start + #display_text,
            hl = "Bold",
          })
        end

        byte_pos = byte_pos + #padded
        table.insert(parts, sep .. padded)

        -- " " after cell (before next separator)
        byte_pos = byte_pos + 1
        table.insert(parts, " ")
      end

      -- Trailing "│"
      local trailing = "│"
      table.insert(hls, { col = byte_pos, end_col = byte_pos + #trailing, hl = "FloatBorder" })
      table.insert(parts, trailing)

      table.insert(all_lines, indent .. table.concat(parts))
      table.insert(all_hls, hls)
      table.insert(all_lnks, lnks)
    end

    return all_lines, all_hls, all_lnks
  end

  --- Build a separator line
  ---@return string line
  ---@return MdRender.Highlight.Group[] highlights
  local function build_separator()
    local parts = {}
    local byte_pos = #indent

    for col = 1, num_cols do
      local sep_str = "│" .. string.rep("─", col_widths[col] + 2)
      table.insert(parts, sep_str)
      byte_pos = byte_pos + #sep_str
    end
    table.insert(parts, "│")

    local line = indent .. table.concat(parts)
    local hls = { { col = #indent, end_col = #line, hl = "FloatBorder" } }
    return line, hls
  end

  -- Header row and separator (skip when header is empty, e.g. HTML tables without <th>)
  if not parsed_table.empty_header then
    if expanded then
      local h_lines, h_hls_list, h_links_list = build_wrapped_row(parsed_table.headers, true)
      for i, line in ipairs(h_lines) do
        table.insert(out_lines, line)
        table.insert(out_highlights, h_hls_list[i])
        table.insert(out_links, h_links_list[i])
      end
    else
      local h_line, h_hls, h_links = build_row(parsed_table.headers, true)
      table.insert(out_lines, h_line)
      table.insert(out_highlights, h_hls)
      table.insert(out_links, h_links)
    end

    local s_line, s_hls = build_separator()
    table.insert(out_lines, s_line)
    table.insert(out_highlights, s_hls)
    table.insert(out_links, {})
  end

  --- Build an empty row line with borders only (for image placeholder rows)
  ---@return string line
  ---@return MdRender.Highlight.Group[] highlights
  local function build_empty_row()
    local parts = {}
    local hls = {}
    local byte_pos = #indent

    for col = 1, num_cols do
      local sep = "│ "
      table.insert(hls, { col = byte_pos, end_col = byte_pos + #sep, hl = "FloatBorder" })
      byte_pos = byte_pos + #sep

      local padding = string.rep(" ", col_widths[col])
      byte_pos = byte_pos + #padding + 1
      table.insert(parts, sep .. padding .. " ")
    end

    local trailing = "│"
    table.insert(hls, { col = byte_pos, end_col = byte_pos + #trailing, hl = "FloatBorder" })
    table.insert(parts, trailing)

    return indent .. table.concat(parts), hls
  end

  -- Image placements to return
  local out_image_placements = {}

  -- Data rows
  for row_idx, row in ipairs(parsed_table.rows) do
    -- Use pre-detected image info from cache
    local cached = row_images_cache[row_idx]
    local row_has_images = cached ~= nil
    local row_images = {}
    if cached then
      local image_mod = require "md-render.image"
      for col, img in pairs(cached) do
        if img.img_w and img.img_h then
          local display_cols, display_rows = image_mod.calc_display_size(img.img_w, img.img_h, col_widths[col], 15)
          row_images[col] = {
            alt = img.alt, url = img.url, resolved = img.resolved,
            display_cols = display_cols, display_rows = display_rows,
            video = img.video,
          }
        elseif img.resolved and img.video then
          -- Auto-detected video: resolved path but no dimensions yet
          row_images[col] = {
            alt = img.alt, url = img.url, resolved = img.resolved,
            display_cols = col_widths[col], display_rows = 10,
            video = true,
          }
        elseif img.src_url then
          row_images[col] = {
            alt = img.alt, url = img.url, resolved = nil, src_url = img.src_url,
            display_cols = col_widths[col], display_rows = 10,
            video = img.video,
          }
        end
      end
      row_has_images = next(row_images) ~= nil
    end

    if row_has_images then
      -- Calculate max image height across all cells in this row
      local max_img_rows = 0
      for _, img in pairs(row_images) do
        max_img_rows = math.max(max_img_rows, img.display_rows)
      end

      -- Build the label row (alt text)
      local label_cells = {}
      for col = 1, num_cols do
        if row_images[col] then
          local icons_mod = require "md-render.icons"
          local raw_icon, icon_hl = icons_mod.get_image_icon(row_images[col].url or "")
          local img_icon = icons_mod.pad_icon(raw_icon)
          local label = img_icon .. " " .. row_images[col].alt
          local lbl_hls = {
            { col = #img_icon + 1, end_col = #label, hl = "Comment" },
          }
          if icon_hl then
            table.insert(lbl_hls, 1, { col = 0, end_col = #img_icon, hl = icon_hl })
          end
          label_cells[col] = {
            text = label,
            highlights = lbl_hls,
            links = {},
          }
        else
          label_cells[col] = row[col]
        end
      end
      -- Center-align image label cells
      local img_align_overrides = {}
      for col = 1, num_cols do
        if row_images[col] then
          img_align_overrides[col] = "center"
        end
      end
      local label_line, label_hls, label_links = build_row(label_cells, false, img_align_overrides)
      table.insert(out_lines, label_line)
      table.insert(out_highlights, label_hls)
      table.insert(out_links, label_links)

      -- Add placeholder rows for images
      local img_start_line_idx = #out_lines  -- 0-indexed line where images start
      for _ = 1, max_img_rows do
        local empty_line, empty_hls = build_empty_row()
        table.insert(out_lines, empty_line)
        table.insert(out_highlights, empty_hls)
        table.insert(out_links, {})
      end

      -- Record image placements (positions relative to table start)
      for col, img in pairs(row_images) do
        -- Calculate the display column offset of this column's content area
        -- (put_image uses display columns, not byte offsets)
        local col_display_offset = vim.api.nvim_strwidth(indent)
        for c = 1, col - 1 do
          col_display_offset = col_display_offset + sep_width + 2 + col_widths[c] -- "│" + " " + width + " "
        end
        col_display_offset = col_display_offset + sep_width + 1 -- "│ " for this column

        -- Center image horizontally within the cell.
        -- When the gap is odd, expand the image by 1 cell so centering is symmetric.
        local img_cols = img.display_cols
        local diff = col_widths[col] - img_cols
        if diff > 0 and diff % 2 == 1 then
          img_cols = img_cols + 1
        end
        local center_pad = math.max(0, math.floor((col_widths[col] - img_cols) / 2))
        col_display_offset = col_display_offset + center_pad

        -- Pass pre-computed img_w/img_h so process_placement skips recalculation
        -- (which would undo the +1 expansion above).
        local cached_img = cached[col]
        table.insert(out_image_placements, {
          resolved = img.resolved,
          src_url = img.src_url,
          line_offset = img_start_line_idx,
          col = col_display_offset,
          rows = img.display_rows,
          cols = img_cols,
          img_w = cached_img and cached_img.img_w or nil,
          img_h = cached_img and cached_img.img_h or nil,
          video = img.video,
        })
      end

      -- Add separator after image row (but not after the last row)
      if row_idx < #parsed_table.rows then
        local sep_line, sep_hls = build_separator()
        table.insert(out_lines, sep_line)
        table.insert(out_highlights, sep_hls)
        table.insert(out_links, {})
      end
    else
      if expanded then
        local r_lines, r_hls_list, r_links_list = build_wrapped_row(row, false)
        for i, line in ipairs(r_lines) do
          table.insert(out_lines, line)
          table.insert(out_highlights, r_hls_list[i])
          table.insert(out_links, r_links_list[i])
        end
        -- Add separator between all rows when expanded (not after the last row)
        if row_idx < #parsed_table.rows then
          local sep_line, sep_hls = build_separator()
          table.insert(out_lines, sep_line)
          table.insert(out_highlights, sep_hls)
          table.insert(out_links, {})
        end
      else
        local r_line, r_hls, r_links = build_row(row, false)
        table.insert(out_lines, r_line)
        table.insert(out_highlights, r_hls)
        table.insert(out_links, r_links)
      end
    end
  end

  return out_lines, out_highlights, out_links, out_image_placements
end

return MarkdownTable
