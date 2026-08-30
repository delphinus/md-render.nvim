# md-render.nvim

[日本語版はこちら / Japanese version](README.ja.md) — Full Japanese/CJK support with kinsoku shori and BudouX phrase segmentation.

A Markdown rendering engine for Neovim. Transforms raw Markdown into richly highlighted, interactive content — right inside your editor. Supports floating windows, tab views, and a pager mode for `less`-like usage from the command line.

<figure align="center">
  <img src="https://github.com/user-attachments/assets/6c51f971-84bb-49fe-aaff-21db40712187" width="900" height="685" alt="md-render.nvim showcase: inline formatting, tables, callouts, code blocks, images, video, and Mermaid diagrams" />
</figure>

## Highlights

- **Rich inline formatting** — bold, strikethrough, inline code, links, Obsidian `==highlight==`, all rendered in-place
- **Tables** — box-drawing borders, column alignment, proportional sizing, and inline formatting within cells
- **Callouts & folds** — GitHub and Obsidian alert types with colored borders, icons, and folding you can toggle by clicking or with `za` / `<CR>`
- **Code blocks** — fenced blocks with treesitter syntax highlighting; expandable when truncated (click or `za` / `<CR>`)
- **Images** — local and web images (PNG, JPEG, WebP, GIF, animated GIF) displayed inline via terminal graphics protocol
- **Video** — local and web video (MP4, WebM, MOV, AVI, MKV, M4V) played as animated frames inline
- **Mermaid diagrams** — rendered as images inline
- **PlantUML diagrams** — rendered as images inline by a local renderer, or by a server you name
- **CommonMark paragraphs** — soft-wrapped source lines join into one paragraph, including a list item's continuation lines and a blockquote body; no extra space is inserted between CJK characters
- **Nested block structure** — a blockquote, callout, or fenced code block indented to a list item's content is rendered in place, not as literal text
- **CJK-aware word wrapping** — JIS X 4051 kinsoku shori + optional [BudouX](https://github.com/google/budoux) phrase segmentation via [budoux.lua](https://github.com/delphinus/budoux.lua)
- **Clickable links** — mouse click to open URLs; hover the mouse over a link to peek the full URL in a subtle floating window; OSC 8 hyperlink support for compatible terminals
- **`<details>` support** — collapsible sections you can toggle by clicking or with `za` / `<CR>`, respecting the `open` attribute
- **Status footer** — the floating preview shows the file name, your position in the source, and a box-drawing progress bar on its bottom border, without stealing a content row or touching your statusline
- **Library API** — use the rendering engine programmatically from your own plugins

<figure align="center">
  <img src="assets/screenshot-rendering.png" width="672" height="751" alt="Inline formatting, tables, callouts, code blocks, and CJK line-breaking" />
  <figcaption><em>Static preview: inline formatting, tables, callouts, code blocks, and CJK line-breaking</em></figcaption>
</figure>

## Try it yourself

The repo bundles a showcase Markdown file demonstrating every feature. After cloning, view it with the pager:

```bash
git clone https://github.com/delphinus/md-render.nvim
cd md-render.nvim
nvim +"MdRender pager" assets/showcase.md
```

Or, once the plugin is installed, run `:MdRender demo` to see a built-in demo of every supported notation.

## Requirements

- Neovim >= 0.12 (uses `vim.api.nvim_ui_send` for terminal writes)
- For inline images and video: a terminal supporting the [Kitty graphics protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/).
  Verified on [WezTerm](https://wezfurlong.org/wezterm/), [Kitty](https://sw.kovidgoyal.net/kitty/), and [Ghostty](https://ghostty.org/) (macOS/Linux).

<details>
<summary><strong>Optional dependencies</strong></summary>

| Dependency | Purpose | Fallback |
|---|---|---|
| [curl](https://curl.se/) | Download web images and video | Custom function via `set_download_fn()` |
| [FFmpeg](https://ffmpeg.org/) (`ffmpeg` / `ffprobe`) | JPEG/WebP → PNG conversion, animated GIF / video frame extraction | Falls back to ImageMagick (images only; video requires ffmpeg) |
| [ImageMagick](https://imagemagick.org/) (`magick`) | JPEG/WebP → PNG, animated GIF frame extraction | `sips` (macOS) handles static conversion; animated GIF requires ffmpeg or magick |
| [Mermaid CLI](https://github.com/mermaid-js/mermaid-cli) (`mmdc`) | Render Mermaid diagrams as images | Falls back to `npx -y @mermaid-js/mermaid-cli` |
| [PlantUML](https://plantuml.com/) (`plantuml`, or `java` with `$PLANTUML_JAR`) | Render PlantUML diagrams as images | A PlantUML server, if you name one (needs curl); otherwise the fence stays a code block |
| [budoux.lua](https://github.com/delphinus/budoux.lua) | CJK phrase-level line breaking (BudouX) | Character-level splitting (kinsoku rules still apply) |
| Treesitter parsers | Syntax highlighting in code blocks | Code blocks rendered without highlighting |
| [nvim-web-devicons](https://github.com/nvim-tree/nvim-web-devicons) or [mini.icons](https://github.com/echasnovski/mini.icons) | File type icons in code block headers | Built-in icon table |

For image/video format conversion and animation support, the plugin tries tools in this order:

| Use case | 1st | 2nd | 3rd |
|---|---|---|---|
| Static image conversion (JPEG/WebP → PNG) | `sips` (macOS) | `ffmpeg` | `magick` |
| Animated GIF frame extraction | `ffmpeg` | `magick` | — |
| Video frame extraction | `ffmpeg` | — | — |

</details>

## Installation

### lazy.nvim

```lua
{
  "delphinus/md-render.nvim",
  version = "*",
  dependencies = {
    { "nvim-tree/nvim-web-devicons", version = "*" }, -- optional: file type icons in code blocks
    { "delphinus/budoux.lua", version = "*" }, -- optional: CJK phrase-level line breaking
  },
  keys = {
    { "<leader>mp", "<Plug>(md-render-preview)",     desc = "Markdown preview (toggle)" },
    { "<leader>mt", "<Plug>(md-render-preview-tab)", desc = "Markdown preview in tab (toggle)" },
    { "<leader>md", "<Plug>(md-render-demo)",        desc = "Markdown render demo" },
  },
}
```

### vim.pack (Neovim 0.12+)

```lua
vim.pack.add({
  "https://github.com/delphinus/md-render.nvim",
  -- optional:
  "https://github.com/nvim-tree/nvim-web-devicons",
  "https://github.com/delphinus/budoux.lua",
})
```

### mini.deps

```lua
local add = MiniDeps.add
add({
  source = "delphinus/md-render.nvim",
  depends = {
    "nvim-tree/nvim-web-devicons", -- optional
    "delphinus/budoux.lua",        -- optional
  },
})
```

## Comparison with similar plugins

<details>
<summary><strong>Why not other Markdown previewers?</strong></summary>

- **[markdown-preview.nvim](https://github.com/iamcco/markdown-preview.nvim)** — Excellent for true browser-quality rendering, but requires a browser context. md-render runs entirely inside the terminal.
- **[render-markdown.nvim](https://github.com/MeanderingProgrammer/render-markdown.nvim)** — Beautiful in-buffer rendering, but modifies the editing buffer itself. md-render keeps your editing buffer untouched and renders into a separate floating/tab window or pager view.
- **[mcat](https://github.com/Skardyy/mcat)** — Closest in spirit (a pure-terminal Markdown renderer), but lacks complex layout features like auto-folding tables, click-to-toggle folds, and CJK word wrapping.

md-render.nvim aims to be a dedicated previewer that runs entirely in the terminal, with rich layout support and first-class CJK handling.

</details>

## Keymaps

The plugin provides `<Plug>` mappings but does **not** set any default keybindings. Map them yourself:

```lua
vim.keymap.set("n", "<leader>mp", "<Plug>(md-render-preview)",     { desc = "Markdown preview (toggle)" })
vim.keymap.set("n", "<leader>mt", "<Plug>(md-render-preview-tab)", { desc = "Markdown preview in tab (toggle)" })
vim.keymap.set("n", "<leader>md", "<Plug>(md-render-demo)",        { desc = "Markdown render demo" })
```

| `<Plug>` mapping | Description |
|---|---|
| `<Plug>(md-render-preview)` | Toggle a floating preview window for the current Markdown buffer |
| `<Plug>(md-render-preview-tab)` | Toggle a tab preview for the current Markdown buffer |
| `<Plug>(md-render-toggle)` | Toggle the current window between source and render mode in place |
| `<Plug>(md-render-auto)` | **[experimental]** Toggle auto mode (render outside Insert) for the current buffer |
| `<Plug>(md-render-split)` | Open a split showing source and rendered Markdown |
| `<Plug>(md-render-demo)` | Show a demo window with all supported Markdown notations |

### In-preview keys

Inside a rendered preview (floating, tab, or in-place toggle), these buffer-local keys are set automatically:

| Key | Action |
|---|---|
| `za` | Toggle the fold / expandable region under the cursor (no-op elsewhere) |
| `<CR>` | Toggle the fold / expandable region under the cursor (no-op elsewhere) |
| `<LeftMouse>` | Toggle folds, expand regions, and open links by clicking |
| `q` / `<Esc>` / `<C-c>` | Close the window (floating / tab mode only) |

## Commands

The plugin exposes a single `:MdRender` command with subcommands:

| Command | Description |
|---|---|
| `:MdRender` | Floating preview window (alias of `:MdRender float`) |
| `:MdRender float` | Toggle a floating preview window |
| `:MdRender tab` | Toggle a tab preview |
| `:MdRender toggle` | Toggle the current window between source and render mode in place |
| `:MdRender split` | Open a split showing source and rendered Markdown (honours `:vert`, `:tab`, `:topleft`, `:botright`) |
| `:MdRender auto [on\|off\|toggle]` | **[experimental]** Auto-toggle source/render based on Insert mode (per buffer) |
| `:MdRender textsize [on\|off\|toggle]` | **[experimental]** Scale headings via the Kitty text sizing protocol (on by default) |
| `:MdRender pager` | Pager mode — full-screen, no chrome, `q` to quit Neovim |
| `:MdRender demo` | Show a demo window with all supported Markdown notations |

Tab completion lists the subcommands for the first arg, and `on` / `off` / `toggle` after `auto` and `textsize`.

> **Backwards compatibility.** The legacy top-level commands (`:MdRenderTab`, `:MdRenderToggle`, `:MdRenderSplit`, `:MdRenderAuto`, `:MdRenderPager`, `:MdRenderDemo`) still work and forward to the new dispatcher. They print a one-shot deprecation warning per Neovim session and will be removed in a future major version.

### In-place toggle

`:MdRender toggle` swaps the current window between the source Markdown buffer and a rendered view of it — without opening a new tab or floating window. This is designed for split layouts where you want, for example, code in one split and the rendered README in the other.

```vim
:vsplit README.md
:MdRender toggle
```

Behavior:

- The render buffer is **read-only** and reused across toggles (one render buffer per source).
- When the same source is shown in multiple windows, only the invoking window swaps; edits from other windows are reflected on the next toggle into render mode.
- Cursor position round-trips between source and render via the source-line mapping.
- `number`, `relativenumber`, and `list` are turned off on render-mode windows. The originals are stashed on the window and restored when toggling back to source.
- Inside render mode, `q` / `<Esc>` / `<C-c>` are **not** bound to close — call `:MdRender toggle` again to return to source mode. `<LeftMouse>`, `za`, and `<CR>` still toggle folds and expand regions (and `<LeftMouse>` opens links).

### Auto-toggle on Insert mode (experimental)

> **Experimental.** This feature is new and the UX may change. Please report issues or rough edges.

`:MdRender auto on` keeps the current buffer in render mode while in Normal mode and swaps back to source automatically when you start editing. Pass `off` to disable, or call `:MdRender auto` (or `:MdRender auto toggle`) to toggle. To opt every Markdown buffer in:

```vim
autocmd FileType markdown silent! MdRender auto on
```

See `:help :MdRender-auto` for behavior details — the `i` / `I` / `a` / `A` / `o` / `O` remaps, `:w` forwarding, and the editing operations that are blocked on the read-only render buffer.

### Scaled headings (experimental, Kitty only)

> **Experimental.** New and Kitty-only. The UX may change or the feature may be withdrawn. Please report issues or rough edges.

Kitty 0.40 added the [text sizing protocol](https://sw.kovidgoyal.net/kitty/text-sizing-protocol/) (OSC 66), which draws text at a multiple of the base font size. md-render uses it to give every heading level its own size:

| Level | `#` | `##` | `###` | `####` | `#####` | `######` |
|---|---|---|---|---|---|---|
| Size | 2.00x | 1.75x | 1.50x | 1.40x | 1.25x | 1.17x |

This is on whenever the terminal supports it — no configuration needed. Turn it off with `:MdRender textsize off`, or permanently with:

```lua
require("md-render.text_size").setup { enabled = false }
```

The ladder is fixed. Kitty's `s=` scale multiplies the *cells* a run occupies, not just the font, so every level stays at `s=2` — one extra rendered row, never more — and the sizes below 2x come from the protocol's fractional scale plus a `w=` width per run. The protocol caps `d` at 15 and `w` at 7, which is why the deepest level lands on 1.17x rather than something closer to plain.

Headings wrap at `1 / size` of the usual width so that every level scales rather than only the ones that happen to fit, and each wrapped line gets its own two-row block.

A fractionally scaled heading goes out as several runs, because each has to declare its width in whole cells while its text does not measure a whole number of them. That width is rounded up — Kitty drops characters that do not fit — and the runs are cut where the leftover cell disappears: at a boundary that comes out exact where there is one, and otherwise after a space, so the slack reads as a slightly wider word gap instead of a hole in a word.

The scaled text is written straight to the terminal, the same way inline images are, so Neovim knows nothing about it. The plain-size heading stays in the buffer underneath and the scaled text is painted over it — every terminal repaint degrades to the normal heading rather than to a blank line, and `y` / `/` / `:w` still see the real text.

Known limitations:

- **Kitty >= 0.40 only.** Support is detected by asking the terminal to identify itself (XTVERSION) and requires a positive answer. This is deliberately strict: some terminals swallow an OSC 66 sequence *together with its payload text*, which would delete the heading rather than fall back to unscaled text. Everywhere else the feature costs nothing and headings render as they always did.
- Inline formatting inside a heading (inline code, links, `==highlight==`) loses its colors while scaled.
- Every level reserves a two-row block while only `#` fills it, so the rest are centered in theirs (`v=2`) instead of sitting against the top edge, which is the protocol's default. At `######` — 1.17x in a block twice as tall — the top edge left almost a whole row empty under the heading.
- The level icon stays at normal size, but goes out as a run of its own rather than as the plain text underneath, so it is centered in the same block and stays level with the heading it labels (`n=1:d=2` against `s=2` cancels the cell scale exactly). Its own run is also what keeps it legible: Kitty gives a scaled run exactly `s` cells per source cell, and these Nerd Font glyphs report as one cell wide while being drawn wider, so sharing the heading's run would clip the icon — `󰉬` would render as a bare "H". Alone, `w=1` gives it the two-cell block the icon already occupies, and it fits.
- A heading whose second row would fall outside the window stays plain until scrolled into view.
- A repaint by anything else (another plugin forcing a redraw, a message or popup overlapping the window, the terminal shifting cells for a mouse scroll) drops the heading back to plain size, and there is no way to stop that happening. Recovery is on three signals, in order of how quickly they arrive: a scroll, resize, or window opening or closing repaints at once; any redraw at all is picked up from a decoration provider on the tick after it; and `SafeState` covers the rest, rate-limited, with a 500 ms timer behind it for a repaint that never settles. md-render's own repaints are handled properly rather than waited out — inline images and scaled headings both draw outside Neovim's grid and are both destroyed by a full repaint, so whichever of the two repaints announces it and the other puts itself back at once.
- **A plugin that repaints inside `eventignore = "all"` costs a frame that cannot be recovered any sooner.** Autocmds are how everything above learns that anything happened, and that setting silences all of them. The decoration provider still fires — it is not an autocmd — so the heading comes back on the next tick, but it does go for that one frame. [nvim-scrollview](https://github.com/dstein64/nvim-scrollview) is the known case: it opens a float the size of the whole editor, moves a dozen small ones and closes them again, about twenty times a second while the mouse moves, all of it inside `eventignore = "all"`. Measured over fifteen seconds, 308 calls to `nvim_open_win` produced one `WinNew`. To turn it off while a preview is on screen, match on `b:md_render` (set on every buffer md-render renders into) rather than pairing open and close events — a preview can be opened more than once and split by hand, and asking "is one open" needs no bookkeeping:

  ```lua
  local off = false
  vim.api.nvim_create_autocmd({ "WinNew", "WinClosed", "BufWinEnter" }, {
    callback = vim.schedule_wrap(function()
      local want = false
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        if vim.b[vim.api.nvim_win_get_buf(w)].md_render then
          want = true
          break
        end
      end
      if want ~= off then
        off = want
        vim.cmd(want and "ScrollViewDisable" or "ScrollViewEnable")
      end
    end),
  })
  ```

- Each layout change costs a full-screen repaint to clear the previous scaled run, so scrolling is more expensive than usual. When the window also holds images the image redraw does that clearing, and the scaled text is simply written after it.
- The Telescope and Snacks previewers opt out. They redraw on every cursor step, and a full-screen repaint per step is not something a picker can afford.

See `:help md-render-text-size` for the full rationale.

### Source/render split

<figure>
  <img src="https://github.com/user-attachments/assets/24999fe8-9ff0-4ca3-9bd1-b72ec5d7f33c" width="407" height="328" alt="Source/render split" />
  <figcaption><em>Source/render split — edits propagate live, including inline images</em></figcaption>
</figure>

`:MdRender split` opens a split showing the source buffer and the rendered view together. Direction follows standard Vim split modifiers:

- `:MdRender split` — horizontal split
- `:vert MdRender split` — vertical split (typical "README + code" layout)
- `:tab MdRender split` — split inside a new tab
- `:topleft MdRender split` — place at the top
- `:botright MdRender split` — place at the bottom

Edits to the source propagate live, and cursor/scroll position is synchronized in both directions. See `:help :MdRender-split` for full behavior and the inline-image limitation.

### Pager mode

<figure>
  <img src="https://github.com/user-attachments/assets/3c8d94a2-7a7d-4d99-ac9c-1b69870fee67" width="682" height="446" alt="Pager mode" />
  <figcaption><em>Pager mode — browse Markdown like <code>less</code></em></figcaption>
</figure>

Use `:MdRender pager` to view Markdown files like `less`:

```bash
nvim +"MdRender pager" README.md
```

Add a shell alias for convenience:

```bash
alias mdless='nvim +"MdRender pager"'
mdless README.md
```

## Telescope Integration

<figure>
  <img src="https://github.com/user-attachments/assets/29fff5f5-d437-46d7-b92c-3d1a4bb21dd8" width="472" height="457" alt="Telescope integration" />
  <figcaption><em>Telescope previewer with md-render</em></figcaption>
</figure>

### Previewer

`require("md-render.telescope").previewer()` creates a previewer that can be
passed to any [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim)
picker — builtin, extension, or custom:

```lua
local previewer = require("md-render.telescope").previewer()

require("telescope.builtin").find_files({ previewer = previewer })
require("telescope").extensions.egrepify.egrepify({ previewer = previewer })
```

The previewer automatically handles three kinds of files:

| File type | Behavior |
|---|---|
| Markdown (`.md`, `.markdown`) | Full md-render rendering with highlights, links, and images |
| Image / Video (PNG, JPEG, WebP, GIF, MP4, ...) | Inline display via Kitty graphics protocol |
| Other files | Falls back to telescope's default previewer with syntax highlighting |

For grep-based pickers, the preview scrolls to the matched line.

### `:Telescope md_render` Extension

A shortcut for builtin pickers. Wraps `telescope.builtin` pickers with the
md-render previewer. All arguments are passed through:

```vim
:Telescope md_render find_files
:Telescope md_render live_grep cwd=~/notes
:Telescope md_render grep_string search=TODO
```

## Snacks.nvim Integration

`require("md-render.snacks").preview()` creates a preview function for
[snacks.nvim](https://github.com/folke/snacks.nvim) pickers. It handles the
same three file types as the telescope previewer (Markdown, image/video, and
fallback).

Configure it globally to apply to all pickers:

```lua
require("snacks").setup({
  picker = {
    preview = require("md-render.snacks").preview(),
  },
})
```

Or per-source:

```lua
require("snacks").setup({
  picker = {
    sources = {
      files = { preview = require("md-render.snacks").preview() },
      grep = { preview = require("md-render.snacks").preview() },
    },
  },
})
```

## FAQ / Troubleshooting

<details>
<summary><strong>Images don't show — only their alt text or filenames appear</strong></summary>

Inline image display requires a terminal that supports the [Kitty graphics protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/). Verify you're using **WezTerm**, **Kitty**, or **Ghostty**. tmux and other multiplexers may strip the image escape sequences unless explicitly configured to pass them through.

</details>

<details>
<summary><strong>Videos appear as a single static frame</strong></summary>

Video frame extraction requires `ffmpeg` to be installed and available in `$PATH`. Without it, the plugin falls back to displaying just the first frame as a still image. Install it via your package manager (e.g. `brew install ffmpeg`).

</details>

<details>
<summary><strong>Mermaid diagrams don't render</strong></summary>

Mermaid rendering requires the `mmdc` binary from [@mermaid-js/mermaid-cli](https://github.com/mermaid-js/mermaid-cli). If `mmdc` isn't installed globally, the plugin falls back to `npx -y @mermaid-js/mermaid-cli`, which is significantly slower on first invocation. Install it globally with `npm install -g @mermaid-js/mermaid-cli` for faster rendering.

</details>

<details>
<summary><strong>PlantUML diagrams don't render</strong></summary>

Fenced blocks tagged `plantuml` or `puml` are rendered locally when a `plantuml` binary is on your `PATH` (most package managers ship one), or when `java` is available and `$PLANTUML_JAR` points at a readable `plantuml.jar`. Install one of those and the fence becomes a diagram.

There is no fallback unless you ask for one. PlantUML renders on a server by design, and rendering on somebody else's means sending the diagram there, so the plugin will not choose that for you — without a local renderer, a `plantuml` fence stays a code block. Name a server and it will be used:

```lua
require("md-render.image").setup {
  -- Your own instance, or "https://www.plantuml.com/plantuml" for the public
  -- one. Either way the diagram source is sent there, so pick knowing that.
  plantuml_server = "https://plantuml.example.com/plantuml",
}
```

The server also needs `curl`. Rendered diagrams are cached under `stdpath("cache")/md-render/plantuml`, keyed by the diagram source, so a diagram is only sent once.

</details>

<details>
<summary><strong>Japanese text wrapping looks unnatural</strong></summary>

By default, md-render applies JIS X 4051 kinsoku shori (forbidden line-break rules) at the character level. For phrase-level segmentation that respects natural word boundaries in Japanese, install [budoux.lua](https://github.com/delphinus/budoux.lua) — the plugin will automatically detect and use it.

</details>

<details>
<summary><strong>Code blocks have no syntax highlighting</strong></summary>

Syntax highlighting requires the corresponding treesitter parser to be installed. For example, to highlight Lua code blocks, install the `lua` parser via `:TSInstall lua` (with [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter)) or via Neovim 0.11+'s built-in parser management.

</details>

## Usage as a library

<details>
<summary><strong>Programmatic API</strong></summary>

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

-- Display images (requires a Kitty Graphics Protocol compatible terminal)
-- Images are automatically cleaned up when the window is closed.
local win = vim.api.nvim_get_current_win()
md.display_utils.setup_images(win, content, ns)
```

</details>

## Development

### Running Tests

```bash
make test
```

This runs all `tests/*_test.lua` files via `nvim --headless`. New test files matching the `*_test.lua` pattern are picked up automatically.

## License

MIT — see [LICENSE](LICENSE).
