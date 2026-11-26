-- A web image whose download failed says why on its placeholder
-- Run: nvim --headless -u NONE --noplugin -l tests/image_load_error_test.lua

package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local ContentBuilder = require("md-render.content_builder").ContentBuilder
local image = require "md-render.image"

local pass_count = 0
local fail_count = 0

local function assert_eq(actual, expected, msg)
  if vim.deep_equal(actual, expected) then
    pass_count = pass_count + 1
  else
    fail_count = fail_count + 1
    print("FAIL: " .. msg)
    print("  expected: " .. vim.inspect(expected))
    print("  actual:   " .. vim.inspect(actual))
  end
end

local function test(name, fn)
  local ok, err = pcall(fn)
  if not ok then
    fail_count = fail_count + 1
    print("ERROR: " .. name .. ": " .. tostring(err))
  end
end

--- Render `lines` as if the terminal showed images and downloads had failed
--- with the reasons in `errors`.
---@param lines string[]
---@param errors table<string, string> url → reason
---@param max_width? integer
---@return MdRender.Content
local function render(lines, errors, max_width)
  local orig_kitty, orig_error = image.supports_kitty, image.get_download_error
  image.supports_kitty = function()
    return true
  end
  image.get_download_error = function(url)
    return errors[url]
  end
  local ok, result = pcall(function()
    local b = ContentBuilder.new()
    b:render_document(lines, { max_width = max_width or 80, indent = "  " })
    return b:result()
  end)
  image.supports_kitty, image.get_download_error = orig_kitty, orig_error
  if not ok then error(result) end
  return result
end

--- The line holding `needle`, and the highlight groups on it.
---@param content MdRender.Content
---@param needle string
---@return string? line
---@return string[] groups
local function find(content, needle)
  for i, line in ipairs(content.lines) do
    if line:find(needle, 1, true) then
      local groups = {}
      for _, h in ipairs(content.highlights) do
        if h.line == i - 1 then
          for _, g in ipairs(h.groups) do
            table.insert(groups, g.hl)
          end
        end
      end
      return line, groups
    end
  end
  return nil, {}
end

local url = "https://example.invalid/md-render-test-missing.png"

test("a failed download names the reason on the placeholder", function()
  local content = render({ "![missing](" .. url .. ")" }, { [url] = "HTTP 404" })
  local line, groups = find(content, "Failed to load image (HTTP 404)")
  assert_eq(line ~= nil, true, "the placeholder says the download failed and why")
  assert_eq(
    groups,
    { "MdRenderImagePlaceholder", "MdRenderImageError", "MdRenderImagePlaceholder" },
    "the message takes the error colour on the placeholder's background"
  )
  assert_eq(find(content, "Loading image...") == nil, true, "and no longer says it is loading")
end)

test("a placeholder too narrow for the sentence shows the reason alone", function()
  local content = render({ "![missing](" .. url .. ")" }, { [url] = "HTTP 404" }, 30)
  assert_eq(find(content, "Failed to load") == nil, true, "the sentence does not fit")
  assert_eq(find(content, "HTTP 404") ~= nil, true, "the reason does")
end)

test("an image that has not failed still says it is loading", function()
  local content = render({ "![missing](" .. url .. ")" }, {})
  assert_eq(find(content, "Loading image...") ~= nil, true, "the loading message is unchanged")
end)

print(string.format("%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
