# md-render.nvim

Markdown rendering engine for Neovim floating windows. Transforms raw Markdown text into richly highlighted, interactive content displayed in floating windows.

## Features

- **Inline formatting** — bold (`**bold**`), strikethrough (`~~strike~~`), inline code (`` `code` ``), and Obsidian highlight (`==highlight==`)
- **Headings** — ATX (`# H1` .. `###### H6`) and Setext styles, each with distinct icons and treesitter-aware colors
- **Links** — `[text](url)`, reference-style `[text][ref]`, bare URLs (auto-truncated), `#123` issue/PR references, and configurable autolinks (e.g. `JIRA-123`)
- **Obsidian support** — `[[wikilinks]]`, `![[embeds]]`, `%%inline comments%%`, block comments, and all callout/alert types
- **Alerts / Callouts** — GitHub (`NOTE`, `TIP`, `IMPORTANT`, `WARNING`, `CAUTION`) and Obsidian extended types (`ABSTRACT`, `TODO`, `SUCCESS`, `QUESTION`, `FAILURE`, `DANGER`, `BUG`, `EXAMPLE`, `QUOTE`, etc.) with colored borders, icons, and background highlights
- **Foldable callouts** — `[!TYPE]+` / `[!TYPE]-` syntax with click-to-toggle fold indicators
- **Tables** — parsed and rendered with box-drawing borders, column alignment (left/center/right), proportional column shrinking, and inline formatting within cells
- **Code blocks** — fenced code blocks with treesitter syntax highlighting for the specified language
- **Word wrapping** — CJK-aware wrapping with JIS X 4051 kinsoku shori (line-breaking rules)
- **Blockquotes** — nested blockquote rendering with `│` border indicators
- **Ordered lists** — CommonMark-compliant renumbering
- **Expandable regions** — click to expand/collapse truncated code blocks and tables
- **Clickable links** — mouse click to open URLs; native OSC 8 hyperlink support for compatible terminals
- **YAML frontmatter** — parsed and displayed as a properties section
- **Auto-close** — floating windows close on cursor movement or window change

## Requirements

- Neovim >= 0.10
- Treesitter parsers for syntax-highlighted code blocks (optional)

## Installation

### lazy.nvim

```lua
{
  "delphinus/md-render.nvim",
  version = "*",
  keys = {
    { "<leader>mp", "<Plug>(md-render-preview)", desc = "Markdown preview (toggle)" },
    { "<leader>md", "<Plug>(md-render-demo)",    desc = "Markdown render demo" },
  },
}
```

## Keymaps

The plugin provides `<Plug>` mappings but does **not** set any default keybindings. Map them yourself:

```lua
vim.keymap.set("n", "<leader>mp", "<Plug>(md-render-preview)", { desc = "Markdown preview (toggle)" })
vim.keymap.set("n", "<leader>md", "<Plug>(md-render-demo)",    { desc = "Markdown render demo" })
```

| `<Plug>` mapping | Description |
|---|---|
| `<Plug>(md-render-preview)` | Toggle a floating preview window for the current Markdown buffer |
| `<Plug>(md-render-demo)` | Show a demo window with all supported Markdown notations |

## Usage

### Markdown Preview

Open a floating preview window for the current Markdown buffer:

```lua
require("md-render").preview.show()
```

### Demo

Show a demo window with all supported Markdown notations (headings, lists, tables, code blocks, alerts, kinsoku wrapping, etc.):

```lua
require("md-render").preview.show_demo()
```

### As a Library

Use the rendering engine to build highlighted content programmatically:

```lua
local md = require("md-render")

-- Render a single line of markdown
local text, highlights, links = md.Markdown.render("**bold** and [link](https://example.com)")

-- Build full document content
local ContentBuilder = md.ContentBuilder
local b = ContentBuilder.new()
b:render_document(lines, {
  max_width = 80,
  indent = "  ",
  repo_base_url = "https://github.com/user/repo",
  autolinks = {
    { key_prefix = "JIRA-", url_template = "https://jira.example.com/browse/JIRA-<num>" },
  },
})
local content = b:result()

-- Apply to a buffer
local buf = vim.api.nvim_create_buf(false, true)
local ns = vim.api.nvim_create_namespace("my_ns")
md.display_utils.apply_content_to_buffer(buf, ns, content)
```

## Module Structure

| Module | Description |
|---|---|
| `md-render.init` | Entry point; sets up highlight groups and re-exports submodules |
| `md-render.markdown` | Markdown line parser — inline formatting, links, alerts, blockquotes |
| `md-render.content_builder` | Builds rendered content with word wrapping, code blocks, tables, and callouts |
| `md-render.markdown_table` | Table parser and renderer with alignment and proportional column sizing |
| `md-render.float_win` | Floating window lifecycle management with auto-close |
| `md-render.display_utils` | Buffer/window utilities — extmarks, treesitter highlights, keymaps, OSC 8 |
| `md-render.preview` | Markdown preview command with YAML frontmatter and interactive fold/expand |

## Highlight Groups

The plugin defines the following highlight groups (all set with `default = true`, so your colorscheme takes precedence):

- `MdRenderH1` .. `MdRenderH6` — heading levels, derived from treesitter `@markup.heading` groups
- `MdRenderHighlight` — Obsidian `==highlight==` markers
- `MdRenderAlert{Type}` — alert title text (e.g. `MdRenderAlertNote`, `MdRenderAlertWarning`)
- `MdRenderAlert{Type}Bg` — alert background (blended from the alert color and `NormalFloat` background)

## License

MIT
