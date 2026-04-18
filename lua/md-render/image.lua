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
local tty_mod = require("md-render.tty")

-- ============================================================================
-- Batched terminal writes
-- ============================================================================

local _batch_buffer = nil
local _batch_stack = nil

--- @return string?
local function get_tty_path()
  if M._test_tty_path ~= nil then return M._test_tty_path end
  return tty_mod.get_tty_path()
end

---@param data string
local function term_write(data)
  if data == "" then return end
  if _batch_buffer then
    table.insert(_batch_buffer, data)
    return
  end
  if M._test_write then
    M._test_write(data)
    return
  end
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
  if not _batch_buffer then
    uv.sleep(1)
  end
end

--- Start batching terminal writes. Subsequent term_write calls accumulate
--- in memory instead of writing to the terminal immediately.
--- Supports nesting: inner batches append to the parent batch on flush.
function M.begin_batch()
  if _batch_buffer then
    -- Already batching: push current buffer onto stack
    _batch_stack = _batch_stack or {}
    table.insert(_batch_stack, _batch_buffer)
  end
  _batch_buffer = {}
end

--- Flush all accumulated terminal writes as a single write operation.
--- If nested, appends to the parent batch instead of writing to terminal.
function M.flush_batch()
  if not _batch_buffer then return end
  local data = table.concat(_batch_buffer)
  -- Pop parent batch if nested
  if _batch_stack and #_batch_stack > 0 then
    _batch_buffer = table.remove(_batch_stack)
    if data ~= "" then
      table.insert(_batch_buffer, data)
    end
  else
    _batch_buffer = nil
    if data ~= "" then
      term_write(data)
    end
  end
end

-- ============================================================================
-- Synchronized terminal update (DEC private mode 2026)
-- ============================================================================

--- Begin synchronized update. The terminal buffers all subsequent output
--- and renders it atomically when end_sync_update() is called.
--- Supported by WezTerm, Kitty, foot, and others.
function M.begin_sync_update()
  term_write("\x1b[?2026h")
end

--- End synchronized update and flush buffered output to screen.
function M.end_sync_update()
  term_write("\x1b[?2026l")
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
    int open(const char *path, int flags);
    int close(int fd);
  ]])
end

local TIOCGWINSZ = (vim.fn.has("mac") == 1 or vim.fn.has("bsd") == 1) and 0x40087468 or 0x5413

---@return { cell_w: number, cell_h: number }?
function M.get_cell_size()
  if M._test_cell_size then return M._test_cell_size end
  ensure_ffi()
  local sz = ffi.new("winsize")
  -- Try stdout (fd 1) first; after :restart it may be /dev/null,
  -- so fall back to opening the discovered TTY device.
  if ffi.C.ioctl(1, TIOCGWINSZ, sz) ~= 0 then
    local tty = get_tty_path()
    if not tty then return nil end
    local fd = ffi.C.open(tty, 0) -- O_RDONLY
    if fd < 0 then return nil end
    local rc = ffi.C.ioctl(fd, TIOCGWINSZ, sz)
    ffi.C.close(fd)
    if rc ~= 0 then return nil end
  end
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

local function gif_dimensions(path)
  local h = read_header(path, 10)
  if not h or #h < 10 then return nil end
  if h:sub(1, 3) ~= "GIF" then return nil end
  return le16(h, 7), le16(h, 9)
end

--- Check if a GIF file has multiple frames (is animated).
--- Only reads the first 64KB to avoid loading huge files.
---@param path string
---@return boolean
function M.is_animated_gif(path)
  local h = read_header(path, 6)
  if not h or h:sub(1, 3) ~= "GIF" then return false end
  -- Read first 64KB — enough to find a second Image Descriptor
  local f = io.open(path, "rb")
  if not f then return false end
  local data = f:read(65536)
  f:close()
  if not data then return false end
  local count = 0
  for pos = 1, #data do
    if data:byte(pos) == 0x2C then
      count = count + 1
      if count > 1 then return true end
    end
  end
  return false
end

--- Video file extensions supported for frame extraction
local VIDEO_EXTENSIONS = {
  mp4 = true, webm = true, mov = true, avi = true, mkv = true, m4v = true,
}

--- Check if a file path points to a video file (by extension).
---@param path string
---@return boolean
function M.is_video_file(path)
  local ext = path:match("%.(%w+)$")
  if not ext then return false end
  return VIDEO_EXTENSIONS[ext:lower()] == true
end

--- Check if a file contains video content by examining magic bytes.
--- Detects MP4 (ftyp), WebM/MKV (EBML), AVI (RIFF+AVI).
---@param path string
---@return boolean
function M.is_video_content(path)
  local h = read_header(path, 12)
  if not h or #h < 8 then return false end
  -- MP4/M4V: bytes 5-8 are "ftyp"
  if h:sub(5, 8) == "ftyp" then return true end
  -- WebM/MKV: starts with EBML header (0x1A45DFA3)
  if h:byte(1) == 0x1A and h:byte(2) == 0x45 and h:byte(3) == 0xDF and h:byte(4) == 0xA3 then return true end
  -- AVI: RIFF....AVI
  if h:sub(1, 4) == "RIFF" and #h >= 12 and h:sub(9, 11) == "AVI" then return true end
  return false
end

--- Get video frame dimensions using ffprobe.
--- Returns the original video dimensions (not the downscaled frame size).
--- Results are cached in memory keyed by path.
---@param path string absolute path to video file
---@return integer? width, integer? height
function M.video_dimensions(path)
  if vim.fn.executable("ffprobe") ~= 1 then return nil, nil end
  local result = vim.system(
    {
      "ffprobe", "-v", "error",
      "-select_streams", "v:0",
      "-show_entries", "stream=width,height",
      "-of", "csv=p=0:s=x", path,
    },
    { text = true, timeout = 5000 }
  ):wait()
  if result.code == 0 and result.stdout then
    local w, h = result.stdout:match("(%d+)x(%d+)")
    if w and h then return tonumber(w), tonumber(h) end
  end
  return nil, nil
end

