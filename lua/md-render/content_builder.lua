---@class MdRender.Highlight.Group
---@field col integer 0-indexed start column
---@field end_col integer 0-indexed end column (-1 means end of line)
---@field hl string highlight group name
---@field hl_eol? boolean extend highlight to end of line

---@class MdRender.LineHighlight
---@field line integer 0-indexed line number
---@field groups MdRender.Highlight.Group[]

---@class MdRender.LinkMetadata
---@field line integer 0-indexed line number
---@field col_start integer 0-indexed start column
---@field col_end integer 0-indexed end column
---@field url string

---@class MdRender.CodeBlock
---@field language string
---@field start_line integer 0-indexed, first code line
---@field end_line integer   0-indexed, last code line
---@field prefix_len integer byte length of line prefix to strip for treesitter (default 2)
---@field source_lines? string[] original (non-truncated) code lines for accurate treesitter parsing

---@class MdRender.CalloutFold
---@field header_line integer 0-indexed rendered line of the callout header
---@field source_line integer 1-indexed source line index
---@field collapsed boolean current fold state

---@class MdRender.ExpandableRegion
---@field start_line integer 0-indexed first rendered line of the region
---@field end_line integer 0-indexed last rendered line of the region
---@field block_id integer unique identifier for expand_state lookup
---@field expanded boolean current state

---@class MdRender.ImagePlacement
---@field path string? absolute path to image file (nil if not yet downloaded)
---@field line integer 0-indexed rendered line where image starts
---@field col integer 0-indexed column offset
---@field rows integer display height in cells
---@field cols integer display width in cells
---@field img_w? integer source image width in pixels
---@field img_h? integer source image height in pixels
---@field animated? boolean true if animated GIF
---@field src_url? string original URL for async download
---@field mermaid_source? string mermaid source for async rendering

---@class MdRender.Content
---@field lines string[]
---@field highlights MdRender.LineHighlight[]
---@field link_metadata MdRender.LinkMetadata[]
---@field code_blocks MdRender.CodeBlock[]
---@field callout_folds MdRender.CalloutFold[]
---@field expandable_regions MdRender.ExpandableRegion[]
---@field image_placements MdRender.ImagePlacement[]
---@field footnote_anchors table<string, integer> anchor name → 0-indexed line number
---@field heading_anchors table<string, integer> heading slug → 0-indexed line number
---@field source_line_map integer[] rendered line index (1-based) → source line number (1-based)
---@field title_line? integer
---@field title_text? string
---@field close_line_idx? integer

---@class MdRender.ContentBuilder
---@field lines string[]
---@field highlights MdRender.LineHighlight[]
---@field link_metadata MdRender.LinkMetadata[]
---@field code_blocks MdRender.CodeBlock[]
---@field callout_folds MdRender.CalloutFold[]
---@field expandable_regions MdRender.ExpandableRegion[]
---@field image_placements MdRender.ImagePlacement[]
---@field footnote_anchors table<string, integer>
---@field source_line_map integer[]
---@field private _current_source_line integer
local ContentBuilder = {}

---@return MdRender.ContentBuilder
function ContentBuilder.new()
  return setmetatable({
    lines = {},
    highlights = {},
    link_metadata = {},
    code_blocks = {},
    callout_folds = {},
    expandable_regions = {},
    image_placements = {},
    footnote_anchors = {},
    heading_anchors = {},
    source_line_map = {},
    _current_source_line = 0,
  }, { __index = ContentBuilder })
end

---@param source_line integer 1-indexed source line number
function ContentBuilder:set_source_line(source_line)
  self._current_source_line = source_line
end

