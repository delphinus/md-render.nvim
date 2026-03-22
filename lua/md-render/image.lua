--- Image display support for md-render.nvim
--- Uses Kitty Graphics Protocol to display images in terminal.
--- Supports PNG, JPEG, and WebP formats.
---
--- Two-phase approach:
---   1. transmit_image(): send image data to terminal with a=t (store, no display)
---   2. put_image(): display stored image at cursor with a=p (lightweight, repeatable)
--- This allows re-displaying images after redraws without retransmitting data.

local M = {}

local uv = vim.uv or vim.loop
local ffi = require("ffi")

-- ============================================================================
-- TTY setup (cached at module level)
-- ============================================================================

local _tty_path = nil
local _tty_detected = false

---@return string?
local function get_tty_path()
  if _tty_detected then return _tty_path end
  _tty_detected = true
  local handle = io.popen("tty 2>/dev/null")
  if handle then
    _tty_path = vim.fn.trim(handle:read("*a"))
    handle:close()
    if _tty_path == "" or _tty_path == "not a tty" then _tty_path = nil end
  end
  return _tty_path
end

---@param data string
local function term_write(data)
  if data == "" then return end
  local tty = get_tty_path()
  if tty then
    local f = io.open(tty, "w")
    if f then
      f:write(data)
      f:close()
      return
    end
  end
  local stdout = uv.new_tty(1, false)
  if stdout then
    stdout:write(data)
    stdout:close()
  end
end

local function move_cursor(x, y)
  term_write("\x1b[" .. y .. ";" .. x .. "H")
  uv.sleep(1)
end

-- ============================================================================
-- Terminal cell size detection via TIOCGWINSZ
-- ============================================================================

local _ffi_declared = false
local function ensure_ffi()
  if _ffi_declared then return end
  _ffi_declared = true
  ffi.cdef([[
    typedef struct { unsigned short row; unsigned short col; unsigned short xpixel; unsigned short ypixel; } winsize;
    int ioctl(int, unsigned long, ...);
  ]])
end

local TIOCGWINSZ = (vim.fn.has("mac") == 1 or vim.fn.has("bsd") == 1) and 0x40087468 or 0x5413

---@return { cell_w: number, cell_h: number }?
function M.get_cell_size()
  ensure_ffi()
  local sz = ffi.new("winsize")
  if ffi.C.ioctl(1, TIOCGWINSZ, sz) ~= 0 then return nil end
  local xpixel, ypixel = sz.xpixel, sz.ypixel
  if xpixel == 0 or ypixel == 0 then
    xpixel = sz.col * 8
    ypixel = sz.row * 16
  end
  return { cell_w = xpixel / sz.col, cell_h = ypixel / sz.row }
end

-- ============================================================================
-- Image dimension detection from file headers
-- ============================================================================

local function read_header(path, n)
  local f = io.open(path, "rb")
  if not f then return nil end
  local data = f:read(n)
  f:close()
  return data
end

local function be16(s, o) return s:byte(o) * 256 + s:byte(o + 1) end
local function be32(s, o)
  return s:byte(o) * 16777216 + s:byte(o + 1) * 65536
       + s:byte(o + 2) * 256 + s:byte(o + 3)
end
local function le16(s, o) return s:byte(o) + s:byte(o + 1) * 256 end
local function le24(s, o) return s:byte(o) + s:byte(o + 1) * 256 + s:byte(o + 2) * 65536 end

local function png_dimensions(path)
  local h = read_header(path, 24)
  if not h or #h < 24 or h:sub(1, 4) ~= "\137PNG" then return nil end
  return be32(h, 17), be32(h, 21)
end

