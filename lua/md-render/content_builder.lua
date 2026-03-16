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

---@class MdRender.Content
---@field lines string[]
---@field highlights MdRender.LineHighlight[]
---@field link_metadata MdRender.LinkMetadata[]
---@field code_blocks MdRender.CodeBlock[]
---@field callout_folds MdRender.CalloutFold[]
---@field expandable_regions MdRender.ExpandableRegion[]
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
  }, { __index = ContentBuilder })
end

---@param text string
---@param hl_groups? MdRender.Highlight.Group[]
function ContentBuilder:add_line(text, hl_groups)
  table.insert(self.lines, text)
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
    local ms, me = raw_line:find("https?://[^%s%)<>]+", pos)
    if not ms then break end
    local url = raw_line:sub(ms, me):gsub("[.,;:!?*~]+$", "")
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

--- Characters that must not appear at the start of a line (JIS X 4051 行頭禁則文字).
---@type table<string, true>
local NO_BREAK_START = {}
for _, ch in ipairs {
  -- Cl.02 終わり括弧類
  "）", "〕", "］", "｝", "〉", "》", "」", "』", "】", "｠", "〙", "〗", "»",
  -- Cl.03 ハイフン類
  "‐", "〜",
  -- Cl.04 区切り約物
  "！", "？", "‼", "⁇", "⁈", "⁉",
  -- Cl.05 中点類
  "・", "：", "；",
  -- Cl.06 句点類
  "。", "．",
  -- Cl.07 読点類
  "、", "，",
  -- Cl.08 繰返し記号
  "ゝ", "ゞ", "ヽ", "ヾ", "々", "〻",
  -- Cl.09 長音記号
  "ー",
  -- Cl.10 小書きの仮名
  "ぁ", "ぃ", "ぅ", "ぇ", "ぉ", "っ", "ゃ", "ゅ", "ょ", "ゎ", "ゕ", "ゖ",
  "ァ", "ィ", "ゥ", "ェ", "ォ", "ッ", "ャ", "ュ", "ョ", "ヮ", "ヵ", "ヶ",
  "ㇰ", "ㇱ", "ㇲ", "ㇳ", "ㇴ", "ㇵ", "ㇶ", "ㇷ", "ㇸ", "ㇹ", "ㇺ", "ㇻ", "ㇼ", "ㇽ", "ㇾ", "ㇿ",
  -- 半角カタカナ
  "｡", "､", "｣", "ｧ", "ｨ", "ｩ", "ｪ", "ｫ", "ｯ", "ｬ", "ｭ", "ｮ", "ｰ",
} do
  NO_BREAK_START[ch] = true
end

--- Characters that must not appear at the end of a line (JIS X 4051 行末禁則文字).
---@type table<string, true>
local NO_BREAK_END = {}
for _, ch in ipairs {
  -- Cl.01 始め括弧類
  "（", "〔", "［", "｛", "〈", "《", "「", "『", "【", "｟", "〘", "〖", "«",
  -- 半角カタカナ
  "｢",
} do
  NO_BREAK_END[ch] = true
end

--- Split text into segments for wrapping, handling CJK/fullwidth characters individually.
--- Each CJK/fullwidth character becomes its own segment so it can be wrapped independently.
---@param text string
---@return {text: string, byte_pos: integer, has_leading_space: boolean}[]
local function split_segments(text)
  local segments = {}
  local current_word = ""
  local current_word_start = 0
  local has_leading_space = false
  local byte_pos = 0

  for char in text:gmatch "[%z\1-\127\194-\253][\128-\191]*" do
    if char:match "%s" then
      -- Flush accumulated ASCII word
      if current_word ~= "" then
        table.insert(segments, { text = current_word, byte_pos = current_word_start, has_leading_space = has_leading_space })
        current_word = ""
        has_leading_space = false
      end
      has_leading_space = true
    elseif vim.fn.strdisplaywidth(char) >= 2 then
      -- CJK/fullwidth character: flush word first, then emit as individual segment
      if current_word ~= "" then
        table.insert(segments, { text = current_word, byte_pos = current_word_start, has_leading_space = has_leading_space })
        current_word = ""
        has_leading_space = false
      end
      table.insert(segments, { text = char, byte_pos = byte_pos, has_leading_space = has_leading_space })
      has_leading_space = false
    else
      -- ASCII/narrow character: accumulate into word
      if current_word == "" then
        current_word_start = byte_pos
      end
      current_word = current_word .. char
    end
    byte_pos = byte_pos + #char
  end

  -- Flush remaining word
  if current_word ~= "" then
    table.insert(segments, { text = current_word, byte_pos = current_word_start, has_leading_space = has_leading_space })
  end

  return segments