--- Get video frame dimensions asynchronously using ffprobe.
--- Returns the original video dimensions (not the downscaled frame size).
---@param path string absolute path to video file
---@param callback fun(width: integer?, height: integer?)
function M.video_dimensions_async(path, callback)
  -- Use ffprobe to get original video dimensions
  vim.system(
    {
      "ffprobe", "-v", "error",
      "-select_streams", "v:0",
      "-show_entries", "stream=width,height",
      "-of", "csv=p=0:s=x", path,
    },
    { text = true, timeout = 10000 },
    function(result)
      vim.schedule(function()
        if result.code == 0 and result.stdout then
          local w, h = result.stdout:match("(%d+)x(%d+)")
          if w and h then
            callback(tonumber(w), tonumber(h))
            return
          end
        end
        callback(nil, nil)
      end)
    end
  )
end

---@param path string
---@return integer? width, integer? height
function M.image_dimensions(path)
  local h = read_header(path, 4)
  if not h then return nil end
  if h:sub(1, 4) == "\137PNG" then return png_dimensions(path) end
  if h:byte(1) == 0xFF and h:byte(2) == 0xD8 then return jpeg_dimensions(path) end
  if h:sub(1, 4) == "RIFF" then return webp_dimensions(path) end
  if h:sub(1, 3) == "GIF" then return gif_dimensions(path) end
  return nil
end

-- ============================================================================
-- Mermaid diagram rendering
-- ============================================================================

--- Get cache directory for rendered mermaid diagrams
---@return string
local function get_mermaid_cache_dir()
  local dir = vim.fn.stdpath("cache") .. "/md-render/mermaid"
  vim.fn.mkdir(dir, "p")
  return dir
end

--- Find the mmdc executable (mermaid CLI).
--- Searches PATH first, then falls back to npx.
---@return string[]? command prefix (e.g. {"mmdc"} or {"npx", "-y", "@mermaid-js/mermaid-cli"})
local _mmdc_cmd = nil
local _mmdc_checked = false

local function find_mmdc()
  if _mmdc_checked then return _mmdc_cmd end
  _mmdc_checked = true
  if vim.fn.executable("mmdc") == 1 then
    _mmdc_cmd = { "mmdc" }
  elseif vim.fn.executable("npx") == 1 then
    _mmdc_cmd = { "npx", "-y", "@mermaid-js/mermaid-cli" }
  end
  return _mmdc_cmd
end

--- Check if mermaid rendering is available
---@return boolean
function M.has_mmdc()
  return find_mmdc() ~= nil
end

--- Detect whether Neovim is using a dark or light background and return
--- the appropriate mermaid theme name and background color hex string.
---@return string theme, string bg_hex
local function mermaid_theme_args()
  local bg = vim.o.background  -- "dark" or "light"
  local hl = vim.api.nvim_get_hl(0, { name = "NormalFloat", link = false })
  if not hl.bg then
    hl = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  end
  local bg_color = hl.bg
  if bg == "dark" then
    local hex = bg_color and string.format("#%06x", bg_color) or "#1e1e2e"
    return "dark", hex
  else
    local hex = bg_color and string.format("#%06x", bg_color) or "#ffffff"
    return "default", hex
  end
end

--- Compute cache path for mermaid source (includes theme in hash).
---@param source string
---@return string
local function mermaid_cache_path(source)
  local theme, bg_hex = mermaid_theme_args()
  local hash = vim.fn.sha256(source .. "\0" .. theme .. "\0" .. bg_hex):sub(1, 16)
  return get_mermaid_cache_dir() .. "/" .. hash .. ".png"
end

--- Build the mmdc command arguments with theme-aware colors.
---@param cmd_prefix string[]
---@param input_path string
---@param output_path string
---@return string[]
local function build_mmdc_cmd(cmd_prefix, input_path, output_path)
  local theme, bg_hex = mermaid_theme_args()
  local cmd = vim.list_extend({}, cmd_prefix)
  vim.list_extend(cmd, {
    "-i", input_path, "-o", output_path,
    "-t", theme, "-b", bg_hex, "-s", "2",
  })
  return cmd
end

--- Check if a mermaid diagram is already cached (no rendering).
---@param source string mermaid diagram source code
---@return string? cached_path
function M.get_mermaid_cached(source)
  local cache_path = mermaid_cache_path(source)
  if vim.fn.filereadable(cache_path) == 1 then
    return cache_path
  end
  return nil
end

--- Render mermaid source code to a PNG image (synchronous, cached).
---@param source string mermaid diagram source code
---@return string? png_path
function M.render_mermaid(source)
  local cmd_prefix = find_mmdc()
  if not cmd_prefix then return nil end

  local cache_path = mermaid_cache_path(source)
  if vim.fn.filereadable(cache_path) == 1 then
    return cache_path
  end

  local tmp_input = os.tmpname() .. ".mmd"
  local f = io.open(tmp_input, "w")
  if not f then return nil end
  f:write(source)
  f:close()

  local cmd = build_mmdc_cmd(cmd_prefix, tmp_input, cache_path)
  local result = vim.system(cmd, { text = true, timeout = 30000 }):wait()
  os.remove(tmp_input)

  if vim.fn.filereadable(cache_path) == 1 then
    return cache_path
  end
  return nil
end

--- Render mermaid source code to a PNG image (asynchronous, cached).
---@param source string mermaid diagram source code
---@param callback fun(png_path: string?)
function M.render_mermaid_async(source, callback)
  local cmd_prefix = find_mmdc()
  if not cmd_prefix then
    callback(nil)
    return
  end

  local cache_path = mermaid_cache_path(source)
  if vim.fn.filereadable(cache_path) == 1 then
    callback(cache_path)
    return
  end

  local tmp_input = os.tmpname() .. ".mmd"
  local f = io.open(tmp_input, "w")
  if not f then
    callback(nil)
    return
  end
  f:write(source)
  f:close()

  local cmd = build_mmdc_cmd(cmd_prefix, tmp_input, cache_path)

  vim.system(cmd, { text = true, timeout = 30000 }, function(result)
    vim.schedule(function()
      os.remove(tmp_input)
      if vim.fn.filereadable(cache_path) == 1 then
        callback(cache_path)
      else
        callback(nil)
      end
    end)
  end)
end

--- Check if file is a format the terminal can display directly (no conversion needed)
---@param path string
---@return boolean
function M.is_native_format(path)
  local h = read_header(path, 4)
  if not h then return false end
  -- Only PNG is natively supported by Kitty graphics protocol (f=100).
  -- GIF must be converted to PNG before transmission.
  return h:sub(1, 4) == "\137PNG"
end