local function jpeg_dimensions(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  if not data or #data < 2 or data:byte(1) ~= 0xFF or data:byte(2) ~= 0xD8 then return nil end
  local pos = 3
  while pos < #data - 1 do
    if data:byte(pos) ~= 0xFF then pos = pos + 1; goto continue end
    local marker = data:byte(pos + 1)
    if marker >= 0xC0 and marker <= 0xCF and marker ~= 0xC4 and marker ~= 0xC8 then
      if pos + 9 <= #data then
        return be16(data, pos + 7), be16(data, pos + 5)
      end
    end
    if pos + 3 <= #data then
      pos = pos + 2 + be16(data, pos + 2)
    else
      break
    end
    ::continue::
  end
  return nil
end

local function webp_dimensions(path)
  local h = read_header(path, 30)
  if not h or #h < 16 or h:sub(1, 4) ~= "RIFF" or h:sub(9, 12) ~= "WEBP" then return nil end
  local chunk_type = h:sub(13, 16)
  if chunk_type == "VP8 " and #h >= 30 then
    if h:byte(24) == 0x9D and h:byte(25) == 0x01 and h:byte(26) == 0x2A then
      return bit.band(le16(h, 27), 0x3FFF), bit.band(le16(h, 29), 0x3FFF)
    end
  elseif chunk_type == "VP8L" and #h >= 26 then
    if h:byte(22) == 0x2F then
      local b = le16(h, 23) + le16(h, 25) * 65536
      return bit.band(b, 0x3FFF) + 1, bit.band(bit.rshift(b, 14), 0x3FFF) + 1
    end
  elseif chunk_type == "VP8X" and #h >= 30 then
    return le24(h, 25) + 1, le24(h, 28) + 1
  end
  return nil
end

---@param path string
---@return integer? width, integer? height
function M.image_dimensions(path)
  local h = read_header(path, 4)
  if not h then return nil end
  if h:sub(1, 4) == "\137PNG" then return png_dimensions(path) end
  if h:byte(1) == 0xFF and h:byte(2) == 0xD8 then return jpeg_dimensions(path) end
  if h:sub(1, 4) == "RIFF" then return webp_dimensions(path) end
  return nil
end

function M.is_png(path)
  local h = read_header(path, 4)
  return h ~= nil and h:sub(1, 4) == "\137PNG"
end

-- ============================================================================
-- Kitty Graphics Protocol support detection
-- ============================================================================

local _kitty_supported = nil

function M.supports_kitty()
  if _kitty_supported ~= nil then return _kitty_supported end
  local term = vim.env.TERM_PROGRAM
  if term then
    local supported = { ["WezTerm"] = true, ["kitty"] = true, ["ghostty"] = true }
    if supported[term] then
      _kitty_supported = true
      return true
    end
  end
  _kitty_supported = false
  return false
end

function M.reset_cache()
  _kitty_supported = nil
  _tty_path = nil
  _tty_detected = false
end

-- ============================================================================
-- Image conversion
-- ============================================================================

---@param path string
---@return string? png_path, boolean is_temp
function M.ensure_png(path)
  if M.is_png(path) then return path, false end
  local tmp = os.tmpname() .. ".png"
  local result = vim.system({ "magick", path, "-resize", "2000x2000>", tmp }, { text = true }):wait()
  if result.code ~= 0 then return nil, false end
  return tmp, true
end

---@param img_w integer
---@param img_h integer
---@param max_cols integer
---@param max_rows integer
---@return integer cols, integer rows
function M.calc_display_size(img_w, img_h, max_cols, max_rows)
  local cell = M.get_cell_size()
  if not cell then return math.min(20, max_cols), math.min(10, max_rows) end
  local cols = math.ceil(img_w / cell.cell_w)
  local rows = math.ceil(img_h / cell.cell_h)
  if cols > max_cols then
    local scale = max_cols / cols
    cols = max_cols
    rows = math.ceil(rows * scale)
  end
  if rows > max_rows then
    local scale = max_rows / rows
    rows = max_rows
    cols = math.ceil(cols * scale)
  end
  return cols, rows
end

-- ============================================================================
-- Two-phase image display: transmit + put
-- ============================================================================

local _image_id = 100

--- Transmit image data to terminal (store without displaying).
--- The image can then be displayed cheaply with put_image().
---@param path string absolute path to image file
---@return integer? image_id
---@return boolean? is_temp  true if a temp PNG was created
function M.transmit_image(path)
  if not M.supports_kitty() then return nil end
  if not get_tty_path() then return nil end

  local png_path, is_temp = M.ensure_png(path)
  if not png_path then return nil end

  _image_id = _image_id + 1
  local id = _image_id

  local b64_path = vim.base64.encode(png_path)
  local t = is_temp and "t" or "f"

  -- a=t: transmit and store, q=2: suppress all responses
  local message = string.format(
    "\x1b_Ga=t,f=100,t=%s,i=%d,q=2;%s\x1b\\",
    t, id, b64_path
  )
  term_write(message)

  return id
end

--- Display a previously transmitted image at a screen position.
--- This is lightweight and can be called repeatedly after redraws.
---@param image_id integer  Kitty image ID from transmit_image()
---@param win integer  window handle
---@param row integer  0-indexed row within window content
---@param col integer  0-indexed column within window content
---@param display_cols integer
---@param display_rows integer
function M.put_image(image_id, win, row, col, display_cols, display_rows)
  if not M.supports_kitty() then return end
  if not vim.api.nvim_win_is_valid(win) then return end

  local win_pos = vim.api.nvim_win_get_position(win)
  local screen_row = win_pos[1] + row + 2
  local screen_col = win_pos[2] + col + 2

  -- Check if the image row is within visible window area
  local win_height = vim.api.nvim_win_get_height(win)
  local topline = vim.fn.getwininfo(win)[1].topline - 1  -- 0-indexed
  local visible_start = topline
  local visible_end = topline + win_height

  if row < visible_start or row >= visible_end then return end

  -- Adjust screen position for scroll offset
  local visual_row = row - topline
  screen_row = win_pos[1] + visual_row + 2

  -- a=p: display (put) a previously transmitted image
  local message = string.format(
    "\x1b_Ga=p,i=%d,c=%d,r=%d,C=1,q=2\x1b\\",
    image_id, display_cols, display_rows
  )

  term_write("\x1b[s")
  move_cursor(screen_col, screen_row)
  term_write(message)
  term_write("\x1b[u")
end

--- Delete a stored image from terminal memory
---@param image_id integer
function M.delete_image(image_id)
  if not M.supports_kitty() then return end
  term_write(string.format("\x1b_Ga=d,d=i,i=%d\x1b\\", image_id))
end

--- Delete multiple images
---@param image_ids integer[]
function M.delete_images(image_ids)
  if not M.supports_kitty() or #image_ids == 0 then return end
  local parts = {}
  for _, id in ipairs(image_ids) do
    table.insert(parts, string.format("\x1b_Ga=d,d=i,i=%d\x1b\\", id))
  end
  term_write(table.concat(parts))
end

return M
