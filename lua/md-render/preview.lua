local FloatWin = require "md-render.float_win"
local cb = require "md-render.content_builder"
local display_utils = require "md-render.display_utils"
local ContentBuilder = cb.ContentBuilder

local float_win = FloatWin.new "md_render_preview_float"
local demo_float_win = FloatWin.new "md_render_demo_float"

local MdPreview = {}

--- Parse simple YAML frontmatter lines into key-value pairs
---@param fm_lines string[]
---@return {key: string, value: string}[]
local function parse_frontmatter(fm_lines)
  local entries = {}
  local current_key = nil
  local current_list = {}

  local function flush_list()
    if current_key and #current_list > 0 then
      table.insert(entries, {
        key = current_key,
        value = table.concat(current_list, ", "),
      })
      current_key = nil
      current_list = {}
    end
  end

  for _, line in ipairs(fm_lines) do
    local list_value = line:match "^%s+%-%s+(.+)$"
    if list_value and current_key then
      table.insert(current_list, list_value)
    else
      flush_list()
      local key, value = line:match "^([%w_%-]+):%s*(.*)$"
      if key then
        if value and value ~= "" then
          table.insert(entries, { key = key, value = value })
          current_key = nil
        else
          current_key = key
          current_list = {}
        end
      end
    end
  end
  flush_list()

  return entries
end