-- ============================================================================
-- Kitty Graphics Protocol support detection
-- ============================================================================

local _kitty_supported = nil
local _is_ghostty = nil

--- Check if running inside Ghostty terminal.
--- Ghostty does not support t=t (temporary file transfer mode) in Kitty
--- graphics protocol, so we must use t=f and clean up temp files ourselves.
local function is_ghostty()
  if _is_ghostty ~= nil then return _is_ghostty end
  _is_ghostty = vim.env.TERM_PROGRAM == "ghostty" or vim.env.GHOSTTY_RESOURCES_DIR ~= nil
  return _is_ghostty
end

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
  -- Fallback: detect via terminal-specific env vars that Neovim may preserve
  -- even when TERM_PROGRAM is cleared
  if vim.env.KITTY_WINDOW_ID then
    _kitty_supported = true
    return true
  end
  if vim.env.GHOSTTY_RESOURCES_DIR then
    _kitty_supported = true
    return true
  end
  if vim.env.WEZTERM_EXECUTABLE then
    _kitty_supported = true
    return true
  end
  _kitty_supported = false
  return false
end

function M.reset_cache()
  _kitty_supported = nil
  _is_ghostty = nil
  _session_cleared = false
  _convert_cmd = nil
  _convert_checked = false
  _anim_cmd = nil
  _anim_checked = false
  tty_mod.reset()
end

--- Override kitty support detection for testing.
---@param val boolean?
function M._set_kitty_supported(val)
  _kitty_supported = val
end

--- Reset image ID counter for testing.
function M._reset_image_id()
  _image_id = 100
end

-- ============================================================================
-- URL detection and download with cache
-- ============================================================================

--- Custom download function for authenticated or special URL handling.
--- Signature: fn(url, output_path, callback) -> handled
---   - url: the image URL to download
---   - output_path: absolute path where the image file should be saved
---   - callback: fun(ok: boolean) — call with true on success, false on failure
---   - return true if this function handles the URL (callback will be called later)
---   - return false to fall back to the default curl downloader
---@type fun(url: string, output_path: string, callback: fun(ok: boolean)): boolean
local _custom_download_fn = nil

--- Register a custom download function for URL images.
--- The function is called before the default curl downloader. If it returns
--- true, it is expected to handle the download and call the callback. If it
--- returns false, the default curl-based downloader is used as a fallback.
---@param fn fun(url: string, output_path: string, callback: fun(ok: boolean)): boolean
function M.set_download_fn(fn)
  _custom_download_fn = fn
end

--- Check if a string is an HTTP(S) URL
---@param s string
---@return boolean
function M.is_url(s)
  return s:match("^https?://") ~= nil
end

--- URLs that are badges or tiny icons — not worth displaying as block images
local BADGE_PATTERNS = {
  "img%.shields%.io",
  "badge%.fury%.io",
  "badgen%.net",
  "badges%.gitter%.im",
  "coveralls%.io/repos",
  "travis%-ci%.org",
  "ci%.appveyor%.com",
  "codecov%.io",
  "scan%.coverity%.com",
  "repology%.org/badge",
  "badges%.debian%.net",
  "github%.com/.*badge",
  "github%.com/.*/workflows/.*/badge",
  "img%.shields%.io",
  "flat%-square",
  "for%-the%-badge",
}

--- Check if a URL looks like a badge/shield image
---@param url string
---@return boolean
function M.is_badge_url(url)
  for _, pat in ipairs(BADGE_PATTERNS) do
    if url:match(pat) then return true end
  end
  return false
end

-- In-memory cache: URL -> local file path
local _url_cache = {}

--- Get cache directory for downloaded images
---@return string
local function get_cache_dir()
  local dir = vim.fn.stdpath("cache") .. "/md-render/images"
  vim.fn.mkdir(dir, "p")
  return dir
end

--- Generate a cache filename from a URL
---@param url string
---@return string
local function url_to_cache_path(url)
  -- Use a hash of the URL as filename, preserve extension
  local hash = vim.fn.sha256(url):sub(1, 16)
  local ext = url:match("%.(%w+)$") or "png"
  -- Clean extension (remove query params)
  ext = ext:match("^(%w+)") or "png"
  return get_cache_dir() .. "/" .. hash .. "." .. ext
end

--- Check if a URL is already cached (in-memory or on disk).
---@param url string
---@return string? cached_path
function M.get_cached(url)
  if _url_cache[url] and vim.fn.filereadable(_url_cache[url]) == 1 then
    -- Validate cached file is a recognized image or video format
    if M.image_dimensions(_url_cache[url]) or M.is_video_content(_url_cache[url]) then
      return _url_cache[url]
    end
    -- Stale/corrupt cache entry: remove file and clear in-memory cache
    os.remove(_url_cache[url])
    _url_cache[url] = nil
    return nil
  end
  local cache_path = url_to_cache_path(url)
  if vim.fn.filereadable(cache_path) == 1 then
    -- Validate cached file is a recognized image or video format
    if M.image_dimensions(cache_path) or M.is_video_content(cache_path) then
      _url_cache[url] = cache_path
      return cache_path
    end
    -- Stale/corrupt cache file: remove it
    os.remove(cache_path)
    return nil
  end
  -- Try video extensions (file may have been renamed by finalize_download)
  local hash = cache_path:match("/([^/]+)%.[^.]+$")
  if hash then
    for _, ext in ipairs({ "mp4", "webm", "avi" }) do
      local alt_path = get_cache_dir() .. "/" .. hash .. "." .. ext
      if vim.fn.filereadable(alt_path) == 1 and M.is_video_content(alt_path) then
        _url_cache[url] = alt_path
        return alt_path
      end
    end
  end
  return nil
end

--- Detect video format from magic bytes and return the correct extension.
---@param path string
---@return string? ext  "mp4", "webm", or "avi"
local function detect_video_ext(path)
  local h = read_header(path, 12)
  if not h or #h < 8 then return nil end
  if h:sub(5, 8) == "ftyp" then return "mp4" end
  if h:byte(1) == 0x1A and h:byte(2) == 0x45 and h:byte(3) == 0xDF and h:byte(4) == 0xA3 then return "webm" end
  if h:sub(1, 4) == "RIFF" and #h >= 12 and h:sub(9, 11) == "AVI" then return "avi" end
  return nil
end

