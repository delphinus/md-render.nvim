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
  -- Remove trailing | if present
  if inner:sub(-1) == "|" then
    inner = inner:sub(1, -2)
  end
  local cells = {}
  for cell in (inner .. "|"):gmatch "(.-)|" do
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

--- Truncate text to fit within a display width, appending "…" if truncated.
--- Handles multi-byte (CJK) characters correctly.
---@param text string
---@param max_display_width integer
---@return string truncated text
---@return integer byte_length of the kept portion (before "…")
local function truncate_to_width(text, max_display_width)
  local text_width = vim.fn.strdisplaywidth(text)
  if text_width <= max_display_width then
    return text, #text
  end
  -- Need at least 1 col for "…"
  local target = max_display_width - 1
  if target <= 0 then
    return "…", 0
  end
  local current_width = 0
  local byte_pos = 0
  for char in text:gmatch "[%z\1-\127\194-\253][\128-\191]*" do
    local char_width = vim.fn.strdisplaywidth(char)
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
  local text_width = vim.fn.strdisplaywidth(text)
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
    local w = vim.fn.strdisplaywidth(headers[col].text)
    for _, row in ipairs(rows) do
      if row[col] then
        w = math.max(w, vim.fn.strdisplaywidth(row[col].text))
      end
    end
    col_widths[col] = w
  end

  return {
    headers = headers,
    alignments = alignments,
    rows = rows,
    col_widths = col_widths,
    _raw_lines = lines,
  }
end

