local M = {}

--- Alert type definitions: where each alert type takes its color from.
--- A string names a highlight group whose fg is used as is. A table with
--- `between` names two groups; the color is the hue halfway between them,
--- going the way that passes through magenta (see `hue_between`).
---
--- The five GitHub types follow GitHub's own palette: blue, green, purple,
--- yellow, red. No highlight group is purple in every colorscheme
--- (`Statement` is purple in some, blue, red or gray in others), so the
--- purple is made from the blue and the red of the diagnostics, which every
--- colorscheme defines.
local ALERT_HL_BASES = {
  Note = "DiagnosticInfo",
  Tip = "DiagnosticOk",
  Important = { between = { "DiagnosticInfo", "DiagnosticError" } },
  Warning = "DiagnosticWarn",
  Caution = "DiagnosticError",
  -- Obsidian additional types
  Abstract = "DiagnosticHint",
  Todo = "DiagnosticInfo",
  Success = "DiagnosticOk",
  Question = "DiagnosticWarn",
  Failure = "DiagnosticError",
  Danger = "DiagnosticError",
  Bug = "DiagnosticError",
  Example = { between = { "DiagnosticInfo", "DiagnosticError" } },
  Quote = "Comment",
}

--- sRGB channel (0-1) to linear light, and back
local function to_linear(v)
  return v <= 0.04045 and v / 12.92 or ((v + 0.055) / 1.055) ^ 2.4
end
local function from_linear(v)
  return v <= 0.0031308 and v * 12.92 or 1.055 * v ^ (1 / 2.4) - 0.055
end

