--- Icon resolution for md-render.nvim
--- Provides file-type-specific Nerd Font icons via nvim-web-devicons, mini.icons,
--- or a built-in fallback table.
local M = {}

--- Nerd Font icon mapping for common file extensions.
--- Used as fallback when nvim-web-devicons / mini.icons is not available.
---@type table<string, string>
local file_ext_icons = {
  lua = "",
  py = "",
  js = "",
  ts = "",
  jsx = "",
  tsx = "",
  rb = "",
  go = "",
  rs = "",
  c = "",
  cpp = "",
  h = "",
  hpp = "",
  cs = "󰌛",
  java = "",
  kt = "",
  swift = "",
  php = "",
  r = "",
  sh = "",
  bash = "",
  zsh = "",
  fish = "",
  ps1 = "󰨊",
  vim = "",
  html = "",
  css = "",
  scss = "",
  sass = "",
  less = "",
  json = "",
  yaml = "",
  yml = "",
  toml = "",
  xml = "󰗀",
  md = "",
  markdown = "",
  txt = "󰈙",
  sql = "",
  graphql = "",
  dockerfile = "",
  docker = "",
  makefile = "",
  cmake = "",
  ex = "",
  exs = "",
  erl = "",
  hs = "",
  ml = "",
  clj = "",
  scala = "",
  dart = "",
  vue = "",
  svelte = "",
  zig = "",
  nim = "",
  perl = "",
  pl = "",
  diff = "",
  patch = "",
  lock = "",
  conf = "",
  cfg = "",
  ini = "",
  env = "",
  csv = "",
  svg = "󰜡",
  png = "",
  jpg = "",
  jpeg = "",
  gif = "",
  pdf = "",
  zip = "",
  gz = "",
  tar = "",
  tf = "󱁢",
  nix = "",
}

--- Special filename → icon mapping (case-insensitive basenames).
---@type table<string, string>
local file_name_icons = {
  makefile = "",
  dockerfile = "",
  gemfile = "",
  rakefile = "",
  procfile = "",
  vagrantfile = "⍱",
  [".gitignore"] = "",
  [".gitconfig"] = "",
  [".editorconfig"] = "",
  [".env"] = "",
}

--- Default image icon (Nerd Font)
local DEFAULT_IMAGE_ICON = "󰋩"

--- Pad a Nerd Font icon glyph so it always occupies 2 display cells.
--- When setcellwidths makes the glyph width 1, an extra space is appended.
---@param icon string single icon character
---@return string
function M.pad_icon(icon)
  if vim.fn.strdisplaywidth(icon) == 1 then
    return icon .. " "
  end
  return icon
end

--- Get a Nerd Font icon and highlight group for a filename.
--- Tries nvim-web-devicons first, then mini.icons, then the built-in table.
---@param filename string
---@return string icon
---@return string|nil hl_group highlight group for the icon (nil if no color info)
function M.get_file_icon(filename)
  -- Try nvim-web-devicons
  local ok, devicons = pcall(require, "nvim-web-devicons")
  if ok then
    local icon, hl = devicons.get_icon(filename, nil, { default = false })
    if icon then
      return icon, hl
    end
  end

  -- Try mini.icons
  local ok2, mini_icons = pcall(require, "mini.icons")
  if ok2 then
    local ok3, icon, hl = pcall(mini_icons.get, "file", filename)
    if ok3 and icon then
      return icon, hl
    end
  end

  -- Built-in fallback: check special filenames first
  local base = filename:match("[^/]+$") or filename
  local base_lower = base:lower()
  if file_name_icons[base_lower] then
    return file_name_icons[base_lower], nil
  end

  -- Then check extension
  local ext = base:match("%.([^.]+)$")
  if ext then
    local icon = file_ext_icons[ext:lower()]
    if icon then
      return icon, nil
    end
  end

  -- Default file icon
  return "", nil
end

--- Get a Nerd Font icon and highlight group for an image path/URL.
--- Uses file extension to find a type-specific icon (e.g.  for .png),
--- falling back to a generic image icon.
---@param path string image path or URL
---@return string icon
---@return string|nil hl_group highlight group for the icon (nil if no color info)
function M.get_image_icon(path)
  -- Extract basename from path or URL (strip query string / fragment)
  local clean = path:gsub("[?#].*$", "")
  local base = clean:match("([^/]+)$") or clean
  if base ~= "" then
    local icon, hl = M.get_file_icon(base)
    if icon ~= "" then
      return icon, hl
    end
  end
  return DEFAULT_IMAGE_ICON, nil
end

return M
