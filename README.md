# md-render.nvim

[日本語版はこちら / Japanese version](README.ja.md)

A Markdown renderer for Neovim that runs entirely in the terminal. It shows a Markdown buffer — images, video, and diagrams included — in a floating window, a tab, a split beside the source, in place of the source, or as a `less`-like pager, and leaves the buffer you edit untouched.

<figure align="center">
  <img src="https://github.com/user-attachments/assets/6c51f971-84bb-49fe-aaff-21db40712187" width="900" height="685" alt="md-render.nvim showcase: inline formatting, tables, callouts, code blocks, images, video, and Mermaid diagrams" />
</figure>

## Features

- **Markdown, fully rendered** — inline formatting, tables, GitHub / Obsidian callouts, `<details>`, and code blocks highlighted by treesitter. Callouts, `<details>`, and truncated code blocks and tables fold and expand with `<CR>` or a click
- **Images and video** — PNG, JPEG, WebP, GIF, and MP4 / WebM / MOV, local or from the web, drawn inline with the Kitty graphics protocol
- **Diagrams** — Mermaid and PlantUML fences rendered as images
- **Zoom** — `<CR>` or a click on an image, a video, or a diagram enlarges it to fill the editor. A Mermaid diagram is drawn again at that size, so its text stays sharp
- **Links** — click to open, hover to see the full URL, OSC 8 hyperlinks
- **Japanese and other CJK text** — JIS X 4051 line breaking, optional [BudouX](https://github.com/google/budoux) phrase breaking, and no stray spaces between joined lines
- **Scaled headings** (experimental, Kitty only) — headings drawn larger with the text sizing protocol
- **Picker previews** — for [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) and [snacks.nvim](https://github.com/folke/snacks.nvim)
- **Library API** — use the rendering engine from your own plugin

https://github.com/user-attachments/assets/1ec8f1fc-bcbd-4333-8751-0372ff1bd73a

## Requirements

- Neovim 0.12 or later
- For images and video: a terminal that supports the [Kitty graphics protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/), such as [WezTerm](https://wezfurlong.org/wezterm/), [Kitty](https://sw.kovidgoyal.net/kitty/), or [Ghostty](https://ghostty.org/)
- Optional: `ffmpeg` (video, animated GIF), [`mmdc`](https://github.com/mermaid-js/mermaid-cli) (Mermaid), `plantuml` (PlantUML), `curl` (web images), [budoux.lua](https://github.com/delphinus/budoux.lua) (CJK phrase breaking), [nvim-web-devicons](https://github.com/nvim-tree/nvim-web-devicons) or [mini.icons](https://github.com/echasnovski/mini.icons) (icons). See `:help md-render-dependencies`

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "delphinus/md-render.nvim",
  version = "*",
  dependencies = {
    { "nvim-tree/nvim-web-devicons", version = "*" }, -- optional
    { "delphinus/budoux.lua", version = "*" }, -- optional
  },
  keys = {
    { "<leader>mp", "<Plug>(md-render-preview)", desc = "Markdown preview (toggle)" },
    { "<leader>mt", "<Plug>(md-render-preview-tab)", desc = "Markdown preview in tab (toggle)" },
  },
}
```

The plugin sets no key mappings of its own. For `vim.pack` and mini.deps, see `:help md-render-installation`.

## Quick start

To see every feature, open the showcase bundled with the plugin in the pager, or run `:MdRender demo`:

```sh
git clone https://github.com/delphinus/md-render.nvim
nvim +"MdRender pager" md-render.nvim/assets/showcase.md
```

| Command | Shows the current Markdown buffer |
|---|---|
| `:MdRender` | in a floating window |
| `:MdRender tab` | in a new tab |
| `:MdRender split` | in a split beside the source; edits and the cursor follow live |
| `:MdRender toggle` | in place of the source, in the same window |
| `:MdRender pager` | full screen; `q` quits Neovim |

In a preview:

| Key | Action |
|---|---|
| `<CR>` | Enlarge the image, or fold / expand the block, under the cursor |
| click | Enlarge an image, fold / expand a block, or open a link |
| `za` | Fold / expand the block under the cursor |
| `q` / `<Esc>` | Close the floating window or tab |

## Documentation

Everything else is in the help: all commands and options, rendering width, the experimental features, picker integration, the Lua API, highlight groups, and troubleshooting.

- `:help md-render.txt` ([doc/md-render.txt](doc/md-render.txt))
- Japanese: `:help md-render.jax` ([doc/md-render.jax](doc/md-render.jax))

## Development

`make test` runs the tests. See [tests/README.md](tests/README.md) for the other test layers.

## License

MIT — see [LICENSE](LICENSE).

`lua/md-render/vendor/` is third-party code kept verbatim under its own license:
a copy of Neovim's `vim.async` (Apache-2.0), which gives Neovim 0.12 the async
runtime 0.13 has built in. See [its README](lua/md-render/vendor/README.md).