--- 0xRRGGBB to OKLCH (https://bottosson.github.io/posts/oklab/).
--- OKLCH is used rather than HSL because its lightness follows what the eye
--- sees: in HSL a purple at the same lightness as a cyan looks far darker.
---@param c integer 0xRRGGBB
---@return number l lightness 0-1
---@return number c chroma
---@return number h hue in degrees
local function rgb_to_oklch(c)
  local r = to_linear(bit.rshift(c, 16) / 255)
  local g = to_linear(bit.band(bit.rshift(c, 8), 0xFF) / 255)
  local b = to_linear(bit.band(c, 0xFF) / 255)
  local l_ = (0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b) ^ (1 / 3)
  local m_ = (0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b) ^ (1 / 3)
  local s_ = (0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b) ^ (1 / 3)
  local L = 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_
  local A = 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_
  local B = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_
  return L, math.sqrt(A * A + B * B), math.deg(math.atan2(B, A)) % 360
end

---@param L number
---@param C number
---@param h number degrees
---@return integer 0xRRGGBB (out-of-gamut channels are clamped)
local function oklch_to_rgb(L, C, h)
  local A, B = C * math.cos(math.rad(h)), C * math.sin(math.rad(h))
  local l_ = (L + 0.3963377774 * A + 0.2158037573 * B) ^ 3
  local m_ = (L - 0.1055613458 * A - 0.0638541728 * B) ^ 3
  local s_ = (L - 0.0894841775 * A - 1.2914855480 * B) ^ 3
  local r = 4.0767416621 * l_ - 3.3077115913 * m_ + 0.2309699292 * s_
  local g = -1.2684380046 * l_ + 2.6097574011 * m_ - 0.3413193965 * s_
  local b = -0.0041960863 * l_ - 0.7034186147 * m_ + 1.7076147010 * s_
  local function byte(v)
    v = from_linear(math.max(0, math.min(1, v)))
    return math.floor(v * 255 + 0.5)
  end
  return bit.lshift(byte(r), 16) + bit.lshift(byte(g), 8) + byte(b)
end

--- The color halfway between two colors in hue, going up from the first
--- hue to the second. From blue (about 230° in OKLCH) up to red (about 25°,
--- i.e. 385°) the way passes through purple, so the midpoint is a purple
--- (about 310°). Lightness and chroma are averaged.
---@param from integer 0xRRGGBB
---@param to integer 0xRRGGBB
---@return integer 0xRRGGBB
local function hue_between(from, to)
  local l1, c1, h1 = rgb_to_oklch(from)
  local l2, c2, h2 = rgb_to_oklch(to)
  if h2 <= h1 then h2 = h2 + 360 end
  return oklch_to_rgb((l1 + l2) / 2, (c1 + c2) / 2, ((h1 + h2) / 2) % 360)
end

--- The fg color an alert type takes from the current colorscheme.
---@param base string|{between: string[]}
---@return integer 0xRRGGBB
local function alert_fg(base)
  if type(base) == "string" then return vim.api.nvim_get_hl(0, { name = base, link = false }).fg or 0xFFFFFF end
  local a = vim.api.nvim_get_hl(0, { name = base.between[1], link = false }).fg
  local b = vim.api.nvim_get_hl(0, { name = base.between[2], link = false }).fg
  -- Without both colors there is no hue to take the middle of
  if not (a and b) then return vim.api.nvim_get_hl(0, { name = "Special", link = false }).fg or 0xFFFFFF end
  return hue_between(a, b)
end

--- Blend two colors by alpha (0.0 = bg, 1.0 = fg)
---@param fg integer foreground color (0xRRGGBB)
---@param bg integer background color (0xRRGGBB)
---@param alpha number blend factor (0.0-1.0)
---@return integer blended color
local function blend_color(fg, bg, alpha)
  local r = math.floor(bit.rshift(fg, 16) * alpha + bit.rshift(bg, 16) * (1 - alpha) + 0.5)
  local g =
    math.floor(bit.band(bit.rshift(fg, 8), 0xFF) * alpha + bit.band(bit.rshift(bg, 8), 0xFF) * (1 - alpha) + 0.5)
  local b = math.floor(bit.band(fg, 0xFF) * alpha + bit.band(bg, 0xFF) * (1 - alpha) + 0.5)
  return bit.lshift(r, 16) + bit.lshift(g, 8) + b
end

--- Set up heading highlight groups (MdRenderH1..MdRenderH6).
--- All attributes from `@markup.heading.<level>.markdown` are carried over
--- (including `bg`, `italic`, `underline`, etc.) so colorschemes that paint
--- a heading background (e.g. tokyonight) render the same way in the
--- preview buffer as in the source buffer. `bold` is forced as a fallback
--- for colorschemes that omit it.
function M.setup_heading_highlights()
  for level = 1, 6 do
    local hl_name = "MdRenderH" .. level
    local ts_name = "@markup.heading." .. level .. ".markdown"
    local ts_hl = vim.api.nvim_get_hl(0, { name = ts_name, link = false })
    if ts_hl.fg or ts_hl.bg then
      ts_hl.bold = true
      ts_hl.default = true
      vim.api.nvim_set_hl(0, hl_name, ts_hl)
    else
      vim.api.nvim_set_hl(0, hl_name, { link = "Title", default = true })
    end
  end
end

--- Set up alert highlight groups (MdRenderAlert* and MdRenderAlert*Bg)
function M.setup_alert_highlights()
  local normal_hl = vim.api.nvim_get_hl(0, { name = "NormalFloat", link = false })
  if not normal_hl.bg then normal_hl = vim.api.nvim_get_hl(0, { name = "Normal", link = false }) end
  local normal_bg = normal_hl.bg or 0x1e1e2e

  for name, base in pairs(ALERT_HL_BASES) do
    local fg = alert_fg(base)
    vim.api.nvim_set_hl(0, "MdRenderAlert" .. name, { fg = fg, bold = true, default = true })
    vim.api.nvim_set_hl(0, "MdRenderAlert" .. name .. "Bg", { bg = blend_color(fg, normal_bg, 0.1), default = true })
  end
end

--- Set up <details> highlight groups (MdRenderDetailsBg)
function M.setup_details_highlights()
  local normal_hl = vim.api.nvim_get_hl(0, { name = "NormalFloat", link = false })
  if not normal_hl.bg then normal_hl = vim.api.nvim_get_hl(0, { name = "Normal", link = false }) end
  local normal_bg = normal_hl.bg or 0x1e1e2e

  local border_hl = vim.api.nvim_get_hl(0, { name = "FloatBorder", link = false })
  local fg = border_hl.fg or 0x888888
  local bg = blend_color(fg, normal_bg, 0.1)
  vim.api.nvim_set_hl(0, "MdRenderDetailsBg", { bg = bg, default = true })
  vim.api.nvim_set_hl(0, "MdRenderDetailsBar", { fg = fg, bg = bg, default = true })
end

--- Set up all highlight groups used by md-render
function M.setup_highlights()
  -- Inline formatting fallbacks (many colorschemes define Bold but not Italic)
  vim.api.nvim_set_hl(0, "Bold", { bold = true, default = true })
  vim.api.nvim_set_hl(0, "Italic", { italic = true, default = true })
  -- Obsidian ==highlight== marker
  vim.api.nvim_set_hl(0, "MdRenderHighlight", { bg = "#3b3600", fg = "#ffec80", default = true })
  -- Obsidian #tag
  vim.api.nvim_set_hl(0, "MdRenderTag", { link = "Label", default = true })
  -- Inline/block math
  vim.api.nvim_set_hl(0, "MdRenderMath", { link = "Special", default = true })
  -- Internal anchor links (#heading)
  vim.api.nvim_set_hl(0, "MdRenderLinkAnchor", { link = "DiagnosticHint", default = true })
  -- Obsidian wikilinks ([[...]])
  vim.api.nvim_set_hl(0, "MdRenderLinkObsidian", { link = "Special", default = true })
  -- MdRenderSplit shadow cursor (marks the unfocused side's matching line)
  vim.api.nvim_set_hl(0, "MdRenderShadowCursor", { link = "CursorLine", default = true })
  -- The caption above an image while the cursor or the mouse is on the image,
  -- and the hint at its end that says the image can be enlarged
  vim.api.nvim_set_hl(0, "MdRenderImageZoomCaption", { link = "Visual", default = true })
  vim.api.nvim_set_hl(0, "MdRenderImageZoomHint", { link = "Special", default = true })
  -- Preview float footer (status info drawn on the bottom border).
  -- The unfilled part of the progress bar follows FloatBorder so it blends
  -- into the border it is drawn on.
  vim.api.nvim_set_hl(0, "MdRenderFooter", { link = "FloatFooter", default = true })
  vim.api.nvim_set_hl(0, "MdRenderFooterName", { link = "FloatTitle", default = true })
  vim.api.nvim_set_hl(0, "MdRenderFooterBar", { link = "FloatTitle", default = true })
  vim.api.nvim_set_hl(0, "MdRenderFooterBarEmpty", { link = "FloatBorder", default = true })
  M.setup_heading_highlights()
  M.setup_alert_highlights()
  M.setup_details_highlights()
  M.setup_image_placeholder_highlight()
  M.setup_inline_code_highlight()
end

--- Set up image placeholder highlight group (MdRenderImagePlaceholder)
function M.setup_image_placeholder_highlight()
  local normal_hl = vim.api.nvim_get_hl(0, { name = "NormalFloat", link = false })
  if not normal_hl.bg then normal_hl = vim.api.nvim_get_hl(0, { name = "Normal", link = false }) end
  local normal_bg = normal_hl.bg or 0x1e1e2e
  local comment_hl = vim.api.nvim_get_hl(0, { name = "Comment", link = false })
  local fg = comment_hl.fg or 0x888888
  local bg = blend_color(fg, normal_bg, 0.12)
  vim.api.nvim_set_hl(0, "MdRenderImagePlaceholder", { fg = fg, bg = bg, default = true })
  -- The reason a download failed, on the same background
  local error_hl = vim.api.nvim_get_hl(0, { name = "DiagnosticError", link = false })
  vim.api.nvim_set_hl(0, "MdRenderImageError", { fg = error_hl.fg or 0xdb4b4b, bg = bg, default = true })
end

--- Set up inline code highlight group (MdRenderInlineCode).
--- fg follows String so the existing color cue is preserved; bg is a subtle
--- neutral tint (Comment fg blended with Normal bg) so backtick spans stay
--- visually distinct from headings even when the colorscheme paints both green.
function M.setup_inline_code_highlight()
  local normal_hl = vim.api.nvim_get_hl(0, { name = "NormalFloat", link = false })
  if not normal_hl.bg then normal_hl = vim.api.nvim_get_hl(0, { name = "Normal", link = false }) end
  local normal_bg = normal_hl.bg or 0x1e1e2e
  local comment_hl = vim.api.nvim_get_hl(0, { name = "Comment", link = false })
  local tint = comment_hl.fg or 0x888888
  local bg = blend_color(tint, normal_bg, 0.3)
  local string_hl = vim.api.nvim_get_hl(0, { name = "String", link = false })
  if string_hl.fg then
    vim.api.nvim_set_hl(0, "MdRenderInlineCode", { fg = string_hl.fg, bg = bg, default = true })
  else
    vim.api.nvim_set_hl(0, "MdRenderInlineCode", { bg = bg, default = true })
  end
end

-- Re-export submodules (preview is lazy-loaded to avoid circular dependency)
M.ContentBuilder = require("md-render.content_builder").ContentBuilder
M.Markdown = require "md-render.markdown"
M.MarkdownTable = require "md-render.markdown_table"
M.FloatWin = require "md-render.float_win"
M.TabWin = require "md-render.tab_win"
M.display_utils = require "md-render.display_utils"

-- Expose for testing
M._blend_color = blend_color

return setmetatable(M, {
  __index = function(t, k)
    if k == "preview" then
      t.preview = require "md-render.preview"
      return t.preview
    end
  end,
})