--- Render a parsed table into lines with highlights and links
---@param parsed_table MdRender.MarkdownTable.ParsedTable
---@param indent string
---@param max_width? integer Maximum display width (default: no limit)
---@return string[] lines
---@return MdRender.Highlight.Group[][] per_line_highlights
---@return {line: integer, col_start: integer, col_end: integer, url: string}[][] per_line_links
function MarkdownTable.render(parsed_table, indent, max_width)
  local out_lines = {}
  local out_highlights = {}
  local out_links = {}
  local num_cols = #parsed_table.col_widths
  local col_widths = vim.deepcopy(parsed_table.col_widths)

  -- Check if any data row contains image cells
  local has_image_cells = false
  if parsed_table._raw_lines then
    for i = 3, #parsed_table._raw_lines do
      local cells = split_row(parsed_table._raw_lines[i])
      if cells then
        for _, cell_text in ipairs(cells) do
          local trimmed = cell_text:match "^%s*(.-)%s*$"
          if trimmed and trimmed:match "^!%[.-%]%(.-%)" then
            has_image_cells = true
            break
          end
        end
      end
      if has_image_cells then break end
    end
  end

  -- Adjust column widths to fit max_width
  if max_width then
    local indent_width = vim.fn.strdisplaywidth(indent)
    -- Total = indent + num_cols * ("│ " + col_width + " ") + "│"
    --       = indent + num_cols * 3 + sum(col_widths) + 1
    local overhead = indent_width + num_cols * 3 + 1
    local content_sum = 0
    for _, w in ipairs(col_widths) do
      content_sum = content_sum + w
    end
    local total = overhead + content_sum

    if has_image_cells then
      -- Expand columns to fill max_width for better image display
      local budget = max_width - overhead
      if budget > content_sum then
        local per_col = math.floor(budget / num_cols)
        for col = 1, num_cols do
          col_widths[col] = per_col
        end
        -- Distribute remainder
        local remainder = budget - per_col * num_cols
        for col = 1, remainder do
          col_widths[col] = col_widths[col] + 1
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
      local new_widths = {}
      local assigned = 0
      for col = 1, num_cols do
        local proportion = col_widths[col] / content_sum
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

  --- Build a data row line (header or body)
  ---@param cells MdRender.MarkdownTable.ParsedCell[]
  ---@param is_header boolean
  ---@return string line
  ---@return MdRender.Highlight.Group[] highlights
  ---@return {col_start: integer, col_end: integer, url: string}[] links
  local function build_row(cells, is_header)
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
      if vim.fn.strdisplaywidth(display_text) > col_widths[col] then
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

      local padded, left_pad = pad_cell(display_text, col_widths[col], parsed_table.alignments[col])

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

  -- Header row
  local h_line, h_hls, h_links = build_row(parsed_table.headers, true)
  table.insert(out_lines, h_line)
  table.insert(out_highlights, h_hls)
  table.insert(out_links, h_links)

  -- Separator
  local s_line, s_hls = build_separator()
  table.insert(out_lines, s_line)
  table.insert(out_highlights, s_hls)
  table.insert(out_links, {})

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

  --- Check if a cell contains only an image reference ![alt](url)
  ---@param cell MdRender.MarkdownTable.ParsedCell
  ---@param raw_text string original cell text before markdown rendering
  ---@return string? alt, string? url
  local function cell_image(cell, raw_text)
    local alt, url = raw_text:match "^!%[(.-)%]%((.-)%)$"
    if alt and url then return alt, url end
    return nil, nil
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

  -- Image placements to return
  local out_image_placements = {}

  -- Data rows
  for row_idx, row in ipairs(parsed_table.rows) do
    -- Check if any cell in this row is an image
    local row_has_images = false
    local row_images = {} -- col -> {alt, url, resolved, img_w, img_h}
    if #raw_rows >= row_idx then
      local image_mod = require "md-render.image"
      if image_mod.supports_kitty() then
        local buf_dir = vim.fn.expand("%:p:h")
        for col = 1, num_cols do
          local raw = raw_rows[row_idx][col]
          if raw then
            local alt, url = cell_image(row[col], raw)
            if alt and url and not image_mod.is_badge_url(url) then
              local resolved = image_mod.resolve(url, buf_dir)
              local src_url = image_mod.is_url(url) and url or nil
              if resolved then
                local img_w, img_h = image_mod.image_dimensions(resolved)
                if img_w and img_h then
                  local display_cols, display_rows = image_mod.calc_display_size(img_w, img_h, col_widths[col], 15)
                  row_images[col] = {
                    alt = alt, url = url, resolved = resolved,
                    display_cols = display_cols, display_rows = display_rows,
                  }
                  row_has_images = true
                end
              elseif src_url then
                -- URL not yet cached: use estimated size for placeholder
                row_images[col] = {
                  alt = alt, url = url, resolved = nil, src_url = src_url,
                  display_cols = col_widths[col], display_rows = 10,
                }
                row_has_images = true
              end
            end
          end
        end
      end
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
          local label = "🖼 " .. row_images[col].alt
          label_cells[col] = {
            text = label,
            highlights = { { col = 0, end_col = #label, hl = "Comment" } },
            links = {},
          }
        else
          label_cells[col] = row[col]
        end
      end
      local label_line, label_hls, label_links = build_row(label_cells, false)
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
        -- Calculate the byte offset of this column's content area
        local col_byte_offset = #indent
        for c = 1, col - 1 do
          col_byte_offset = col_byte_offset + 3 + col_widths[c] -- "│ " + width + " "
        end
        col_byte_offset = col_byte_offset + 3 -- "│ " for this column

        table.insert(out_image_placements, {
          resolved = img.resolved,
          src_url = img.src_url,
          line_offset = img_start_line_idx,
          col = col_byte_offset,
          rows = img.display_rows,
          cols = img.display_cols,
        })
      end

      -- Add separator after image row
      local sep_line, sep_hls = build_separator()
      table.insert(out_lines, sep_line)
      table.insert(out_highlights, sep_hls)
      table.insert(out_links, {})
    else
      local r_line, r_hls, r_links = build_row(row, false)
      table.insert(out_lines, r_line)
      table.insert(out_highlights, r_hls)
      table.insert(out_links, r_links)
    end
  end

  return out_lines, out_highlights, out_links, out_image_placements
end

return MarkdownTable
