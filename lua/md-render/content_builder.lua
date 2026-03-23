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

---@class MdRender.Content
---@field lines string[]
---@field highlights MdRender.LineHighlight[]
---@field link_metadata MdRender.LinkMetadata[]
---@field code_blocks MdRender.CodeBlock[]
---@field callout_folds MdRender.CalloutFold[]
---@field expandable_regions MdRender.ExpandableRegion[]
---@field image_placements MdRender.ImagePlacement[]
---@field footnote_anchors table<string, integer> anchor name → 0-indexed line number
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
    image_placements = self.image_placements,
    footnote_anchors = self.footnote_anchors,
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
  -- ASCII (half-width) punctuation
  ")", "]", "}", "!", "?", ",", ".", ";", ":",
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
  -- ASCII (half-width) punctuation
  "(", "[", "{",
} do
  NO_BREAK_END[ch] = true
end

local budoux = require "md-render.budoux"
local budoux_ja = require "md-render.budoux_ja"

--- Check if a character is CJK/fullwidth or kinsoku-relevant punctuation.
local function is_cjk_or_kinsoku(char)
  return vim.fn.strdisplaywidth(char) >= 2 or NO_BREAK_START[char] or NO_BREAK_END[char]
end

--- Extract the first UTF-8 character from a string.
local function first_char(s)
  return s:match "[%z\1-\127\194-\253][\128-\191]*"
end

--- Extract the last UTF-8 character from a string.
local function last_char(s)
  local last
  for c in s:gmatch "[%z\1-\127\194-\253][\128-\191]*" do
    last = c
  end
  return last
end

--- Split text into segments for wrapping.
--- CJK runs are segmented using BudouX for natural word-boundary splitting.
--- ASCII words are accumulated as single segments (split at spaces).
---@param text string
---@return {text: string, byte_pos: integer, has_leading_space: boolean}[]
local function split_segments(text)
  local segments = {}
  local current_word = ""
  local current_word_start = 0
  local has_leading_space = false
  local cjk_run = ""
  local cjk_run_start = 0
  local cjk_leading_space = false
  local byte_pos = 0

  local function flush_ascii()
    if current_word ~= "" then
      table.insert(segments, { text = current_word, byte_pos = current_word_start, has_leading_space = has_leading_space })
      current_word = ""
      has_leading_space = false
    end
  end

  local function flush_cjk()
    if cjk_run == "" then return end
    local chunks = budoux.parse(budoux_ja, cjk_run)
    local chunk_byte = cjk_run_start
    local first = true
    for _, chunk in ipairs(chunks) do
      local sub_chunks = budoux.split_by_script(chunk)
      for _, sub in ipairs(sub_chunks) do
        table.insert(segments, {
          text = sub,
          byte_pos = chunk_byte,
          has_leading_space = first and cjk_leading_space or false,
        })
        chunk_byte = chunk_byte + #sub
        first = false
      end
    end
    cjk_run = ""
    has_leading_space = false
  end

  for char in text:gmatch "[%z\1-\127\194-\253][\128-\191]*" do
    if char:match "%s" then
      flush_ascii()
      flush_cjk()
      has_leading_space = true
    elseif is_cjk_or_kinsoku(char) then
      flush_ascii()
      if cjk_run == "" then
        cjk_run_start = byte_pos
        cjk_leading_space = has_leading_space
        has_leading_space = false
      end
      cjk_run = cjk_run .. char
    else
      -- ASCII/narrow character: accumulate into word
      flush_cjk()
      if current_word == "" then
        current_word_start = byte_pos
      end
      current_word = current_word .. char
    end
    byte_pos = byte_pos + #char
  end

  flush_ascii()
  flush_cjk()

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
      -- Kinsoku 追い出し: if this segment starts with a no-break-start char,
      -- push the last segment of the current line to the next line too
      if NO_BREAK_START[first_char(seg.text)] and prev_current ~= "" then
        table.insert(wrapped_lines, prev_current)
        table.insert(line_starts, current_start)
        local sep = seg.has_leading_space and " " or ""
        current = last_seg_text .. sep .. seg.text
        current_start = last_seg_pos
        current_width = vim.fn.strdisplaywidth(current)
      elseif NO_BREAK_START[first_char(seg.text)] then
        -- Kinsoku 追い込み fallback: keep the char on the current line
        -- even if it exceeds max_width, to avoid it starting a new line
        local sep = (seg.has_leading_space and current ~= "") and " " or ""
        current = current .. sep .. seg.text
        current_width = current_width + #sep + seg_width
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
      -- Kinsoku: if this segment ends with a no-break-end char at the end of a full line,
      -- break before it so it doesn't sit at line end
      if NO_BREAK_END[last_char(seg.text)] and current ~= "" then
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
    list_cont_len = vim.fn.strdisplaywidth(list_marker)
  end

  local content_max_width = max_width
  if quote_prefix ~= "" then
    content_max_width = max_width - vim.fn.strdisplaywidth(quote_prefix)
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
  local lines, per_line_hls, per_line_links, tbl_image_placements =
    markdown_table.render(parsed, indent, max_width)
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
function ContentBuilder:add_markdown_line(text, indent, max_width, repo_base_url, autolinks, ref_links, footnote_map)
  local markdown = require "md-render.markdown"
  local rendered_text, md_highlights, md_links, special_type, list_marker, alert_type, fold_mod =
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
  if vim.fn.strdisplaywidth(rendered_text) > max_width then
    self:add_wrapped_markdown(rendered_text, md_highlights, md_links, indent, max_width, quote_prefix, list_marker)
  else
    self:add_simple_markdown(rendered_text, md_highlights, md_links, indent)
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
  if vim.fn.strdisplaywidth(icon) == 1 then
    return icon .. " "
  end
  return icon
