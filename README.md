# md-render.nvim

[日本語版はこちら](#日本語)

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

---

# 日本語

Neovim のフローティングウィンドウで Markdown をリッチにレンダリングするエンジンです。生の Markdown テキストをハイライト付きのインタラクティブなコンテンツに変換して表示します。

## 機能

- **インライン書式** — 太字（`**bold**`）、取り消し線（`~~strike~~`）、インラインコード（`` `code` ``）、Obsidian ハイライト（`==highlight==`）
- **見出し** — ATX（`# H1` .. `###### H6`）と Setext スタイル、treesitter 連携のカラー表示
- **リンク** — `[text](url)`、参照スタイル `[text][ref]`、裸 URL（自動省略表示）、`#123` issue/PR 参照、設定可能なオートリンク（例: `JIRA-123`）
- **Obsidian 対応** — `[[wikilinks]]`、`![[embeds]]`、`%%インラインコメント%%`、ブロックコメント、全コールアウトタイプ
- **アラート / コールアウト** — GitHub（`NOTE`、`TIP`、`IMPORTANT`、`WARNING`、`CAUTION`）および Obsidian 拡張タイプ（`ABSTRACT`、`TODO`、`SUCCESS`、`QUESTION`、`FAILURE`、`DANGER`、`BUG`、`EXAMPLE`、`QUOTE` 等）に対応、色付きボーダー・アイコン・背景ハイライト付き
- **折りたたみコールアウト** — `[!TYPE]+` / `[!TYPE]-` 構文でクリックによる折りたたみ切り替え
- **テーブル** — 罫線文字による描画、列アラインメント（左/中央/右）、比例列縮小、セル内インライン書式
- **コードブロック** — フェンスコードブロックと treesitter によるシンタックスハイライト
- **ワードラップ** — CJK 対応の折り返しと JIS X 4051 禁則処理
- **ブロック引用** — `│` ボーダー付きのネスト対応
- **番号付きリスト** — CommonMark 準拠の番号振り直し
- **展開可能領域** — クリックで省略されたコードブロックやテーブルを展開/折りたたみ
- **クリック可能リンク** — マウスクリックで URL を開く、対応ターミナルでの OSC 8 ハイパーリンク
- **YAML フロントマター** — パースしてプロパティセクションとして表示
- **自動クローズ** — カーソル移動やウィンドウ切り替えでフローティングウィンドウを自動で閉じる

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

### Markdown プレビュー

現在の Markdown バッファのフローティングプレビューウィンドウを開きます：

```lua
require("md-render").preview.show()
```

### デモ

対応する全 Markdown 記法（見出し、リスト、テーブル、コードブロック、アラート、禁則処理など）のデモウィンドウを表示します：

```lua
require("md-render").preview.show_demo()
```

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

## モジュール構成

| モジュール | 説明 |
|---|---|
| `md-render.init` | エントリポイント。ハイライトグループの設定とサブモジュールの再エクスポート |
| `md-render.markdown` | Markdown 行パーサー — インライン書式、リンク、アラート、ブロック引用 |
| `md-render.content_builder` | ワードラップ、コードブロック、テーブル、コールアウトを含むレンダリングコンテンツの構築 |
| `md-render.markdown_table` | テーブルのパースとレンダリング（アラインメント、比例列サイズ調整） |
| `md-render.float_win` | フローティングウィンドウのライフサイクル管理と自動クローズ |
| `md-render.display_utils` | バッファ/ウィンドウユーティリティ — extmarks、treesitter ハイライト、キーマップ、OSC 8 |
| `md-render.preview` | YAML フロントマターとインタラクティブな折りたたみ/展開付き Markdown プレビュー |

## ハイライトグループ

以下のハイライトグループを定義します（すべて `default = true` で設定されるため、カラースキームが優先されます）：

- `MdRenderH1` .. `MdRenderH6` — 見出しレベル、treesitter の `@markup.heading` グループから導出
- `MdRenderHighlight` — Obsidian `==highlight==` マーカー
- `MdRenderAlert{Type}` — アラートタイトルテキスト（例: `MdRenderAlertNote`、`MdRenderAlertWarning`）
- `MdRenderAlert{Type}Bg` — アラート背景（アラート色と `NormalFloat` 背景色のブレンド）

## ライセンス

MIT