--- Validate a downloaded file and update cache, then invoke callback.
--- If the file is video with a wrong extension, rename it to the correct one.
---@param url string
---@param cache_path string
---@param callback fun(path: string?)
local function finalize_download(url, cache_path, callback)
  if vim.fn.filereadable(cache_path) == 1 then
    if M.image_dimensions(cache_path) then
      _url_cache[url] = cache_path
      callback(cache_path)
      return
    end
    -- Check if it's a video with wrong extension
    local video_ext = detect_video_ext(cache_path)
    if video_ext then
      local current_ext = cache_path:match("%.(%w+)$")
      if current_ext and current_ext ~= video_ext then
        local correct_path = cache_path:gsub("%." .. current_ext .. "$", "." .. video_ext)
        os.rename(cache_path, correct_path)
        cache_path = correct_path
      end
      _url_cache[url] = cache_path
      callback(cache_path)
      return
    end
  end
  os.remove(cache_path)
  callback(nil)
end

--- Download a URL to a local file asynchronously.
---@param url string
---@param callback fun(path: string?)  called with local path on success, nil on failure
function M.download_async(url, callback)
  if M.is_badge_url(url) then
    callback(nil)
    return
  end

  local cached = M.get_cached(url)
  if cached then
    callback(cached)
    return
  end

  local cache_path = url_to_cache_path(url)

  -- Try custom download function first (e.g. for authenticated GitHub Enterprise URLs)
  if _custom_download_fn then
    local handled = _custom_download_fn(url, cache_path, function(ok)
      vim.schedule(function()
        if ok then
          finalize_download(url, cache_path, callback)
        else
          callback(nil)
        end
      end)
    end)
    if handled then return end
  end

  -- Default: download with curl
  vim.system(
    { "curl", "-sfL", "--max-time", "10", "--max-filesize", "20000000", "-o", cache_path, url },
    { text = true },
    function(result)
      vim.schedule(function()
        if result.code == 0 then
          finalize_download(url, cache_path, callback)
        else
          os.remove(cache_path)
          callback(nil)
        end
      end)
    end
  )
end

--- Check if a video URL is already cached (in-memory or on disk).
--- Unlike get_cached(), this does not validate with image_dimensions().
---@param url string
---@return string? cached_path
function M.get_video_cached(url)
  if _url_cache[url] and vim.fn.filereadable(_url_cache[url]) == 1 then
    return _url_cache[url]
  end
  local cache_path = url_to_cache_path(url)
  if vim.fn.filereadable(cache_path) == 1 then
    _url_cache[url] = cache_path
    return cache_path
  end
  return nil
end

--- Download a video URL to a local file asynchronously.
--- Unlike download_async(), this uses larger limits and skips image_dimensions validation.
---@param url string
---@param callback fun(path: string?)  called with local path on success, nil on failure
function M.download_video_async(url, callback)
  local cached = M.get_video_cached(url)
  if cached then
    callback(cached)
    return
  end

  local cache_path = url_to_cache_path(url)

  -- Try custom download function first (e.g. for authenticated GitHub Enterprise URLs)
  if _custom_download_fn then
    local handled = _custom_download_fn(url, cache_path, function(ok)
      vim.schedule(function()
        if ok and vim.fn.filereadable(cache_path) == 1 then
          _url_cache[url] = cache_path
          callback(cache_path)
        else
          os.remove(cache_path)
          callback(nil)
        end
      end)
    end)
    if handled then return end
  end

  -- Default: download with curl (larger limits for video)
  vim.system(
    { "curl", "-sfL", "--max-time", "30", "--max-filesize", "104857600", "-o", cache_path, url },
    { text = true },
    function(result)
      vim.schedule(function()
        if result.code == 0 and vim.fn.filereadable(cache_path) == 1 then
          _url_cache[url] = cache_path
          callback(cache_path)
        else
          os.remove(cache_path)
          callback(nil)
        end
      end)
    end
  )
end

--- Resolve an image source to a local file path (cache-only for URLs).
--- For URLs: returns cached path or nil (no download).
--- For local files: resolves path immediately.
---@param src string  image source (URL or path)
---@param base_dir? string  base directory for resolving relative paths
---@return string? resolved_path
function M.resolve(src, base_dir)
  if M.is_url(src) then
    if M.is_badge_url(src) then return nil end
    return M.get_cached(src)
  end

  local resolved = vim.fn.expand(src)
  if resolved:sub(1, 1) ~= "/" and base_dir then
    resolved = base_dir .. "/" .. resolved
  end

  if vim.fn.filereadable(resolved) == 1 then
    return resolved
  end

  -- Fallback: try Obsidian vault resolution
  if base_dir then
    local obsidian = require "md-render.obsidian"
    local vault_resolved = obsidian.resolve(src, base_dir)
    if vault_resolved then
      return vault_resolved
    end
  end

  return nil
end

-- ============================================================================
-- Image conversion tool detection
-- ============================================================================

local _convert_cmd = nil
local _convert_checked = false

--- Detect the best available tool for static image conversion (JPEG/WebP → PNG).
--- Priority: sips (macOS) → ffmpeg → magick
---@return string? tool  "sips", "ffmpeg", or "magick"
local function find_convert_tool()
  if _convert_checked then return _convert_cmd end
  _convert_checked = true
  if vim.fn.has("mac") == 1 and vim.fn.executable("sips") == 1 then
    _convert_cmd = "sips"
  elseif vim.fn.executable("ffmpeg") == 1 then
    _convert_cmd = "ffmpeg"
  elseif vim.fn.executable("magick") == 1 then
    _convert_cmd = "magick"
  end
  return _convert_cmd
end

local _anim_cmd = nil
local _anim_checked = false

--- Detect the best available tool for animated GIF frame extraction.
--- Priority: ffmpeg → magick
---@return string? tool  "ffmpeg" or "magick"
local function find_anim_tool()
  if _anim_checked then return _anim_cmd end
  _anim_checked = true
  if vim.fn.executable("ffmpeg") == 1 then
    _anim_cmd = "ffmpeg"
  elseif vim.fn.executable("magick") == 1 then
    _anim_cmd = "magick"
  end
  return _anim_cmd
end