end

--- Wrap text into lines at word boundaries, tracking original positions.
--- Uses segment-based splitting to handle CJK/fullwidth characters correctly.
--- Applies kinsoku (JIS X 4051) rules using 追い出し (push-out) strategy:
--- characters are pushed to the next line to keep lines within max_width.
---@param text string The text to wrap
---@param max_width integer Maximum display width per line
---@return string[] wrapped_lines
---@return integer[] line_starts 0-indexed start position of each line in the original text
local function wrap_words(text, max_width)
  local wrapped_lines = {}
  local line_starts = {}
  local current = ""
  local current_width = 0
  local current_start = 0

  -- For kinsoku 追い出し: track state before the last segment was appended
  local prev_current = ""
  local prev_width = 0
  local last_seg_text = ""
  local last_seg_pos = 0

  local segments = split_segments(text)

  for i, seg in ipairs(segments) do
    local seg_width = vim.fn.strdisplaywidth(seg.text)
    local space_width = (seg.has_leading_space and current ~= "") and 1 or 0

    if current_width + space_width + seg_width > max_width and current ~= "" then
      -- Kinsoku 追い出し: if this segment is a no-break-start char,
      -- push the last segment of the current line to the next line too
      if NO_BREAK_START[seg.text] and prev_current ~= "" then
        table.insert(wrapped_lines, prev_current)
        table.insert(line_starts, current_start)
        current = last_seg_text .. seg.text
        current_start = last_seg_pos
        current_width = vim.fn.strdisplaywidth(current)
      else
        table.insert(wrapped_lines, current)
        table.insert(line_starts, current_start)
        current = seg.text
        current_start = seg.byte_pos
        current_width = seg_width
      end
      prev_current = ""
      prev_width = 0
      last_seg_text = ""
      last_seg_pos = 0
    else
      -- Kinsoku: if this is a no-break-end char at the end of a full line,
      -- break before it so it doesn't sit at line end
      if NO_BREAK_END[seg.text] and current ~= "" then
        local next_seg = segments[i + 1]
        local next_width = next_seg and vim.fn.strdisplaywidth(next_seg.text) or 0
        if current_width + space_width + seg_width + next_width > max_width then
          table.insert(wrapped_lines, current)
          table.insert(line_starts, current_start)
          current = seg.text
          current_start = seg.byte_pos
          current_width = seg_width
          prev_current = ""
          prev_width = 0
          last_seg_text = ""
          last_seg_pos = 0
          goto continue
        end
      end

      -- Save state before appending (for potential 追い出し on the next segment)
      prev_current = current
      prev_width = current_width
      last_seg_text = seg.text
      last_seg_pos = seg.byte_pos

      if current ~= "" then
        if space_width > 0 then
          current = current .. " " .. seg.text
          current_width = current_width + 1 + seg_width
        else
          current = current .. seg.text
          current_width = current_width + seg_width
        end
      else
        current = seg.text
        current_start = seg.byte_pos
        current_width = seg_width
      end
    end
    ::continue::
  end

  if current ~= "" then
    table.insert(wrapped_lines, current)
    table.insert(line_starts, current_start)
  end

  return wrapped_lines, line_starts
end

