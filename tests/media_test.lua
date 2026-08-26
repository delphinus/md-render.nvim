-- Integration tests for the external media tools (ffmpeg / ImageMagick / sips).
--
-- Everything else in tests/ checks the bytes md-render *emits*. This file
-- checks that the commands it *runs* still work, by actually invoking them on
-- the bundled demo assets. That is the layer that catches a toolchain moving
-- underneath us: FFmpeg 9 removed `-vsync`, extraction started failing for
-- every video and animated GIF, and no unit test noticed because the escape
-- sequences md-render would have emitted were still correct.
--
-- Run: nvim --headless -u NONE --noplugin -l tests/media_test.lua
--
-- Missing tools are reported as SKIP so a contributor without ffmpeg can still
-- run `make test`. Set MD_RENDER_REQUIRE_MEDIA_TOOLS=1 (as CI does) to turn a
-- skip into a failure, so the matrix can never go green by not testing.

package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local image = require "md-render.image"

local pass_count = 0
local fail_count = 0
local skip_count = 0

local REQUIRE_TOOLS = vim.env.MD_RENDER_REQUIRE_MEDIA_TOOLS == "1"

local function pass(msg)
  pass_count = pass_count + 1
  print("  ok   " .. msg)
end

local function fail(msg, detail)
  fail_count = fail_count + 1
  print("  FAIL " .. msg)
  if detail then print("       " .. detail) end
end

local function skip(msg, why)
  if REQUIRE_TOOLS then
    fail(msg, "required tool missing: " .. why .. " (MD_RENDER_REQUIRE_MEDIA_TOOLS=1)")
    return
  end
  skip_count = skip_count + 1
  print("  skip " .. msg .. " (" .. why .. ")")
end

local function have(exe)
  return vim.fn.executable(exe) == 1
end

-- ---------------------------------------------------------------------------
-- Environment report
--
-- Printed unconditionally: when the matrix goes red, the first thing worth
-- knowing is which toolchain it went red on.
-- ---------------------------------------------------------------------------

local function tool_version(exe, args)
  if not have(exe) then return "(not installed)" end
  local r = vim.system(vim.list_extend({ exe }, args), { text = true }):wait()
  local out = (r.stdout or "") .. (r.stderr or "")
  return vim.trim((out:gmatch "[^\r\n]+")() or "?")
end

print "media_test environment:"
print("  ffmpeg   " .. tool_version("ffmpeg", { "-version" }))
print("  ffprobe  " .. tool_version("ffprobe", { "-version" }))
print("  magick   " .. tool_version("magick", { "-version" }))
print("  sips     " .. (have "sips" and "present" or "(not installed)"))
print ""

-- ---------------------------------------------------------------------------
-- Harness
-- ---------------------------------------------------------------------------

local root = vim.fn.getcwd()
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")

--- Copy an asset to a fresh path so its cache key is unique to this run.
---
--- Both the frame cache and the converted-PNG cache are keyed on a hash of the
--- source path, so testing the bundled path directly would hit a cache left by
--- an earlier run and never invoke the tool at all — a green that proves
--- nothing. A unique path guarantees a cache miss and a real invocation.
---@param name string file under assets/demo/
---@return string path
local function fresh_copy(name)
  local src = root .. "/assets/demo/" .. name
  local dst = string.format("%s/%d_%s", tmp, pass_count + fail_count + skip_count, name)
  local data = assert(io.open(src, "rb")):read "*a"
  local out = assert(io.open(dst, "wb"))
  out:write(data)
  out:close()
  return dst
end

--- Run an async transmit and wait for its callback.
---@param fn fun(path: string, cb: fun(...))
---@param path string
---@return any
local function await(fn, path)
  local result, done = nil, false
  fn(path, function(...)
    result = { ... }
    done = true
  end)
  -- Generous: a cold ffmpeg decode of the sample video takes ~1s locally, but
  -- CI runners are slower and the frame transmit yields to the event loop.
  vim.wait(120000, function()
    return done
  end, 50)
  if not done then return nil, "timed out" end
  return result[1]
end

-- md-render only talks to the terminal when it believes one is listening, and
-- these tests run headless. Pretend, and swallow the writes.
local real_ui_send = vim.api.nvim_ui_send
vim.api.nvim_ui_send = function() end
image._set_kitty_supported(true)

-- ---------------------------------------------------------------------------
-- Animated GIF and video frame extraction (ffmpeg / magick)
-- ---------------------------------------------------------------------------

--- @param label string
--- @param asset string
--- @param min_frames integer
local function check_frames(label, asset, min_frames)
  if not (have "ffmpeg" or have "magick") then
    skip(label, "needs ffmpeg or magick")
    return
  end
  local path = fresh_copy(asset)
  local ids, err = await(image.transmit_animated_async, path)
  if err then
    fail(label, err)
  elseif type(ids) ~= "table" or #ids < min_frames then
    fail(label, string.format("expected >= %d frames, got %s", min_frames, ids and #ids or "nil"))
  else
    pass(string.format("%s -> %d frames", label, #ids))
  end
end

check_frames("animated GIF extracts frames", "test_animated.gif", 2)
check_frames("MP4 video extracts frames", "test.mp4", 2)

-- ---------------------------------------------------------------------------
-- Video probing (ffprobe)
-- ---------------------------------------------------------------------------

do
  local label = "ffprobe reports video dimensions"
  if not have "ffprobe" then
    skip(label, "needs ffprobe")
  else
    local w, h = image.video_dimensions(root .. "/assets/demo/test.mp4")
    if type(w) == "number" and type(h) == "number" and w > 0 and h > 0 then
      pass(string.format("%s -> %dx%d", label, w, h))
    else
      fail(label, "got " .. vim.inspect { w, h })
    end
  end
end

-- ---------------------------------------------------------------------------
-- Static conversion to PNG (sips / ffmpeg / magick)
-- ---------------------------------------------------------------------------

--- @param label string
--- @param asset string
local function check_convert(label, asset)
  if not (have "sips" or have "ffmpeg" or have "magick") then
    skip(label, "needs sips, ffmpeg or magick")
    return
  end
  local png = image.ensure_png(fresh_copy(asset))
  if type(png) ~= "string" or vim.fn.filereadable(png) ~= 1 then
    fail(label, "no PNG produced (got " .. vim.inspect(png) .. ")")
    return
  end
  local w, h = image.image_dimensions(png)
  if not w or not h or w <= 0 or h <= 0 then
    fail(label, "output is not a readable PNG: " .. png)
  else
    pass(string.format("%s -> %dx%d PNG", label, w, h))
  end
end

check_convert("JPEG converts to PNG", "test.jpg")
check_convert("WebP converts to PNG", "test.webp")

-- ---------------------------------------------------------------------------
-- Native PNG needs no conversion and transmits
-- ---------------------------------------------------------------------------

do
  local label = "PNG transmits without conversion"
  local path = fresh_copy "test.png"
  if not image.is_native_format(path) then
    fail(label, "PNG should be native")
  else
    local id = image.transmit_image(path)
    if type(id) == "number" and id > 0 then
      pass(string.format("%s -> image id %d", label, id))
    else
      fail(label, "no image id (got " .. vim.inspect(id) .. ")")
    end
  end
end

-- ---------------------------------------------------------------------------

vim.api.nvim_ui_send = real_ui_send
image._set_kitty_supported(nil)
vim.fn.delete(tmp, "rf")

print(string.format("\nmedia_test: %d passed, %d failed, %d skipped", pass_count, fail_count, skip_count))
if fail_count > 0 then os.exit(1) end