--- Build rendered content from markdown lines
---@param lines string[]
---@param opts? { max_width?: integer, fold_state?: table<integer, boolean>, expand_state?: table<integer, boolean>, autolinks?: MdRender.Autolink[] }
---@return MdRender.Content
MdPreview.build_content = function(lines, opts)
  opts = opts or {}
  local max_width = opts.max_width or 80

  local b = ContentBuilder.new()

  -- Detect and extract frontmatter
  local body_start = 1
  if lines[1] and lines[1]:match "^%-%-%-$" then
    local frontmatter_lines = {}
    for i = 2, #lines do
      if lines[i]:match "^%-%-%-$" then
        body_start = i + 1
        break
      end
      table.insert(frontmatter_lines, lines[i])
    end
    if body_start > 1 and #frontmatter_lines > 0 then
      local entries = parse_frontmatter(frontmatter_lines)
      if #entries > 0 then
        b:add_line("  Properties", {
          { col = 2, end_col = 2 + #"Properties", hl = "Title" },
        })
        for _, entry in ipairs(entries) do
          local label = "  " .. entry.key
          local full_line = label .. ": " .. entry.value
          local display_width = vim.fn.strdisplaywidth(full_line)
          if display_width > max_width then
            local target = max_width - 1
            local current_width = 0
            local byte_pos = 0
            for char in full_line:gmatch "[%z\1-\127\194-\253][\128-\191]*" do
              local char_width = vim.fn.strdisplaywidth(char)
              if current_width + char_width > target then
                break
              end
              current_width = current_width + char_width
              byte_pos = byte_pos + #char
            end
            local truncated = full_line:sub(1, byte_pos) .. "…"
            b:add_line(truncated, {
              { col = 0, end_col = #label, hl = "Comment" },
              { col = #label + 2, end_col = byte_pos, hl = "String" },
              { col = byte_pos, end_col = #truncated, hl = "Underlined" },
            })
          else
            b:add_labeled(label, entry.value, "String")
          end
        end
        b:add_line ""
      end
    end
  end

  -- Render the document body using the shared rendering loop
  local body_lines = {}
  for i = body_start, #lines do
    table.insert(body_lines, lines[i])
  end

  b:render_document(body_lines, {
    max_width = max_width,
    fold_state = opts.fold_state,
    expand_state = opts.expand_state,
    autolinks = opts.autolinks,
  })

  return b:result()
end

--- Show a floating window previewing the current buffer's markdown content
---@param opts? { max_width?: integer }
MdPreview.show = function(opts)
  if float_win:close_if_valid() then
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local ft = vim.bo[bufnr].filetype
  local name = vim.api.nvim_buf_get_name(bufnr)

  if ft ~= "markdown" and not name:match "%.md$" and not name:match "%.markdown$" then
    vim.notify("md-render: current buffer is not a Markdown file", vim.log.levels.WARN)
    return
  end

  local source_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local fold_state = {}
  local expand_state = {}
  opts = opts or {}

  local buf = vim.api.nvim_create_buf(false, true)
  local ns = vim.api.nvim_create_namespace "md_render_preview"

  -- Lazy-require to avoid circular dependency (init.lua re-exports preview)
  require("md-render").setup_highlights()

  local content

  local function rebuild()
    opts.fold_state = fold_state
    opts.expand_state = expand_state
    local new_content = MdPreview.build_content(source_lines, opts)
    vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    display_utils.apply_content_to_buffer(buf, ns, new_content)
    vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
    -- Toggle wrap based on whether any block is expanded
    local any_expanded = false
    for _, v in pairs(expand_state) do
      if v then any_expanded = true; break end
    end
    vim.api.nvim_set_option_value("wrap", not any_expanded, { win = win })
    content = new_content
  end

  content = MdPreview.build_content(source_lines, opts)
  display_utils.apply_content_to_buffer(buf, ns, content)
  local win = display_utils.open_float_window(buf, content, float_win, {
    title = " Markdown Preview ",
    position = "center",
    enter = true,
  })

  -- Initialize fold_state from default fold states
  for _, fold in ipairs(content.callout_folds) do
    fold_state[fold.source_line] = fold.collapsed
  end

  display_utils.setup_float_keymaps(buf, ns, win, content, float_win, {
    get_content = function()
      return content
    end,
    on_fold_toggle = function(source_line, collapsed)
      fold_state[source_line] = collapsed
      rebuild()
    end,
    on_expand_toggle = function(block_id, expanded)
      expand_state[block_id] = expanded
      rebuild()
    end,
  })
end

--- Show a demo floating window with all supported Markdown notations
MdPreview.show_demo = function()
  local demo_lines = vim.split(table.concat({
    "## Markdown Rendering Features",
    "",
    "**Bold**, ~~strikethrough~~, `inline code`, and [links](https://neovim.io) — all rendered inline. Bare URLs like https://neovim.io stay clickable. Long ones like https://github.com/neovim/neovim/blob/master/src/nvim/api/buffer.c#L123-L456 are truncated. Obsidian ==highlight== and `%%comments%%` also work.",
    "",
    "### Code & Tables",
    "",
    "```lua",
    'local function greet(name) return "Hello, " .. name end',
    "-- This line is intentionally long to demonstrate that code lines exceeding the max width are truncated with an ellipsis indicator",
    "```",
    "",
    "| Feature | Description | Syntax |",
    "|---------|-------------|--------|",
    "| **Bold** / ~~strike~~ | Inline formatting is rendered inside table cells | `**text**` / `~~text~~` |",
    "| Truncation | Cells that exceed the available width are automatically truncated with an ellipsis | Long content is gracefully handled |",
    "",
    "### Callouts & Folds",
    "",
    "> [!NOTE]",
    "> Standard callout. Five types: `NOTE`, `TIP`, `IMPORTANT`, `WARNING`, `CAUTION`.",
    "",
    "> [!TIP]- Foldable (collapsed)",
    "> Hidden until you click the header. Supports **multiple lines**.",
    "> Click the fold indicator to toggle.",
    "",
    "> [!WARNING]+ Foldable (expanded)",
    "> Visible by default, click to collapse.",
    "> ```lua",
    "> local msg = 'Code blocks inside callouts get treesitter highlighting!'",
    "> ```",
    "",
    "> [!custom] Custom types work too",
    "> Any `[!type]` is rendered as a callout.",
    "",
    "### Expandable Content",
    "",
    "```bash",
    "# This line is intentionally very long to demonstrate the expandable code block feature — click the underlined … to see the full content and scroll horizontally",
    "echo 'Click the … on truncated lines to expand, click again to collapse'",
    "```",
    "",
    "### Collapsible Details",
    "",
    "<details>",
    "<summary>Click to expand this section</summary>",
    "",
    "This content is hidden by default. It supports **bold**, `code`, and [links](https://neovim.io).",
    "",
    "</details>",
    "",
    "<details open>",
    "<summary>Open by default</summary>",
    "",
    "The `open` attribute makes it expanded initially. Click to collapse.",
    "",
    "</details>",
    "",
    "### 日本語テキストの折り返し",
    "",
    "BudouXによる自然な分節処理で、日本語テキストを単語の途中ではなく文節の区切りで改行します。機械学習モデルを使って自然な折り返し位置を推定しています。",
    "",
    "句読点「、」や閉じ括弧「）」が行頭に来ないよう禁則処理（JIS X 4051）を適用。開き括弧「（」は行末に残さず次の行へ送ります。",
    "",
    "> [!NOTE] 日本語コールアウト",
    "> コールアウト内でもBudouXの分節処理と禁則処理は有効。長い文章を自然な位置で折り返します。",
  }, "\n"), "\n")

  if demo_float_win:close_if_valid() then
    return
  end

  local fold_state = {}
  local expand_state = {}
  local opts = {}

  local buf = vim.api.nvim_create_buf(false, true)
  local ns = vim.api.nvim_create_namespace "md_render_demo"

  require("md-render").setup_highlights()

  local content

  local function rebuild()
    opts.fold_state = fold_state
    opts.expand_state = expand_state
    opts.autolinks = {
      { key_prefix = "JIRA-", url_template = "https://jira.example.com/browse/JIRA-<num>" },
    }
    local new_content = MdPreview.build_content(demo_lines, opts)
    vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    display_utils.apply_content_to_buffer(buf, ns, new_content)
    vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
    local any_expanded = false
    for _, v in pairs(expand_state) do
      if v then any_expanded = true; break end
    end
    vim.api.nvim_set_option_value("wrap", not any_expanded, { win = win })
    content = new_content
  end

  opts.autolinks = {
    { key_prefix = "JIRA-", url_template = "https://jira.example.com/browse/JIRA-<num>" },
  }
  content = MdPreview.build_content(demo_lines, opts)
  display_utils.apply_content_to_buffer(buf, ns, content)
  local win = display_utils.open_float_window(buf, content, demo_float_win, {
    title = " Markdown Rendering Demo ",
    position = "center",
    enter = true,
  })

  for _, fold in ipairs(content.callout_folds) do
    fold_state[fold.source_line] = fold.collapsed
  end

  display_utils.setup_float_keymaps(buf, ns, win, content, demo_float_win, {
    get_content = function()
      return content
    end,
    on_fold_toggle = function(source_line, collapsed)
      fold_state[source_line] = collapsed
      rebuild()
    end,
    on_expand_toggle = function(block_id, expanded)
      expand_state[block_id] = expanded
      rebuild()
    end,
  })
end

return MdPreview
