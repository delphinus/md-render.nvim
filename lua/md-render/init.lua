local M = {}

--- Alert type definitions: base highlight group for each alert type
local ALERT_HL_BASES = {
  Note = "DiagnosticInfo",
  Tip = "DiagnosticHint",
  Important = "Special",
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
  Example = "Special",
  Quote = "Comment",
}

--- Blend two colors by alpha (0.0 = bg, 1.0 = fg)
---@param fg integer foreground color (0xRRGGBB)
---@param bg integer background color (0xRRGGBB)
---@param alpha number blend factor (0.0-1.0)
---@return integer blended color
local function blend_color(fg, bg, alpha)
  local r = math.floor(bit.rshift(fg, 16) * alpha + bit.rshift(bg, 16) * (1 - alpha) + 0.5)
  local g = math.floor(bit.band(bit.rshift(fg, 8), 0xFF) * alpha + bit.band(bit.rshift(bg, 8), 0xFF) * (1 - alpha) + 0.5)
  local b = math.floor(bit.band(fg, 0xFF) * alpha + bit.band(bg, 0xFF) * (1 - alpha) + 0.5)
  return bit.lshift(r, 16) + bit.lshift(g, 8) + b
end

--- Set up heading highlight groups (MdRenderH1..MdRenderH6)
function M.setup_heading_highlights()
  for level = 1, 6 do
    local hl_name = "MdRenderH" .. level
    local ts_name = "@markup.heading." .. level .. ".markdown"
    local ts_hl = vim.api.nvim_get_hl(0, { name = ts_name, link = false })
    if ts_hl.fg then
      vim.api.nvim_set_hl(0, hl_name, { fg = ts_hl.fg, bold = true, default = true })
    else
      vim.api.nvim_set_hl(0, hl_name, { link = "Title", default = true })
    end
  end
end

--- Set up alert highlight groups (MdRenderAlert* and MdRenderAlert*Bg)
function M.setup_alert_highlights()
  local normal_hl = vim.api.nvim_get_hl(0, { name = "NormalFloat", link = false })
  if not normal_hl.bg then
    normal_hl = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  end
  local normal_bg = normal_hl.bg or 0x1e1e2e

  for name, base_hl_name in pairs(ALERT_HL_BASES) do
    local base_hl = vim.api.nvim_get_hl(0, { name = base_hl_name, link = false })
    local fg = base_hl.fg or 0xFFFFFF
    vim.api.nvim_set_hl(0, "MdRenderAlert" .. name, { fg = fg, bold = true, default = true })
    vim.api.nvim_set_hl(0, "MdRenderAlert" .. name .. "Bg", { bg = blend_color(fg, normal_bg, 0.1), default = true })
  end
end

--- Set up <details> highlight groups (MdRenderDetailsBg)
function M.setup_details_highlights()
  local normal_hl = vim.api.nvim_get_hl(0, { name = "NormalFloat", link = false })
  if not normal_hl.bg then
    normal_hl = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  end
  local normal_bg = normal_hl.bg or 0x1e1e2e

  local border_hl = vim.api.nvim_get_hl(0, { name = "FloatBorder", link = false })
  local fg = border_hl.fg or 0x888888
  local bg = blend_color(fg, normal_bg, 0.1)
  vim.api.nvim_set_hl(0, "MdRenderDetailsBg", { bg = bg, default = true })
  vim.api.nvim_set_hl(0, "MdRenderDetailsBar", { fg = fg, bg = bg, default = true })
end

--- Set up all highlight groups used by md-render
function M.setup_highlights()
  -- Obsidian ==highlight== marker
  vim.api.nvim_set_hl(0, "MdRenderHighlight", { bg = "#3b3600", fg = "#ffec80", default = true })
  -- Obsidian #tag
  vim.api.nvim_set_hl(0, "MdRenderTag", { link = "Label", default = true })
  -- Inline/block math
  vim.api.nvim_set_hl(0, "MdRenderMath", { link = "Special", default = true })
  M.setup_heading_highlights()
  M.setup_alert_highlights()
  M.setup_details_highlights()
end

-- Re-export submodules (preview is lazy-loaded to avoid circular dependency)
M.ContentBuilder = require("md-render.content_builder").ContentBuilder
M.Markdown = require "md-render.markdown"
M.MarkdownTable = require "md-render.markdown_table"
M.FloatWin = require "md-render.float_win"
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
