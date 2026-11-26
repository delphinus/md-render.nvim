-- A pipe table inside a blockquote renders as a table behind the quote's bar
-- Run: nvim --headless -u NONE --noplugin -l tests/blockquote_table_test.lua

package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local ContentBuilder = require("md-render.content_builder").ContentBuilder

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

---@param lines string[]
---@return MdRender.Content
local function render(lines)
  local b = ContentBuilder.new()
  b:render_document(lines, { max_width = 60, indent = "  " })
  return b:result()
end

--- The highlight groups on 0-based `line`, in order.
---@param content MdRender.Content
---@param line integer
---@return string[]
local function groups(content, line)
  local out = {}
  for _, h in ipairs(content.highlights) do
    if h.line == line then
      for _, g in ipairs(h.groups) do
        table.insert(out, g.hl)
      end
    end
  end
  return out
end

test("a table in a quote is drawn as a table behind the bar", function()
  local c = render { "> | foo | bar |", "> |---|---|", "> | A | B |" }
  assert_eq(c.lines, {
    "  │ │ foo │ bar │",
    "  │ │─────│─────│",
    "  │ │ A   │ B   │",
  }, "the rows are laid out, with the quote's bar in front")
  assert_eq(groups(c, 1)[1], "FloatBorder", "the bar is coloured as a quote's bar")
end)

test("the quote's text around the table keeps the bar across the gaps", function()
  local c = render { "> before", "> | x | y |", "> |---|---|", "> | 1 | 2 |", "> after" }
  assert_eq(c.lines, {
    "  │ before",
    "  │ ",
    "  │ │ x │ y │",
    "  │ │───│───│",
    "  │ │ 1 │ 2 │",
    "  │ ",
    "  │ after",
  }, "the gaps above and below the table are part of the quote")
end)

test("an empty quote line is the gap itself", function()
  local c = render { "> before", ">", "> | x |", "> |---|", ">", "> after" }
  assert_eq(c.lines, {
    "  │ before",
    "  │ ",
    "  │ │ x │",
    "  │ │───│",
    "  │ ",
    "  │ after",
  }, "no second gap is added")
end)

test("a table in a callout takes the callout's colours", function()
  local c = render { "> [!NOTE]", "> | x | y |", "> |---|---|", "> | 1 | 2 |", "", "> plain" }
  assert_eq(c.lines[2], "  │ │ x │ y │", "the table follows the title directly")
  local g = groups(c, 1)
  assert_eq(g[1], "MdRenderAlertNote", "the bar is in the callout's colour")
  assert_eq(g[2], "FloatBorder", "the table's own border is not recoloured")
  assert_eq(g[#g], "MdRenderAlertNoteBg", "and the line has the callout's background")
  assert_eq(groups(c, #c.lines - 1), { "FloatBorder" }, "the callout ends with the table")
end)

test("a nested quote is left as quoted text", function()
  local c = render { ">> | n | m |" }
  assert_eq(c.lines, { "  │ │ | n | m |" }, "only one level of quote is read as a table")
end)

print(string.format("%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
