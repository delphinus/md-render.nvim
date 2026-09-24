-- Rendered text must fit the window, including its display indent.
-- Run: nvim --headless -u NONE --noplugin -l tests/wrap_width_test.lua
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local preview = require "md-render.preview"
local heading_prefix = require("md-render.markdown").heading_icon_prefix(2)
local text = string.rep("甲乙丙丁", 12)
local cases = {
  { name = "paragraph", source = { text }, line = 1, prefix = "", continuation = "" },
  { name = "list", source = { "- " .. text }, line = 1, prefix = "• ", continuation = "  " },
  { name = "quote", source = { "> " .. text }, line = 1, prefix = "│ ", continuation = "│ " },
  { name = "heading", source = { "## " .. text }, line = 1, prefix = heading_prefix, continuation = "" },
  {
    name = "callout",
    source = { "> [!NOTE]", "> " .. text },
    line = 2,
    prefix = "│ ",
    continuation = "│ ",
  },
  {
    name = "Qiita note",
    source = { ":::note info", text, ":::" },
    line = 2,
    prefix = "│ ",
    continuation = "│ ",
  },
  {
    name = "list continuation",
    source = { "1. 項目", "", "   " .. text },
    line = 3,
    prefix = "   ",
    continuation = "   ",
  },
  {
    name = "quote in list",
    source = { "1. 項目", "", "   > " .. text },
    line = 3,
    prefix = "   │ ",
    continuation = "   │ ",
  },
  {
    name = "heading in list",
    source = { "1. 項目", "", "   ## " .. text },
    line = 3,
    prefix = "   " .. heading_prefix,
    continuation = "   ",
  },
  {
    name = "definition",
    source = { "<dl>", "<dt>項目</dt>", "<dd>" .. text .. "</dd>", "</dl>" },
    line = 3,
    prefix = "  ",
    continuation = "  ",
  },
}

local checked = 0
for _, case in ipairs(cases) do
  for _, width in ipairs { 20, 21, 40, 41, 80 } do
    -- nil exercises the real two-space default; empty indent covers split mode.
    for _, opts in ipairs { {}, { indent = "" }, { indent = "    " } } do
      opts.max_width, opts.text_scale = width, false
      local indent = opts.indent or "  "
      local out = preview.build_content(case.source, opts)
      local chunks = {}
      for i, line in ipairs(out.lines) do
        assert(vim.api.nvim_strwidth(line) <= width, case.name .. " overflows " .. width .. ": " .. line)
        if out.source_line_map[i] == case.line and not line:match "^%s*$" then
          local prefix = indent .. (#chunks == 0 and case.prefix or case.continuation)
          assert(line:sub(1, #prefix) == prefix, case.name .. " lost its indent")
          chunks[#chunks + 1] = line:sub(#prefix + 1)
        end
      end
      assert(table.concat(chunks) == text, case.name .. " lost or duplicated text")
      -- The first line must use all available CJK cells: this catches taking
      -- a list container's indent off the budget twice.
      local room = width - vim.api.nvim_strwidth(indent .. case.prefix)
      assert(vim.api.nvim_strwidth(chunks[1]) == math.floor(room / 2) * 2, case.name .. " wraps too early")
      checked = checked + 1
    end
  end
end

-- Formatting and link byte offsets must follow the newly wrapped lines.
local label = string.rep("中文", 20)
local out = preview.build_content({ "前綴 **" .. label .. "** [" .. label .. "](https://example.com)" }, {
  max_width = 20,
  text_scale = false,
})
local bold, links = {}, {}
for _, line in ipairs(out.lines) do
  assert(vim.api.nvim_strwidth(line) <= 20, "formatted text overflows")
end
for _, entry in ipairs(out.highlights) do
  for _, group in ipairs(entry.groups) do
    if group.hl == "Bold" then bold[#bold + 1] = out.lines[entry.line + 1]:sub(group.col + 1, group.end_col) end
  end
end
for _, link in ipairs(out.link_metadata) do
  assert(link.url == "https://example.com", "link target changed")
  links[#links + 1] = out.lines[link.line + 1]:sub(link.col_start + 1, link.col_end)
end
assert(table.concat(bold) == label, "bold spans lost text after wrapping")
assert(table.concat(links) == label, "link spans lost text after wrapping")

print(string.format("Wrap width: %d layout cases and formatting/link offsets passed", checked))
