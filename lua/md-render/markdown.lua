---@class MdRender.Autolink
---@field key_prefix string   -- e.g., "HOGE-"
---@field url_template string -- e.g., "https://jira.example.com/browse/HOGE-<num>"
---@field is_alphanumeric? boolean

---@class MdRender.Markdown.Highlight
---@field col integer 0-indexed start column
---@field end_col integer 0-indexed end column
---@field hl string highlight group name

---@class MdRender.Markdown.Link
---@field col_start integer 0-indexed start column
---@field col_end integer 0-indexed end column
---@field url string

---@class MdRender.Markdown.Removal
---@field start integer 0-indexed position in the input text
---@field count integer number of characters removed

---@class MdRender.Markdown
local Markdown = {}

local MAX_URL_DISPLAY_WIDTH = 50

--- ASCII punctuation characters that can be backslash-escaped (CommonMark spec)
local ESCAPABLE_CHARS = [[!"#$%&'()*+,-./:;<=>?@[\]^_`{|}~]]

--- Escape backslash-escaped characters to placeholders before inline processing.
--- Returns the modified text and a list of {pos, char} for later restoration.
---@param text string
---@return string escaped_text
---@return {pos: integer, char: string}[] escapes
local function escape_backslashes(text)
  local escapes = {}
  local result = {}
  local i = 1
  while i <= #text do
    if text:sub(i, i) == "\\" and i < #text then
      local next_ch = text:sub(i + 1, i + 1)
      if ESCAPABLE_CHARS:find(next_ch, 1, true) then
        -- Use a private-use Unicode character as placeholder (U+F0000 + byte value)
        local placeholder = string.char(0xEF, 0x80, 0x80 + next_ch:byte())
        table.insert(escapes, { pos = #table.concat(result), char = next_ch })
        table.insert(result, placeholder)
        i = i + 2
      else
        table.insert(result, "\\")
        i = i + 1
      end
    else
      table.insert(result, text:sub(i, i))
      i = i + 1
    end
  end
  return table.concat(result), escapes
end

--- Restore placeholders back to their original characters, adjusting highlight/link positions.
---@param text string
---@param escapes {pos: integer, char: string}[]
---@param highlights? MdRender.Markdown.Highlight[]
---@param links? MdRender.Markdown.Link[]
---@return string
local function restore_backslashes(text, escapes, highlights, links)
  if #escapes == 0 then return text end
  local result = {}
  local byte_offset = 0  -- cumulative byte shift (3-byte placeholder → 1-byte char = -2 each)
  local offsets = {}      -- {pos_in_output, delta} for position adjustments
  local i = 1
  while i <= #text do
    local b1 = text:byte(i)
    if b1 == 0xEF and i + 2 <= #text and text:byte(i + 1) == 0x80 then
      local b3 = text:byte(i + 2)
      if b3 >= 0x80 then
        local orig_byte = b3 - 0x80
        local out_pos = #table.concat(result)
        table.insert(offsets, { pos = out_pos, delta = 2 })
        table.insert(result, string.char(orig_byte))
        byte_offset = byte_offset + 2
        i = i + 3
      else
        table.insert(result, text:sub(i, i))
        i = i + 1
      end
    else
      table.insert(result, text:sub(i, i))
      i = i + 1
    end
  end

  if byte_offset > 0 and (highlights or links) then
    local function adjust(pos)
      local shift = 0
      for _, o in ipairs(offsets) do
        if pos > o.pos then
          shift = shift + o.delta
        end
      end
      return pos - shift
    end
    if highlights then
      for _, hl in ipairs(highlights) do
        hl.col = adjust(hl.col)
        hl.end_col = adjust(hl.end_col)
      end
    end
    if links then
      for _, link in ipairs(links) do
        link.col_start = adjust(link.col_start)
        link.col_end = adjust(link.col_end)
      end
    end
  end

  return table.concat(result)
end

--- Common HTML named character references
local HTML_ENTITIES = {
  amp = "&", lt = "<", gt = ">", quot = '"', apos = "'",
  nbsp = "\194\160", -- U+00A0
  ndash = "–", mdash = "—", lsquo = "\226\128\152", rsquo = "\226\128\153",
  ldquo = "\226\128\156", rdquo = "\226\128\157", bull = "•",
  hellip = "…", copy = "©", reg = "®", trade = "™",
  laquo = "«", raquo = "»", middot = "·", times = "×", divide = "÷",
  plusmn = "±", micro = "µ", para = "¶", sect = "§", deg = "°",
  frac14 = "¼", frac12 = "½", frac34 = "¾",
  larr = "←", rarr = "→", uarr = "↑", darr = "↓",
  hearts = "♥", diams = "♦", clubs = "♣", spades = "♠",
  checkmark = "✓", cross = "✗",
}

--- Encode a Unicode codepoint as a UTF-8 string
---@param cp integer Unicode codepoint
---@return string
local function utf8_char(cp)
  if cp < 0x80 then
    return string.char(cp)
  elseif cp < 0x800 then
    return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64)
  elseif cp < 0x10000 then
    return string.char(0xE0 + math.floor(cp / 4096), 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
  elseif cp < 0x110000 then
    return string.char(
      0xF0 + math.floor(cp / 262144),
      0x80 + math.floor(cp / 4096) % 64,
      0x80 + math.floor(cp / 64) % 64,
      0x80 + cp % 64
    )
  end
  return ""
end

--- Decode HTML character references (named, decimal, hex) in text.
--- Adjusts highlight and link positions for byte-length changes.
---@param text string
---@param highlights MdRender.Markdown.Highlight[]
---@param links MdRender.Markdown.Link[]
---@return string
local function decode_html_entities(text, highlights, links)
  local result = {}
  local offsets = {}
  local i = 1
  while i <= #text do
    if text:sub(i, i) == "&" then
      -- Try numeric reference &#123; or &#x1F;
      local num_match, num_end = text:match("^(&#(%d+);)", i)
      if not num_match then
        num_match, num_end = text:match("^(&#[xX](%x+);)", i)
        if num_match then
          num_end = tonumber(num_end, 16)
        end
      else
        num_end = tonumber(num_end)
      end
      if num_match and num_end then
        local replacement = utf8_char(num_end)
        local out_pos = #table.concat(result)
        local delta = #num_match - #replacement
        if delta ~= 0 then
          table.insert(offsets, { pos = out_pos, delta = delta })
        end
        table.insert(result, replacement)
        i = i + #num_match
      else
        -- Try named reference &amp;
        local name, named_match = text:match("^&(%a+)(;)", i)
        if name and named_match then
          local replacement = HTML_ENTITIES[name] or HTML_ENTITIES[name:lower()]
          if replacement then
            local full = "&" .. name .. ";"
            local out_pos = #table.concat(result)
            local delta = #full - #replacement
            if delta ~= 0 then
              table.insert(offsets, { pos = out_pos, delta = delta })
            end
            table.insert(result, replacement)
            i = i + #full
          else
            table.insert(result, "&")
            i = i + 1
          end
        else
          table.insert(result, "&")
          i = i + 1
        end
      end
    else
      table.insert(result, text:sub(i, i))
      i = i + 1
    end
  end

  if #offsets > 0 then
    local function adjust(pos)
      local shift = 0
      for _, o in ipairs(offsets) do
        if pos > o.pos then
          shift = shift + o.delta
        end
      end
      return pos - shift
    end
    for _, hl in ipairs(highlights) do
      hl.col = adjust(hl.col)
      hl.end_col = adjust(hl.end_col)
    end
    for _, link in ipairs(links) do
      link.col_start = adjust(link.col_start)
      link.col_end = adjust(link.col_end)
    end
  end

  return table.concat(result)
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

--- GitHub Flavored Markdown + Obsidian alert/callout types
local ALERT_TYPES = {
  -- GitHub Alerts
  NOTE = { icon = "󰋽", label = "Note" },
  TIP = { icon = "󰌶", label = "Tip" },
  IMPORTANT = { icon = "󰅾", label = "Important" },
  WARNING = { icon = "󰀪", label = "Warning" },
  CAUTION = { icon = "󰳦", label = "Caution" },
  -- Obsidian additional types
  ABSTRACT = { icon = "󱉫", label = "Abstract" },
  SUMMARY = { icon = "󱉫", label = "Summary", style = "ABSTRACT" },
  TLDR = { icon = "󱉫", label = "TL;DR", style = "ABSTRACT" },
  INFO = { icon = "󰋽", label = "Info", style = "NOTE" },
  TODO = { icon = "󰄬", label = "Todo" },
  SUCCESS = { icon = "󰄬", label = "Success" },
  CHECK = { icon = "󰄬", label = "Check", style = "SUCCESS" },
  DONE = { icon = "󰄬", label = "Done", style = "SUCCESS" },
  QUESTION = { icon = "󱈅", label = "Question" },
  HELP = { icon = "󱈅", label = "Help", style = "QUESTION" },
  FAQ = { icon = "󱈅", label = "FAQ", style = "QUESTION" },
  FAILURE = { icon = "󰅙", label = "Failure" },
  FAIL = { icon = "󰅙", label = "Fail", style = "FAILURE" },
  MISSING = { icon = "󰅙", label = "Missing", style = "FAILURE" },
  DANGER = { icon = "󱐌", label = "Danger" },
  ERROR = { icon = "󱐌", label = "Error", style = "DANGER" },
  BUG = { icon = "󱈰", label = "Bug" },
  EXAMPLE = { icon = "󰆹", label = "Example" },
  QUOTE = { icon = "󱗝", label = "Quote" },
  CITE = { icon = "󱗝", label = "Cite", style = "QUOTE" },
}

--- Adjust highlight and link positions after character removals
---@param highlights MdRender.Markdown.Highlight[]
---@param links MdRender.Markdown.Link[]
---@param removals MdRender.Markdown.Removal[]
---@param hl_count integer number of highlights to adjust (from the beginning)
---@param link_count integer number of links to adjust (from the beginning)
local function adjust_positions(highlights, links, removals, hl_count, link_count)
  if #removals == 0 then
    return
  end
  local function adjust(pos)
    local shift = 0
    for _, r in ipairs(removals) do
      if pos >= r.start + r.count then
        shift = shift + r.count
      elseif pos > r.start then
        shift = shift + (pos - r.start)
      end
    end
    return pos - shift
  end
  for i = 1, hl_count do
    highlights[i].col = adjust(highlights[i].col)
    highlights[i].end_col = adjust(highlights[i].end_col)
  end
  for i = 1, link_count do
    links[i].col_start = adjust(links[i].col_start)
    links[i].col_end = adjust(links[i].col_end)
  end
end

--- Process paired markers (bold, strikethrough) by removing markers and adding highlights
---@param text string The input text
---@param pattern string The Lua pattern to match (e.g., "%*%*([^*]+)%*%*")
---@param hl_group string The highlight group to apply
---@param marker_len integer The length of each marker (e.g., 2 for ** or ~~)
---@param highlights MdRender.Markdown.Highlight[] Existing highlights to adjust
---@param links MdRender.Markdown.Link[] Existing links to adjust
---@return string processed The text with markers removed
local function process_paired_markers(text, pattern, hl_group, marker_len, highlights, links)
  local pre_hl_count = #highlights
  local pre_link_count = #links
  local removals = {}
  local processed = ""
  local i = 1
  while i <= #text do
    local s, e = text:find(pattern, i)
    if s == i then
      local content = text:match(pattern, i)
      table.insert(removals, { start = s - 1, count = marker_len })
      table.insert(removals, { start = s - 1 + marker_len + #content, count = marker_len })
      local start_col = #processed
      processed = processed .. content
      table.insert(highlights, { col = start_col, end_col = start_col + #content, hl = hl_group })
      i = e + 1
    else
      processed = processed .. text:sub(i, i)
      i = i + 1
    end
  end
  adjust_positions(highlights, links, removals, pre_hl_count, pre_link_count)
  return processed
end

--- Process _underscore_ emphasis with word-boundary checking (CommonMark rules).
--- Only matches when _ is at a word boundary to avoid false positives with snake_case.
---@param text string
---@param hl_group string
---@param highlights MdRender.Markdown.Highlight[]
---@param links MdRender.Markdown.Link[]
---@return string processed
local function process_underscore_emphasis(text, hl_group, highlights, links)
  local pre_hl_count = #highlights
  local pre_link_count = #links
  local removals = {}
  local processed = ""
  local i = 1
  while i <= #text do
    if text:sub(i, i) == "_" then
      local prev_char = i > 1 and text:sub(i - 1, i - 1) or ""
      local at_word_boundary = prev_char == "" or prev_char:match "[%s%p]"
      if at_word_boundary then
        local e = text:find("_", i + 1)
        if e then
          local next_char = e < #text and text:sub(e + 1, e + 1) or ""
          local end_boundary = next_char == "" or next_char:match "[%s%p]"
          if end_boundary then
            local content = text:sub(i + 1, e - 1)
            if #content > 0 then
              table.insert(removals, { start = i - 1, count = 1 })
              table.insert(removals, { start = e - 1, count = 1 })
              local start_col = #processed
              processed = processed .. content
              table.insert(highlights, { col = start_col, end_col = start_col + #content, hl = hl_group })
              i = e + 1
            else
              processed = processed .. "_"
              i = i + 1
            end
          else
            processed = processed .. "_"
            i = i + 1
          end
        else
          processed = processed .. "_"
          i = i + 1
        end
      else
        processed = processed .. "_"
        i = i + 1
      end
    else
      processed = processed .. text:sub(i, i)
      i = i + 1
    end
  end
  adjust_positions(highlights, links, removals, pre_hl_count, pre_link_count)
  return processed
end

--- Process code markers (backticks) by removing them and adding highlights
---@param text string The input text
---@param hl_group string The highlight group to apply
---@param highlights MdRender.Markdown.Highlight[] Existing highlights to adjust
---@param links MdRender.Markdown.Link[] Existing links to adjust
---@return string processed The text with backticks removed
local function process_code_markers(text, hl_group, highlights, links)
  local pre_hl_count = #highlights
  local pre_link_count = #links
  local removals = {}
  local processed = ""
  local i = 1
  while i <= #text do
    if text:sub(i, i) == "`" then
      local e = text:find("`", i + 1)
      if e then
        table.insert(removals, { start = i - 1, count = 1 })
        table.insert(removals, { start = e - 1, count = 1 })
        local content = text:sub(i + 1, e - 1)
        local start_col = #processed
        processed = processed .. content
        table.insert(highlights, { col = start_col, end_col = start_col + #content, hl = hl_group })
        i = e + 1
      else
        processed = processed .. text:sub(i, i)
        i = i + 1
      end
    else
      processed = processed .. text:sub(i, i)
      i = i + 1
    end
  end
  adjust_positions(highlights, links, removals, pre_hl_count, pre_link_count)
  return processed
end

--- Process [[wikilinks]]: display as link text with highlight
---@param text string
---@param highlights MdRender.Markdown.Highlight[]
---@param links MdRender.Markdown.Link[]
---@return string processed
local function process_wikilinks(text, highlights, links)
  local processed = ""
  local i = 1

  while i <= #text do
    if text:sub(i, i + 1) == "[[" then
      local close = text:find("]]", i + 2, true)
      if close then
        local inner = text:sub(i + 2, close - 1)
        local display, target

        local pipe_pos = inner:find("|", 1, true)
        if pipe_pos then
          target = inner:sub(1, pipe_pos - 1)
          display = inner:sub(pipe_pos + 1)
        else
          target = inner
          local heading = inner:match "^#(.+)$"
          if heading then
            display = heading
          else
            local page, h = inner:match "^(.+)#(.+)$"
            if page and h then
              display = page .. " > " .. h
            else
              display = inner
            end
          end
        end

        local start_col = #processed
        processed = processed .. display
        table.insert(highlights, { col = start_col, end_col = start_col + #display, hl = "Underlined" })
        table.insert(links, {
          col_start = start_col,
          col_end = start_col + #display,
          url = "obsidian://open?file=" .. target,
        })
        i = close + 2
      else
        processed = processed .. text:sub(i, i)
        i = i + 1
      end
    else
      processed = processed .. text:sub(i, i)
      i = i + 1
    end
  end

  return processed
end

local IMAGE_EXTENSIONS = { png = true, jpg = true, jpeg = true, gif = true, svg = true, webp = true, bmp = true }

--- Process ![[embeds]]: display as icon + filename with highlight
---@param text string
---@param highlights MdRender.Markdown.Highlight[]
---@param links MdRender.Markdown.Link[]
---@return string processed
local function process_embeds(text, highlights, links)
  local processed = ""
  local i = 1

  while i <= #text do
    if text:sub(i, i + 2) == "![[" then
      local close = text:find("]]", i + 3, true)
      if close then
        local inner = text:sub(i + 3, close - 1)
        local target = inner:match "^([^|#]+)" or inner
        local ext = target:match "%.(%w+)$"
        local icon = (ext and IMAGE_EXTENSIONS[ext:lower()]) and "🖼 " or "📎 "
        local display = icon .. target

        local start_col = #processed
        processed = processed .. display
        table.insert(highlights, { col = start_col, end_col = start_col + #display, hl = "Underlined" })
        table.insert(links, {
          col_start = start_col,
          col_end = start_col + #display,
          url = "obsidian://open?file=" .. target,
        })
        i = close + 2
      else
        processed = processed .. text:sub(i, i)
        i = i + 1
      end
    else
      processed = processed .. text:sub(i, i)
      i = i + 1
    end
  end

  return processed
end

--- Process [text](url) links: remove markers and produce highlight/link entries
--- Supports balanced brackets for image-in-link patterns like [![alt](img)](url)
---@param text string
---@param highlights MdRender.Markdown.Highlight[]
---@param links MdRender.Markdown.Link[]
---@return string processed
local function process_links(text, highlights, links)
  local processed = ""
  local i = 1
  while i <= #text do
    if text:sub(i, i) == "[" then
      -- Find matching ] with balanced bracket counting
      local depth = 1
      local j = i + 1
      while j <= #text and depth > 0 do
        local c = text:sub(j, j)
        if c == "[" then
          depth = depth + 1
        elseif c == "]" then
          depth = depth - 1
        end
        j = j + 1
      end
      -- j is now one past the matching ]
      if depth == 0 and j <= #text and text:sub(j, j) == "(" then
        local paren_end = text:find(")", j + 1, true)
        if paren_end then
          local link_text_raw = text:sub(i + 1, j - 2)
          local url = text:sub(j + 1, paren_end - 1)

          -- If link text is an image ![alt](img-url), use alt as display
          local alt = link_text_raw:match "^!%[(.-)%]%((.-)%)$"
          local display_text = alt or link_text_raw

          local start_col = #processed
          processed = processed .. display_text
          table.insert(highlights, { col = start_col, end_col = start_col + #display_text, hl = "Underlined" })
          table.insert(links, { col_start = start_col, col_end = start_col + #display_text, url = url })
          i = paren_end + 1
        else
          processed = processed .. text:sub(i, i)
          i = i + 1
        end
      else
        processed = processed .. text:sub(i, i)
        i = i + 1
      end
    else
      processed = processed .. text:sub(i, i)
      i = i + 1
    end
  end
  return processed
end

--- Process reference-style links: [text][ref] and [text] shortcut forms
---@param text string
---@param ref_links table<string, string> lowercase label -> URL mapping
---@param highlights MdRender.Markdown.Highlight[]
---@param links MdRender.Markdown.Link[]
---@return string processed
local function process_reference_links(text, ref_links, highlights, links)
  if not ref_links or not next(ref_links) then
    return text
  end
  local processed = ""
  local i = 1
  while i <= #text do
    if text:sub(i, i) == "[" then
      local close = text:find("]", i + 1, true)
      if close then
        local label = text:sub(i + 1, close - 1)
        -- Check for [text][ref] form
        if close + 1 <= #text and text:sub(close + 1, close + 1) == "[" then
          local close2 = text:find("]", close + 2, true)
          if close2 then
            local ref = text:sub(close + 2, close2 - 1)
            local url = ref_links[ref:lower()]
            if url then
              local start_col = #processed
              processed = processed .. label
              table.insert(highlights, { col = start_col, end_col = start_col + #label, hl = "Underlined" })
              table.insert(links, { col_start = start_col, col_end = start_col + #label, url = url })
              i = close2 + 1
            else
              processed = processed .. text:sub(i, i)
              i = i + 1
            end
          else
            processed = processed .. text:sub(i, i)
            i = i + 1
          end
        else
          -- Check for [text] shortcut form (not followed by '(')
          if close + 1 > #text or text:sub(close + 1, close + 1) ~= "(" then
            local url = ref_links[label:lower()]
            if url then
              local start_col = #processed
              processed = processed .. label
              table.insert(highlights, { col = start_col, end_col = start_col + #label, hl = "Underlined" })
              table.insert(links, { col_start = start_col, col_end = start_col + #label, url = url })
              i = close + 1
            else
              processed = processed .. text:sub(i, i)
              i = i + 1
            end
          else
            processed = processed .. text:sub(i, i)
            i = i + 1
          end
        end
      else
        processed = processed .. text:sub(i, i)
        i = i + 1
      end
    else
      processed = processed .. text:sub(i, i)
      i = i + 1
    end
  end
  return processed
end

--- Process bare URLs: detect standalone URLs, truncate for display, add link metadata with full URL
---@param text string
---@param max_url_width integer
---@param highlights MdRender.Markdown.Highlight[]
---@param links MdRender.Markdown.Link[]
---@return string processed
local function process_bare_urls(text, max_url_width, highlights, links)
  local pre_hl_count = #highlights
  local pre_link_count = #links
  local processed = ""
  local i = 1
  local in_backtick = false
  local adjustments = {}

  while i <= #text do
    if text:sub(i, i) == "`" then
      in_backtick = not in_backtick
      processed = processed .. "`"
      i = i + 1
    elseif not in_backtick then
      local s, e = text:find("https?://[^%s%)<>\"']+", i)
      if s == i then
        local url_match = text:sub(s, e)
        -- Strip trailing punctuation (including markdown markers)
        local url = url_match:gsub("[.,;:!?*~]+$", "")
        local start_col = #processed
        local display_url

        if vim.fn.strdisplaywidth(url) > max_url_width then
          local target = max_url_width - 1
          local current_width = 0
          local byte_pos = 0
          for char in url:gmatch "[%z\1-\127\194-\253][\128-\191]*" do
            local char_width = vim.fn.strdisplaywidth(char)
            if current_width + char_width > target then
              break
            end
            current_width = current_width + char_width
            byte_pos = byte_pos + #char
          end
          display_url = url:sub(1, byte_pos) .. "…"
          table.insert(adjustments, {
            input_pos = i - 1 + byte_pos,
            delta = #url - byte_pos - #"…",
          })
        else
          display_url = url
        end

        processed = processed .. display_url
        table.insert(highlights, { col = start_col, end_col = start_col + #display_url, hl = "Underlined" })
        table.insert(links, { col_start = start_col, col_end = start_col + #display_url, url = url })
        i = i + #url
      else
        processed = processed .. text:sub(i, i)
        i = i + 1
      end
    else
      processed = processed .. text:sub(i, i)
      i = i + 1
    end
  end

  if #adjustments > 0 then
    local function adjust(pos)
      local total_delta = 0
      for _, adj in ipairs(adjustments) do
        if pos > adj.input_pos then
          total_delta = total_delta + adj.delta
        end
      end
      return pos - total_delta
    end
    for idx = 1, pre_hl_count do
      highlights[idx].col = adjust(highlights[idx].col)
      highlights[idx].end_col = adjust(highlights[idx].end_col)
    end
    for idx = 1, pre_link_count do
      links[idx].col_start = adjust(links[idx].col_start)
      links[idx].col_end = adjust(links[idx].col_end)
    end
  end

  return processed
end

--- Process #123 issue/PR references: make them clickable (skip inside backticks)
---@param text string
---@param repo_base_url string
---@param highlights MdRender.Markdown.Highlight[]
---@param links MdRender.Markdown.Link[]
---@return string processed
local function process_issue_refs(text, repo_base_url, highlights, links)
  local processed = ""
  local i = 1
  local in_backtick = false
  while i <= #text do
    if text:sub(i, i) == "`" then
      in_backtick = not in_backtick
      processed = processed .. "`"
      i = i + 1
    else
      local s, e = text:find("#%d+", i)
      if s == i and not in_backtick then
        local issue_num = text:match("#(%d+)", i)
        local issue_text = "#" .. issue_num
        local url = repo_base_url .. "/issues/" .. issue_num
        local start_col = #processed
        processed = processed .. issue_text
        table.insert(highlights, { col = start_col, end_col = start_col + #issue_text, hl = "Underlined" })
        table.insert(links, { col_start = start_col, col_end = start_col + #issue_text, url = url })
        i = e + 1
      else
        processed = processed .. text:sub(i, i)
        i = i + 1
      end
    end
  end
  return processed
end

--- Process autolink references: make key_prefix matches clickable (skip inside backticks)
---@param text string
---@param autolinks MdRender.Autolink[]
---@param highlights MdRender.Markdown.Highlight[]
---@param links MdRender.Markdown.Link[]
---@return string processed
local function process_autolink_refs(text, autolinks, highlights, links)
  local processed = ""
  local i = 1
  local in_backtick = false
  while i <= #text do
    if text:sub(i, i) == "`" then
      in_backtick = not in_backtick
      processed = processed .. "`"
      i = i + 1
    elseif not in_backtick then
      local matched = false
      for _, autolink in ipairs(autolinks) do
        local prefix = autolink.key_prefix
        if text:sub(i, i + #prefix - 1) == prefix then
          -- Try to match the value after the prefix
          local rest = text:sub(i + #prefix)
          local value
          if autolink.is_alphanumeric then
            value = rest:match "^([%w]+)"
          else
            value = rest:match "^(%d+)"
          end
          if value and #value > 0 then
            local ref_text = prefix .. value
            local url = autolink.url_template:gsub("<num>", value)
            local start_col = #processed
            processed = processed .. ref_text
            table.insert(highlights, { col = start_col, end_col = start_col + #ref_text, hl = "Underlined" })
            table.insert(links, { col_start = start_col, col_end = start_col + #ref_text, url = url })
            i = i + #ref_text
            matched = true
            break
          end
        end
      end
      if not matched then
        processed = processed .. text:sub(i, i)
        i = i + 1
      end
    else
      processed = processed .. text:sub(i, i)
      i = i + 1
    end
  end
  return processed
end

--- Prepend blockquote visual prefix and shift all highlight/link positions
---@param text string
---@param quote_prefix string
---@param highlights MdRender.Markdown.Highlight[]
---@param links MdRender.Markdown.Link[]
---@return string
local function apply_blockquote_prefix(text, quote_prefix, highlights, links)
  local offset = #quote_prefix
  text = quote_prefix .. text
  table.insert(highlights, 1, { col = 0, end_col = offset, hl = "FloatBorder" })
  for idx = 2, #highlights do
    highlights[idx].col = highlights[idx].col + offset
    highlights[idx].end_col = highlights[idx].end_col + offset
  end
  for _, link in ipairs(links) do
    link.col_start = link.col_start + offset
    link.col_end = link.col_end + offset
  end
  return text
end

--- HTML inline tag definitions: tag names -> highlight group (false = strip tags only)
local HTML_TAG_HIGHLIGHTS = {
  b = "Bold",
  strong = "Bold",
  i = "Italic",
  em = "Italic",
  code = "String",
  s = "DiagnosticDeprecated",
  del = "DiagnosticDeprecated",
  strike = "DiagnosticDeprecated",
  u = "Underlined",
  mark = "MdRenderHighlight",
  kbd = "Special",
  sub = false,
  sup = false,
}

--- Process HTML tags: <a href> links, <img> images, and paired inline tags
--- Skips tags inside backtick-delimited code spans.
---@param text string
---@param highlights MdRender.Markdown.Highlight[]
---@param links MdRender.Markdown.Link[]
---@return string processed
local function process_html_tags(text, highlights, links)
  local pre_hl_count = #highlights
  local pre_link_count = #links
  local removals = {}
  local processed = ""
  local i = 1
  local in_backtick = false
  while i <= #text do
    if text:sub(i, i) == "`" then
      in_backtick = not in_backtick
      processed = processed .. "`"
      i = i + 1
    elseif not in_backtick and text:sub(i, i) == "<" then
      local rest = text:sub(i)
      local matched = false

      -- Try <a href="...">text</a>
      local a_tag = rest:match "^(<a%s[^>]*>)"
      if a_tag then
        local href = a_tag:match 'href="([^"]*)"' or a_tag:match "href='([^']*)'"
        local close_start, close_end = text:find("</a>", i + #a_tag, true)
        if href and close_start then
          local content = text:sub(i + #a_tag, close_start - 1)
          table.insert(removals, { start = i - 1, count = #a_tag })
          table.insert(removals, { start = close_start - 1, count = 4 })
          local start_col = #processed
          processed = processed .. content
          table.insert(highlights, { col = start_col, end_col = start_col + #content, hl = "Underlined" })
          table.insert(links, { col_start = start_col, col_end = start_col + #content, url = href })
          i = close_end + 1
          matched = true
        end
      end

      -- Try <img src="..." alt="...">
      if not matched then
        local img_tag = rest:match "^(<img%s[^>]*>)"
        if img_tag then
          local src = img_tag:match 'src="([^"]*)"' or img_tag:match "src='([^']*)'"
          if src then
            local alt = img_tag:match 'alt="([^"]*)"' or img_tag:match "alt='([^']*)'"
            local display = (alt and alt ~= "") and ("🖼 " .. alt) or ("🖼 " .. (src:match "([^/]+)$" or src))
            table.insert(removals, { start = i - 1, count = #img_tag })
            local start_col = #processed
            processed = processed .. display
            table.insert(highlights, { col = start_col, end_col = start_col + #display, hl = "Underlined" })
            table.insert(links, { col_start = start_col, col_end = start_col + #display, url = src })
            i = i + #img_tag
            matched = true
          end
        end
      end

      -- Try paired HTML tags (<b>, <strong>, <em>, etc.)
      if not matched then
        local tag_name = rest:match "^<(%a+)[%s>]"
        if tag_name then
          local lower_tag = tag_name:lower()
          local hl = HTML_TAG_HIGHLIGHTS[lower_tag]
          if hl ~= nil then
            local open_tag = rest:match("^(<" .. tag_name .. "[^>]*>)")
            if open_tag then
              local close_tag = "</" .. tag_name .. ">"
              local close_start = text:find(close_tag, i + #open_tag, true)
              if not close_start and tag_name ~= lower_tag then
                close_tag = "</" .. lower_tag .. ">"
                close_start = text:find(close_tag, i + #open_tag, true)
              end
              if close_start then
                local content = text:sub(i + #open_tag, close_start - 1)
                table.insert(removals, { start = i - 1, count = #open_tag })
                table.insert(removals, { start = close_start - 1, count = #close_tag })
                local start_col = #processed
                processed = processed .. content
                if hl then
                  table.insert(highlights, { col = start_col, end_col = start_col + #content, hl = hl })
                end
                i = close_start + #close_tag
                matched = true
              end
            end
          end
        end
      end

      if not matched then
        processed = processed .. text:sub(i, i)
        i = i + 1
      end
    else
      processed = processed .. text:sub(i, i)
      i = i + 1
    end
  end
  adjust_positions(highlights, links, removals, pre_hl_count, pre_link_count)
  return processed
end

--- Process Obsidian-style #tags: highlight tag text (skip inside backticks).
--- Tags must contain at least one non-digit character to avoid confusion with issue refs.
---@param text string
---@param highlights MdRender.Markdown.Highlight[]
---@return string processed
local function process_tags(text, highlights)
  local processed = ""
  local i = 1
  local in_backtick = false
  while i <= #text do
    if text:sub(i, i) == "`" then
      in_backtick = not in_backtick
      processed = processed .. "`"
      i = i + 1
    elseif not in_backtick and text:sub(i, i) == "#" then
      local prev_char = i > 1 and text:sub(i - 1, i - 1) or ""
      local at_boundary = prev_char == "" or prev_char:match "%s"
      if at_boundary then
        local tag = text:match("^#([%w_/-][%w_/%-]*)", i)
        if tag and tag:match "%a" then
          local full = "#" .. tag
          local start_col = #processed
          processed = processed .. full
          table.insert(highlights, { col = start_col, end_col = start_col + #full, hl = "MdRenderTag" })
          i = i + #full
        else
          processed = processed .. "#"
          i = i + 1
        end
      else
        processed = processed .. "#"
        i = i + 1
      end
    else
      processed = processed .. text:sub(i, i)
      i = i + 1
    end
  end
  return processed
end

--- Unicode superscript digit characters
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

--- Process footnote references [^id] → superscript number with highlight
---@param text string
---@param footnote_map table<string, integer> footnote label → number mapping
---@param highlights MdRender.Markdown.Highlight[]
---@return string processed
local function process_footnote_refs(text, footnote_map, highlights)
  if not footnote_map or not next(footnote_map) then
    return text
  end
  local processed = ""
  local i = 1
  while i <= #text do
    if text:sub(i, i + 1) == "[^" then
      local close = text:find("]", i + 2, true)
      if close then
        local label = text:sub(i + 2, close - 1)
        local num = footnote_map[label]
        if num then
          local display = to_superscript(num)
          local start_col = #processed
          processed = processed .. display
          table.insert(highlights, { col = start_col, end_col = start_col + #display, hl = "Special" })
          i = close + 1
        else
          processed = processed .. text:sub(i, i)
          i = i + 1
        end
      else
        processed = processed .. text:sub(i, i)
        i = i + 1
      end
    else
      processed = processed .. text:sub(i, i)
      i = i + 1
    end
  end
  return processed
end

--- Process inline math $...$ by removing dollar signs and adding highlights.
--- Skips $$ (display math) and content inside backticks.
---@param text string
---@param hl_group string
---@param highlights MdRender.Markdown.Highlight[]
---@param links MdRender.Markdown.Link[]
---@return string processed
local function process_inline_math(text, hl_group, highlights, links)
  local pre_hl_count = #highlights
  local pre_link_count = #links
  local removals = {}
  local processed = ""
  local i = 1
  local in_backtick = false
  while i <= #text do
    if text:sub(i, i) == "`" then
      in_backtick = not in_backtick
      processed = processed .. "`"
      i = i + 1
    elseif not in_backtick and text:sub(i, i) == "$" and text:sub(i, i + 1) ~= "$$" then
      local e = text:find("%$", i + 1)
      if e and e > i + 1 then
        local content = text:sub(i + 1, e - 1)
        if not content:match "^%s" and not content:match "%s$" then
          table.insert(removals, { start = i - 1, count = 1 })
          table.insert(removals, { start = e - 1, count = 1 })
          local start_col = #processed
          processed = processed .. content
          table.insert(highlights, { col = start_col, end_col = start_col + #content, hl = hl_group })
          i = e + 1
        else
          processed = processed .. "$"
          i = i + 1
        end
      else
        processed = processed .. "$"
        i = i + 1
      end
    else
      processed = processed .. text:sub(i, i)
      i = i + 1
    end
  end
  adjust_positions(highlights, links, removals, pre_hl_count, pre_link_count)
  return processed
end

--- Keep remaining HTML tags with a dim highlight (tags not handled by process_html_tags)
--- Skips tags inside backtick-delimited code spans.
---@param text string
---@param highlights MdRender.Markdown.Highlight[]
---@return string processed
local function strip_html_tags(text, highlights)
  local processed = ""
  local i = 1
  local in_backtick = false
  while i <= #text do
    if text:sub(i, i) == "`" then
      in_backtick = not in_backtick
      processed = processed .. "`"
      i = i + 1
    elseif not in_backtick and text:sub(i, i) == "<" then
      local tag = text:sub(i):match "^(</?%a[^>]*>)"
      if tag then
        local start_col = #processed
        processed = processed .. tag
        table.insert(highlights, { col = start_col, end_col = start_col + #tag, hl = "Comment" })
        i = i + #tag
      else
        processed = processed .. text:sub(i, i)
        i = i + 1
      end
    else
      processed = processed .. text:sub(i, i)
      i = i + 1
    end
  end
  return processed
end

--- Render markdown text to plain text with highlight and link metadata
---@param text string The markdown text to render
---@param repo_base_url? string Optional repository base URL for issue/PR references
---@param autolinks? MdRender.Autolink[] Optional autolink definitions
---@param ref_links? table<string, string> Optional reference link definitions (lowercase label -> URL)
---@return string rendered_text The rendered plain text
---@return MdRender.Markdown.Highlight[] highlights
---@return MdRender.Markdown.Link[] links
---@return string? special_type Special type like "heading" if applicable
---@return string? list_marker List marker if applicable
---@return string? alert_type Alert type (NOTE, TIP, etc.) if applicable
Markdown.render = function(text, repo_base_url, autolinks, ref_links, footnote_map)
  local rendered_text = text:gsub("\r", "")
  -- Collapse multiple consecutive spaces (preserve leading whitespace)
  local leading_ws = rendered_text:match "^(%s*)" or ""
  rendered_text = leading_ws .. rendered_text:sub(#leading_ws + 1):gsub("  +", " ")
  local highlights = {}
  local links = {}

  -- Heading (# ## ### etc.) - detect level and strip markers, process inline elements below
  local heading_markers, heading_content = rendered_text:match "^(#+)%s+(.+)$"
  local heading_level = nil
  if heading_markers then
    heading_level = math.min(#heading_markers, 6)
    rendered_text = heading_content
  end

  -- Blockquote (> ) - extract prefix
  local quote_prefix = ""
  local is_blockquote = false
  while rendered_text:match "^>%s?" do
    rendered_text = rendered_text:gsub("^>%s?", "", 1)
    quote_prefix = quote_prefix .. "│ "
    is_blockquote = true
  end

  -- Detect alert/callout syntax [!TYPE], [!TYPE]+, [!TYPE]- with optional title
  if is_blockquote then
    local alert_key, fold_mod, custom_title
    -- Try: [!TYPE]+/- Title
    alert_key, fold_mod, custom_title = rendered_text:match "^%[!(%a+)%]([+-])%s+(.+)$"
    if not alert_key then
      -- Try: [!TYPE] Title (no fold modifier)
      alert_key, custom_title = rendered_text:match "^%[!(%a+)%]%s+(.+)$"
    end
    if not alert_key then
      -- Try: [!TYPE]+/- (no title)
      alert_key, fold_mod = rendered_text:match "^%[!(%a+)%]([+-])$"
    end
    if not alert_key then
      -- Try: [!TYPE] (no fold modifier, no title)
      alert_key = rendered_text:match "^%[!(%a+)%]$"
    end
    if alert_key then
      alert_key = alert_key:upper()
      local alert = ALERT_TYPES[alert_key]
      local style_key, icon, label
      if alert then
        style_key = alert.style or alert_key
        icon = alert.icon
        label = alert.label
      else
        -- Unknown callout type: use a generic style
        style_key = "NOTE"
        icon = "❝"
        -- Capitalize: first letter upper, rest lower
        label = alert_key:sub(1, 1) .. alert_key:sub(2):lower()
      end
      local padded_icon = pad_icon(icon)
      if custom_title then
        rendered_text = padded_icon .. " " .. custom_title
      else
        rendered_text = padded_icon .. " " .. label
      end
      rendered_text = apply_blockquote_prefix(rendered_text, quote_prefix, highlights, links)
      return rendered_text, highlights, links, "blockquote", nil, style_key, fold_mod
    end
  end

  -- List items (- * 1.) - detect marker
  local list_marker = rendered_text:match "^(%s*[-*]%s)"
    or rendered_text:match "^(%s*%d+%.%s)"

  -- Checkbox (- [ ] / - [x] / - [X] / - [-]) - replace marker + checkbox with icon
  local checkbox_hl = nil
  if list_marker then
    local after_marker = rendered_text:sub(#list_marker + 1)
    local cb_match, cb_char = after_marker:match "^(%[([xX %-])%]%s?)"
    if cb_match then
      local icon
      if cb_char == " " then
        icon = pad_icon("󰄱") .. " "
        checkbox_hl = "Comment"
      elseif cb_char == "-" then
        icon = pad_icon("󰡖") .. " "
        checkbox_hl = "DiagnosticWarn"
      else
        icon = pad_icon("󰄲") .. " "
        checkbox_hl = "DiagnosticOk"
      end
      local indent_part = list_marker:match "^(%s*)" or ""
      list_marker = indent_part .. icon
      rendered_text = list_marker .. after_marker:sub(#cb_match + 1)
    end
  end

  -- Strip hard line break marker (trailing backslash)
  rendered_text = rendered_text:gsub("\\%s*$", "")

  -- Remove Obsidian inline comments (%%...%%)
  rendered_text = rendered_text:gsub("%%%%(.-)%%%%", "")

  -- Remove inline HTML comments (<!-- ... -->)
  rendered_text = rendered_text:gsub("<!%-%-.-%-*%-%->", "")

  -- Escape backslash sequences before inline processing
  local backslash_escapes
  rendered_text, backslash_escapes = escape_backslashes(rendered_text)

  -- Process inline elements (embeds and wikilinks before standard links)
  rendered_text = process_embeds(rendered_text, highlights, links)
  rendered_text = process_wikilinks(rendered_text, highlights, links)
  rendered_text = process_footnote_refs(rendered_text, footnote_map, highlights)
  rendered_text = process_links(rendered_text, highlights, links)
  rendered_text = process_reference_links(rendered_text, ref_links, highlights, links)
  repeat
    local prev = rendered_text
    rendered_text = process_html_tags(rendered_text, highlights, links)
  until rendered_text == prev
  rendered_text = strip_html_tags(rendered_text, highlights)
  rendered_text = process_bare_urls(rendered_text, MAX_URL_DISPLAY_WIDTH, highlights, links)
  if repo_base_url then
    rendered_text = process_issue_refs(rendered_text, repo_base_url, highlights, links)
  end
  if autolinks and #autolinks > 0 then
    rendered_text = process_autolink_refs(rendered_text, autolinks, highlights, links)
  end
  rendered_text = process_tags(rendered_text, highlights)
  rendered_text = process_paired_markers(rendered_text, "%*%*([^*]+)%*%*", "Bold", 2, highlights, links)
  rendered_text = process_paired_markers(rendered_text, "%*([^*]+)%*", "Italic", 1, highlights, links)
  rendered_text = process_underscore_emphasis(rendered_text, "Italic", highlights, links)
  rendered_text = process_paired_markers(rendered_text, "~~([^~]+)~~", "DiagnosticDeprecated", 2, highlights, links)
  rendered_text = process_paired_markers(rendered_text, "==([^=]+)==", "MdRenderHighlight", 2, highlights, links)
  rendered_text = process_inline_math(rendered_text, "MdRenderMath", highlights, links)
  rendered_text = process_code_markers(rendered_text, "String", highlights, links)

  -- Restore backslash-escaped characters (adjusts highlight/link positions)
  rendered_text = restore_backslashes(rendered_text, backslash_escapes, highlights, links)

  -- Decode HTML character references (&amp; &#123; &#x1F; etc.)
  rendered_text = decode_html_entities(rendered_text, highlights, links)

  -- Add heading icon and highlight
  if heading_level then
    local raw_icons = { "󰉫", "󰉬", "󰉭", "󰉮", "󰉯", "󰉰" }
    local icon = pad_icon(raw_icons[heading_level]) .. " "
    local icon_len = #icon
    -- Shift all existing highlights and links by the icon length
    for _, hl in ipairs(highlights) do
      hl.col = hl.col + icon_len
      hl.end_col = hl.end_col + icon_len
    end
    for _, link in ipairs(links) do
      link.col_start = link.col_start + icon_len
      link.col_end = link.col_end + icon_len
    end
    rendered_text = icon .. rendered_text
    local hl_group = "MdRenderH" .. heading_level
    table.insert(highlights, 1, { col = 0, end_col = #rendered_text, hl = hl_group })
    return rendered_text, highlights, links, "heading"
  end

  -- Add list marker and checkbox highlight
  if list_marker then
    if checkbox_hl then
      local indent_len = #(list_marker:match "^(%s*)" or "")
      table.insert(highlights, 1, { col = indent_len, end_col = #list_marker, hl = checkbox_hl })
    else
      table.insert(highlights, 1, { col = 0, end_col = #list_marker, hl = "Special" })
    end
  end

  -- Prepend blockquote prefix
  if is_blockquote then
    rendered_text = apply_blockquote_prefix(rendered_text, quote_prefix, highlights, links)
    return rendered_text, highlights, links, "blockquote", list_marker
  end

  return rendered_text, highlights, links, nil, list_marker
end

--- Parse footnote definitions from document lines.
--- Returns ordered list of {label, text} and a label→number mapping.
---@param lines string[]
---@return {label: string, text: string}[] definitions
---@return table<string, integer> label_to_number
Markdown.parse_footnotes = function(lines)
  local defs = {}
  local label_to_num = {}
  local current_label = nil
  local current_parts = {}
  local in_code = false

  local function flush()
    if current_label then
      if not label_to_num[current_label] then
        table.insert(defs, { label = current_label, text = table.concat(current_parts, " ") })
        label_to_num[current_label] = #defs
      end
      current_label = nil
      current_parts = {}
    end
  end

  for _, line in ipairs(lines) do
    if line:match "^```" then
      in_code = not in_code
    end
    if in_code then goto continue end

    local label, text = line:match "^%[%^([^%]]+)%]:%s+(.+)$"
    if label then
      flush()
      current_label = label
      current_parts = { text }
    elseif current_label and line:match "^%s%s+" then
      -- Continuation line (indented)
      table.insert(current_parts, line:match "^%s+(.+)$" or "")
    else
      flush()
    end
    ::continue::
  end
  flush()

  return defs, label_to_num
end

--- Check if a line is a footnote definition
---@param line string
---@return boolean
Markdown.is_footnote_def = function(line)
  return line:match "^%[%^[^%]]+%]:%s+" ~= nil
end

--- Parse reference link definitions from document lines
--- Extracts lines like [label]: url and returns a mapping from lowercase label to URL
---@param lines string[]
---@return table<string, string> ref_links mapping from lowercase label to URL
Markdown.parse_reference_links = function(lines)
  local refs = {}
  for _, line in ipairs(lines) do
    local label, rest = line:match "^%[([^%]]+)%]:%s+(.+)$"
    if label then
      local url = rest:match "^<(.+)>" or rest:match "^(%S+)" or rest
      refs[label:lower()] = url
    end
  end
  return refs
end

--- Check if a line is a reference link definition
---@param line string
---@return boolean
Markdown.is_reference_link_def = function(line)
  return line:match "^%[([^%]]+)%]:%s+" ~= nil
end

--- Get the list marker type of a line.
--- Returns the specific marker character/delimiter to distinguish list types per CommonMark:
--- "-", "*", "+" for bullet lists, "." or ")" for ordered list delimiters, or nil for non-list lines.
---@param line string
---@return string? marker_type
Markdown.list_marker_type = function(line)
  local bullet = line:match "^%s*([-*+])%s"
  if bullet then
    return bullet
  end
  local delim = line:match "^%s*%d+([.)])%s"
  if delim then
    return delim
  end
  return nil
end

--- Renumber ordered list items following CommonMark rules.
--- The first item's number determines the start; subsequent items are
--- numbered sequentially regardless of their source numbers.
---@param lines string[]
---@return string[]
Markdown.renumber_ordered_lists = function(lines)
  local result = {}
  -- Stack of { prefix = string, counter = integer } for nested lists
  local stack = {}

  for _, line in ipairs(lines) do
    local prefix, num, rest = line:match "^(%s*>?%s*)(%d+)(%.%s.*)$"
    if prefix and num then
      -- Pop stack entries deeper than current prefix
      while #stack > 0 and #stack[#stack].prefix > #prefix do
        table.remove(stack)
      end
      if #stack > 0 and stack[#stack].prefix == prefix then
        stack[#stack].counter = stack[#stack].counter + 1
      else
        table.insert(stack, { prefix = prefix, counter = tonumber(num) })
      end
      table.insert(result, prefix .. tostring(stack[#stack].counter) .. rest)
    else
      if not line:match "^%s*$" then
        stack = {}
      end
      table.insert(result, line)
    end
  end
  return result
end

return Markdown