---@param text string
---@param hl_groups? MdRender.Highlight.Group[]
function ContentBuilder:add_line(text, hl_groups)
  table.insert(self.lines, text)
  table.insert(self.source_line_map, self._current_source_line)
  if hl_groups then
    table.insert(self.highlights, { line = #self.lines - 1, groups = hl_groups })
  end
end

---@param label string
---@param value string
---@param value_hl? string
function ContentBuilder:add_labeled(label, value, value_hl)
  local line = label .. ": " .. value
  self:add_line(line, {
    { col = 0, end_col = #label, hl = "Comment" },
    { col = #label + 2, end_col = #line, hl = value_hl or "Normal" },
  })
end

---@return MdRender.Content
function ContentBuilder:result()
  return {
    lines = self.lines,
    highlights = self.highlights,
    link_metadata = self.link_metadata,
    code_blocks = self.code_blocks,
    callout_folds = self.callout_folds,
    expandable_regions = self.expandable_regions,
    image_placements = self.image_placements,
    footnote_anchors = self.footnote_anchors,
    heading_anchors = self.heading_anchors,
    source_line_map = self.source_line_map,
  }
end

--- Detect bare URLs in a code block line and add link metadata for clickability.
--- This ensures that URLs inside code blocks are clickable even when the line is
--- visually truncated (the full URL is stored in the extmark).
---@param self MdRender.ContentBuilder
---@param raw_line string Raw code line content (without indent/prefix)
---@param prefix_len integer Byte length of the displayed prefix
---@param content_byte_end integer Byte position in displayed line where content ends (before "…" if truncated)
local function detect_urls_in_code_line(self, raw_line, prefix_len, content_byte_end)
  local pos = 1
  while true do
    local ms, me = raw_line:find("https?://[^%s%)<>\"]+", pos)
    if not ms then break end
    local url = raw_line:sub(ms, me):gsub("[.,;:!?*~]+$", "")
    -- Strip trailing non-ASCII symbols (e.g. ⏎, →) that are not valid in URLs.
    -- charclass returns 1 for punctuation/symbols, >=2 for letters/digits.
    while #url > 0 do
      local last_char = vim.fn.strcharpart(url, vim.fn.strchars(url) - 1, 1)
      if #last_char > 1 and vim.fn.charclass(last_char) <= 1 then
        url = url:sub(1, #url - #last_char)
      else
        break
      end
    end
    local col_start = prefix_len + ms - 1
    local col_end = prefix_len + ms - 1 + #url
    if col_start < content_byte_end then
      table.insert(self.link_metadata, {
        line = #self.lines - 1,
        col_start = col_start,
        col_end = math.min(col_end, content_byte_end),
        url = url,
      })
    end
    pos = me + 1
  end
end

--- Unicode superscript digit characters for footnote numbering
local SUPERSCRIPT_DIGITS = { "⁰", "¹", "²", "³", "⁴", "⁵", "⁶", "⁷", "⁸", "⁹" }

--- Convert a number to superscript Unicode string
---@param n integer
---@return string
local function to_superscript(n)
  local s = tostring(n)
  local result = {}
  for i = 1, #s do
    local d = tonumber(s:sub(i, i))
    table.insert(result, SUPERSCRIPT_DIGITS[d + 1])
  end
  return table.concat(result)
end

local wrap_mod = require "md-render.wrap"
local icons = require "md-render.icons"

local split_segments = wrap_mod.split_segments
local wrap_words = wrap_mod.wrap_words

--- Distribute markdown highlights across wrapped lines
---@param md_highlights MdRender.Markdown.Highlight[]
---@param wrapped_lines string[] The wrapped line texts
---@param line_starts integer[] Start positions of each wrapped line
---@param indent string Indentation prefix
---@param quote_prefix string Blockquote prefix (may be empty)
---@param content_offset integer Byte offset of content within the original rendered text
---@param list_prefix_len? integer Byte length of list marker prefix (0 if none)
---@param list_cont_len? integer Display width of list marker for continuation indent (0 if none)
---@return MdRender.Highlight.Group[][] per_line_highlights Array of highlight lists, one per wrapped line
local function distribute_highlights(md_highlights, wrapped_lines, line_starts, indent, quote_prefix, content_offset, list_prefix_len, list_cont_len)
  list_prefix_len = list_prefix_len or 0
  list_cont_len = list_cont_len or list_prefix_len
  local per_line = {}
  for idx, wline in ipairs(wrapped_lines) do
    local line_start_pos = line_starts[idx]
    local lm_len = idx == 1 and list_prefix_len or list_cont_len
    local line_prefix = (quote_prefix ~= "" and (indent .. quote_prefix) or indent)
        .. string.rep(" ", lm_len)
    local line_hls = {}

    -- Add FloatBorder highlight for blockquote prefix on continuation lines
    if quote_prefix ~= "" and idx > 1 then
      table.insert(line_hls, {
        col = #indent,
        end_col = #indent + #quote_prefix,
        hl = "FloatBorder",
      })
    end

    for _, hl in ipairs(md_highlights) do
      local hl_start = hl.col - content_offset
      local hl_end = hl.end_col - content_offset

      -- Marker-area highlights (list markers, checkbox icons) that end at or before
      -- the content start should only appear on line 1 with their original positions
      if hl.end_col <= content_offset and hl.hl ~= "FloatBorder" then
        if idx == 1 then
          table.insert(line_hls, {
            col = #indent + hl.col,
            end_col = #indent + hl.end_col,
            hl = hl.hl,
          })
        end
      elseif hl.hl == "FloatBorder" and hl.col == 0 then
        if idx == 1 then
          table.insert(line_hls, {
            col = #indent + hl.col,
            end_col = #indent + hl.end_col,
            hl = hl.hl,
          })
        end
      else
        local wline_end = line_start_pos + #wline
        if hl_end > line_start_pos and hl_start < wline_end then
          local local_start = math.max(0, hl_start - line_start_pos)
          local local_end = math.min(#wline, hl_end - line_start_pos)
          table.insert(line_hls, {
            col = local_start + #line_prefix,
            end_col = local_end + #line_prefix,
            hl = hl.hl,
          })
        end
      end
    end

    per_line[idx] = line_hls
  end
  return per_line
end

--- Distribute link metadata across wrapped lines
---@param md_links MdRender.Markdown.Link[]
---@param wrapped_lines string[] The wrapped line texts
---@param line_starts integer[] Start positions of each wrapped line
---@param indent string Indentation prefix
---@param quote_prefix string Blockquote prefix (may be empty)
---@param content_offset integer Byte offset of content within the original rendered text
---@param base_line integer Current line count in the builder (0-indexed, before adding wrapped lines)
---@param list_prefix_len? integer Byte length of list marker prefix (0 if none)
---@param list_cont_len? integer Display width of list marker for continuation indent (0 if none)
---@return MdRender.LinkMetadata[] link_entries
local function distribute_links(md_links, wrapped_lines, line_starts, indent, quote_prefix, content_offset, base_line, list_prefix_len, list_cont_len)
  list_prefix_len = list_prefix_len or 0
  list_cont_len = list_cont_len or list_prefix_len
  local entries = {}
  for idx, wline in ipairs(wrapped_lines) do
    local line_start_pos = line_starts[idx]
    local lm_len = idx == 1 and list_prefix_len or list_cont_len
    local line_prefix = (quote_prefix ~= "" and (indent .. quote_prefix) or indent)
        .. string.rep(" ", lm_len)

    for _, link in ipairs(md_links) do
      local link_start = link.col_start - content_offset
      local link_end = link.col_end - content_offset
      local wline_end = line_start_pos + #wline

      if link_end > line_start_pos and link_start < wline_end then
        local local_start = math.max(0, link_start - line_start_pos)
        local local_end = math.min(#wline, link_end - line_start_pos)
        table.insert(entries, {
          line = base_line + idx - 1,
          col_start = local_start + #line_prefix,
          col_end = local_end + #line_prefix,
          url = link.url,
        })
      end
    end
  end
  return entries
end

--- Add a wrapped markdown line with highlights and links distributed across wrapped lines
---@param self MdRender.ContentBuilder
---@param rendered_text string
---@param md_highlights MdRender.Markdown.Highlight[]
---@param md_links MdRender.Markdown.Link[]
---@param indent string
---@param max_width integer
---@param quote_prefix string
---@param list_marker? string
function ContentBuilder:add_wrapped_markdown(rendered_text, md_highlights, md_links, indent, max_width, quote_prefix, list_marker)
  local wrap_text = rendered_text
  local content_offset = 0
  if quote_prefix ~= "" then
    wrap_text = rendered_text:sub(#quote_prefix + 1)
    content_offset = #quote_prefix
  end

  -- Strip list marker from wrap_text so wrapping is based on content only
  local list_prefix_len = 0
  local list_cont_len = 0
  if list_marker and list_marker ~= "" then
    wrap_text = wrap_text:sub(#list_marker + 1)
    content_offset = content_offset + #list_marker
    list_prefix_len = #list_marker
    list_cont_len = vim.api.nvim_strwidth(list_marker)
  end

  local content_max_width = max_width
  if quote_prefix ~= "" then
    content_max_width = max_width - vim.api.nvim_strwidth(quote_prefix)
  end
  if list_cont_len > 0 then
    content_max_width = content_max_width - list_cont_len
  end

  local wrapped_lines, line_starts = wrap_words(wrap_text, content_max_width)
  local per_line_hls = distribute_highlights(md_highlights, wrapped_lines, line_starts, indent, quote_prefix, content_offset, list_prefix_len, list_cont_len)
  local base_line = #self.lines
  local link_entries = distribute_links(md_links, wrapped_lines, line_starts, indent, quote_prefix, content_offset, base_line, list_prefix_len, list_cont_len)

  local list_prefix = list_marker or ""
  local list_continuation = string.rep(" ", list_cont_len)

  for idx, wline in ipairs(wrapped_lines) do
    local line_prefix = quote_prefix ~= "" and (indent .. quote_prefix) or indent
    local lm = idx == 1 and list_prefix or list_continuation
    local line_hls = per_line_hls[idx]
    self:add_line(line_prefix .. lm .. wline, #line_hls > 0 and line_hls or nil)
  end

  for _, entry in ipairs(link_entries) do
    table.insert(self.link_metadata, entry)
  end
end

--- Add a simple (non-wrapped) markdown line with highlights and links
---@param self MdRender.ContentBuilder
---@param rendered_text string
---@param md_highlights MdRender.Markdown.Highlight[]
---@param md_links MdRender.Markdown.Link[]
---@param indent string
function ContentBuilder:add_simple_markdown(rendered_text, md_highlights, md_links, indent)
  local line_hls = {}
  for _, hl in ipairs(md_highlights) do
    table.insert(line_hls, {
      col = hl.col + #indent,
      end_col = hl.end_col + #indent,
      hl = hl.hl,
    })
  end

  self:add_line(indent .. rendered_text, #line_hls > 0 and line_hls or nil)

  for _, link in ipairs(md_links) do
    table.insert(self.link_metadata, {
      line = #self.lines - 1,
      col_start = link.col_start + #indent,
      col_end = link.col_end + #indent,
      url = link.url,
    })
  end
end

--- Add a table block with highlights and links
---@param self MdRender.ContentBuilder
---@param table_lines string[]
---@param indent string
---@param max_width integer
---@param repo_base_url? string
---@param autolinks? MdRender.Autolink[]
--- @param per_row_source? boolean When true (markdown pipe tables), each
---   rendered line gets its source attribution from the corresponding
---   source row offset. When false/nil (HTML tables, where the source
---   isn't a per-row enumeration), all rows inherit the caller's
---   _current_source_line as-is.
function ContentBuilder:add_table(table_lines, indent, max_width, repo_base_url, autolinks, expanded, buf_dir, per_row_source)
  local markdown_table = require "md-render.markdown_table"
  local parsed = markdown_table.parse(table_lines, repo_base_url, autolinks)
  if not parsed then
    -- Fallback: render each line as markdown
    for _, line in ipairs(table_lines) do
      self:add_markdown_line(line, indent, max_width, repo_base_url, autolinks)
    end
    return
  end
  local lines, per_line_hls, per_line_links, tbl_image_placements, src_offsets =
    markdown_table.render(parsed, indent, max_width, expanded, buf_dir)
  local base_line = #self.lines
  -- For pipe tables, table_lines[i] corresponds to source line
  -- (caller's _current_source_line + i - 1). Use the offset returned by
  -- render to stamp each emitted line at the right source row.
  local saved_src_line = self._current_source_line
  for i, line in ipairs(lines) do
    if per_row_source and src_offsets and src_offsets[i] then
      self._current_source_line = saved_src_line + src_offsets[i]
    end
    self:add_line(line, #per_line_hls[i] > 0 and per_line_hls[i] or nil)
    for _, link in ipairs(per_line_links[i] or {}) do
      table.insert(self.link_metadata, {
        line = base_line + i - 1,
        col_start = link.col_start,
        col_end = link.col_end,
        url = link.url,
      })
    end
  end
  self._current_source_line = saved_src_line

  -- Register image placements from table cells (inline within table borders)
  if tbl_image_placements then
    for _, p in ipairs(tbl_image_placements) do
      table.insert(self.image_placements, {
        path = p.resolved,
        line = base_line + p.line_offset,
        col = p.col,
        rows = p.rows,
        cols = p.cols,
        src_url = p.src_url,
        img_w = p.img_w,
        img_h = p.img_h,
        video = p.video,
      })
    end
  end
end

--- Emit an image/video header line (icon + display name) with wrapping.
---@param self MdRender.ContentBuilder
---@param indent string
---@param img_icon string Padded icon string
---@param icon_hl? string Highlight group for the icon
---@param display_name string Alt text or filename
---@param max_width integer
---@param name_hl string Highlight group for the display name text
---@return integer lines_added Number of lines emitted
function ContentBuilder:_emit_image_header(indent, img_icon, icon_hl, display_name, max_width, name_hl)
  local icon_start = #indent
  local icon_end = icon_start + #img_icon
  local icon_display_width = vim.api.nvim_strwidth(img_icon)
  local cont_width = icon_display_width + 1
  local available = math.max(1, max_width - vim.api.nvim_strwidth(indent) - cont_width)

  local wrapped, _ = wrap_words(display_name, available)

  for idx, segment in ipairs(wrapped) do
    if idx == 1 then
      local header = indent .. img_icon .. " " .. segment
      local hls = {
        { col = icon_end, end_col = #header, hl = name_hl },
      }
      if icon_hl then
        table.insert(hls, 1, { col = icon_start, end_col = icon_end, hl = icon_hl })
      end
      self:add_line(header, hls)
    else
      local cont_pad = string.rep(" ", cont_width)
      local line = indent .. cont_pad .. segment
      self:add_line(line, {
        { col = #indent + #cont_pad, end_col = #line, hl = name_hl },
      })
    end
  end
  return #wrapped
end

--- Add a markdown-rendered line with wrapping support
---@param self MdRender.ContentBuilder
---@param text string
---@param indent string
---@param max_width integer
---@param repo_base_url? string
---@param autolinks? MdRender.Autolink[]
---@param ref_links? table<string, string>
---@return string? alert_type Alert type if this line is an alert header
---@return string? fold_mod Fold modifier ("+" or "-") if this is a foldable callout
function ContentBuilder:add_markdown_line(text, indent, max_width, repo_base_url, autolinks, ref_links, footnote_map)
  local markdown = require "md-render.markdown"
  local rendered_text, md_highlights, md_links, special_type, list_marker, alert_type, fold_mod, heading_content =
    markdown.render(text, repo_base_url, autolinks, ref_links, footnote_map)

  local quote_prefix = ""
  if special_type == "blockquote" then
    local bar_space = "│ " -- U+2502 + space (4 bytes)
    local pos = 1
    while rendered_text:sub(pos, pos + #bar_space - 1) == bar_space do
      pos = pos + #bar_space
    end
    quote_prefix = rendered_text:sub(1, pos - 1)
  end

  local lines_before_fn = #self.lines
  if vim.api.nvim_strwidth(indent) + vim.api.nvim_strwidth(rendered_text) > max_width then
    self:add_wrapped_markdown(rendered_text, md_highlights, md_links, indent, max_width, quote_prefix, list_marker)
  else
    self:add_simple_markdown(rendered_text, md_highlights, md_links, indent)
  end

  -- Register heading anchor (slug → rendered line)
  if heading_content then
    local slug = markdown.heading_slug(heading_content)
    if slug ~= "" then
      self.heading_anchors[slug] = lines_before_fn
    end
  end

  -- Register footnote ref anchors (first occurrence per label)
  for _, link in ipairs(self.link_metadata) do
    if link.line >= lines_before_fn then
      local label = link.url and link.url:match("^#footnote%-def%-(.+)$")
      if label and not self.footnote_anchors["footnote-ref-" .. label] then
        self.footnote_anchors["footnote-ref-" .. label] = link.line
      end
    end
  end

  return alert_type, fold_mod
end

--- Apply alert styling to lines added between lines_before and current line count
---@param self MdRender.ContentBuilder
---@param lines_before integer Line count before adding the alert line(s)
---@param lines_after integer Line count after adding the alert line(s)
---@param alert_type string Alert type key (e.g. "NOTE", "WARNING")
---@param is_header boolean Whether this is the alert header line (with icon+label)
function ContentBuilder:apply_alert_styling(lines_before, lines_after, alert_type, is_header)
  local alert_hl = "MdRenderAlert" .. alert_type:sub(1, 1) .. alert_type:sub(2):lower()
  local alert_bg_hl = alert_hl .. "Bg"

  for _, hl_info in ipairs(self.highlights) do
    if hl_info.line >= lines_before and hl_info.line < lines_after then
      -- Replace FloatBorder highlights with alert-colored border
      for _, group in ipairs(hl_info.groups) do
        if group.hl == "FloatBorder" then
          group.hl = alert_hl
        end
      end

      -- On header line, add alert highlight for content after the bar
      if is_header and hl_info.line == lines_before then
        local line_text = self.lines[hl_info.line + 1]
        if line_text then
          -- Find end of blockquote prefix (after "│ ")
          local bar_end = 0
          for _, group in ipairs(hl_info.groups) do
            if group.hl == alert_hl then
              bar_end = group.end_col
              break
            end
          end
          if bar_end > 0 then
            table.insert(hl_info.groups, { col = bar_end, end_col = #line_text, hl = alert_hl })
          end
        end
      end

      -- Add background highlight for the entire line
      table.insert(hl_info.groups, { col = 0, end_col = -1, hl = alert_bg_hl, hl_eol = true })
    end
  end

  -- Also handle lines that have no existing highlights
  for line_idx = lines_before, lines_after - 1 do
    local has_hl = false
    for _, hl_info in ipairs(self.highlights) do
      if hl_info.line == line_idx then
        has_hl = true
        break
      end
    end
    if not has_hl then
      table.insert(self.highlights, {
        line = line_idx,
        groups = { { col = 0, end_col = -1, hl = alert_bg_hl, hl_eol = true } },
      })
    end
  end
end

--- Pad a Nerd Font icon glyph so it always occupies 2 display cells.
--- When setcellwidths makes the glyph width 1, an extra space is appended.
---@param icon string single icon character
---@return string
local function pad_icon(icon)
  if vim.api.nvim_strwidth(icon) == 1 then
    return icon .. " "
  end
  return icon
end

local get_file_icon = icons.get_file_icon

--- Append a fold indicator (›/∨) to the end of a callout header line
---@param self MdRender.ContentBuilder
---@param line_idx integer 0-indexed rendered line
---@param is_collapsed boolean
function ContentBuilder:add_fold_indicator(line_idx, is_collapsed)
  local indicator = is_collapsed and (" " .. pad_icon("󰅂")) or (" " .. pad_icon("󰅀"))
  local line = self.lines[line_idx + 1]
  if not line then
    return
  end

  -- Append indicator at the end of the line (no highlight shifts needed)
  self.lines[line_idx + 1] = line .. indicator
end

--- Render a markdown document into the builder.
--- This is the shared rendering loop used by both PR body rendering and markdown preview.
---@param self MdRender.ContentBuilder
---@param lines string[] Pre-processed lines (already renumbered and cleaned)
---@param opts? MdRender.RenderDocumentOpts
--- Check if a line is a Markdown thematic break (---, ***, ___, etc.)
---@param line string
---@return boolean
local function is_thematic_break(line)
  local stripped = line:gsub("%s", "")
  if #stripped < 3 then return false end
  local ch = stripped:sub(1, 1)
  if ch ~= "-" and ch ~= "*" and ch ~= "_" then return false end
  return stripped == string.rep(ch, #stripped)
end

--- Tags already handled by render_document's main loop (skip in preprocessing)
local HTML_SKIP_TAGS = {
  details = true, summary = true,
  hr = true,
  figure = true,
  p = true,
  div = true, span = true,
  dl = true,
  table = true, tr = true, td = true, th = true, thead = true, tbody = true,
}

--- HTML void elements (self-closing, no end tag) — must not accumulate lines.
local HTML_VOID_ELEMENTS = {
  area = true, base = true, br = true, col = true, embed = true,
  hr = true, img = true, input = true, link = true, meta = true,
  param = true, source = true, track = true, wbr = true,
}

--- Convert accumulated HTML table lines into pipe-table format lines.
--- Parses <tr>, <th>, <td> structure and extracts align attributes.
---@param html_lines string[] lines between <table> and </table> (inclusive)
---@return string[] pipe-table lines suitable for MarkdownTable.parse
local function html_table_to_pipe(html_lines)
  -- Join all lines and normalize whitespace
  local html = table.concat(html_lines, " ")
  html = html:gsub("  +", " ")

  -- Extract rows from <tr>...</tr>
  local rows = {}
  for tr_content in html:gmatch "<tr[^>]*>(.-)</tr>" do
    local cells = {}
    local aligns = {}
    -- Match <th> or <td> with optional attributes
    for tag, attrs, content in tr_content:gmatch "<(t[hd])([^>]*)>(.-)</%1>" do
      -- Extract align attribute
      local align = attrs:match 'align%s*=%s*"([^"]*)"' or attrs:match "align%s*=%s*'([^']*)'"
      table.insert(aligns, align or "")
      -- Preserve the cell content as-is (inline HTML like <img>, <em> will be
      -- processed later by markdown.render / process_html_tags)
      local cell = content:gsub("^%s+", ""):gsub("%s+$", "")
      table.insert(cells, { text = cell, is_header = tag == "th" })
    end
    if #cells > 0 then
      table.insert(rows, { cells = cells, aligns = aligns })
    end
  end

  if #rows == 0 then
    return {}
  end

  -- Determine column count
  local num_cols = 0
  for _, row in ipairs(rows) do
    num_cols = math.max(num_cols, #row.cells)
  end

  -- Determine if first row is a header row
  local has_header = false
  if rows[1] then
    has_header = rows[1].cells[1] and rows[1].cells[1].is_header
  end

  -- Build alignment from header or first data row
  local col_aligns = {}
  for col = 1, num_cols do
    local align = ""
    for _, row in ipairs(rows) do
      if row.aligns[col] and row.aligns[col] ~= "" then
        align = row.aligns[col]
        break
      end
    end
    col_aligns[col] = align
  end

  -- Build pipe-table lines
  local result = {}

  -- Header row
  local header_parts = {}
  if has_header then
    for col = 1, num_cols do
      local cell = rows[1].cells[col]
      header_parts[col] = cell and cell.text or ""
    end
  else
    -- No <th> found — use empty header
    for col = 1, num_cols do
      header_parts[col] = " "
    end
  end
  table.insert(result, "| " .. table.concat(header_parts, " | ") .. " |")

  -- Separator row with alignment
  local sep_parts = {}
  for col = 1, num_cols do
    local a = col_aligns[col]:lower()
    if a == "center" then
      sep_parts[col] = ":---:"
    elseif a == "right" then
      sep_parts[col] = "---:"
    else
      sep_parts[col] = "---"
    end
  end
  table.insert(result, "| " .. table.concat(sep_parts, " | ") .. " |")

  -- Data rows (skip first row if it was the header)
  local start = has_header and 2 or 1
  for i = start, #rows do
    local parts = {}
    for col = 1, num_cols do
      local cell = rows[i].cells[col]
      parts[col] = cell and cell.text or ""
    end
    table.insert(result, "| " .. table.concat(parts, " | ") .. " |")
  end

  return result
end

--- Preprocess lines to handle multi-line HTML tags.
--- HTML collapses whitespace: all lines within a tag are joined with spaces.
--- This applies to both block and inline elements per the HTML spec.
---@param lines string[]
---@return string[]
--- Check if a line starts a block-level construct (not a paragraph continuation)
---@param line string
---@return boolean
local function is_block_start(line)
  if line:match "^%s*$" then return true end
  if line:match "^#+%s" then return true end
  if line:match "^```" or line:match "^~~~" then return true end
  if line:match "^%s*|" then return true end
  if line:match "^%s*[%-%*%+]%s" then return true end
  if line:match "^%s*%d+[%.)]%s" then return true end
  if line:match "^>" then return true end
  if line:match "^%s*[-_*]%s*[-_*]%s*[-_*]" then return true end
  if line:match "^[=-]+%s*$" then return true end
  if line:match "^%[.+%]:" then return true end
  if line:match "^%[%^.+%]:" then return true end
  if line:match "^%s*<" then return true end
  if line:match "^%s*!%[" then return true end
  if line:match "^%$%$$" then return true end
  if line:match "^%%%%" then return true end
  if line:match "^:::" then return true end
  if line:match "^    %S" then return true end -- indented code block (4+ spaces)
  return false
end

--- Join paragraph continuation lines into single lines.
--- In CommonMark, consecutive lines that don't start block-level constructs
--- form a single paragraph. This is needed for inline constructs (like links)
--- that span multiple source lines.
---
--- `src_indices` is a parallel array giving the original buffer line
--- number for each input line. The returned `result_indices` carries the
--- original line number of the *first* line of each joined paragraph,
--- so `source_line_map` can point back to the real buffer position.
---@param lines string[]
---@param src_indices integer[]
---@return string[] result, integer[] result_indices
local function join_paragraph_continuations(lines, src_indices)
  local result = {}
  local result_indices = {}
  local para = {}
  local para_src = nil
  local in_code = false
  local in_html_comment = false

  local function flush_para()
    if #para > 0 then
      table.insert(result, table.concat(para, " "))
      table.insert(result_indices, para_src)
      para = {}
      para_src = nil
    end
  end

  for idx, line in ipairs(lines) do
    local src = src_indices[idx]
    -- Track code fences
    if line:match "^```" or line:match "^~~~" then
      in_code = not in_code
    end

    -- Track multi-line HTML comments
    if not in_code then
      if in_html_comment then
        -- Flush paragraph, keep comment lines separate
        flush_para()
        table.insert(result, line)
        table.insert(result_indices, src)
        if line:match "%-%->" then
          in_html_comment = false
        end
        goto next_line
      end
      if line:match "^%s*<!%-%-" and not line:match "%-%->%s*$" then
        in_html_comment = true
        flush_para()
        table.insert(result, line)
        table.insert(result_indices, src)
        goto next_line
      end
    end

    if in_code or is_block_start(line) then
      -- Flush accumulated paragraph
      flush_para()
      table.insert(result, line)
      table.insert(result_indices, src)
    else
      if #para == 0 then para_src = src end
      table.insert(para, line)
    end

    ::next_line::
  end

  flush_para()

  return result, result_indices
end

--- Preprocess multi-line HTML constructs into single result lines.
---
--- `src_indices` is a parallel array giving the original buffer line
--- number for each input line. The returned `result_indices` carries the
--- original line of the *first* input line of each accumulated
--- multi-line block, so callers can set source_line_map back to the
--- correct buffer position even after collapse.
---@param lines string[]
---@param src_indices integer[]  parallel original-line indices for `lines`
---@return string[] result, integer[] result_indices
local function preprocess_multiline_html(lines, src_indices)
  local result = {}
  local result_indices = {}
  local accum = nil -- { tag: string, lines: string[], depth: integer, src: integer }
  local in_code = false

  for idx, l in ipairs(lines) do
    local src = src_indices[idx]
    if accum then
      table.insert(accum.lines, l)
      local ll = l:lower()
      for _ in ll:gmatch("<" .. accum.tag .. "[%s>]") do
        accum.depth = accum.depth + 1
      end
      for _ in ll:gmatch("</" .. accum.tag .. "[%s>]") do
        accum.depth = accum.depth - 1
      end
      if accum.depth <= 0 then
        -- Join all lines with spaces (HTML whitespace collapsing)
        local joined = table.concat(accum.lines, " ")
        joined = joined:gsub("  +", " ")
        table.insert(result, joined)
        table.insert(result_indices, accum.src)
        accum = nil
      end
    else
      if l:match "^```" then
        in_code = not in_code
      end
      if not in_code then
        local tag_name = l:match "^%s*<(%a%w*)[%s>]"
        if tag_name then
          local lower_tag = tag_name:lower()
          if not HTML_SKIP_TAGS[lower_tag] and not HTML_VOID_ELEMENTS[lower_tag] and not l:match "/>%s*$" then
            local ll = l:lower()
            local open_count = 0
            for _ in ll:gmatch("<" .. lower_tag .. "[%s>]") do
              open_count = open_count + 1
            end
            local close_count = 0
            for _ in ll:gmatch("</" .. lower_tag .. "[%s>]") do
              close_count = close_count + 1
            end
            if open_count > close_count then
              accum = {
                tag = lower_tag,
                lines = { l },
                depth = open_count - close_count,
                src = src,
              }
            else
              table.insert(result, l)
              table.insert(result_indices, src)
            end
          else
            table.insert(result, l)
            table.insert(result_indices, src)
          end
        else
          table.insert(result, l)
          table.insert(result_indices, src)
        end
      else
        table.insert(result, l)
        table.insert(result_indices, src)
      end
    end
  end

  -- Unclosed accumulation: output lines as-is, each at its own original
  -- line. We don't have src indices for the inner lines anymore (we only
  -- stashed accum.src), so fall back to that for all of them; the
  -- shadow's owner-fallback will treat them as one block.
  if accum then
    for _, l in ipairs(accum.lines) do
      table.insert(result, l)
      table.insert(result_indices, accum.src)
    end
  end

  return result, result_indices
end

function ContentBuilder:render_document(lines, opts)
  opts = opts or {}
  local markdown = require "md-render.markdown"

  -- Track each transformed line back to its original buffer line so
  -- source_line_map records real buffer positions, not post-transform
  -- array indices.
  local src_indices = {}
  for i = 1, #lines do
    src_indices[i] = i
  end
  lines, src_indices = preprocess_multiline_html(lines, src_indices)
  lines, src_indices = join_paragraph_continuations(lines, src_indices)
  lines = markdown.renumber_ordered_lists(lines)
  -- renumber_ordered_lists rewrites text but keeps line count, so
  -- src_indices stays valid.
  local ref_links = markdown.parse_reference_links(lines)
  local footnote_defs, footnote_map = markdown.parse_footnotes(lines)

  local max_width = opts.max_width or 80
  local indent = opts.indent or "  "
  local max_lines = opts.max_lines or math.huge
  local repo_base_url = opts.repo_base_url
  local autolinks = opts.autolinks
  local fold_state = opts.fold_state or {}
  local expand_state = opts.expand_state or {}
  local source_line_offset = opts.source_line_offset or 0
  local buf_dir = opts.buf_dir or vim.fn.expand("%:p:h")

  local in_code_block = false
  local code_block_lang = nil
  local code_block_start = nil
  local code_source_lines = nil
  local code_block_id = nil
  local code_block_has_truncation = false
  local prev_was_heading = false
  local prev_was_hr = false
  local prev_rendered_blank = false
  local prev_list_marker_type = nil
  local lines_shown = 0
  local table_buf = {}
  local table_buf_start_idx = nil
  local truncated = false
  local current_alert_type = nil
  local skip_callout_body = false
  local in_callout_code_block = false
  local callout_code_lang = nil
  local callout_code_start = nil
  local callout_code_prefix = nil
  local callout_code_source_lines = nil
  local callout_code_block_id = nil
  local callout_code_has_truncation = false
  local in_math_block = false
  local math_block_start = nil
  local math_block_id = nil
  local in_indented_code = false
  local in_comment_block = false
  local in_html_comment = false
  local skip_next_line = false
  local in_details = false
  local details_src_idx = nil
  local details_default_open = false
  local details_summary_rendered = false
  local details_depth = 0
  local in_details_summary = false
  local details_summary_parts = {}
  local in_figure = false
  local figure_caption = nil
  -- Original buffer line of the <figcaption> tag, captured at parse
  -- time so we can stamp source_line_map under it when the caption is
  -- actually rendered at </figure>.
  local figure_caption_src = nil
  local in_p_tag = false
  local skip_details_body = false
  local in_qiita_note = false
  local qiita_note_type = nil
  local in_dl = false
  local in_html_table = false
  local html_table_lines = {}
  local html_table_src_idx = nil
  local html_table_depth = 0

  --- Flush accumulated table lines
  local function flush_table()
    if #table_buf > 0 then
      local lines_before_tbl = #self.lines
      local tbl_expanded = table_buf_start_idx and expand_state[table_buf_start_idx]
      -- The trigger line (e.g. the blank after the table) has already
      -- advanced _current_source_line. Stamp the table's first source
      -- line so add_table's emissions land in source_line_map under the
      -- table itself, then restore for the caller.
      local saved_src_line = self._current_source_line
      if table_buf_start_idx then
        self._current_source_line = table_buf_start_idx + source_line_offset
      end
      self:add_table(table_buf, indent, max_width, repo_base_url, autolinks, tbl_expanded or false, buf_dir, true)
      self._current_source_line = saved_src_line
      local lines_added = #self.lines - lines_before_tbl
      lines_shown = lines_shown + lines_added
      local has_truncation = false
      if not tbl_expanded then
        for li = lines_before_tbl + 1, #self.lines do
          if self.lines[li] and self.lines[li]:match "…" then
            has_truncation = true
            break
          end
        end
      end
      if has_truncation or tbl_expanded then
        table.insert(self.expandable_regions, {
          start_line = lines_before_tbl,
          end_line = #self.lines - 1,
          block_id = table_buf_start_idx,
          expanded = tbl_expanded or false,
        })
      end
      table_buf = {}
      table_buf_start_idx = nil
    end
  end

  --- Render a <details> summary header with fold indicator
  local function render_details_summary(summary_text)
    local is_collapsed
    if fold_state[details_src_idx] ~= nil then
      is_collapsed = fold_state[details_src_idx]
    else
      is_collapsed = not details_default_open
    end

    local det_lines_before = #self.lines
    local det_icon = is_collapsed and "▶ " or "▼ "
    local det_rendered, det_hls, det_links = markdown.render(
      summary_text, repo_base_url, autolinks, ref_links
    )

    local det_icon_len = #det_icon
    for _, hl in ipairs(det_hls) do
      hl.col = hl.col + det_icon_len
      hl.end_col = hl.end_col + det_icon_len
    end
    for _, link in ipairs(det_links) do
      link.col_start = link.col_start + det_icon_len
      link.col_end = link.col_end + det_icon_len
    end

    local det_full = det_icon .. det_rendered
    table.insert(det_hls, 1, { col = 0, end_col = #det_full, hl = "Title" })

    self:add_simple_markdown(det_full, det_hls, det_links, indent)

    table.insert(self.callout_folds, {
      header_line = det_lines_before,
      source_line = details_src_idx,
      collapsed = is_collapsed,
    })

    if is_collapsed then
      skip_details_body = true
    end

    details_summary_rendered = true
    lines_shown = lines_shown + (#self.lines - det_lines_before)
  end

  --- Apply │ prefix and FloatBorder highlight to lines rendered within a <details> body
  local function apply_details_body_prefix(from_line, to_line)
    local prefix = "│ "
    local prefix_len = #prefix
    local indent_len = #indent

    for i = from_line + 1, to_line do
      local line_text = self.lines[i]
      self.lines[i] = line_text:sub(1, indent_len) .. prefix .. line_text:sub(indent_len + 1)
    end

    for _, hl_info in ipairs(self.highlights) do
      if hl_info.line >= from_line and hl_info.line < to_line then
        for _, group in ipairs(hl_info.groups) do
          group.col = group.col + prefix_len
          if group.end_col >= 0 then
            group.end_col = group.end_col + prefix_len
          end
        end
        table.insert(hl_info.groups, 1, {
          col = indent_len,
          end_col = indent_len + prefix_len,
          hl = "MdRenderDetailsBar",
        })
        table.insert(hl_info.groups, { col = 0, end_col = -1, hl = "MdRenderDetailsBg", hl_eol = true })
      end
    end

    for line_idx = from_line, to_line - 1 do
      local has_hl = false
      for _, hl_info in ipairs(self.highlights) do
        if hl_info.line == line_idx then
          has_hl = true
          break
        end
      end
      if not has_hl then
        table.insert(self.highlights, {
          line = line_idx,
          groups = {
            { col = indent_len, end_col = indent_len + prefix_len, hl = "MdRenderDetailsBar" },
            { col = 0, end_col = -1, hl = "MdRenderDetailsBg", hl_eol = true },
          },
        })
      end
    end

    for _, link in ipairs(self.link_metadata) do
      if link.line >= from_line and link.line < to_line then
        link.col_start = link.col_start + prefix_len
        link.col_end = link.col_end + prefix_len
      end
    end

    for _, cb in ipairs(self.code_blocks) do
      if cb.start_line >= from_line and cb.end_line < to_line then
        cb.prefix_len = (cb.prefix_len or indent_len) + prefix_len
      end
    end
  end

  for src_idx, line in ipairs(lines) do
    -- src_idx is the post-transform array index; src_indices[src_idx]
    -- is the original buffer line, which is what consumers (cursor sync,
    -- shadow cursor, link/anchor extraction) actually expect.
    self:set_source_line(src_indices[src_idx] + source_line_offset)

    -- Skip setext heading underline
    if skip_next_line then
      skip_next_line = false
      goto continue
    end

    -- Skip reference link definition lines
    if not in_code_block and markdown.is_reference_link_def(line) then
      goto continue
    end

    -- Skip footnote definition lines (rendered in footnote section at end)
    if not in_code_block and markdown.is_footnote_def(line) then
      goto continue
    end

    -- Handle <div>/<span> wrapper tags (outside code blocks)
    -- Strip wrapper tags and let inner content fall through to normal processing.
    if not in_code_block and not in_callout_code_block then
      -- Closing </div> or </span> on its own line
      if line:match "^%s*</div>%s*$" or line:match "^%s*</span>%s*$" then
        goto continue
      end
      -- Opening <div>/<span> with no content on the same line
      if (line:match "^%s*<div>%s*$" or line:match "^%s*<div%s[^>]*>%s*$")
        or (line:match "^%s*<span>%s*$" or line:match "^%s*<span%s[^>]*>%s*$") then
        goto continue
      end
      -- Single-line <div>...</div>: extract inner content
      local div_inner = line:match "^%s*<div[^>]*>%s*(.-)%s*</div>%s*$"
      if div_inner and div_inner:match "%S" then
        line = div_inner
        -- Fall through with extracted content
      end
      -- Single-line <span>...</span>: extract inner content
      local span_inner = line:match "^%s*<span[^>]*>%s*(.-)%s*</span>%s*$"
      if span_inner and span_inner:match "%S" then
        line = span_inner
        -- Fall through with extracted content
      end
      -- Opening <div>/<span> with content after the tag (no closing on same line)
      local div_rest = line:match "^%s*<div[^>]*>%s*(.+)$"
      if div_rest and not line:match "</div>" then
        line = div_rest
        -- Fall through with extracted content
      end
      local span_rest = line:match "^%s*<span[^>]*>%s*(.+)$"
      if span_rest and not line:match "</span>" then
        line = span_rest
        -- Fall through with extracted content
      end
    end

    -- Detect setext heading: current non-blank line followed by === or ---
    if not in_code_block and not line:match "^%s*$" and not line:match "^[#>%-%*`|%d]" then
      local next_line = lines[src_idx + 1]
      if next_line then
        if next_line:match "^=+%s*$" then
          line = "# " .. line
          skip_next_line = true
        elseif next_line:match "^%-+%s*$" then
          line = "## " .. line
          skip_next_line = true
        end
      end
    end

    -- Convert HTML headings <h1>-<h6> to markdown format
    -- If heading contains an <img>, split it into separate image + heading lines
    if not in_code_block then
      local h_level, h_content = line:match "^%s*<h([1-6])[^>]*>(.-)</h%1>%s*$"
      if h_level then
        local img_tag = h_content:match "(<img%s[^>]*>)"
        if img_tag then
          -- Extract the img tag as a standalone line, render it before the heading
          local remaining = h_content:gsub("<img%s[^>]*>", ""):gsub("^%s+", ""):gsub("%s+$", "")
          -- Insert the img tag line (will be processed by subsequent iteration);
          -- keep src_indices in sync so set_source_line() at line 1170 doesn't
          -- index past the end. The synthetic img line shares the heading's
          -- original buffer line.
          table.insert(lines, src_idx + 1, img_tag)
          table.insert(src_indices, src_idx + 1, src_indices[src_idx])
          if remaining ~= "" then
            line = string.rep("#", tonumber(h_level)) .. " " .. remaining
          else
            goto continue
          end
        else
          line = string.rep("#", tonumber(h_level)) .. " " .. h_content
        end
      end
    end

    local is_blank = line:match "^%s*$" ~= nil
    local is_heading = (not in_code_block) and line:match "^#+%s+" ~= nil
    local is_table_line = (not in_code_block) and line:match "^%s*|" ~= nil

    -- Skip body lines of a collapsed foldable callout
    if skip_callout_body then
      if line:match "^>" then
        goto continue
      else
        skip_callout_body = false
        current_alert_type = nil
      end
    end

    -- Toggle Obsidian block comment (outside code blocks)
    if not in_code_block and line:match "^%s*%%%%%s*$" then
      in_comment_block = not in_comment_block
      goto continue
    end
    if in_comment_block then
      goto continue
    end

    -- Handle HTML comments (<!-- ... -->) outside code blocks
    if not in_code_block then
      if in_html_comment then
        if line:match "%-%->" then
          in_html_comment = false
        end
        goto continue
      end
      -- Single-line HTML comment
      if line:match "^%s*<!%-%-.*%-%->%s*$" then
        goto continue
      end
      -- Multi-line HTML comment start
      if line:match "^%s*<!%-%-" then
        in_html_comment = true
        goto continue
      end
    end

    -- Handle <details>/<summary> HTML blocks (outside code blocks)
    if not in_code_block and not in_callout_code_block then
      -- Handle </details> end tag
      if line:match "^%s*</details>%s*$" then
        if in_details then
          if details_depth > 0 then
            details_depth = details_depth - 1
          else
            in_details = false
            skip_details_body = false
            details_src_idx = nil
            details_summary_rendered = false
          end
        end
        goto continue
      end

      -- Skip body of collapsed <details>
      if skip_details_body then
        if line:match "^%s*<details" then
          details_depth = details_depth + 1
        end
        goto continue
      end

      -- Handle <details> opening tag
      if line:match "^%s*<details" then
        if in_details then
          details_depth = details_depth + 1
          goto continue
        end
        local attrs = line:match "^%s*<details(.-)>" or ""
        in_details = true
        details_src_idx = src_idx
        details_default_open = attrs:match "open" ~= nil
        details_summary_rendered = false
        details_depth = 0
        in_details_summary = false
        details_summary_parts = {}

        -- Check for inline <summary>...</summary>
        local rest = line:match "^%s*<details.->(.+)$"
        if rest then
          local s = rest:match "<summary>(.-)</summary>"
          if s then
            render_details_summary(s ~= "" and s or "Details")
          end
        end
        goto continue
      end

      -- Handle <summary> within <details>
      if in_details and not details_summary_rendered then
        if in_details_summary then
          -- Accumulating multi-line summary
          local before = line:match "^(.-)</summary>%s*$"
          if before then
            if before ~= "" then
              table.insert(details_summary_parts, before)
            end
            in_details_summary = false
            local joined = table.concat(details_summary_parts, " ")
            render_details_summary(joined ~= "" and joined or "Details")
            goto continue
          end
          table.insert(details_summary_parts, line)
          goto continue
        end

        -- Single-line <summary>text</summary>
        local s = line:match "^%s*<summary>(.-)</summary>%s*$"
        if s then
          render_details_summary(s ~= "" and s or "Details")
          goto continue
        end

        -- Multi-line <summary> start
        local start_text = line:match "^%s*<summary>(.*)$"
        if start_text then
          in_details_summary = true
          details_summary_parts = {}
          if start_text ~= "" then
            table.insert(details_summary_parts, start_text)
          end
          goto continue
        end

        -- No <summary> found and this is content - render default header
        if not is_blank then
          render_details_summary "Details"
          -- Fall through to render this line as body content
        end
      end
    end

    -- Handle <figure> blocks (outside code blocks)
    -- Lines inside <figure> pass through normally (e.g. <img> lines are rendered
    -- by the standalone image detector below). Only the <figure>, </figure>, and
    -- <figcaption> wrapper tags are consumed here.
    if not in_code_block and not in_callout_code_block then
      if in_figure then
        if line:match "^%s*</figure>%s*$" then
          in_figure = false
          -- Render figcaption centered (captured during figure body processing).
          -- Process inline markdown so tags like <em>/<strong> render properly,
          -- and wrap long captions instead of overflowing the window.
          if figure_caption then
            -- Trigger line is </figure>; restore the figcaption's own
            -- source line so its render rows are attributed to it.
            local saved_src_line = self._current_source_line
            if figure_caption_src then
              self._current_source_line = figure_caption_src + source_line_offset
            end
            local rendered_text, md_highlights, md_links =
              markdown.render(figure_caption, repo_base_url, autolinks, ref_links, footnote_map)
            -- Apply Comment as the base highlight covering the whole caption
            table.insert(md_highlights, 1, {
              col = 0,
              end_col = #rendered_text,
              hl = "Comment",
            })

            local indent_width = vim.api.nvim_strwidth(indent)
            local available = math.max(1, max_width - indent_width)
            local wrapped_lines, line_starts
            if vim.api.nvim_strwidth(rendered_text) > available then
              wrapped_lines, line_starts = wrap_words(rendered_text, available)
            else
              wrapped_lines, line_starts = { rendered_text }, { 0 }
            end

            local base_line = #self.lines
            for idx, wline in ipairs(wrapped_lines) do
              local line_width = vim.api.nvim_strwidth(wline)
              local pad = math.max(0, math.floor((max_width - line_width) / 2) - indent_width)
              local prefix_len = #indent + pad
              local padded = indent .. string.rep(" ", pad) .. wline
              local line_start = line_starts[idx] or 0
              local line_end_pos = line_start + #wline

              local line_hls = {}
              for _, hl in ipairs(md_highlights) do
                if hl.end_col > line_start and hl.col < line_end_pos then
                  local local_start = math.max(0, hl.col - line_start)
                  local local_end = math.min(#wline, hl.end_col - line_start)
                  table.insert(line_hls, {
                    col = prefix_len + local_start,
                    end_col = prefix_len + local_end,
                    hl = hl.hl,
                  })
                end
              end
              self:add_line(padded, #line_hls > 0 and line_hls or nil)

              for _, link in ipairs(md_links) do
                if link.col_end > line_start and link.col_start < line_end_pos then
                  local local_start = math.max(0, link.col_start - line_start)
                  local local_end = math.min(#wline, link.col_end - line_start)
                  table.insert(self.link_metadata, {
                    line = base_line + idx - 1,
                    col_start = prefix_len + local_start,
                    col_end = prefix_len + local_end,
                    url = link.url,
                  })
                end
              end

              lines_shown = lines_shown + 1
            end
            figure_caption = nil
            figure_caption_src = nil
            self._current_source_line = saved_src_line
          end
          goto continue
        end
        -- Extract <figcaption> content for rendering when </figure> is reached
        local cap = line:match "^%s*<figcaption>(.-)</figcaption>%s*$"
        if cap and cap:match "%S" then
          figure_caption = cap
          figure_caption_src = src_indices[src_idx]
          goto continue
        end
        -- Other lines inside <figure> (e.g. <img>) fall through to normal processing
      end

      if line:match "^%s*<figure[^>]*>%s*$" then
        in_figure = true
        goto continue
      end
    end

    -- Handle <p> blocks (outside code blocks)
    -- Strip <p>/<p align="..."> wrapper tags and let inner content (e.g. <img>,
    -- <em>) fall through to normal processing, similar to <figure>.
    if not in_code_block and not in_callout_code_block then
      if in_p_tag then
        if line:match "^%s*</p>%s*$" then
          in_p_tag = false
          goto continue
        end
        -- Inner content falls through to normal processing
      end

      if line:match "^%s*<p[%s>]" and not line:match "</p>" then
        in_p_tag = true
        goto continue
      end
      -- Single-line <p>...</p>: extract inner content and process it
      local p_inner = line:match "^%s*<p[^>]*>%s*(.-)%s*</p>%s*$"
      if p_inner and p_inner:match "%S" then
        line = p_inner
        -- Fall through with extracted content
      end
    end

    -- Handle <dl> definition lists (outside code blocks)
    if not in_code_block and not in_callout_code_block then
      if in_dl then
        if line:match "^%s*</dl>%s*$" then
          in_dl = false
          -- Ensure blank line after </dl> block
          self:add_line(indent)
          lines_shown = lines_shown + 1
          prev_rendered_blank = true
          goto continue
        end
        -- Parse <dt> and <dd> elements from the line
        -- A line may contain <dt>term</dt><dd>description patterns
        flush_table()
        local rest = line
        -- Strip standalone <dl> opening if present
        rest = rest:gsub("^%s*<dl>%s*", "")
        if rest:match "^%s*$" then goto continue end
        while rest and rest ~= "" do
          -- Try to match <dt>...</dt> or <dt>...
          local dt_content = rest:match "^%s*<dt>(.-)</dt>"
          if dt_content then
            rest = rest:match "^%s*<dt>.-</dt>%s*(.*)" or ""
            -- Split on <br> / <br/> / <br /> and render each segment
            local dt_lines_before = #self.lines
            for _, seg in ipairs(vim.split(dt_content, "<br%s*/?>", { plain = false, trimempty = true })) do
              seg = seg:gsub("^%s+", ""):gsub("%s+$", "")
              if seg ~= "" then
                local dt_rendered, dt_hls, dt_links = markdown.render(seg, repo_base_url, autolinks, ref_links)
                table.insert(dt_hls, { col = 0, end_col = #dt_rendered, hl = "Bold" })
                self:add_simple_markdown(dt_rendered, dt_hls, dt_links, indent)
              end
            end
            if in_details and details_summary_rendered and not skip_details_body then
              apply_details_body_prefix(dt_lines_before, #self.lines)
            end
            lines_shown = lines_shown + (#self.lines - dt_lines_before)
          end
          -- Try to match <dd>...</dd> or <dd>... (may not have closing tag)
          local dd_content = rest:match "^%s*<dd>(.-)</dd>"
          if dd_content then
            rest = rest:match "^%s*<dd>.-</dd>%s*(.*)" or ""
          else
            dd_content = rest:match "^%s*<dd>(.*)"
            if dd_content then
              rest = ""
            end
          end
          if dd_content and dd_content ~= "" then
            local dd_indent = indent .. "  "
            local dd_lines_before = #self.lines
            -- Split on <br> / <br/> / <br /> and render each segment
            for _, seg in ipairs(vim.split(dd_content, "<br%s*/?>", { plain = false, trimempty = true })) do
              seg = seg:gsub("^%s+", ""):gsub("%s+$", "")
              if seg ~= "" then
                local dd_rendered, dd_hls, dd_links = markdown.render(seg, repo_base_url, autolinks, ref_links)
                if vim.api.nvim_strwidth(dd_rendered) > max_width - 2 then
                  self:add_wrapped_markdown(dd_rendered, dd_hls, dd_links, dd_indent, max_width - 2, "")
                else
                  self:add_simple_markdown(dd_rendered, dd_hls, dd_links, dd_indent)
                end
              end
            end
            if in_details and details_summary_rendered and not skip_details_body then
              apply_details_body_prefix(dd_lines_before, #self.lines)
            end
            lines_shown = lines_shown + (#self.lines - dd_lines_before)
          end
          -- If nothing matched, skip rest to avoid infinite loop
          if not dt_content and not dd_content then
            break
          end
        end
        goto continue
      end

      if line:match "^%s*<dl[^>]*>" then
        flush_table()
        -- Ensure blank line before <dl> block
        if lines_shown > 0 and not prev_rendered_blank then
          self:add_line(indent)
          lines_shown = lines_shown + 1
        end
        in_dl = true
        goto continue
      end
    end

    -- Handle HTML <table> blocks (outside code blocks)
    if not in_code_block and not in_callout_code_block then
      if in_html_table then
        table.insert(html_table_lines, line)
        -- Track nested <table> depth
        local ll = line:lower()
        for _ in ll:gmatch "<table[%s>]" do
          html_table_depth = html_table_depth + 1
        end
        for _ in ll:gmatch "</table" do
          html_table_depth = html_table_depth - 1
        end
        if html_table_depth <= 0 then
          in_html_table = false
          -- Convert HTML table to pipe-table lines and render
          local pipe_lines = html_table_to_pipe(html_table_lines)
          if #pipe_lines >= 2 then
            flush_table()
            if lines_shown > 0 and not prev_rendered_blank then
              self:add_line(indent)
              lines_shown = lines_shown + 1
            end
            local tbl_lines_before = #self.lines
            local tbl_expanded = html_table_src_idx and expand_state[html_table_src_idx]
            -- Same source-line stamping rationale as flush_table above.
            local saved_src_line = self._current_source_line
            if html_table_src_idx then
              self._current_source_line = html_table_src_idx + source_line_offset
            end
            self:add_table(pipe_lines, indent, max_width, repo_base_url, autolinks, tbl_expanded or false)
            self._current_source_line = saved_src_line
            local tbl_lines_added = #self.lines - tbl_lines_before
            lines_shown = lines_shown + tbl_lines_added
            local has_truncation = false
            if not tbl_expanded then
              for li = tbl_lines_before + 1, #self.lines do
                if self.lines[li] and self.lines[li]:match "…" then
                  has_truncation = true
                  break
                end
              end
            end
            if has_truncation or tbl_expanded then
              table.insert(self.expandable_regions, {
                start_line = tbl_lines_before,
                end_line = #self.lines - 1,
                block_id = html_table_src_idx,
                expanded = tbl_expanded or false,
              })
            end
            if in_details and details_summary_rendered and not skip_details_body then
              apply_details_body_prefix(tbl_lines_before, #self.lines)
            end
            prev_rendered_blank = false
          end
          html_table_lines = {}
          html_table_src_idx = nil
        end
        goto continue
      end

      if line:match "^%s*<table[^>]*>" then
        flush_table()
        in_html_table = true
        html_table_depth = 1
        html_table_lines = { line }
        html_table_src_idx = src_indices[src_idx]
        -- Check if </table> is on the same line
        if line:lower():match "</table" then
          html_table_depth = 0
          -- will be handled on next iteration; re-process
          in_html_table = false
          local pipe_lines = html_table_to_pipe(html_table_lines)
          if #pipe_lines >= 2 then
            if lines_shown > 0 and not prev_rendered_blank then
              self:add_line(indent)
              lines_shown = lines_shown + 1
            end
            local tbl_lines_before = #self.lines
            self:add_table(pipe_lines, indent, max_width, repo_base_url, autolinks, nil, buf_dir)
            lines_shown = lines_shown + (#self.lines - tbl_lines_before)
            if in_details and details_summary_rendered and not skip_details_body then
              apply_details_body_prefix(tbl_lines_before, #self.lines)
            end
          end
          html_table_lines = {}
          html_table_src_idx = nil
        end
        goto continue
      end
    end

    -- Handle <hr> as horizontal rule
    if not in_code_block and line:match "^%s*<hr[^>]*>%s*$" then
      flush_table()
      if lines_shown > 0 and not prev_was_hr then
        self:add_line(indent)
        lines_shown = lines_shown + 1
      end
      local hr_lines_before = #self.lines
      local rule = indent .. string.rep("─", max_width)
      self:add_line(rule, { { col = 0, end_col = #rule, hl = "FloatBorder" } })
      if in_details and details_summary_rendered and not skip_details_body then
        apply_details_body_prefix(hr_lines_before, #self.lines)
      end
      lines_shown = lines_shown + 1
      prev_was_heading = false
      prev_was_hr = true
      prev_list_marker_type = nil
      goto continue
    end

    -- Handle markdown thematic breaks (---, ***, ___, etc.)
    if not in_code_block and is_thematic_break(line) then
      flush_table()
      if lines_shown > 0 and not prev_was_hr then
        self:add_line(indent)
        lines_shown = lines_shown + 1
      end
      local hr_lines_before = #self.lines
      local rule = indent .. string.rep("─", max_width)
      self:add_line(rule, { { col = 0, end_col = #rule, hl = "FloatBorder" } })
      if in_details and details_summary_rendered and not skip_details_body then
        apply_details_body_prefix(hr_lines_before, #self.lines)
      end
      lines_shown = lines_shown + 1
      prev_was_heading = false
      prev_was_hr = true
      prev_list_marker_type = nil
      goto continue
    end

    -- Add blank line after HR for regular content (not heading, not HR)
    -- Headings already add their own blank line before them.
    if prev_was_hr and not is_blank and not is_heading then
      self:add_line(indent)
      lines_shown = lines_shown + 1
    end
    if prev_was_hr and not is_blank then
      prev_was_hr = false
    end

    -- Accumulate table lines
    if is_table_line then
      if #table_buf == 0 then
        -- Record the table's original buffer line so flush_table can
        -- stamp source_line_map with the table itself rather than the
        -- line that happens to trigger the flush.
        table_buf_start_idx = src_indices[src_idx]
        -- Ensure exactly 1 blank line before table
        if lines_shown > 0 and not prev_rendered_blank then
          self:add_line(indent)
          lines_shown = lines_shown + 1
        end
      end
      table.insert(table_buf, line)
      goto continue
    end

    -- Flush table buffer when a non-table line is encountered
    if #table_buf > 0 then
      flush_table()
      if lines_shown >= max_lines then
        self:add_line(indent .. "... (truncated)", { { col = 0, end_col = -1, hl = "Comment" } })
        truncated = true
        break
      end
      -- Ensure exactly 1 blank line after table (collapse duplicates below)
      self:add_line(indent)
      lines_shown = lines_shown + 1
      prev_rendered_blank = true
    end

    -- Collapse consecutive rendered blank lines (outside regular code blocks)
    if not in_code_block and is_blank and prev_rendered_blank then
      goto continue
    end

    -- Skip blank lines adjacent to headings (outside code blocks)
    if not in_code_block and not in_callout_code_block and is_blank then
      local skip = prev_was_heading or prev_was_hr
      if not skip then
        for k = src_idx + 1, #lines do
          -- Skip blank lines, reference link definitions, and footnote definitions (not rendered)
          if not lines[k]:match "^%s*$"
            and not markdown.is_reference_link_def(lines[k])
            and not markdown.is_footnote_def(lines[k]) then
            -- Check ATX heading or setext heading (text followed by === or ---)
            skip = lines[k]:match "^#+%s+" ~= nil
            if not skip then
              skip = is_thematic_break(lines[k])
            end
            if not skip then
              skip = lines[k]:match "^:::$" ~= nil
            end
            if not skip and not lines[k]:match "^[#>%-%*`|%d]" then
              local kk = lines[k + 1]
              if kk and (kk:match "^=+%s*$" or kk:match "^%-+%s*$") then
                skip = true
              end
            end
            break
          end
        end
      end
      if skip then
        goto continue
      end

      -- Skip blank lines between list items of the same marker type (loose list → tight)
      if not skip and prev_list_marker_type then
        local next_marker_type
        for k = src_idx + 1, #lines do
          if not lines[k]:match "^%s*$" then
            next_marker_type = markdown.list_marker_type(lines[k])
            break
          end
        end
        if next_marker_type and next_marker_type == prev_list_marker_type then
          goto continue
        end
      end
    end

    -- Ensure exactly one blank line before headings (except the first content)
    if not in_code_block and is_heading and lines_shown > 0 then
      self:add_line(indent)
      lines_shown = lines_shown + 1
      if lines_shown >= max_lines then
        self:add_line(indent .. "... (truncated)", { { col = 0, end_col = -1, hl = "Comment" } })
        truncated = true
        break
      end
    end

    -- Indented code block: 4+ spaces, not in a list/blockquote/etc context
    if not in_code_block and not in_math_block and not current_alert_type
        and line:match "^    " and not line:match "^    [%-*+]%s" and not line:match "^    %d+[.)]%s"
        and (in_indented_code or not prev_list_marker_type) then
      in_indented_code = true
      local code_content = line:sub(5) -- strip 4-space indent
      local indented_line = indent .. code_content
      local display_width = vim.api.nvim_strwidth(indented_line)
      local ib_lines_before = #self.lines
      if display_width > max_width then
        local target = max_width - vim.api.nvim_strwidth("…")
        local current_width = 0
        local byte_pos = 0
        for char in indented_line:gmatch "[%z\1-\127\194-\253][\128-\191]*" do
          local char_width = vim.api.nvim_strwidth(char)
          if current_width + char_width > target then
            break
          end
          current_width = current_width + char_width
          byte_pos = byte_pos + #char
        end
        local truncated_line = indented_line:sub(1, byte_pos) .. "…"
        self:add_line(truncated_line, { { col = 0, end_col = -1, hl = "String" } })
      else
        self:add_line(indented_line, { { col = 0, end_col = -1, hl = "String" } })
      end
      detect_urls_in_code_line(self, code_content, #indent, #indented_line)
      if in_details and details_summary_rendered and not skip_details_body then
        apply_details_body_prefix(ib_lines_before, #self.lines)
      end
      lines_shown = lines_shown + 1
      goto continue
    end
    in_indented_code = false

    local lines_before = #self.lines

    -- Handle Qiita :::note / :::message blocks (outside code blocks)
    if not in_code_block and not in_math_block then
      -- Closing :::
      if in_qiita_note and line:match "^:::$" then
        in_qiita_note = false
        qiita_note_type = nil
        current_alert_type = nil
        prev_rendered_blank = false
        goto continue
      end

      -- Opening :::note or :::message
      local note_type = line:match "^:::note%s+(%a+)%s*$"
        or (line:match "^:::note%s*$" and "info")
        or line:match "^:::message%s+(%a+)%s*$"
        or (line:match "^:::message%s*$" and "info")
      if note_type then
        in_qiita_note = true
        -- Map Qiita note types to existing alert style keys
        local qiita_map = {
          info  = { style = "NOTE",    icon = "󰋽", label = "Note" },
          warn  = { style = "WARNING", icon = "󰀪", label = "Warning" },
          alert = { style = "CAUTION", icon = "󰳦", label = "Caution" },
        }
        local qm = qiita_map[note_type] or qiita_map.info
        qiita_note_type = qm.style

        local icon = pad_icon(qm.icon)
        local header_text = indent .. "│ " .. icon .. " " .. qm.label
        self:add_line(header_text, {
          { col = #indent, end_col = #indent + #"│ ", hl = "FloatBorder" },
          { col = #indent + #"│ ", end_col = #header_text, hl = "MdRenderAlert" .. (qiita_note_type:sub(1, 1) .. qiita_note_type:sub(2):lower()) },
        })
        self:apply_alert_styling(lines_before, #self.lines, qiita_note_type, true)
        lines_shown = lines_shown + 1
        prev_rendered_blank = false
        prev_was_heading = true -- suppress blank line after header (like heading)
        prev_list_marker_type = nil
        goto continue
      end

      -- Body lines inside :::note block
      if in_qiita_note then
        -- Code blocks inside Qiita notes: transform to callout format
        -- and fall through to the callout code block handler below
        if in_callout_code_block or line:match "^```" then
          line = "> " .. line
          current_alert_type = qiita_note_type
        else
          -- Render as blockquote-style content with alert styling
          local qn_line = "> " .. line
          local alert_type_ret = self:add_markdown_line(qn_line, indent, max_width, repo_base_url, autolinks, ref_links, footnote_map)
          local lines_after = #self.lines
          if not alert_type_ret then
            self:apply_alert_styling(lines_before, lines_after, qiita_note_type, false)
          end
          lines_shown = lines_shown + (lines_after - lines_before)
          prev_rendered_blank = is_blank
          prev_was_heading = false
          prev_list_marker_type = nil
          goto continue
        end
      end
    end

    if not in_code_block and line:match "^%$%$$" then
      if not in_math_block then
        in_math_block = true
        math_block_start = #self.lines
        math_block_id = src_idx
      else
        in_math_block = false
        math_block_start = nil
        math_block_id = nil
      end
    elseif in_math_block then
      local indented = indent .. line
      self:add_line(indented, { { col = 0, end_col = -1, hl = "MdRenderMath" } })
    elseif line:match "^```" then
      if not in_code_block then
        in_code_block = true
        local info_string = line:match "^```(%S+)" or nil
        code_block_lang = info_string
        -- Split lang:filename (Qiita-style code block filename)
        local code_block_filename = nil
        if info_string and info_string:find(":", 1, true) then
          local lang_part, file_part = info_string:match "^([^:]*):(.+)$"
          if file_part then
            code_block_filename = file_part
            code_block_lang = (lang_part ~= "") and lang_part or nil
          end
        end
        -- Render filename header above code block
        if code_block_filename then
          local file_icon, icon_hl = get_file_icon(code_block_filename)
          file_icon = pad_icon(file_icon)
          local icon_start = #indent
          local icon_end = icon_start + #file_icon
          local fname_line = indent .. file_icon .. " " .. code_block_filename
          local hls = {
            { col = icon_end, end_col = #fname_line, hl = "Comment" },
          }
          if icon_hl then
            table.insert(hls, 1, { col = icon_start, end_col = icon_end, hl = icon_hl })
          else
            hls[1].col = icon_start
          end
          self:add_line(fname_line, hls)
          lines_shown = lines_shown + 1
        end
        code_block_start = #self.lines
        code_source_lines = {}
        code_block_id = src_idx
        code_block_has_truncation = false
      else
        -- Mermaid code blocks: render as image if possible
        local mermaid_handled = false
        if code_block_lang and code_block_lang:lower() == "mermaid" and code_source_lines and #code_source_lines > 0 then
          local image = require "md-render.image"
          if image.supports_kitty() and image.has_mmdc() then
            local mermaid_source = table.concat(code_source_lines, "\n")
            -- Remove the code lines that were already added as text
            local lines_to_remove = #self.lines - code_block_start
            for _ = 1, lines_to_remove do
              table.remove(self.lines)
              table.remove(self.highlights)
            end

            -- Only use cached result synchronously; otherwise render async
            local cached = image.get_mermaid_cached(mermaid_source)
            local display_cols, display_rows
            local orig_img_w, orig_img_h
            local img_max_cols = max_width - 2

            if cached then
              orig_img_w, orig_img_h = image.image_dimensions(cached)
              if orig_img_w and orig_img_h then
                display_cols, display_rows = image.calc_display_size(orig_img_w, orig_img_h, img_max_cols, 25)
              end
            end

            if not display_cols then
              display_cols = math.floor(img_max_cols * 0.8)
              display_rows = 15
            end

            local header = indent .. "Mermaid"
            self:add_line(header, {
              { col = 0, end_col = #header, hl = "Comment" },
            })
            local img_start_line = #self.lines
            local img_col = math.max(0, math.floor((max_width - display_cols) / 2))
            if not cached then
              local placeholder_msg = "Rendering mermaid diagram..."
              local placeholder_row = math.floor(display_rows / 2)
              for r = 1, display_rows do
                if r == placeholder_row + 1 then
                  local pad = math.max(0, math.floor((display_cols - vim.api.nvim_strwidth(placeholder_msg)) / 2))
                  local placeholder_line = indent .. string.rep(" ", img_col) .. string.rep(" ", pad) .. placeholder_msg
                  self:add_line(placeholder_line, {
                    { col = 0, end_col = #placeholder_line, hl = "Comment" },
                  })
                else
                  self:add_line(indent)
                end
              end
            else
              for _ = 1, display_rows do
                self:add_line(indent)
              end
            end
            table.insert(self.image_placements, {
              path = cached,
              line = img_start_line,
              col = img_col,
              rows = display_rows,
              cols = display_cols,
              img_w = orig_img_w,
              img_h = orig_img_h,
              mermaid_source = not cached and mermaid_source or nil,
            })
            lines_shown = lines_shown + 1 + display_rows
            mermaid_handled = true
          end
        end

        if not mermaid_handled then
          if code_block_lang and code_block_start < #self.lines then
            local cb_prefix = #indent
            if in_details and details_summary_rendered then
              cb_prefix = cb_prefix + #"│ "
            end
            table.insert(self.code_blocks, {
              language = code_block_lang,
              start_line = code_block_start,
              end_line = #self.lines - 1,
              prefix_len = cb_prefix,
              source_lines = code_source_lines,
            })
          end
          if code_block_has_truncation or expand_state[code_block_id] then
            table.insert(self.expandable_regions, {
              start_line = code_block_start,
              end_line = #self.lines - 1,
              block_id = code_block_id,
              expanded = expand_state[code_block_id] or false,
            })
          end
        end
        in_code_block = false
        code_block_lang = nil
        code_source_lines = nil
        code_block_id = nil
      end
    elseif in_code_block then
      table.insert(code_source_lines, line)
      local indented = indent .. line
      local display_width = vim.api.nvim_strwidth(indented)
      if not expand_state[code_block_id] and display_width > max_width then
        code_block_has_truncation = true
        local target = max_width - vim.api.nvim_strwidth("…")
        local current_width = 0
        local byte_pos = 0
        for char in indented:gmatch "[%z\1-\127\194-\253][\128-\191]*" do
          local char_width = vim.api.nvim_strwidth(char)
          if current_width + char_width > target then
            break
          end
          current_width = current_width + char_width
          byte_pos = byte_pos + #char
        end
        local truncated_line = indented:sub(1, byte_pos) .. "…"
        self:add_line(truncated_line, {
          { col = 0, end_col = byte_pos, hl = "String" },
          { col = byte_pos, end_col = #truncated_line, hl = "Underlined" },
        })
        detect_urls_in_code_line(self, line, #indent, byte_pos)
      else
        self:add_line(indented, { { col = 0, end_col = -1, hl = "String" } })
        detect_urls_in_code_line(self, line, #indent, #indented)
      end
    else
      local handled = false

      -- Handle code blocks inside callouts
      if current_alert_type and line:match "^>" then
        local stripped = line:gsub("^>%s?", "")
        if stripped:match "^```" then
          if not in_callout_code_block then
            in_callout_code_block = true
            local callout_info = stripped:match "^```(%S+)" or nil
            callout_code_lang = callout_info
            -- Split lang:filename (Qiita-style)
            if callout_info and callout_info:find(":", 1, true) then
              local lang_part, file_part = callout_info:match "^([^:]*):(.+)$"
              if file_part then
                callout_code_lang = (lang_part ~= "") and lang_part or nil
                local cb_file_icon, cb_icon_hl = get_file_icon(file_part)
                cb_file_icon = pad_icon(cb_file_icon)
                local cb_icon_start = #indent + #"│ "
                local cb_icon_end = cb_icon_start + #cb_file_icon
                local fname_line = indent .. "│ " .. cb_file_icon .. " " .. file_part
                local cb_hls = {
                  { col = #indent, end_col = cb_icon_start, hl = "FloatBorder" },
                  { col = cb_icon_end, end_col = #fname_line, hl = "Comment" },
                }
                if cb_icon_hl then
                  table.insert(cb_hls, 2, { col = cb_icon_start, end_col = cb_icon_end, hl = cb_icon_hl })
                else
                  cb_hls[2].col = cb_icon_start
                end
                self:add_line(fname_line, cb_hls)
                self:apply_alert_styling(lines_before, #self.lines, current_alert_type, false)
                lines_shown = lines_shown + 1
              end
            end
            callout_code_prefix = indent .. "│ "
            callout_code_start = #self.lines
            callout_code_source_lines = {}
            callout_code_block_id = src_idx
            callout_code_has_truncation = false
          else
            if callout_code_lang and callout_code_start < #self.lines then
              table.insert(self.code_blocks, {
                language = callout_code_lang,
                start_line = callout_code_start,
                end_line = #self.lines - 1,
                prefix_len = #callout_code_prefix,
                source_lines = callout_code_source_lines,
              })
            end
            if callout_code_has_truncation or expand_state[callout_code_block_id] then
              table.insert(self.expandable_regions, {
                start_line = callout_code_start,
                end_line = #self.lines - 1,
                block_id = callout_code_block_id,
                expanded = expand_state[callout_code_block_id] or false,
              })
            end
            in_callout_code_block = false
            callout_code_lang = nil
            callout_code_source_lines = nil
            callout_code_block_id = nil
          end
          handled = true
        elseif in_callout_code_block then
          table.insert(callout_code_source_lines, stripped)
          local code_line = callout_code_prefix .. stripped
          local display_width = vim.api.nvim_strwidth(code_line)
          if not expand_state[callout_code_block_id] and display_width > max_width then
            callout_code_has_truncation = true
            local target = max_width - vim.api.nvim_strwidth("…")
            local current_width = 0
            local byte_pos = 0
            for char in code_line:gmatch "[%z\1-\127\194-\253][\128-\191]*" do
              local char_width = vim.api.nvim_strwidth(char)
              if current_width + char_width > target then
                break
              end
              current_width = current_width + char_width
              byte_pos = byte_pos + #char
            end
            local truncated_code = code_line:sub(1, byte_pos) .. "…"
            self:add_line(truncated_code, {
              { col = #indent, end_col = #indent + #"│ ", hl = "FloatBorder" },
              { col = #callout_code_prefix, end_col = byte_pos, hl = "String" },
              { col = byte_pos, end_col = #truncated_code, hl = "Underlined" },
            })
            detect_urls_in_code_line(self, stripped, #callout_code_prefix, byte_pos)
          else
            self:add_line(code_line, {
              { col = #indent, end_col = #indent + #"│ ", hl = "FloatBorder" },
              { col = #callout_code_prefix, end_col = -1, hl = "String" },
            })
            detect_urls_in_code_line(self, stripped, #callout_code_prefix, #code_line)
          end
          self:apply_alert_styling(lines_before, #self.lines, current_alert_type, false)
          handled = true
        end
      end

      if not handled then
        -- Reset callout code block state if we leave the callout
        if in_callout_code_block and not (line:match "^>") then
          in_callout_code_block = false
          callout_code_lang = nil
        end

        -- Detect image lines: ![alt](path), <img src="path">, ![[image]]
        local img_path, img_alt
        if not current_alert_type then
          -- Markdown image: ![alt](path) (standalone on line)
          img_alt, img_path = line:match "^%s*!%[([^%]]-)%]%(([^)]-)%)%s*$"
          -- Also match heading lines that are just an image: # ![alt](path)
          if not img_path then
            img_alt, img_path = line:match "^#+%s+!%[([^%]]-)%]%(([^)]-)%)%s*$"
          end
          -- Linked image: [![alt](img-path)](link-url) (standalone on line)
          if not img_path then
            img_alt, img_path = line:match "^%s*%[!%[(.-)%]%((.-)%)%]%(.-%)%s*$"
          end
          -- HTML img: <img src="path" alt="alt"> as sole content on line
          -- Also matches inside headings: # <img ...> or ## <img ...>
          if not img_path then
            local img_tag = line:match "^%s*(<img%s[^>]*>)%s*$"
              or line:match "^#+%s+(<img%s[^>]*>)%s*$"
            if img_tag then
              img_path = img_tag:match 'src="([^"]*)"' or img_tag:match "src='([^']*)'"
              img_alt = img_tag:match 'alt="([^"]*)"' or img_tag:match "alt='([^']*)'"
            end
          end
          -- HTML video: <video src="url">...</video> or <video><source src="url">...</video>
          if not img_path then
            local video_tag = line:match "^%s*(<video[%s>].-</video>)%s*$"
            if video_tag then
              img_path = video_tag:match 'src="([^"]*)"' or video_tag:match "src='([^']*)'"
              -- If no src on <video>, check for <source src="...">
              if not img_path then
                img_path = video_tag:match '<source[^>]*src="([^"]*)"'
                  or video_tag:match "<source[^>]*src='([^']*)'>"
              end
              if img_path then
                img_alt = img_path:match "([^/]+)$" or img_path
              end
            end
          end
          -- Obsidian embed: ![[file]] or ![[file|caption]]
          if not img_path then
            local embed = line:match "^%s*!%[%[(.-)%]%]%s*$"
            if embed then
              local target = embed:match "^([^|#]+)" or embed
              local ext = target:match "%.(%w+)$"
              local img_exts = { png = true, jpg = true, jpeg = true, gif = true, webp = true, bmp = true, svg = true }
              local vid_exts = { mp4 = true, webm = true, mov = true, avi = true, mkv = true, m4v = true }
              if ext and (img_exts[ext:lower()] or vid_exts[ext:lower()]) then
                img_path = target
                local caption = embed:match "|(.+)$"
                img_alt = caption or target:match "([^/]+)$"
              end
            end
          end
        end

        -- Collect images: single image or multiple images on one line
        local img_entries = {}
        if img_path and img_path ~= "" then
          table.insert(img_entries, { alt = img_alt, path = img_path })
        elseif not current_alert_type then
          -- Multiple images on one line: ![alt](url) ![alt](url) ...
          -- Also supports linked images: [![alt](img)](url) mixed in
          local remainder = line:gsub("^%s+", ""):gsub("%s+$", "")
          if remainder:match "!%[" then
            local tmp = remainder
            -- Strip linked images [![alt](img)](url)
            tmp = tmp:gsub("%[!%[.-%]%(.-%)]%(.-%)", "")
            -- Strip plain images ![alt](url)
            tmp = tmp:gsub("!%[.-%]%(.-%)", "")
            -- If only whitespace remains, the line is composed entirely of images
            if tmp:match "^%s*$" then
              for linked_alt, linked_path in remainder:gmatch "%[!%[(.-)%]%((.-)%)%]%(.-%)%s*" do
                table.insert(img_entries, { alt = linked_alt, path = linked_path })
              end
              for plain_alt, plain_path in remainder:gmatch "!%[(.-)%]%((.-)%)" do
                -- Skip images already captured as part of linked images
                local is_linked = false
                for _, entry in ipairs(img_entries) do
                  if entry.path == plain_path then
                    is_linked = true
                    break
                  end
                end
                if not is_linked then
                  table.insert(img_entries, { alt = plain_alt, path = plain_path })
                end
              end
            end
          end
        end

        for _, img_entry in ipairs(img_entries) do
          local image = require "md-render.image"

          -- Skip badge/shield URLs entirely — they are too small to render
          -- as block images and SVG badges cannot be displayed via Kitty protocol.
          if image.is_url(img_entry.path) and image.is_badge_url(img_entry.path) then
            goto continue_img
          end

          local is_video = image.is_video_file(img_entry.path)

          local resolved, src_url, display_cols, display_rows, is_animated
          local orig_img_w, orig_img_h

          if is_video then
            -- Video files: skip image_dimensions validation
            src_url = image.is_url(img_entry.path) and img_entry.path or nil
            if src_url then
              resolved = image.get_video_cached(src_url)
            else
              local video_path = vim.fn.expand(img_entry.path)
              if video_path:sub(1, 1) ~= "/" and buf_dir then
                video_path = buf_dir .. "/" .. video_path
              end
              if vim.fn.filereadable(video_path) == 1 then
                resolved = video_path
              end
              -- Fallback: try Obsidian vault resolution for local video files
              if not resolved and buf_dir then
                local obsidian = require "md-render.obsidian"
                resolved = obsidian.resolve(img_entry.path, buf_dir)
              end
            end
            is_animated = true
            local img_max_cols = max_width - 2
            if resolved then
              orig_img_w, orig_img_h = image.video_dimensions(resolved)
              if orig_img_w and orig_img_h then
                display_cols, display_rows = image.calc_display_size(orig_img_w, orig_img_h, img_max_cols, 25)
              end
            end
            if not display_cols then
              -- Video not yet cached or ffprobe unavailable: use placeholder size
              display_cols = math.floor(img_max_cols * 0.8)
              display_rows = 15
            end
          else
            resolved = image.resolve(img_entry.path, buf_dir)
            src_url = image.is_url(img_entry.path) and img_entry.path or nil
            local img_max_cols = max_width - 2
            if resolved then
              orig_img_w, orig_img_h = image.image_dimensions(resolved)
              if orig_img_w and orig_img_h then
                display_cols, display_rows = image.calc_display_size(orig_img_w, orig_img_h, img_max_cols, 25)
                is_animated = image.is_animated_gif(resolved)
              elseif image.is_video_content(resolved) then
                -- URL without video extension resolved to a video file
                is_video = true
                is_animated = true
                orig_img_w, orig_img_h = image.video_dimensions(resolved)
                if orig_img_w and orig_img_h then
                  display_cols, display_rows = image.calc_display_size(orig_img_w, orig_img_h, img_max_cols, 25)
                end
              end
            end
            if not display_cols then
              if src_url or is_video then
                display_cols = math.floor(img_max_cols * 0.8)
                display_rows = 15
              end
            end
          end

          local display_name = (img_entry.alt and img_entry.alt ~= "") and img_entry.alt or (img_entry.path:match "([^/]+)$" or img_entry.path)
          if image.supports_kitty() then
            if display_cols and display_rows then
              local raw_icon, icon_hl = icons.get_image_icon(img_entry.path)
              local img_icon = pad_icon(raw_icon)
              local header_lines_added = self:_emit_image_header(indent, img_icon, icon_hl, display_name, max_width, "Comment")
              local img_start_line = #self.lines
              -- Center the image horizontally
              local img_col = math.max(0, math.floor((max_width - display_cols) / 2))
              -- Show placeholder with background highlight while the image is loading.
              -- The image overlay (Kitty graphics) will cover this once loaded.
              local indent_width = vim.api.nvim_strwidth(indent)
              local placeholder_msg
              if is_video then
                placeholder_msg = "Loading video..."
              elseif is_animated then
                placeholder_msg = "Loading animation..."
              else
                placeholder_msg = "Loading image..."
              end
              local msg_width = vim.api.nvim_strwidth(placeholder_msg)
              local mid_row = math.floor(display_rows / 2) + 1
              for r = 1, display_rows do
                local spaces_to_img = math.max(0, img_col - indent_width)
                if r == mid_row and msg_width <= display_cols then
                  -- Center a short message within the image area
                  local pad = math.floor((display_cols - msg_width) / 2)
                  local right_pad = display_cols - pad - msg_width
                  local placeholder_line = indent .. string.rep(" ", spaces_to_img)
                      .. string.rep(" ", pad) .. placeholder_msg .. string.rep(" ", right_pad)
                  local hl_start = #indent + spaces_to_img
                  self:add_line(placeholder_line, {
                    { col = hl_start, end_col = #placeholder_line, hl = "MdRenderImagePlaceholder" },
                  })
                else
                  local fill = indent .. string.rep(" ", spaces_to_img) .. string.rep(" ", display_cols)
                  local hl_start = #indent + spaces_to_img
                  self:add_line(fill, {
                    { col = hl_start, end_col = #fill, hl = "MdRenderImagePlaceholder" },
                  })
                end
              end
              table.insert(self.image_placements, {
                path = resolved,
                line = img_start_line,
                col = img_col,
                rows = display_rows,
                cols = display_cols,
                img_w = orig_img_w,
                img_h = orig_img_h,
                animated = is_animated,
                src_url = src_url,
                video = is_video,
              })
              lines_shown = lines_shown + header_lines_added + display_rows
              handled = true
            end
          end

          if not handled then
            -- Fallback: text-only display
            local raw_icon, icon_hl = icons.get_image_icon(img_entry.path)
            local img_icon = pad_icon(raw_icon)
            local fb_lines = self:_emit_image_header(indent, img_icon, icon_hl, display_name, max_width, "Underlined")
            lines_shown = lines_shown + fb_lines
            handled = true
          end
          ::continue_img::
        end

        -- Skip blank blockquote lines at callout boundaries (after header, before end)
        if not handled and current_alert_type and line:match "^>%s*$" then
          local should_skip = prev_was_heading
          if not should_skip then
            local found_next = false
            for k = src_idx + 1, #lines do
              local kl = lines[k]
              if not kl:match "^%s*$" then
                should_skip = not kl:match "^>"
                found_next = true
                break
              end
            end
            if not found_next then
              should_skip = true -- end of document = callout ends
            end
          end
          if should_skip then
            handled = true
          end
        end

        if not handled then
          local alert_type, fold_mod = self:add_markdown_line(line, indent, max_width, repo_base_url, autolinks, ref_links, footnote_map)
          local lines_after = #self.lines
          if alert_type then
            current_alert_type = alert_type
            is_heading = true -- suppress blank line after header (like heading)

            if fold_mod then
              local is_collapsed
              if fold_state[src_idx] ~= nil then
                is_collapsed = fold_state[src_idx]
              else
                is_collapsed = (fold_mod == "-")
              end
              self:add_fold_indicator(lines_before, is_collapsed)
              table.insert(self.callout_folds, {
                header_line = lines_before,
                source_line = src_idx,
                collapsed = is_collapsed,
              })
              if is_collapsed then
                skip_callout_body = true
              end
            end

            self:apply_alert_styling(lines_before, #self.lines, current_alert_type, true)
          elseif current_alert_type and line:match "^>" then
            self:apply_alert_styling(lines_before, lines_after, current_alert_type, false)
          else
            current_alert_type = nil
          end
        end
      end
    end

    -- Apply │ prefix to lines rendered within <details> body
    if in_details and details_summary_rendered and not skip_details_body then
      local lines_after_render = #self.lines
      if lines_after_render > lines_before then
        apply_details_body_prefix(lines_before, lines_after_render)
      end
    end

    local lines_added = #self.lines - lines_before
    lines_shown = lines_shown + lines_added

    -- Only update rendered-state tracking when lines were actually added;
    -- code fence open/close inside callout code blocks produce no output
    -- and must not reset prev_rendered_blank.
    if lines_added > 0 then
      prev_was_heading = is_heading
      prev_rendered_blank = is_blank
      if not is_blank then
        prev_list_marker_type = markdown.list_marker_type(line)
      end
    end

    if lines_shown >= max_lines then
      self:add_line(indent .. "... (truncated)", { { col = 0, end_col = -1, hl = "Comment" } })
      truncated = true
      break
    end

    ::continue::
  end

  -- Flush any remaining table lines at end of document
  if not truncated then
    flush_table()
    if lines_shown >= max_lines then
      self:add_line(indent .. "... (truncated)", { { col = 0, end_col = -1, hl = "Comment" } })
    end
  end

  -- Render footnote section at end of document
  if not truncated and #footnote_defs > 0 then
    -- Separator
    self:add_line(indent)
    local rule = indent .. string.rep("─", max_width)
    self:add_line(rule, { { col = 0, end_col = #rule, hl = "FloatBorder" } })

    for _, def in ipairs(footnote_defs) do
      local num = footnote_map[def.label]
      local prefix = indent .. to_superscript(num) .. " "
      local prefix_display_width = vim.api.nvim_strwidth(prefix)
      local rendered_text, md_highlights, md_links =
        markdown.render(def.text, repo_base_url, autolinks, ref_links, footnote_map)

      local full_text = prefix .. rendered_text
      local def_first_line = #self.lines -- 0-indexed line where this def starts
      if vim.api.nvim_strwidth(full_text) > max_width then
        -- Wrap: use prefix on first line, spaces on continuation lines
        local content_max_width = max_width - prefix_display_width
        local wrapped_lines, line_starts = wrap_words(rendered_text, content_max_width)
        local continuation = string.rep(" ", prefix_display_width)

        -- Distribute highlights/links across wrapped lines (content_offset=0, no quote/list)
        local per_line_hls = distribute_highlights(md_highlights, wrapped_lines, line_starts, "", "", 0, 0, 0)
        local base_line = #self.lines
        local link_entries = distribute_links(md_links, wrapped_lines, line_starts, "", "", 0, base_line, 0, 0)

        for idx, wline in ipairs(wrapped_lines) do
          local line_prefix = idx == 1 and prefix or (indent .. continuation:sub(#indent + 1))
          local actual_prefix = idx == 1 and prefix or continuation
          local line_hls = {}
          -- Shift highlights by prefix length
          for _, hl in ipairs(per_line_hls[idx]) do
            table.insert(line_hls, {
              col = hl.col + #actual_prefix,
              end_col = hl.end_col + #actual_prefix,
              hl = hl.hl,
            })
          end
          if idx == 1 then
            table.insert(line_hls, { col = #indent, end_col = #prefix, hl = "Special" })
          end
          table.insert(line_hls, { col = 0, end_col = -1, hl = "Comment" })
          self:add_line(line_prefix .. wline, line_hls)
        end

        -- Shift link entries by prefix length
        for _, entry in ipairs(link_entries) do
          local line_idx = entry.line - base_line
          local actual_prefix = line_idx == 0 and prefix or continuation
          entry.col_start = entry.col_start + #actual_prefix
          entry.col_end = entry.col_end + #actual_prefix
          table.insert(self.link_metadata, entry)
        end
      else
        -- No wrapping needed
        local prefix_len = #prefix
        for _, hl in ipairs(md_highlights) do
          hl.col = hl.col + prefix_len
          hl.end_col = hl.end_col + prefix_len
        end
        for _, link in ipairs(md_links) do
          link.col_start = link.col_start + prefix_len
          link.col_end = link.col_end + prefix_len
        end

        local line_hls = {}
        table.insert(line_hls, { col = #indent, end_col = #prefix, hl = "Special" })
        for _, hl in ipairs(md_highlights) do
          table.insert(line_hls, hl)
        end
        table.insert(line_hls, { col = 0, end_col = -1, hl = "Comment" })

        self:add_line(full_text, line_hls)

        local base_line = #self.lines - 1
        for _, link in ipairs(md_links) do
          table.insert(self.link_metadata, {
            line = base_line,
            col_start = link.col_start,
            col_end = link.col_end,
            url = link.url,
          })
        end
      end

      -- Register footnote definition anchor and back-link on the superscript number
      self.footnote_anchors["footnote-def-" .. def.label] = def_first_line
      table.insert(self.link_metadata, {
        line = def_first_line,
        col_start = #indent,
        col_end = #prefix - 1, -- superscript number (exclude trailing space)
        url = "#footnote-ref-" .. def.label,
      })
    end
  end
end

---@class MdRender.RenderDocumentOpts
---@field max_width? integer Maximum display width (default: 80)
---@field indent? string Indentation prefix (default: "  ")
---@field max_lines? integer Maximum number of rendered lines (default: unlimited)
---@field repo_base_url? string Repository base URL for issue/PR references
---@field autolinks? MdRender.Autolink[] Autolink definitions
---@field fold_state? table<integer, boolean> Callout fold state by source line
---@field expand_state? table<integer, boolean> Expandable region state by block id
---@field source_line_offset? integer Offset added to src_idx for source_line_map (default: 0)
---@field buf_dir? string Directory of the source buffer for resolving relative paths (default: vim.fn.expand("%:p:h"))

local M = {}
M.ContentBuilder = ContentBuilder
return M
