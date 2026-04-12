--- Shared text wrapping utilities for md-render.
--- Provides BudouX-aware, kinsoku-compliant line wrapping used by both
--- content_builder (for markdown text) and markdown_table (for table cells).

local M = {}

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

local has_budoux, budoux = pcall(require, "budoux")
local budoux_parser = has_budoux and budoux.load_default_japanese_parser() or nil
local budoux_model = budoux_parser and budoux_parser.model or nil

--- Split a katakana string using BudouX's model with a relaxed threshold.
--- BudouX's default threshold (score > 0) is too strict for pure katakana compounds
--- (e.g. "マリオカートワールドミッション" scores are all negative but the relative
--- peaks correctly identify word boundaries).  This function picks the top-scoring
--- boundary positions to split into segments of at least `min_chars` characters.
---
--- A score bonus is applied after "ン" (moraic nasal), which is a strong linguistic
--- signal for sub-word boundaries in katakana loanwords (e.g. "ポケモン|レジェンズ",
--- "バリデーション|スクリプト").
---@param text string Pure katakana string
---@param min_chars? integer Minimum characters per segment (default 4)
---@return string[] chunks
local function split_katakana_compound(text, min_chars)
  if not budoux_model then
    return { text }
  end
  min_chars = min_chars or 4

  local INVALID = "\xef\xbf\xbd"
  local chars = {}
  for c in text:gmatch "[%z\1-\127\194-\253][\128-\191]*" do
    chars[#chars + 1] = c
  end
  if #chars <= min_chars * 2 then
    return { text }
  end

  -- Score bonus for boundaries after "ン" (moraic nasal).
  -- "ン" almost always ends a morpheme in katakana loanwords, making it
  -- a very strong word boundary signal that BudouX's model underweights.
  -- Exception: don't boost before voiced consonants (濁音: ガ/ザ/ダ/バ行),
  -- because "ン" + voiced consonant is usually within a single loanword
  -- (e.g. レジェンズ, サウンド, メンバー, エンジン).
  local moraic_n_bonus = math.floor(budoux_model.base_score * 0.4)
  local dakuten = {}
  for _, ch in ipairs {
    "ガ", "ギ", "グ", "ゲ", "ゴ",
    "ザ", "ジ", "ズ", "ゼ", "ゾ",
    "ダ", "ヂ", "ヅ", "デ", "ド",
    "バ", "ビ", "ブ", "ベ", "ボ",
  } do
    dakuten[ch] = true
  end

  -- Calculate BudouX scores at each boundary position
  local boundary_scores = {}
  for i = 2, #chars do
    local p1 = chars[i - 3] or INVALID
    local p2 = chars[i - 2] or INVALID
    local p3 = chars[i - 1]
    local w1 = chars[i]
    local w2 = chars[i + 1] or INVALID
    local w3 = chars[i + 2] or INVALID

    local score = -budoux_model.base_score
    if budoux_model.UW1 then score = score + (budoux_model.UW1[p1] or 0) end
    if budoux_model.UW2 then score = score + (budoux_model.UW2[p2] or 0) end
    if budoux_model.UW3 then score = score + (budoux_model.UW3[p3] or 0) end
    if budoux_model.UW4 then score = score + (budoux_model.UW4[w1] or 0) end
    if budoux_model.UW5 then score = score + (budoux_model.UW5[w2] or 0) end
    if budoux_model.UW6 then score = score + (budoux_model.UW6[w3] or 0) end
    if budoux_model.BW1 then score = score + (budoux_model.BW1[p2 .. p3] or 0) end
    if budoux_model.BW2 then score = score + (budoux_model.BW2[p3 .. w1] or 0) end
    if budoux_model.BW3 then score = score + (budoux_model.BW3[w1 .. w2] or 0) end
    if budoux_model.TW1 then score = score + (budoux_model.TW1[p1 .. p2 .. p3] or 0) end
    if budoux_model.TW2 then score = score + (budoux_model.TW2[p2 .. p3 .. w1] or 0) end
    if budoux_model.TW3 then score = score + (budoux_model.TW3[p3 .. w1 .. w2] or 0) end
    if budoux_model.TW4 then score = score + (budoux_model.TW4[w1 .. w2 .. w3] or 0) end

    -- Boost score for boundaries after "ン", unless followed by voiced consonant
    if p3 == "ン" and not dakuten[w1] then
      score = score + moraic_n_bonus
    end

    -- Penalty for splitting right after ッ + consonant kana.
    -- "ッ" (geminate) bonds tightly with the following kana, and the next
    -- character often continues the same morpheme (e.g. シンタック|ス is wrong;
    -- シンタックス|ハイライト is correct).  Strong boundaries like
    -- コードブロック|ヘッダ still pass because their base score is high enough.
    if i >= 3 and chars[i - 2] == "ッ" then
      score = score - math.floor(budoux_model.base_score * 0.35)
    end

    boundary_scores[i] = score
  end

  -- Only consider boundaries with scores above a quality threshold.
  -- BudouX scores are unreliable for pure katakana strings (all scores tend
  -- to be deeply negative).  A relaxed threshold filters out noise while
  -- keeping genuinely strong boundaries (e.g. "コードブロック|ヘッダ",
  -- "フローティング|プレビュー").
  -- When no boundary passes, fall back to kinsoku-grouped segments.
  local score_threshold = -math.floor(budoux_model.base_score * 0.95)

  -- Collect candidate split positions sorted by score (highest first),
  -- filtering out positions that would split before kinsoku characters
  -- (small kana, ー, ッ, ン) and positions below the quality threshold.
  local candidates = {}
  for i = 2, #chars do
    local w1 = chars[i]
    -- Don't split before small kana, ー, ッ, ン (these attach to preceding char)
    if not NO_BREAK_START[w1] and w1 ~= "ッ" and w1 ~= "ン" and w1 ~= "ー"
        and boundary_scores[i] > score_threshold then
      candidates[#candidates + 1] = { pos = i, score = boundary_scores[i] }
    end
  end
  table.sort(candidates, function(a, b) return a.score > b.score end)

  -- Greedily select split positions (highest score first) that maintain min_chars
  local selected = {}
  for _, cand in ipairs(candidates) do
    -- Check if this position is compatible with already-selected positions
    local ok = true
    -- Build sorted list of all boundaries (including start and end)
    local boundaries = { 1 }
    for _, s in ipairs(selected) do
      boundaries[#boundaries + 1] = s
    end
    boundaries[#boundaries + 1] = cand.pos
    boundaries[#boundaries + 1] = #chars + 1
    table.sort(boundaries)
    -- Check all segments have at least min_chars (min_tail for the last segment)
    local min_tail = min_chars - 1
    for j = 1, #boundaries - 1 do
      local min_len = (j == #boundaries - 1) and min_tail or min_chars
      if boundaries[j + 1] - boundaries[j] < min_len then
        ok = false
        break
      end
    end
    if ok then
      selected[#selected + 1] = cand.pos
    end
  end
  table.sort(selected)

  if #selected == 0 then
    -- No reliable boundary found: split into kinsoku-grouped segments.
    -- Each NO_BREAK_START character (small kana, ー, ッ, etc.) is attached
    -- to the preceding character, preventing cascading 追い出し issues in
    -- wrap_words while still allowing flexible line breaking.
    local grouped = {}
    for _, c in ipairs(chars) do
      if (NO_BREAK_START[c] or c == "ン" or c == "ん") and #grouped > 0 then
        grouped[#grouped] = grouped[#grouped] .. c
      else
        grouped[#grouped + 1] = c
      end
    end
    return grouped
  end

  -- Build result chunks
  local chunks = {}
  local start = 1
  for _, pos in ipairs(selected) do
    local parts = {}
    for j = start, pos - 1 do
      parts[#parts + 1] = chars[j]
    end
    chunks[#chunks + 1] = table.concat(parts)
    start = pos
  end
  -- Remaining tail
  local parts = {}
  for j = start, #chars do
    parts[#parts + 1] = chars[j]
  end
  chunks[#chunks + 1] = table.concat(parts)

  return chunks
end

--- Extract Unicode code point from a UTF-8 character.
---@param char string A single UTF-8 character
---@return integer
local function utf8_codepoint(char)
  local b1 = char:byte(1)
  if b1 < 0x80 then return b1 end
  if b1 < 0xE0 then return (b1 - 0xC0) * 64 + (char:byte(2) - 128) end
  if b1 < 0xF0 then return (b1 - 0xE0) * 4096 + (char:byte(2) - 128) * 64 + (char:byte(3) - 128) end
  return (b1 - 0xF0) * 262144 + (char:byte(2) - 128) * 4096 + (char:byte(3) - 128) * 64 + (char:byte(4) - 128)
end

--- Classify a character into a script class for sub-splitting.
--- "C" = CJK ideograph, "H" = hiragana, "K" = katakana, "O" = other
---@param char string
---@return string
local function script_class(char)
  local cp = utf8_codepoint(char)
  if cp >= 0x4E00 and cp <= 0x9FFF then return "C" end
  if cp >= 0x3400 and cp <= 0x4DBF then return "C" end
  if cp >= 0xF900 and cp <= 0xFAFF then return "C" end
  if cp >= 0x3040 and cp <= 0x309F then return "H" end
  if cp >= 0x30A0 and cp <= 0x30FF then return "K" end
  if cp >= 0x31F0 and cp <= 0x31FF then return "K" end
  if cp >= 0xFF65 and cp <= 0xFF9F then return "K" end
  return "O"
end

--- Sub-split a BudouX chunk at script transition boundaries (kanji <-> kana).
---@param chunk string
---@return string[]
local function split_by_script(chunk)
  local chars = {}
  for c in chunk:gmatch "[%z\1-\127\194-\253][\128-\191]*" do
    chars[#chars + 1] = c
  end
  if #chars <= 1 then return { chunk } end

  local sub_chunks = {}
  local current = chars[1]
  local prev_cls = script_class(chars[1])
  local kanji_run = prev_cls == "C" and 1 or 0

  for i = 2, #chars do
    local cls = script_class(chars[i])
    local should_split = false
    if chars[i - 1] == "・" and current ~= "・" then
      should_split = true
    end
    if cls ~= "O" and cls ~= prev_cls then
      if prev_cls == "K" then
        should_split = true
      elseif prev_cls == "C" and cls ~= "H" then
        should_split = true
      end
    end
    if should_split then
      sub_chunks[#sub_chunks + 1] = current
      current = chars[i]
      kanji_run = 0
    else
      current = current .. chars[i]
    end
    if cls == "C" then
      kanji_run = kanji_run + 1
    elseif cls ~= "O" then
      kanji_run = 0
    end
    if cls ~= "O" then prev_cls = cls end
  end
  sub_chunks[#sub_chunks + 1] = current
  return sub_chunks
end

--- Check if a string consists entirely of katakana (script class "K") characters.
---@param s string
---@return boolean
local function is_katakana_only(s)
  for c in s:gmatch "[%z\1-\127\194-\253][\128-\191]*" do
    if script_class(c) ~= "K" then
      return false
    end
  end
  return true
end

--- Count UTF-8 characters in a string.
---@param s string
---@return integer
local function utf8_charcount(s)
  local n = 0
  for _ in s:gmatch "[%z\1-\127\194-\253][\128-\191]*" do
    n = n + 1
  end
  return n
end

--- Check if a character is CJK/fullwidth or kinsoku-relevant punctuation.
--- Half-width ASCII punctuation (single byte) is excluded so that it stays
--- with adjacent ASCII words in split_segments (e.g. ".gitignore" stays as
--- one segment).  Kinsoku rules for these chars still apply in wrap_words.
--- Results are cached per character for performance (avoids repeated
--- vim.api.nvim_strwidth calls on large CJK documents).
local _is_cjk_cache = {}
local function is_cjk_or_kinsoku(char)
  local cached = _is_cjk_cache[char]
  if cached ~= nil then return cached end
  if #char == 1 then
    _is_cjk_cache[char] = false
    return false
  end
  local result = vim.api.nvim_strwidth(char) >= 2 or NO_BREAK_START[char] or NO_BREAK_END[char]
  _is_cjk_cache[char] = result
  return result
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

--- Vowel lookup for English syllable-like word splitting.
local ascii_vowels = {
  [string.byte "a"] = true, [string.byte "e"] = true, [string.byte "i"] = true,
  [string.byte "o"] = true, [string.byte "u"] = true,
  [string.byte "A"] = true, [string.byte "E"] = true, [string.byte "I"] = true,
  [string.byte "O"] = true, [string.byte "U"] = true,
}

--- Split a long ASCII word into syllable-like segments at vowel→consonant
--- transitions (V|C boundaries).  This provides natural break points for
--- line wrapping in narrow contexts (e.g. table cells) while having no
--- visual impact in wide contexts since wrap_words reassembles segments
--- that fit on the same line.
---
--- Example: "Truncation" → ["Tru", "nca", "tion"]
---          "automatically" → ["au", "to", "ma", "ti", "ca", "lly"]
---@param word string ASCII word (≥ 7 characters)
---@param word_start integer 0-indexed byte position of word in original text
---@param leading_space boolean whether this word had a leading space
---@return {text: string, byte_pos: integer, has_leading_space: boolean}[]
local function split_ascii_syllables(word, word_start, leading_space)
  local result = {}
  local seg_start = 1
  local first = true

  for i = 2, #word - 2 do
    local b = word:byte(i)
    local b_next = word:byte(i + 1)
    -- Break after a vowel when followed by an alphabetic consonant,
    -- ensuring at least 2 chars remain on each side
    if ascii_vowels[b] and b_next and not ascii_vowels[b_next]
        and ((b_next >= 65 and b_next <= 90) or (b_next >= 97 and b_next <= 122))
        and i - seg_start >= 1 and #word - i >= 2 then
      table.insert(result, {
        text = word:sub(seg_start, i),
        byte_pos = word_start + seg_start - 1,
        has_leading_space = first and leading_space or false,
      })
      seg_start = i + 1
      first = false
    end
  end

  -- Remaining tail
  table.insert(result, {
    text = word:sub(seg_start),
    byte_pos = word_start + seg_start - 1,
    has_leading_space = first and leading_space or false,
  })

  return result
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
    if has_budoux then
      local chunks = budoux_parser:parse(cjk_run)
      local chunk_byte = cjk_run_start
      local first = true
      for _, chunk in ipairs(chunks) do
        local sub_chunks = split_by_script(chunk)
        for _, sub in ipairs(sub_chunks) do
          -- Long katakana-only segments (e.g. "バリデーションスクリプト") cannot be
          -- broken by wrap_words since they are a single segment.  Use BudouX's
          -- model with a relaxed threshold to find natural sub-word boundaries
          -- (e.g. "マリオカート|ワールド|ミッション").
          if is_katakana_only(sub) and utf8_charcount(sub) > 4 then
            local kata_chunks = split_katakana_compound(sub)
            local kata_byte = chunk_byte
            for _, kata_chunk in ipairs(kata_chunks) do
              table.insert(segments, {
                text = kata_chunk,
                byte_pos = kata_byte,
                has_leading_space = first and cjk_leading_space or false,
              })
              first = false
              kata_byte = kata_byte + #kata_chunk
            end
          else
            table.insert(segments, {
              text = sub,
              byte_pos = chunk_byte,
              has_leading_space = first and cjk_leading_space or false,
            })
            first = false
          end
          chunk_byte = chunk_byte + #sub
        end
      end
    else
      -- Without BudouX, split CJK runs into individual characters.
      -- Kinsoku rules in wrap_words still apply for proper line breaking.
      local chunk_byte = cjk_run_start
      local first = true
      for char in cjk_run:gmatch "[%z\1-\127\194-\253][\128-\191]*" do
        table.insert(segments, {
          text = char,
          byte_pos = chunk_byte,
          has_leading_space = first and cjk_leading_space or false,
        })
        chunk_byte = chunk_byte + #char
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
      -- Allow line breaking after hyphens in compound words (e.g. "mission-code-job")
      -- by flushing the current word (including the hyphen) as a segment.
      if char == "-" and #current_word > 1 and current_word:sub(-2, -2):match "[%w]" then
        flush_ascii()
      end
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
function M.wrap_words(text, max_width)
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
    local seg_width = vim.api.nvim_strwidth(seg.text)
    local space_width = (seg.has_leading_space and current ~= "") and 1 or 0

    if current_width + space_width + seg_width > max_width and current ~= "" then
      -- Kinsoku 追い出し: if this segment starts with a no-break-start char,
      -- push the last segment of the current line to the next line too.
      -- Skip for multi-char ASCII words where the first char happens to be
      -- punctuation (e.g. ".gitignore" starts with "." which is in NO_BREAK_START,
      -- but the segment is a filename, not standalone punctuation).
      local fc = first_char(seg.text)
      local is_no_break_start = NO_BREAK_START[fc] and not (#fc == 1 and #seg.text > 1)
      if is_no_break_start and prev_current ~= "" then
        table.insert(wrapped_lines, prev_current)
        table.insert(line_starts, current_start)
        local sep = seg.has_leading_space and " " or ""
        current = last_seg_text .. sep .. seg.text
        current_start = last_seg_pos
        current_width = vim.api.nvim_strwidth(current)
      elseif is_no_break_start then
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
      -- break before it so it doesn't sit at line end.
      -- Use >= to be conservative: even if the next segment barely fits, subsequent
      -- 追い出し could push it away and strand this char at line end.
      if NO_BREAK_END[last_char(seg.text)] and current ~= "" then
        local next_seg = segments[i + 1]
        local next_width = next_seg and vim.api.nvim_strwidth(next_seg.text) or 0
        if current_width + space_width + seg_width + next_width >= max_width then
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

-- Export tables for content_builder (which needs them for its own logic)
M.split_ascii_syllables = split_ascii_syllables
M.NO_BREAK_START = NO_BREAK_START
M.NO_BREAK_END = NO_BREAK_END
M.split_segments = split_segments
M.is_cjk_or_kinsoku = is_cjk_or_kinsoku
M.first_char = first_char
M.last_char = last_char
M.split_by_script = split_by_script
M.utf8_codepoint = utf8_codepoint
M.script_class = script_class

return M
