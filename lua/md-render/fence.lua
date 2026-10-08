--- Fenced code block delimiters, as CommonMark / GFM define them.
---
--- A fence is a run of at least three backticks or three tildes.  The info
--- string after it may be separated by spaces (``` bash), and its first word
--- is the language.  A block is closed only by a run of the *same* character
--- that is at least as long as the opening one and followed by nothing but
--- whitespace, so ```` can wrap a sample that itself contains ```, and a
--- ~~~ block can hold ``` lines.
---
--- Every pass that has to skip code (tab expansion, container indent,
--- paragraph joining, footnote collection, the renderer itself) tracks fences
--- through this module, so they all agree on where a block starts and ends.

local M = {}

---@class MdRender.Fence
---@field char string "`" or "~"
---@field len integer length of the fence run
---@field indent string whitespace in front of the fence
---@field info string info string, trimmed
---@field lang string? first word of the info string

--- Parse an opening fence.
---@param line string
---@return MdRender.Fence?
function M.opening(line)
  local indent, run = line:match "^(%s*)(```+)"
  if not run then
    indent, run = line:match "^(%s*)(~~~+)"
  end
  if not run then return nil end
  local info = line:sub(#indent + #run + 1)
  -- A backtick fence's info string may not contain a backtick; ``` x ```
  -- is an inline code span, not a fence.
  if run:sub(1, 1) == "`" and info:find("`", 1, true) then return nil end
  info = vim.trim(info)
  return {
    char = run:sub(1, 1),
    len = #run,
    indent = indent,
    info = info,
    lang = info:match "^%S+",
  }
end

--- Whether `line` closes the block opened by `fence`.
---@param line string
---@param fence MdRender.Fence
---@return boolean
function M.closes(line, fence)
  local indent, run = line:match "^(%s*)(```+)%s*$"
  if not run then
    indent, run = line:match "^(%s*)(~~~+)%s*$"
  end
  if not run or run:sub(1, 1) ~= fence.char or #run < fence.len then return false end
  -- Four more columns than the container is code, not a fence.  The
  -- container's column is not known here (a fence under a list item keeps
  -- the item's indent), so measure from the opening fence instead.
  return #indent <= #fence.indent + 3
end

--- Advance a fence tracker by one line.
---
--- `open` is the fence of the block the previous line was in (nil outside
--- code).  Returns the fence the next line is in, and whether this line was
--- itself a fence (opening or closing).
---@param open MdRender.Fence?
---@param line string
---@return MdRender.Fence? open, boolean is_fence
function M.step(open, line)
  if open then
    if M.closes(line, open) then return nil, true end
    return open, false
  end
  local fence = M.opening(line)
  return fence, fence ~= nil
end

return M