--- Build a command to convert a static image to PNG with resize.
---@param tool string  "sips", "ffmpeg", or "magick"
---@param src string  input file path
---@param dst string  output PNG path
---@return string[]
local function build_convert_cmd(tool, src, dst)
  if tool == "sips" then
    -- -Z resizes only if the image is larger than the specified dimension
    return { "sips", "-s", "format", "png", "-Z", "2000", src, "--out", dst }
  elseif tool == "ffmpeg" then
    -- scale filter with force_original_aspect_ratio keeps aspect ratio;
    -- -vframes 1 ensures only one frame for static images
    return {
      "ffmpeg", "-y", "-i", src,
      "-vframes", "1",
      "-vf", "scale='min(2000,iw)':'min(2000,ih)':force_original_aspect_ratio=decrease",
      dst,
    }
  else
    return { "magick", src, "-resize", "2000x2000>", dst }
  end
end

-- ============================================================================
-- Image conversion
-- ============================================================================

--- Ensure image is in a format the terminal can display natively (synchronous).
--- PNG and GIF are passed through. JPEG/WebP are converted to PNG.
---@param path string
---@return string? png_path, boolean is_temp
function M.ensure_png(path)
  if M.is_native_format(path) then return path, false end
  local tool = find_convert_tool()
  if not tool then return nil, false end
  local tmp = os.tmpname() .. ".png"
  local result = vim.system(build_convert_cmd(tool, path, tmp), { text = true }):wait()
  if result.code ~= 0 then return nil, false end
  return tmp, true
end

--- Ensure image is in a native format (asynchronous).
---@param path string
---@param callback fun(png_path: string?, is_temp: boolean)
function M.ensure_png_async(path, callback)
  if M.is_native_format(path) then
    callback(path, false)
    return
  end
  local tool = find_convert_tool()
  if not tool then
    callback(nil, false)
    return
  end
  local tmp = os.tmpname() .. ".png"
  vim.system(
    build_convert_cmd(tool, path, tmp),
    { text = true },
    function(result)
      vim.schedule(function()
        if result.code == 0 then
          callback(tmp, true)
        else
          callback(nil, false)
        end
      end)
    end
  )
end

--- Choose the rounding direction (floor vs ceil) for the dependent dimension
--- that best preserves the original pixel aspect ratio.
---@param fixed_cells integer  the already-determined cell count (cols or rows)
---@param fixed_cell_px number  pixel size of the fixed dimension's cell
---@param dep_px number  target pixel size of the dependent dimension
---@param dep_cell_px number  pixel size of the dependent dimension's cell
---@param dep_max integer  upper bound for the dependent cell count
---@param img_w integer  original image width
---@param img_h integer  original image height
---@param fixed_is_cols boolean  true when fixed dimension is columns
---@return integer
local function best_round(fixed_cells, fixed_cell_px, dep_px, dep_cell_px, dep_max, img_w, img_h, fixed_is_cols)
  local r_floor = math.max(1, math.floor(dep_px / dep_cell_px))
  local r_ceil = math.min(dep_max, math.ceil(dep_px / dep_cell_px))
  if r_floor == r_ceil then return r_floor end
  local target = img_w / img_h
  local fl_ratio, cl_ratio
  if fixed_is_cols then
    fl_ratio = (fixed_cells * fixed_cell_px) / (r_floor * dep_cell_px)
    cl_ratio = (fixed_cells * fixed_cell_px) / (r_ceil * dep_cell_px)
  else
    fl_ratio = (r_floor * dep_cell_px) / (fixed_cells * fixed_cell_px)
    cl_ratio = (r_ceil * dep_cell_px) / (fixed_cells * fixed_cell_px)
  end
  if math.abs(fl_ratio - target) <= math.abs(cl_ratio - target) then
    return r_floor
  end
  return r_ceil
end

