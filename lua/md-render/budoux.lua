--- BudouX parser for Japanese text segmentation.
--- Ported to Lua from https://github.com/google/budoux
--- Original work Copyright 2021 Google LLC, licensed under Apache-2.0.
--- See LICENSE-APACHE-2.0 and NOTICE in the project root.
---
--- Uses a compact machine-learning model to find natural word boundaries in CJK text,
--- producing more readable line breaks than character-level splitting.

local M = {}

-- Boundary markers used to pad the beginning/end of text
local INVALID = "\xef\xbf\xbd" -- U+FFFD REPLACEMENT CHARACTER

--- Iterate over UTF-8 characters in a string.
---@param s string
---@return string[]
local function utf8_chars(s)
  local chars = {}
  for c in s:gmatch "[%z\1-\127\194-\253][\128-\191]*" do
    chars[#chars + 1] = c
  end
  return chars
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
--- This provides finer-grained segments so that wrap_words can break long
--- phrases like "参照してください" into "参照" + "してください".
--- Punctuation/symbols ("O" class) attach to the preceding run.
---@param chunk string
---@return string[]
function M.split_by_script(chunk)
  local chars = utf8_chars(chunk)
  if #chars <= 1 then return { chunk } end

  local sub_chunks = {}
  local current = chars[1]
  local prev_cls = script_class(chars[1])
  local kanji_run = prev_cls == "C" and 1 or 0

  for i = 2, #chars do
    local cls = script_class(chars[i])
    -- Split when transitioning FROM kanji/katakana TO a different script.
    -- Hiragana→kanji transitions are NOT split, keeping units like "お知" together.
    -- For kanji→hiragana, only split when 2+ kanji preceded (漢語 + 助詞/助動詞).
    -- Single kanji + hiragana is likely 送り仮名 (e.g. 起こる, 食べる) — don't split.
    -- Split AFTER nakaguro "・" (U+30FB): it acts as a word separator
    -- in katakana compounds (e.g. "ユニグラム・バイグラム" → "ユニグラム・" | "バイグラム").
    -- The "・" stays at the end of the preceding chunk (it's in NO_BREAK_START).
    local should_split = false
    if chars[i - 1] == "・" and current ~= "・" then
      should_split = true
    end
    if cls ~= "O" and cls ~= prev_cls then
      if prev_cls == "K" then
        should_split = true
      elseif prev_cls == "C" and cls == "H" then
        should_split = kanji_run >= 2
      elseif prev_cls == "C" then
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

--- Parse text into chunks using the BudouX model.
--- Each chunk represents a segment that should not be broken across lines.
---@param model table BudouX model (e.g. require("md-render.budoux_ja"))
---@param text string Input text
---@return string[] chunks
function M.parse(model, text)
  local chars = utf8_chars(text)
  if #chars <= 3 then
    return { text }
  end

  local chunks = {}
  local chunk_start = 1

  -- We examine each position i (between chars[i-1] and chars[i]).
  -- Features use a window of 6 characters centered around the boundary.
  for i = 2, #chars do
    local p1 = chars[i - 3] or INVALID
    local p2 = chars[i - 2] or INVALID
    local p3 = chars[i - 1] or INVALID
    local w1 = chars[i]
    local w2 = chars[i + 1] or INVALID
    local w3 = chars[i + 2] or INVALID

    local score = -model.base_score

    -- Unigram features
    local uw1 = model.UW1
    local uw2 = model.UW2
    local uw3 = model.UW3
    local uw4 = model.UW4
    local uw5 = model.UW5
    local uw6 = model.UW6
    if uw1 then score = score + (uw1[p1] or 0) end
    if uw2 then score = score + (uw2[p2] or 0) end
    if uw3 then score = score + (uw3[p3] or 0) end
    if uw4 then score = score + (uw4[w1] or 0) end
    if uw5 then score = score + (uw5[w2] or 0) end
    if uw6 then score = score + (uw6[w3] or 0) end

    -- Bigram features
    local bw1 = model.BW1
    local bw2 = model.BW2
    local bw3 = model.BW3
    if bw1 then score = score + (bw1[p2 .. p3] or 0) end
    if bw2 then score = score + (bw2[p3 .. w1] or 0) end
    if bw3 then score = score + (bw3[w1 .. w2] or 0) end

    -- Trigram features
    local tw1 = model.TW1
    local tw2 = model.TW2
    local tw3 = model.TW3
    local tw4 = model.TW4
    if tw1 then score = score + (tw1[p1 .. p2 .. p3] or 0) end
    if tw2 then score = score + (tw2[p2 .. p3 .. w1] or 0) end
    if tw3 then score = score + (tw3[p3 .. w1 .. w2] or 0) end
    if tw4 then score = score + (tw4[w1 .. w2 .. w3] or 0) end

    if score > 0 then
      -- Collect the chunk from chunk_start to i-1
      local parts = {}
      for j = chunk_start, i - 1 do
        parts[#parts + 1] = chars[j]
      end
      chunks[#chunks + 1] = table.concat(parts)
      chunk_start = i
    end
  end

  -- Remaining tail
  local parts = {}
  for j = chunk_start, #chars do
    parts[#parts + 1] = chars[j]
  end
  chunks[#chunks + 1] = table.concat(parts)

  return chunks
end

return M