end

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
}

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
  return false
end

--- Join paragraph continuation lines into single lines.
--- In CommonMark, consecutive lines that don't start block-level constructs
--- form a single paragraph. This is needed for inline constructs (like links)
--- that span multiple source lines.
---@param lines string[]
---@return string[]
local function join_paragraph_continuations(lines)
  local result = {}
  local para = {}
  local in_code = false
  local in_html_comment = false

  for _, line in ipairs(lines) do
    -- Track code fences
    if line:match "^```" or line:match "^~~~" then
      in_code = not in_code
    end

    -- Track multi-line HTML comments
    if not in_code then
      if in_html_comment then
        -- Flush paragraph, keep comment lines separate
        if #para > 0 then
          table.insert(result, table.concat(para, " "))
          para = {}
        end
        table.insert(result, line)
        if line:match "%-%->" then
          in_html_comment = false
        end
        goto next_line
      end
      if line:match "^%s*<!%-%-" and not line:match "%-%->%s*$" then
        in_html_comment = true
        if #para > 0 then
          table.insert(result, table.concat(para, " "))
          para = {}
        end
        table.insert(result, line)
        goto next_line
      end
    end

    if in_code or is_block_start(line) then
      -- Flush accumulated paragraph
      if #para > 0 then
        table.insert(result, table.concat(para, " "))
        para = {}
      end
      table.insert(result, line)
    else
      table.insert(para, line)
    end

    ::next_line::
  end

  -- Flush remaining
  if #para > 0 then
    table.insert(result, table.concat(para, " "))
  end

  return result
end

local function preprocess_multiline_html(lines)
  local result = {}
  local accum = nil -- { tag: string, lines: string[], depth: integer }
  local in_code = false

  for _, l in ipairs(lines) do
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
          if not HTML_SKIP_TAGS[lower_tag] and not l:match "/>%s*$" then
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
              }
            else
              table.insert(result, l)
            end
          else
            table.insert(result, l)
          end
        else
          table.insert(result, l)
        end
      else
        table.insert(result, l)
      end
    end
  end

  -- Unclosed accumulation: output lines as-is
  if accum then
    for _, l in ipairs(accum.lines) do
      table.insert(result, l)
    end
  end

  return result
end