---@param img_w integer
---@param img_h integer
---@param max_cols integer
---@param max_rows integer
---@return integer cols, integer rows
function M.calc_display_size(img_w, img_h, max_cols, max_rows)
  local cell = M.get_cell_size()
  if not cell then return math.min(20, max_cols), math.min(10, max_rows) end

  -- Work in pixel space to minimize aspect-ratio distortion from rounding.
  local max_w = max_cols * cell.cell_w
  local max_h = max_rows * cell.cell_h

  -- Scale to fit within bounds (don't upscale)
  local scale = math.min(max_w / img_w, max_h / img_h, 1.0)

  local pixel_w = img_w * scale
  local pixel_h = img_h * scale

  -- Determine the constraining dimension and compute the other
  -- with optimal rounding to best preserve the aspect ratio.
  local cols, rows
  if max_w / img_w <= max_h / img_h then
    -- Width-constrained: fix cols, compute rows
    cols = math.min(max_cols, math.ceil(pixel_w / cell.cell_w))
    rows = best_round(cols, cell.cell_w, pixel_h, cell.cell_h, max_rows, img_w, img_h, true)
  else
    -- Height-constrained: fix rows, compute cols
    rows = math.min(max_rows, math.ceil(pixel_h / cell.cell_h))
    cols = best_round(rows, cell.cell_h, pixel_w, cell.cell_w, max_cols, img_w, img_h, false)
  end

  return math.max(1, cols), math.max(1, rows)
end

-- ============================================================================
-- Two-phase image display: transmit + put
-- ============================================================================

local _image_id = 100
local _image_paths = {}  -- image_id → file path (for Ghostty a=T workaround)
local _temp_image_paths = {}  -- image_id → true for temp files that need cleanup
local _session_cleared = false

--- Transmit image data to terminal (store without displaying).
--- The image can then be displayed cheaply with put_image().
---@param path string absolute path to image file
---@return integer? image_id
function M.transmit_image(path)
  if not M.supports_kitty() then return nil end
  if not get_tty_path() then return nil end

  local png_path, is_temp = M.ensure_png(path)
  if not png_path then return nil end

  _image_id = _image_id + 1
  local id = _image_id

  local b64_path = vim.base64.encode(png_path)
  -- Ghostty does not support t=t; always use t=f and delete temp files ourselves
  local t = (is_temp and not is_ghostty()) and "t" or "f"

  -- a=t: transmit and store, q=2: suppress all responses
  local message = string.format(
    "\x1b_Ga=t,f=100,t=%s,i=%d,q=2;%s\x1b\\",
    t, id, b64_path
  )
  term_write(message)

  if is_temp and is_ghostty() then
    -- Ghostty uses a=T (re-reads the file on each placement), so keep temp
    -- files alive until the image is deleted.  Mark for deferred cleanup.
    _temp_image_paths[id] = true
  end

  _image_paths[id] = png_path
  return id
end

local MAX_ANIM_FRAMES = 300  -- max frames to extract (= 60 seconds at 5 fps)

--- Build a command to count frames in an animated GIF.
---@param tool string  "ffmpeg" or "magick"
---@param path string  GIF file path
---@return string[] cmd
local function build_frame_count_cmd(tool, path)
  if tool == "ffmpeg" then
    return {
      "ffprobe", "-v", "error",
      "-count_frames", "-select_streams", "v:0",
      "-show_entries", "stream=nb_read_frames",
      "-of", "csv=p=0", path,
    }
  else
    return { "magick", "identify", "-format", "%n\n", path }
  end
end

--- Build a command to extract frames from an animated GIF.
---@param tool string  "ffmpeg" or "magick"
---@param path string  GIF file path
---@param cache_dir string  output directory
---@param total_frames integer  total number of frames
---@return string[] cmd
local function build_frame_extract_cmd(tool, path, cache_dir, total_frames)
  if tool == "ffmpeg" then
    local vf_parts = {}
    -- Convert to display frame rate (5 fps matches the 200 ms animation timer)
    table.insert(vf_parts, "fps=5")
    table.insert(vf_parts, "scale='min(400,iw)':'min(400,ih)':force_original_aspect_ratio=decrease")
    return {
      "ffmpeg", "-y", "-i", path,
      "-vf", table.concat(vf_parts, ","),
      "-frames:v", tostring(MAX_ANIM_FRAMES),
      "-vsync", "vfr",
      cache_dir .. "/frame_%04d.png",
    }
  else
    local cmd = { "magick", path, "-coalesce" }
    if total_frames > MAX_ANIM_FRAMES then
      local step = math.ceil(total_frames / MAX_ANIM_FRAMES)
      local delete = {}
      for i = 0, total_frames - 1 do
        if i % step ~= 0 then
          table.insert(delete, tostring(i))
        end
      end
      if #delete > 0 then
        table.insert(cmd, "-delete")
        table.insert(cmd, table.concat(delete, ","))
      end
    end
    table.insert(cmd, "-resize")
    table.insert(cmd, "800x800>")
    table.insert(cmd, cache_dir .. "/frame_%04d.png")
    return cmd
  end
end

--- Extract frames from an animated GIF and transmit each as a separate image.
--- Large GIFs are resized and frames are sampled to stay under MAX_ANIM_FRAMES.
--- Extracted frames are cached on disk for fast subsequent loads.
--- Returns array of frame IDs and nil (frames are cached, not temporary).
---@param path string absolute path to animated GIF
---@return integer[]? frame_ids
---@return string? tmp_dir  always nil (frames persist in cache)
---@return integer? frame_w  actual width of transmitted frame PNGs
---@return integer? frame_h  actual height of transmitted frame PNGs
function M.transmit_animated(path)
  if not M.supports_kitty() then return nil end
  if not get_tty_path() then return nil end

  local anim_tool = find_anim_tool()
  if not anim_tool then return nil end

  local cache_dir = get_frames_cache_dir(path)

  -- Check frame cache first
  local cached = get_cached_frames(path, cache_dir)
  if not cached then
    -- Count total frames first
    local count_result = vim.system(
      build_frame_count_cmd(anim_tool, path),
      { text = true }
    ):wait()
    local total_frames = 1
    if count_result.code == 0 and count_result.stdout then
      total_frames = tonumber(count_result.stdout:match("%d+")) or 1
    end

    vim.fn.mkdir(cache_dir, "p")

    local cmd = build_frame_extract_cmd(anim_tool, path, cache_dir, total_frames)
    local result = vim.system(cmd, { text = true, timeout = 30000 }):wait()

    if result.code ~= 0 then
      vim.fn.delete(cache_dir, "rf")
      return nil
    end

    cached = vim.fn.glob(cache_dir .. "/frame_*.png", false, true)
    table.sort(cached)
    if #cached == 0 then
      vim.fn.delete(cache_dir, "rf")
      return nil
    end
  end

  -- Read actual frame dimensions (may differ from original GIF due to resize)
  local frame_w, frame_h = M.image_dimensions(cached[1])

  local frame_ids = {}
  for _, frame_path in ipairs(cached) do
    _image_id = _image_id + 1
    local id = _image_id
    local b64_path = vim.base64.encode(frame_path)
    term_write(string.format(
      "\x1b_Ga=t,f=100,t=f,i=%d,q=2;%s\x1b\\",
      id, b64_path
    ))
    _image_paths[id] = frame_path
    table.insert(frame_ids, id)
  end

  -- Frames are in persistent cache, not a tmp_dir
  return frame_ids, nil, frame_w, frame_h
end

--- Transmit image asynchronously (converts to PNG if needed, then transmits).
--- When the image is converted (e.g. JPEG→PNG with resize), the callback
--- receives the actual transmitted image dimensions so callers can update
--- their source rectangle parameters accordingly.
---@param path string absolute path to image file
---@param callback fun(image_id: integer?, tx_w: integer?, tx_h: integer?)
function M.transmit_image_async(path, callback)
  if not M.supports_kitty() or not get_tty_path() then
    callback(nil)
    return
  end
  M.ensure_png_async(path, function(png_path, is_temp)
    if not png_path then
      callback(nil)
      return
    end
    _image_id = _image_id + 1
    local id = _image_id
    local b64_path = vim.base64.encode(png_path)
    -- Ghostty does not support t=t; always use t=f and delete temp files ourselves
    local t = (is_temp and not is_ghostty()) and "t" or "f"
    term_write(string.format(
      "\x1b_Ga=t,f=100,t=%s,i=%d,q=2;%s\x1b\\",
      t, id, b64_path
    ))
    if is_temp and is_ghostty() then
      _temp_image_paths[id] = true
    end
    _image_paths[id] = png_path
    -- Return actual transmitted dimensions when conversion changed the size
    local tx_w, tx_h
    if is_temp then
      tx_w, tx_h = M.image_dimensions(png_path)
    end
    callback(id, tx_w, tx_h)
  end)
end

--- Get persistent cache directory for extracted GIF frames.
--- Uses a hash of the source path to create a stable directory name.
---@param gif_path string
---@return string
local function get_frames_cache_dir(gif_path)
  local hash = vim.fn.sha256(gif_path):sub(1, 16)
  local dir = get_cache_dir() .. "/frames_" .. hash
  return dir
end

--- Check if cached frames are still valid (exist and are newer than source GIF).
---@param gif_path string
---@param cache_dir string
---@return string[]?  sorted list of frame PNG paths, or nil if cache miss
local function get_cached_frames(gif_path, cache_dir)
  local frames = vim.fn.glob(cache_dir .. "/frame_*.png", false, true)
  if #frames == 0 then return nil end
  table.sort(frames)
  -- Invalidate if source GIF is newer than cached frames
  local gif_mtime = vim.fn.getftime(gif_path)
  local frame_mtime = vim.fn.getftime(frames[1])
  if gif_mtime > frame_mtime then
    vim.fn.delete(cache_dir, "rf")
    return nil
  end
  return frames
end

--- Extract GIF frames and transmit asynchronously.
--- Large GIFs are sampled down to MAX_ANIM_FRAMES.
--- Extracted frames are cached on disk for fast subsequent loads.
---@param path string absolute path to animated GIF
---@param callback fun(frame_ids: integer[]?, tmp_dir: string?, frame_w: integer?, frame_h: integer?)
function M.transmit_animated_async(path, callback)
  if not M.supports_kitty() or not get_tty_path() then
    callback(nil)
    return
  end

  local anim_tool = find_anim_tool()
  if not anim_tool then
    callback(nil)
    return
  end

  local cache_dir = get_frames_cache_dir(path)

  --- Transmit pre-extracted frames and invoke callback.
  --- Sends frames in small batches (BATCH_SIZE), yielding to the event loop
  --- between batches so Neovim stays responsive while the terminal processes
  --- the image data. Callback is invoked after the first batch so animation
  --- can start immediately with available frames.
  ---@param frames string[]
  local function transmit_frames(frames)
    local frame_w, frame_h = M.image_dimensions(frames[1])
    local total = #frames
    local BATCH_SIZE = 10

    -- Pre-allocate all frame IDs so the callback receives the full list
    local all_ids = {}
    for i = 1, total do
      _image_id = _image_id + 1
      all_ids[i] = _image_id
    end

    local idx = 1
    local function send_next_batch()
      local end_idx = math.min(idx + BATCH_SIZE - 1, total)
      M.begin_batch()
      for i = idx, end_idx do
        local b64_path = vim.base64.encode(frames[i])
        term_write(string.format(
          "\x1b_Ga=t,f=100,t=f,i=%d,q=2;%s\x1b\\",
          all_ids[i], b64_path
        ))
        _image_paths[all_ids[i]] = frames[i]
      end
      M.flush_batch()
      idx = end_idx + 1
      if idx <= total then
        vim.defer_fn(send_next_batch, 10)
      end
    end

    send_next_batch()
    callback(all_ids, nil, frame_w, frame_h)
  end

  -- Check frame cache first
  local cached = get_cached_frames(path, cache_dir)
  if cached then
    transmit_frames(cached)
    return
  end

  -- Count frames first
  vim.system(
    build_frame_count_cmd(anim_tool, path),
    { text = true },
    function(count_result)
      vim.schedule(function()
        local total_frames = 1
        if count_result.code == 0 and count_result.stdout then
          total_frames = tonumber(count_result.stdout:match("%d+")) or 1
        end

        vim.fn.mkdir(cache_dir, "p")

        local cmd = build_frame_extract_cmd(anim_tool, path, cache_dir, total_frames)

        vim.system(cmd, { text = true, timeout = 30000 }, function(result)
          vim.schedule(function()
            if result.code ~= 0 then
              vim.fn.delete(cache_dir, "rf")
              callback(nil)
              return
            end

            local frames = vim.fn.glob(cache_dir .. "/frame_*.png", false, true)
            table.sort(frames)
            if #frames == 0 then
              vim.fn.delete(cache_dir, "rf")
              callback(nil)
              return
            end

            transmit_frames(frames)
          end)
        end)
      end)
    end
  )
end

--- Display an image at a screen position.
--- For static images: uses a=p (lightweight, references previously transmitted data).
---@param image_id integer  Kitty image ID from transmit_image()
---@param win integer  window handle
---@param row integer  0-indexed row within window content
---@param col integer  0-indexed column within window content
---@param display_cols integer
---@param display_rows integer
---@param anim_path? string  if set, use a=T for animated GIF display
---@param img_w? integer  source image width in pixels (for cropping)
---@param img_h? integer  source image height in pixels (for cropping)
function M.put_image(image_id, win, row, col, display_cols, display_rows, anim_path, img_w, img_h)
  if not M.supports_kitty() then return end
  if not vim.api.nvim_win_is_valid(win) then return end

  local win_pos = vim.api.nvim_win_get_position(win)

  -- Check if the image is within visible window area
  local win_height = vim.api.nvim_win_get_height(win)
  local wininfo = vim.fn.getwininfo(win)[1]
  local topline = wininfo.topline - 1  -- 0-indexed
  local leftcol = wininfo.leftcol or 0

  -- Image entirely above or below visible area
  local img_end_row = row + display_rows - 1
  if img_end_row < topline or row >= topline + win_height then return end

  -- Adjust screen position for scroll offset
  local visual_row = row - topline
  -- Compute border dimensions from window config
  local border_left_width = 0
  local border_top_height = 0
  local ok_cfg, win_cfg = pcall(vim.api.nvim_win_get_config, win)
  if ok_cfg and win_cfg.border then
    local border = win_cfg.border
    if type(border) == "table" then
      local left = border[8] -- 8th element = left border char
      if type(left) == "table" then left = left[1] end
      if left and left ~= "" then
        border_left_width = vim.api.nvim_strwidth(left)
      end
      local top = border[2] -- 2nd element = top border char
      if type(top) == "table" then top = top[1] end
      if top and top ~= "" then
        border_top_height = 1
      end
    elseif border ~= "none" and border ~= "" then
      border_left_width = vim.api.nvim_strwidth("│")
      border_top_height = 1
    end
  end
  -- Adjust for horizontal scroll offset
  local visual_col = col - leftcol

  -- Image entirely to the left or right of visible area
  local img_end_col = col + display_cols - 1
  if img_end_col < leftcol or col >= leftcol + vim.api.nvim_win_get_width(win) then return end

  local screen_col = win_pos[2] + visual_col + border_left_width + 1

  -- Crop to visible area using source rectangle (no scaling distortion)
  local crop_params = ""

  -- Left crop: image starts to the left of visible area
  if visual_col < 0 then
    local hidden_cols = -visual_col
    if img_w then
      local crop_x = math.floor(img_w * hidden_cols / display_cols)
      crop_params = crop_params .. ",x=" .. crop_x
      crop_params = crop_params .. ",w=" .. (img_w - crop_x)
    end
    display_cols = display_cols - hidden_cols
    visual_col = 0
    screen_col = win_pos[2] + border_left_width + 1
  end

  -- Top crop: image starts above visible area
  if visual_row < 0 then
    local hidden_rows = -visual_row
    if img_h then
      local crop_y = math.floor(img_h * hidden_rows / display_rows)
      crop_params = crop_params .. ",y=" .. crop_y
      -- Explicit h= required: some terminals (Ghostty) need both y= and h=
      crop_params = crop_params .. ",h=" .. (img_h - crop_y)
    end
    display_rows = display_rows - hidden_rows
    visual_row = 0
  end

  local screen_row = wininfo.winrow + visual_row + border_top_height

  -- Bottom crop: image extends below visible area
  local visible_rows = win_height - visual_row
  if visible_rows <= 0 then return end
  if display_rows > visible_rows and img_h then
    -- When top is also cropped, calculate h relative to remaining source region
    local remaining_h = img_h
    local existing_y = crop_params:match(",y=(%d+)")
    if existing_y then
      remaining_h = img_h - tonumber(existing_y)
    end
    local crop_h = math.floor(remaining_h * visible_rows / display_rows)
    -- Update h= if already set by top crop, otherwise add it
    local existing_h = crop_params:match(",h=%d+")
    if existing_h then
      crop_params = crop_params:gsub(",h=%d+", ",h=" .. crop_h)
    else
      crop_params = crop_params .. ",h=" .. crop_h
    end
    display_rows = visible_rows
  end

  local win_width = vim.api.nvim_win_get_width(win)
  local visible_cols = win_width - visual_col
  if visible_cols <= 0 then return end
  if display_cols > visible_cols and img_w then
    -- When left is also cropped, calculate w relative to remaining source region
    local remaining_w = img_w
    local existing_x = crop_params:match(",x=(%d+)")
    if existing_x then
      remaining_w = img_w - tonumber(existing_x)
    end
    local crop_w = math.floor(remaining_w * visible_cols / display_cols)
    -- Update w= if already set by left crop, otherwise add it
    local existing_w = crop_params:match(",w=%d+")
    if existing_w then
      crop_params = crop_params:gsub(",w=%d+", ",w=" .. crop_w)
    else
      crop_params = crop_params .. ",w=" .. crop_w
    end
    display_cols = visible_cols
  end

  local message
  local img_path = anim_path or (is_ghostty() and _image_paths[image_id] or nil)
  if img_path then
    -- Transmit and display in one step (a=T).
    -- Used for animated GIFs and as a Ghostty workaround: Ghostty does not
    -- reliably place images with a=p after a=t, so we re-transmit each time.
    local b64_path = vim.base64.encode(img_path)
    message = string.format(
      "\x1b_Ga=T,f=100,t=f,i=%d,c=%d,r=%d%s,C=1,q=2;%s\x1b\\",
      image_id, display_cols, display_rows, crop_params, b64_path
    )
  else
    -- Static: put a previously transmitted image
    message = string.format(
      "\x1b_Ga=p,i=%d,c=%d,r=%d%s,C=1,q=2\x1b\\",
      image_id, display_cols, display_rows, crop_params
    )
  end

  term_write("\x1b[s")
  move_cursor(screen_col, screen_row)
  term_write(message)
  term_write("\x1b[u")
end

--- Delete all placements for an image but keep the transmitted data.
---@param image_id integer
function M.clear_placements(image_id)
  if not M.supports_kitty() then return end
  term_write(string.format("\x1b_Ga=d,d=a,i=%d,q=2\x1b\\", image_id))
end

--- Delete all images and placements from terminal memory.
function M.delete_all()
  if not M.supports_kitty() then return end
  term_write("\x1b_Ga=d,d=A,q=2\x1b\\")
  for id, path in pairs(_image_paths) do
    if _temp_image_paths[id] then
      os.remove(path)
    end
  end
  _image_paths = {}
  _temp_image_paths = {}
end

--- Delete a stored image from terminal memory
---@param image_id integer
function M.delete_image(image_id)
  if not M.supports_kitty() then return end
  term_write(string.format("\x1b_Ga=d,d=i,i=%d\x1b\\", image_id))
  if _temp_image_paths[image_id] and _image_paths[image_id] then
    os.remove(_image_paths[image_id])
    _temp_image_paths[image_id] = nil
  end
  _image_paths[image_id] = nil
end

--- Delete multiple images
---@param image_ids integer[]
function M.delete_images(image_ids)
  if not M.supports_kitty() or #image_ids == 0 then return end
  local parts = {}
  for _, id in ipairs(image_ids) do
    table.insert(parts, string.format("\x1b_Ga=d,d=i,i=%d\x1b\\", id))
    if _temp_image_paths[id] and _image_paths[id] then
      os.remove(_image_paths[id])
      _temp_image_paths[id] = nil
    end
    _image_paths[id] = nil
  end
  term_write(table.concat(parts))
end

--- Clear all images from terminal memory (once per Neovim session).
--- Removes stale image data from previous sessions that may interfere
--- with new transmissions using the same ID range.
function M.clear_all()
  if _session_cleared then return end
  _session_cleared = true
  if not M.supports_kitty() then return end
  -- d=A: delete all stored image data and placements
  term_write("\x1b_Ga=d,d=A\x1b\\")
  -- Reset ID counter and path mapping to ensure clean state
  _image_id = 100
  for id, path in pairs(_image_paths) do
    if _temp_image_paths[id] then
      os.remove(path)
    end
  end
  _image_paths = {}
  _temp_image_paths = {}

  -- Ensure images are cleaned up when Neovim exits (e.g. :restart in Kitty)
  vim.api.nvim_create_autocmd("VimLeavePre", {
    once = true,
    callback = function()
      M.delete_all()
    end,
  })
end

return M
