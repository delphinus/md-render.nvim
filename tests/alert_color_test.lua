-- Test the colors of alert/callout headers (MdRenderAlert*)
-- Run: nvim --headless -u NONE --noplugin -l tests/alert_color_test.lua

package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local M = require "md-render"

local pass_count = 0
local fail_count = 0

local function assert_true(val, msg)
  if val then
    pass_count = pass_count + 1
  else
    fail_count = fail_count + 1
    print("FAIL: " .. msg)
  end
end

local function assert_eq(actual, expected, msg)
  assert_true(actual == expected, string.format("%s\n  expected: %s\n  actual:   %s", msg, expected, actual))
end

--- Hue (0-360) of 0xRRGGBB, in HSV terms
local function hue(c)
  local r, g, b = bit.rshift(c, 16) / 255, bit.band(bit.rshift(c, 8), 0xFF) / 255, bit.band(c, 0xFF) / 255
  local max, min = math.max(r, g, b), math.min(r, g, b)
  local d = max - min
  if d == 0 then return nil end
  local h
  if max == r then
    h = ((g - b) / d) % 6
  elseif max == g then
    h = (b - r) / d + 2
  else
    h = (r - g) / d + 4
  end
  return h * 60
end

local function fg(name)
  return vim.api.nvim_get_hl(0, { name = name }).fg
end

--- Give the diagnostic groups fixed colors, as a colorscheme would
local function set_palette(p)
  for name, color in pairs(p) do
    vim.api.nvim_set_hl(0, name, { fg = color })
  end
  for _, t in ipairs { "Note", "Tip", "Important", "Warning", "Caution", "Example" } do
    vim.api.nvim_set_hl(0, "MdRenderAlert" .. t, {})
    vim.api.nvim_set_hl(0, "MdRenderAlert" .. t .. "Bg", {})
  end
  M.setup_alert_highlights()
end

-- A palette like tokyonight-storm, where Info, Hint and Special are all cyan
set_palette {
  DiagnosticInfo = 0x0db9d7,
  DiagnosticHint = 0x1abc9c,
  DiagnosticOk = 0x73daca,
  DiagnosticWarn = 0xe0af68,
  DiagnosticError = 0xdb4b4b,
  Special = 0x2ac3de,
}

assert_eq(fg "MdRenderAlertNote", 0x0db9d7, "NOTE takes DiagnosticInfo")
assert_eq(fg "MdRenderAlertTip", 0x73daca, "TIP takes DiagnosticOk")
assert_eq(fg "MdRenderAlertWarning", 0xe0af68, "WARNING takes DiagnosticWarn")
assert_eq(fg "MdRenderAlertCaution", 0xdb4b4b, "CAUTION takes DiagnosticError")

local important = fg "MdRenderAlertImportant"
local h = hue(important)
assert_true(h and h > 250 and h < 300, string.format("IMPORTANT is purple (hue %s)", h))
assert_eq(fg "MdRenderAlertExample", important, "EXAMPLE takes the same purple as IMPORTANT")

-- The five GitHub types are told apart: no two share a color
local seen = {}
for _, t in ipairs { "Note", "Tip", "Important", "Warning", "Caution" } do
  local c = fg("MdRenderAlert" .. t)
  assert_true(not seen[c], t .. " has a color of its own")
  seen[c] = true
end

-- The purple keeps about the lightness of the colors it comes from: on a dark
-- background it must not turn into a dark violet
local function luminance(c)
  local function lin(v)
    v = v / 255
    return v <= 0.04045 and v / 12.92 or ((v + 0.055) / 1.055) ^ 2.4
  end
  return 0.2126 * lin(bit.rshift(c, 16))
    + 0.7152 * lin(bit.band(bit.rshift(c, 8), 0xFF))
    + 0.0722 * lin(bit.band(c, 0xFF))
end
local lo = math.min(luminance(0x0db9d7), luminance(0xdb4b4b))
assert_true(luminance(important) >= lo * 0.8, "IMPORTANT is not much darker than NOTE and CAUTION")

-- A colorscheme without DiagnosticError: IMPORTANT falls back to Special
vim.api.nvim_set_hl(0, "DiagnosticError", {})
set_palette { DiagnosticInfo = 0x0db9d7, Special = 0x2ac3de }
assert_eq(fg "MdRenderAlertImportant", 0x2ac3de, "without both colors, IMPORTANT takes Special")

-- A user's own color is kept (the groups are defined with default = true)
vim.api.nvim_set_hl(0, "MdRenderAlertImportant", { fg = 0x123456 })
M.setup_alert_highlights()
assert_eq(fg "MdRenderAlertImportant", 0x123456, "a user-defined MdRenderAlertImportant is kept")

print(string.format("alert_color_test: %d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