function ContentBuilder:render_document(lines, opts)
  opts = opts or {}
  local markdown = require "md-render.markdown"

  lines = preprocess_multiline_html(lines)
  lines = join_paragraph_continuations(lines)
  lines = markdown.renumber_ordered_lists(lines)
  local ref_links = markdown.parse_reference_links(lines)
  local footnote_defs, footnote_map = markdown.parse_footnotes(lines)

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
  local prev_was_hr = false
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
  local skip_details_body = false
  local in_qiita_note = false
  local qiita_note_type = nil

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
          -- Insert the img tag line (will be processed by subsequent iteration)
          table.insert(lines, src_idx + 1, img_tag)
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
          -- Render figcaption centered (captured during figure body processing)
          if figure_caption then
            local caption_text = figure_caption
            local caption_width = vim.api.nvim_strwidth(caption_text)
            local pad = math.max(0, math.floor((max_width - caption_width) / 2) - #indent)
            local byte_start = #indent + pad
            local padded_caption = indent .. string.rep(" ", pad) .. caption_text
            self:add_line(padded_caption, {
              { col = byte_start, end_col = byte_start + #caption_text, hl = "Comment" },
            })
            lines_shown = lines_shown + 1
            figure_caption = nil
          end
          goto continue
        end
        -- Extract <figcaption> content for rendering when </figure> is reached
        local cap = line:match "^%s*<figcaption>(.-)</figcaption>%s*$"
        if cap and cap:match "%S" then
          figure_caption = cap
          goto continue
        end
        -- Other lines inside <figure> (e.g. <img>) fall through to normal processing
      end

      if line:match "^%s*<figure[^>]*>%s*$" then
        in_figure = true
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
      local skip = prev_was_heading or prev_was_hr
      if not skip then
        for k = src_idx + 1, #lines do
          if not lines[k]:match "^%s*$" then
            -- Check ATX heading or setext heading (text followed by === or ---)
            skip = lines[k]:match "^#+%s+" ~= nil
            if not skip then
              skip = is_thematic_break(lines[k])
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
        and line:match "^    " and not line:match "^    [%-*+]%s" and not line:match "^    %d+%.%s"
        and (in_indented_code or not prev_list_marker_type) then
      in_indented_code = true
      local code_content = line:sub(5) -- strip 4-space indent
      local indented_line = indent .. code_content
      local ib_lines_before = #self.lines
      self:add_line(indented_line, { { col = 0, end_col = -1, hl = "String" } })
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
        goto continue
      end

      -- Body lines inside :::note block
      if in_qiita_note then
        -- Render as blockquote-style content with alert styling
        local qn_line = "> " .. line
        local alert_type_ret = self:add_markdown_line(qn_line, indent, max_width, repo_base_url, autolinks, ref_links, footnote_map)
        local lines_after = #self.lines
        if not alert_type_ret then
          self:apply_alert_styling(lines_before, lines_after, qiita_note_type, false)
        end
        lines_shown = lines_shown + (lines_after - lines_before)
        goto continue
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
          local fname_line = indent .. "📄 " .. code_block_filename
          self:add_line(fname_line, {
            { col = 0, end_col = #fname_line, hl = "Comment" },
          })
          lines_shown = lines_shown + 1
        end
        code_block_start = #self.lines
        code_source_lines = {}
        code_block_id = src_idx
        code_block_has_truncation = false
      else
        if code_block_lang and code_block_start < #self.lines then
          local cb_prefix = nil
          if in_details and details_summary_rendered then
            cb_prefix = #indent + #"│ "
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
            local callout_info = stripped:match "^```(%S+)" or nil
            callout_code_lang = callout_info
            -- Split lang:filename (Qiita-style)
            if callout_info and callout_info:find(":", 1, true) then
              local lang_part, file_part = callout_info:match "^([^:]*):(.+)$"
              if file_part then
                callout_code_lang = (lang_part ~= "") and lang_part or nil
                local fname_line = indent .. "│ 📄 " .. file_part
                self:add_line(fname_line, {
                  { col = #indent, end_col = #indent + #"│ ", hl = "FloatBorder" },
                  { col = #indent + #"│ ", end_col = #fname_line, hl = "Comment" },
                })
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

        -- Detect image lines: ![alt](path), <img src="path">, ![[image]]
        local img_path, img_alt
        if not current_alert_type then
          -- Markdown image: ![alt](path) (standalone on line)
          img_alt, img_path = line:match "^%s*!%[(.-)%]%((.-)%)%s*$"
          -- Also match heading lines that are just an image: # ![alt](path)
          if not img_path then
            img_alt, img_path = line:match "^#+%s+!%[(.-)%]%((.-)%)%s*$"
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
          -- Obsidian embed: ![[file]]
          if not img_path then
            local embed = line:match "^%s*!%[%[(.-)%]%]%s*$"
            if embed then
              local ext = embed:match "%.(%w+)$"
              local img_exts = { png = true, jpg = true, jpeg = true, gif = true, webp = true, bmp = true, svg = true }
              if ext and img_exts[ext:lower()] then
                img_path = embed
                img_alt = embed:match "([^/]+)$"
              end
            end
          end
        end

        if img_path and img_path ~= "" then
          local image = require "md-render.image"
          local buf_dir = vim.fn.expand("%:p:h")
          local resolved = image.resolve(img_path, buf_dir)

          local display_name = (img_alt and img_alt ~= "") and img_alt or (img_path:match "([^/]+)$" or img_path)
          if image.supports_kitty() then
            local display_cols, display_rows
            local is_animated = false
            local src_url = image.is_url(img_path) and img_path or nil

            -- Standalone image: use full width and center
            local img_max_cols = max_width - 2

            local orig_img_w, orig_img_h
            if resolved then
              orig_img_w, orig_img_h = image.image_dimensions(resolved)
              if orig_img_w and orig_img_h then
                display_cols, display_rows = image.calc_display_size(orig_img_w, orig_img_h, img_max_cols, 25)
                is_animated = image.is_animated_gif(resolved)
              end
            elseif src_url then
              -- URL not yet cached: use estimated placeholder size
              display_cols = math.floor(img_max_cols * 0.8)
              display_rows = 15
            end

            if display_cols and display_rows then
              local header = indent .. "🖼 " .. display_name
              self:add_line(header, {
                { col = 0, end_col = #header, hl = "Comment" },
              })
              local img_start_line = #self.lines
              -- Center the image horizontally
              local img_col = math.max(0, math.floor((max_width - display_cols) / 2))
              -- Show placeholder while the image is loading
              local placeholder_msg = "Loading image..."
              local placeholder_row = math.floor(display_rows / 2)
              for r = 1, display_rows do
                if r == placeholder_row + 1 then
                  local pad = math.max(0, math.floor((display_cols - vim.fn.strdisplaywidth(placeholder_msg)) / 2))
                  local placeholder_line = indent .. string.rep(" ", img_col) .. string.rep(" ", pad) .. placeholder_msg
                  self:add_line(placeholder_line, {
                    { col = 0, end_col = #placeholder_line, hl = "Comment" },
                  })
                else
                  self:add_line(indent)
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
                src_url = src_url,  -- for async download
              })
              lines_shown = lines_shown + 1 + display_rows
              handled = true
            end
          end

          if not handled then
            -- Fallback: text-only display
            local fallback = indent .. "🖼 " .. display_name
            self:add_line(fallback, {
              { col = 0, end_col = #fallback, hl = "Underlined" },
            })
            lines_shown = lines_shown + 1
            handled = true
          end
        end

        if not handled then
          local alert_type, fold_mod = self:add_markdown_line(line, indent, max_width, repo_base_url, autolinks, ref_links, footnote_map)
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

    prev_was_heading = is_heading
    if not is_blank then
      prev_list_marker_type = markdown.list_marker_type(line)
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
      local prefix_display_width = vim.fn.strdisplaywidth(prefix)
      local rendered_text, md_highlights, md_links =
        markdown.render(def.text, repo_base_url, autolinks, ref_links, footnote_map)

      local full_text = prefix .. rendered_text
      local def_first_line = #self.lines -- 0-indexed line where this def starts
      if vim.fn.strdisplaywidth(full_text) > max_width then
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

local M = {}
M.ContentBuilder = ContentBuilder
return M