--- Distribute markdown highlights across wrapped lines
---@param md_highlights MdRender.Markdown.Highlight[]
---@param wrapped_lines string[] The wrapped line texts
---@param line_starts integer[] Start positions of each wrapped line
---@param indent string Indentation prefix
---@param quote_prefix string Blockquote prefix (may be empty)
---@param content_offset integer Byte offset of content within the original rendered text
---@param list_prefix_len? integer Byte length of list marker prefix (0 if none)
---@return MdRender.Highlight.Group[][] per_line_highlights Array of highlight lists, one per wrapped line
local function distribute_highlights(md_highlights, wrapped_lines, line_starts, indent, quote_prefix, content_offset, list_prefix_len)
  list_prefix_len = list_prefix_len or 0
  local per_line = {}
  for idx, wline in ipairs(wrapped_lines) do
    local line_start_pos = line_starts[idx]
    local line_prefix = (quote_prefix ~= "" and (indent .. quote_prefix) or indent)
        .. string.rep(" ", list_prefix_len)
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

      -- "Special" highlights (list markers) that end at or before the content start
      -- should only appear on line 1 with their original positions
      if hl.end_col <= content_offset and hl.hl == "Special" then
        if idx == 1 then
          table.insert(line_hls, {
            col = #indent + #quote_prefix + hl.col,
            end_col = #indent + #quote_prefix + hl.end_col,
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
---@return MdRender.LinkMetadata[] link_entries
local function distribute_links(md_links, wrapped_lines, line_starts, indent, quote_prefix, content_offset, base_line, list_prefix_len)
  list_prefix_len = list_prefix_len or 0
  local entries = {}
  for idx, wline in ipairs(wrapped_lines) do
    local line_start_pos = line_starts[idx]
    local line_prefix = (quote_prefix ~= "" and (indent .. quote_prefix) or indent)
        .. string.rep(" ", list_prefix_len)

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
  if list_marker and list_marker ~= "" then
    wrap_text = wrap_text:sub(#list_marker + 1)
    content_offset = content_offset + #list_marker
    list_prefix_len = #list_marker
  end

  local content_max_width = max_width
  if quote_prefix ~= "" then
    content_max_width = max_width - vim.fn.strdisplaywidth(quote_prefix)
  end
  if list_prefix_len > 0 then
    content_max_width = content_max_width - vim.fn.strdisplaywidth(list_marker)
  end

  local wrapped_lines, line_starts = wrap_words(wrap_text, content_max_width)
  local per_line_hls = distribute_highlights(md_highlights, wrapped_lines, line_starts, indent, quote_prefix, content_offset, list_prefix_len)
  local base_line = #self.lines
  local link_entries = distribute_links(md_links, wrapped_lines, line_starts, indent, quote_prefix, content_offset, base_line, list_prefix_len)

  local list_prefix = list_marker or ""
  local list_continuation = string.rep(" ", list_prefix_len)

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
function ContentBuilder:add_table(table_lines, indent, max_width, repo_base_url, autolinks)
  local markdown_table = require "md-render.markdown_table"
  local parsed = markdown_table.parse(table_lines, repo_base_url, autolinks)
  if not parsed then
    -- Fallback: render each line as markdown
    for _, line in ipairs(table_lines) do
      self:add_markdown_line(line, indent, max_width, repo_base_url, autolinks)
    end
    return
  end
  local lines, per_line_hls, per_line_links = markdown_table.render(parsed, indent, max_width)
  local base_line = #self.lines
  for i, line in ipairs(lines) do
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
function ContentBuilder:add_markdown_line(text, indent, max_width, repo_base_url, autolinks, ref_links)
  local markdown = require "md-render.markdown"
  local rendered_text, md_highlights, md_links, special_type, list_marker, alert_type, fold_mod =
    markdown.render(text, repo_base_url, autolinks, ref_links)

  local quote_prefix = ""
  if special_type == "blockquote" then
    local bar_space = "│ " -- U+2502 + space (4 bytes)
    local pos = 1
    while rendered_text:sub(pos, pos + #bar_space - 1) == bar_space do
      pos = pos + #bar_space
    end
    quote_prefix = rendered_text:sub(1, pos - 1)
  end

  if vim.fn.strdisplaywidth(rendered_text) > max_width then
    self:add_wrapped_markdown(rendered_text, md_highlights, md_links, indent, max_width, quote_prefix, list_marker)
  else
    self:add_simple_markdown(rendered_text, md_highlights, md_links, indent)
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

--- Append a fold indicator (›/∨) to the end of a callout header line
---@param self MdRender.ContentBuilder
---@param line_idx integer 0-indexed rendered line
---@param is_collapsed boolean
function ContentBuilder:add_fold_indicator(line_idx, is_collapsed)
  local indicator = is_collapsed and " 󰅂" or " 󰅀"
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
function ContentBuilder:render_document(lines, opts)
  opts = opts or {}
  local markdown = require "md-render.markdown"

  lines = markdown.renumber_ordered_lists(lines)
  local ref_links = markdown.parse_reference_links(lines)

  local max_width = opts.max_width or 80
  local indent = opts.indent or "  "
  local max_lines = opts.max_lines or math.huge
  local repo_base_url = opts.repo_base_url
  local autolinks = opts.autolinks
  local fold_state = opts.fold_state or {}
  local expand_state = opts.expand_state or {}

  local in_code_block = false
  local code_block_lang = nil
  local code_block_start = nil
  local code_source_lines = nil
  local code_block_id = nil
  local code_block_has_truncation = false
  local prev_was_heading = false
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
  local in_comment_block = false
  local skip_next_line = false

  --- Flush accumulated table lines
  local function flush_table()
    if #table_buf > 0 then
      local lines_before_tbl = #self.lines
      local tbl_expanded = table_buf_start_idx and expand_state[table_buf_start_idx]
      local effective_max = tbl_expanded and math.huge or max_width
      self:add_table(table_buf, indent, effective_max, repo_base_url, autolinks)
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

  for src_idx, line in ipairs(lines) do
    -- Skip setext heading underline
    if skip_next_line then
      skip_next_line = false
      goto continue
    end

    -- Skip reference link definition lines
    if not in_code_block and markdown.is_reference_link_def(line) then
      goto continue
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

    -- Accumulate table lines
    if is_table_line then
      if #table_buf == 0 then
        table_buf_start_idx = src_idx
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
    end

    -- Skip blank lines adjacent to headings (outside code blocks)
    if not in_code_block and is_blank then
      local skip = prev_was_heading
      if not skip then
        for k = src_idx + 1, #lines do
          if not lines[k]:match "^%s*$" then
            -- Check ATX heading or setext heading (text followed by === or ---)
            skip = lines[k]:match "^#+%s+" ~= nil
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

    local lines_before = #self.lines

    if line:match "^```" then
      if not in_code_block then
        in_code_block = true
        code_block_lang = line:match "^```(%S+)" or nil
        code_block_start = #self.lines
        code_source_lines = {}
        code_block_id = src_idx
        code_block_has_truncation = false
      else
        if code_block_lang and code_block_start < #self.lines then
          table.insert(self.code_blocks, {
            language = code_block_lang,
            start_line = code_block_start,
            end_line = #self.lines - 1,
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
        in_code_block = false
        code_block_lang = nil
        code_source_lines = nil
        code_block_id = nil
      end
    elseif in_code_block then
      table.insert(code_source_lines, line)
      local indented = indent .. line
      local display_width = vim.fn.strdisplaywidth(indented)
      if not expand_state[code_block_id] and display_width > max_width then
        code_block_has_truncation = true
        local target = max_width - 1
        local current_width = 0
        local byte_pos = 0
        for char in indented:gmatch "[%z\1-\127\194-\253][\128-\191]*" do
          local char_width = vim.fn.strdisplaywidth(char)
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
            callout_code_lang = stripped:match "^```(%S+)" or nil
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
          local display_width = vim.fn.strdisplaywidth(code_line)
          if not expand_state[callout_code_block_id] and display_width > max_width then
            callout_code_has_truncation = true
            local target = max_width - 1
            local current_width = 0
            local byte_pos = 0
            for char in code_line:gmatch "[%z\1-\127\194-\253][\128-\191]*" do
              local char_width = vim.fn.strdisplaywidth(char)
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

        local alert_type, fold_mod = self:add_markdown_line(line, indent, max_width, repo_base_url, autolinks, ref_links)
        local lines_after = #self.lines
        if alert_type then
          current_alert_type = alert_type

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

    local lines_added = #self.lines - lines_before
    lines_shown = lines_shown + lines_added

    prev_was_heading = is_heading

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
end

---@class MdRender.RenderDocumentOpts
---@field max_width? integer Maximum display width (default: 80)
---@field indent? string Indentation prefix (default: "  ")
---@field max_lines? integer Maximum number of rendered lines (default: unlimited)
---@field repo_base_url? string Repository base URL for issue/PR references
---@field autolinks? MdRender.Autolink[] Autolink definitions
---@field fold_state? table<integer, boolean> Callout fold state by source line
---@field expand_state? table<integer, boolean> Expandable region state by block id

local M = {}
M.ContentBuilder = ContentBuilder
return M
