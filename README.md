# md-render.nvim

[日本語版はこちら](#日本語)

A Markdown rendering engine for Neovim floating windows. Transforms raw Markdown into richly highlighted, interactive content — right inside your editor.

<table>
<tr>
<td><img src="assets/screenshot-rendering.png" alt="Markdown rendering features" /></td>
<td><img src="assets/screenshot-images.png" alt="Images and Mermaid diagrams" /></td>
</tr>
<tr>
<td align="center"><em>Inline formatting, tables, callouts, code blocks, and CJK line-breaking</em></td>
<td align="center"><em>Local/web images (including animated GIF) and Mermaid diagrams</em></td>
</tr>
</table>

## Highlights

- **Rich inline formatting** — bold, strikethrough, inline code, links, Obsidian `==highlight==`, all rendered in-place
- **Tables** — box-drawing borders, column alignment, proportional sizing, and inline formatting within cells
- **Callouts & folds** — GitHub and Obsidian alert types with colored borders, icons, and click-to-toggle folding
- **Code blocks** — fenced blocks with treesitter syntax highlighting; expandable when truncated
- **Images** — local and web images (PNG, JPEG, WebP, GIF, animated GIF) displayed inline via terminal graphics protocol
- **Mermaid diagrams** — rendered as images inline
- **CJK-aware word wrapping** — [BudouX](https://github.com/google/budoux) phrase segmentation + JIS X 4051 kinsoku shori
- **Clickable links** — mouse click to open URLs; OSC 8 hyperlink support for compatible terminals
- **`<details>` support** — collapsible sections with click-to-toggle, respecting the `open` attribute
- **Library API** — use the rendering engine programmatically from your own plugins

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

## License

MIT — see [LICENSE](LICENSE).

This project includes code ported from [BudouX](https://github.com/google/budoux) (Copyright 2021 Google LLC, Apache-2.0). See [NOTICE](NOTICE) for details.

---

# 日本語

Neovim のフローティングウィンドウで Markdown をリッチにレンダリングするエンジンです。生の Markdown テキストをハイライト付きのインタラクティブなコンテンツに変換して、エディタ内で表示します。

<table>
<tr>
<td><img src="assets/screenshot-rendering.png" alt="Markdown レンダリング機能" /></td>
<td><img src="assets/screenshot-images.png" alt="画像と Mermaid ダイアグラム" /></td>
</tr>
<tr>
<td align="center"><em>インライン書式、テーブル、コールアウト、コードブロック、CJK 折り返し</em></td>
<td align="center"><em>ローカル/Web 画像（アニメーション GIF 含む）と Mermaid ダイアグラム</em></td>
</tr>
</table>

## 主な機能

- **リッチなインライン書式** — 太字、取り消し線、インラインコード、リンク、Obsidian `==highlight==` をその場でレンダリング
- **テーブル** — 罫線文字による描画、列アラインメント、比例サイズ調整、セル内インライン書式
- **コールアウト & 折りたたみ** — GitHub / Obsidian のアラートタイプに対応。色付きボーダー・アイコン・クリックで折りたたみ切り替え
- **コードブロック** — treesitter シンタックスハイライト付きフェンスコードブロック。省略時はクリックで展開
- **画像** — ローカルおよび Web 画像（PNG, JPEG, WebP, GIF, アニメーション GIF）をターミナルグラフィクスプロトコルでインライン表示
- **Mermaid ダイアグラム** — 画像としてインライン表示
- **CJK 対応ワードラップ** — [BudouX](https://github.com/google/budoux) のフレーズ分割 + JIS X 4051 禁則処理
- **クリック可能リンク** — マウスクリックで URL を開く。対応ターミナルでは OSC 8 ハイパーリンク
- **`<details>` 対応** — クリックで折りたたみ可能なセクション。`open` 属性にも対応
- **ライブラリ API** — レンダリングエンジンを自作プラグインからプログラム的に利用可能

## 必要要件

- Neovim >= 0.10
- Treesitter パーサー（コードブロックのシンタックスハイライト用、オプション）

## インストール

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

## キーマップ

このプラグインは `<Plug>` マッピングを提供しますが、デフォルトのキーバインドは設定**しません**。自分でマッピングしてください：

```lua
vim.keymap.set("n", "<leader>mp", "<Plug>(md-render-preview)", { desc = "Markdown preview (toggle)" })
vim.keymap.set("n", "<leader>md", "<Plug>(md-render-demo)",    { desc = "Markdown render demo" })
```

| `<Plug>` マッピング | 説明 |
|---|---|
| `<Plug>(md-render-preview)` | 現在の Markdown バッファのフローティングプレビューをトグル |
| `<Plug>(md-render-demo)` | 対応する全 Markdown 記法のデモウィンドウを表示 |

## 使い方

### ライブラリとして使う

レンダリングエンジンをプログラムから利用してハイライト付きコンテンツを構築できます：

```lua
local md = require("md-render")

-- 1 行の Markdown をレンダリング
local text, highlights, links = md.Markdown.render("**bold** and [link](https://example.com)")

-- ドキュメント全体のコンテンツを構築
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

-- バッファに適用
local buf = vim.api.nvim_create_buf(false, true)
local ns = vim.api.nvim_create_namespace("my_ns")
md.display_utils.apply_content_to_buffer(buf, ns, content)
```

## ライセンス

MIT — [LICENSE](LICENSE) を参照。

本プロジェクトには [BudouX](https://github.com/google/budoux)（Copyright 2021 Google LLC、Apache-2.0）から移植したコードが含まれています。詳細は [NOTICE](NOTICE) を参照してください。
