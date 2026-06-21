# md-render.nvim

[English version / 英語版はこちら](README.md)

Neovim 用の Markdown レンダリングエンジンです。生の Markdown テキストをハイライト付きのインタラクティブなコンテンツに変換して、エディタ内で表示します。フローティングウィンドウ、タブ表示、コマンドラインからの `less` ライクなページャーモードに対応しています。

<figure align="center">
  <img src="https://github.com/user-attachments/assets/6c51f971-84bb-49fe-aaff-21db40712187" width="900" height="685" alt="md-render.nvim ショーケース：インライン書式、テーブル、コールアウト、コードブロック、画像、動画、Mermaid ダイアグラム" />
</figure>

## 主な機能

- **リッチなインライン書式** — 太字、取り消し線、インラインコード、リンク、Obsidian `==highlight==` をその場でレンダリング
- **テーブル** — 罫線文字による描画、列アラインメント、比例サイズ調整、セル内インライン書式
- **コールアウト & 折りたたみ** — GitHub / Obsidian のアラートタイプに対応。色付きボーダー・アイコン・クリックまたは `za` / `<CR>` で折りたたみ切り替え
- **コードブロック** — treesitter シンタックスハイライト付きフェンスコードブロック。省略時はクリックまたは `za` / `<CR>` で展開
- **画像** — ローカルおよび Web 画像（PNG, JPEG, WebP, GIF, アニメーション GIF）をターミナルグラフィクスプロトコルでインライン表示
- **動画** — ローカルおよび Web 動画（MP4, WebM, MOV, AVI, MKV, M4V）をアニメーションフレームとしてインライン再生
- **Mermaid ダイアグラム** — 画像としてインライン表示
- **CJK 対応ワードラップ** — JIS X 4051 禁則処理 + [BudouX](https://github.com/google/budoux)（[budoux.lua](https://github.com/delphinus/budoux.lua) 経由）によるオプションのフレーズ分割
- **クリック可能リンク** — マウスクリックで URL を開く。対応ターミナルでは OSC 8 ハイパーリンク
- **`<details>` 対応** — クリックまたは `za` / `<CR>` で折りたたみ可能なセクション。`open` 属性にも対応
- **ライブラリ API** — レンダリングエンジンを自作プラグインからプログラム的に利用可能

<figure align="center">
  <img src="assets/screenshot-rendering.png" width="672" height="751" alt="インライン書式、テーブル、コールアウト、コードブロック、CJK 折り返し" />
  <figcaption><em>静止プレビュー：インライン書式、テーブル、コールアウト、コードブロック、CJK 折り返し</em></figcaption>
</figure>

## 試してみる

リポジトリには全機能を一望できるショーケース Markdown が同梱されています。クローン後、ページャーで開いてみてください：

```bash
git clone https://github.com/delphinus/md-render.nvim
cd md-render.nvim
nvim +"MdRender pager" assets/showcase.md
```

プラグインをインストール済みの場合は、`:MdRender demo` で対応する全記法を確認できます。

## 必要要件

- Neovim >= 0.12（端末への書き出しに `vim.api.nvim_ui_send` を使用）
- 画像・動画のインライン表示には [Kitty graphics protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/) 対応ターミナルが必要。
  動作確認は [WezTerm](https://wezfurlong.org/wezterm/) / [Kitty](https://sw.kovidgoyal.net/kitty/) / [Ghostty](https://ghostty.org/)（macOS/Linux）で実施。

<details>
<summary><strong>オプション依存</strong></summary>

| 依存 | 用途 | フォールバック |
|---|---|---|
| [curl](https://curl.se/) | Web 画像・動画のダウンロード | `set_download_fn()` でカスタム関数を指定可 |
| [FFmpeg](https://ffmpeg.org/) (`ffmpeg` / `ffprobe`) | JPEG/WebP → PNG 変換、アニメーション GIF / 動画のフレーム展開 | ImageMagick にフォールバック（画像のみ。動画には ffmpeg が必要） |
| [ImageMagick](https://imagemagick.org/) (`magick`) | JPEG/WebP → PNG、アニメーション GIF フレーム展開 | macOS では `sips` が静止画変換を処理。アニメーション GIF には ffmpeg か magick が必要 |
| [Mermaid CLI](https://github.com/mermaid-js/mermaid-cli) (`mmdc`) | Mermaid ダイアグラムを画像として描画 | `npx -y @mermaid-js/mermaid-cli` にフォールバック |
| [budoux.lua](https://github.com/delphinus/budoux.lua) | CJK フレーズ単位の改行（BudouX） | 1文字ずつ分割（禁則処理は維持） |
| Treesitter パーサー | コードブロックのシンタックスハイライト | ハイライトなしで表示 |
| [nvim-web-devicons](https://github.com/nvim-tree/nvim-web-devicons) または [mini.icons](https://github.com/echasnovski/mini.icons) | コードブロックヘッダのファイルタイプアイコン | 内蔵アイコンテーブル |

画像・動画のフォーマット変換とアニメーションのサポートでは、以下の優先順位でツールを検索します：

| ユースケース | 1st | 2nd | 3rd |
|---|---|---|---|
| 静止画変換（JPEG/WebP → PNG） | `sips`（macOS） | `ffmpeg` | `magick` |
| アニメーション GIF フレーム展開 | `ffmpeg` | `magick` | — |
| 動画フレーム展開 | `ffmpeg` | — | — |

</details>

## インストール

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

### vim.pack（Neovim 0.12+）

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

## 類似プラグインとの比較

<details>
<summary><strong>他の Markdown プレビューアではダメ?</strong></summary>

- **[markdown-preview.nvim](https://github.com/iamcco/markdown-preview.nvim)** — ブラウザ品質のレンダリングが必要な場合は最適ですが、ブラウザを必要とします。md-render はターミナル内で完結します。
- **[render-markdown.nvim](https://github.com/MeanderingProgrammer/render-markdown.nvim)** — バッファ内レンダリングが美しいですが、編集中のバッファ自体を変更します。md-render は編集バッファに手を加えず、別のフローティング/タブウィンドウまたはページャーへ描画します。
- **[mcat](https://github.com/Skardyy/mcat)** — 思想として最も近い（ピュアターミナルの Markdown レンダラー）ですが、自動折りたたみテーブルやクリックで折りたたみ切り替え、CJK ワードラップなどの複雑なレイアウト機能は未対応です。

md-render.nvim は、ターミナル内で完結する専用プレビューアとして、リッチなレイアウトと第一級の CJK サポートを目指しています。

</details>

## キーマップ

このプラグインは `<Plug>` マッピングを提供しますが、デフォルトのキーバインドは設定**しません**。自分でマッピングしてください：

```lua
vim.keymap.set("n", "<leader>mp", "<Plug>(md-render-preview)",     { desc = "Markdown preview (toggle)" })
vim.keymap.set("n", "<leader>mt", "<Plug>(md-render-preview-tab)", { desc = "Markdown preview in tab (toggle)" })
vim.keymap.set("n", "<leader>md", "<Plug>(md-render-demo)",        { desc = "Markdown render demo" })
```

| `<Plug>` マッピング | 説明 |
|---|---|
| `<Plug>(md-render-preview)` | 現在の Markdown バッファのフローティングプレビューをトグル |
| `<Plug>(md-render-preview-tab)` | 現在の Markdown バッファのタブプレビューをトグル |
| `<Plug>(md-render-toggle)` | 現在のウィンドウをソース ↔ レンダーモードでその場切替 |
| `<Plug>(md-render-auto)` | **[実験的]** 現在のバッファで auto モード(Insert 以外で render)をトグル |
| `<Plug>(md-render-split)` | ウィンドウを分割してソースとレンダリング表示を並べる |
| `<Plug>(md-render-demo)` | 対応する全 Markdown 記法のデモウィンドウを表示 |

### プレビュー内のキー

レンダリングされたプレビュー(フローティング・タブ・その場トグル)内では、以下のバッファローカルなキーが自動で設定されます:

| キー | 動作 |
|---|---|
| `za` | カーソル行の折りたたみ / 展開ブロックを切り替える(該当しない行では何もしない) |
| `<CR>` | カーソル行の折りたたみ / 展開ブロックを切り替える(該当しない行では何もしない) |
| `<LeftMouse>` | クリックで折りたたみ・展開を切り替え、リンクを開く |
| `q` / `<Esc>` / `<C-c>` | ウィンドウを閉じる(フローティング / タブモードのみ) |

## コマンド

このプラグインが公開するユーザコマンドは `:MdRender` ひとつで、サブコマンドで動作モードを切り替えます。

| コマンド | 説明 |
|---|---|
| `:MdRender` | フローティングプレビュー(`:MdRender float` のエイリアス) |
| `:MdRender float` | フローティングプレビューをトグル |
| `:MdRender tab` | タブプレビューをトグル |
| `:MdRender toggle` | 現在のウィンドウをソース ↔ レンダーモードでその場切替 |
| `:MdRender split` | ウィンドウを分割してソースとレンダリング表示を並べる(`:vert` / `:tab` / `:topleft` / `:botright` を尊重) |
| `:MdRender auto [on\|off\|toggle]` | **[実験的]** Insert モードに連動して source/render を自動切替(バッファ単位) |
| `:MdRender pager` | ページャーモード — フルスクリーン、装飾なし、`q` で Neovim 終了 |
| `:MdRender demo` | 対応する全 Markdown 記法のデモウィンドウを表示 |

タブ補完では第1引数としてサブコマンド一覧、`auto` の後では `on` / `off` / `toggle` が候補になります。

> **後方互換について。** 従来のトップレベルコマンド (`:MdRenderTab`、`:MdRenderToggle`、`:MdRenderSplit`、`:MdRenderAuto`、`:MdRenderPager`、`:MdRenderDemo`) は新しいディスパッチャへ転送されるエイリアスとして残しています。Neovim セッションごとに最初の呼び出しで非推奨警告を1度だけ表示します。将来のメジャーバージョンで削除されます。

### その場トグル

`:MdRender toggle` は、現在のウィンドウをソース Markdown バッファとそのレンダリング表示の間で**その場で**切り替えます。新しいタブやフローティングウィンドウは開きません。スプリットレイアウトでコードと README のレンダリングを並べたい、といった用途を想定しています。

```vim
:vsplit README.md
:MdRender toggle
```

挙動:

- レンダーバッファは**読み取り専用**で、トグル間で再利用されます(ソース1つにつきレンダーバッファ1つ)。
- 同じソースが複数のウィンドウで表示されている場合、切替はそのウィンドウだけに作用し、他のウィンドウの編集は次に当該ウィンドウをレンダーモードにした時点で反映されます。
- カーソル位置は source line マップを介してソース ↔ レンダー間を往復します。
- レンダーモードのウィンドウでは `number` / `relativenumber` / `list` が無効化されます。元の値はウィンドウに保存され、ソースに戻したときに復元されます。
- レンダーモード中、`q` / `<Esc>` / `<C-c>` は閉じる動作に**割り当てられません**。ソースに戻すには再度 `:MdRender toggle` を呼びます。`<LeftMouse>` / `za` / `<CR>` は折りたたみ・展開を引き続き切り替えます(リンク open は `<LeftMouse>`)。

### Insert モード連動の自動トグル(実験的)

> **実験的機能です。** 新しく追加された機能で、UX が変わる可能性があります。問題や違和感があればぜひお知らせください。

`:MdRender auto on` は、現在のバッファを Normal モード中はレンダー表示にしておき、編集を始めると自動的に source に戻すモードです。`off` で解除、`:MdRender auto`(または `:MdRender auto toggle`)でトグル。すべての Markdown バッファで有効にしたいときは:

```vim
autocmd FileType markdown silent! MdRender auto on
```

`i` / `I` / `a` / `A` / `o` / `O` の再マップ、`:w` の source への転送、読み取り専用なレンダーバッファ上で効かない編集操作などの詳細は `:help :MdRender-auto` を参照してください。

### ソース/レンダーの分割表示

<figure>
  <img src="https://github.com/user-attachments/assets/24999fe8-9ff0-4ca3-9bd1-b72ec5d7f33c" width="407" height="328" alt="ソース/レンダーの分割表示" />
  <figcaption><em>ソース/レンダーの分割表示 — 編集がインライン画像も含めてリアルタイムに反映される</em></figcaption>
</figure>

`:MdRender split` は、現在のウィンドウを分割してソースとレンダリング表示を並べます。分割方向は標準的な Vim のモディファイアに従います:

- `:MdRender split` — 水平分割
- `:vert MdRender split` — 垂直分割(README とコードを並べる定番)
- `:tab MdRender split` — 新しいタブ内で分割
- `:topleft MdRender split` — 一番上に配置
- `:botright MdRender split` — 一番下に配置

ソースの編集はライブでもう一方のウィンドウに反映され、カーソル/スクロール位置も双方向に同期します。詳細な挙動とインライン画像の制限事項は `:help :MdRender-split` を参照してください。

### ページャーモード

<figure>
  <img src="https://github.com/user-attachments/assets/3c8d94a2-7a7d-4d99-ac9c-1b69870fee67" width="682" height="446" alt="ページャーモード" />
  <figcaption><em>ページャーモード — Markdown を <code>less</code> のように閲覧</em></figcaption>
</figure>

`:MdRender pager` を使うと Markdown ファイルを `less` のように閲覧できます：

```bash
nvim +"MdRender pager" README.md
```

シェルエイリアスを設定すると便利です：

```bash
alias mdless='nvim +"MdRender pager"'
mdless README.md
```

## Telescope 連携

<figure>
  <img src="https://github.com/user-attachments/assets/29fff5f5-d437-46d7-b92c-3d1a4bb21dd8" width="472" height="457" alt="Telescope 連携" />
  <figcaption><em>md-render による Telescope プレビュー</em></figcaption>
</figure>

### Previewer

`require("md-render.telescope").previewer()` で作成した previewer は、任意の
[telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) picker
（builtin、extension、カスタム問わず）に渡せます：

```lua
local previewer = require("md-render.telescope").previewer()

require("telescope.builtin").find_files({ previewer = previewer })
require("telescope").extensions.egrepify.egrepify({ previewer = previewer })
```

ファイルの種類に応じて自動的に表示方法を切り替えます：

| ファイル種別 | 動作 |
|---|---|
| Markdown (`.md`, `.markdown`) | md-render によるフルレンダリング（ハイライト、リンク、画像） |
| 画像・動画 (PNG, JPEG, WebP, GIF, MP4, ...) | Kitty graphics protocol でインライン表示 |
| その他 | telescope のデフォルト previewer（シンタックスハイライト付き）にフォールバック |

grep 系の picker では、マッチした行に自動スクロールします。

### `:Telescope md_render` Extension

builtin picker 用のショートカットです。`telescope.builtin` の picker を md-render
previewer 付きでラップします。引数はすべてそのまま渡されます：

```vim
:Telescope md_render find_files
:Telescope md_render live_grep cwd=~/notes
:Telescope md_render grep_string search=TODO
```

## Snacks.nvim 連携

`require("md-render.snacks").preview()` で
[snacks.nvim](https://github.com/folke/snacks.nvim) の picker 用プレビュー関数を
作成します。telescope 版と同じく Markdown、画像・動画、その他のファイルに対応します。

グローバルに全 picker へ適用：

```lua
require("snacks").setup({
  picker = {
    preview = require("md-render.snacks").preview(),
  },
})
```

source ごとに個別設定：

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

## FAQ / トラブルシューティング

<details>
<summary><strong>画像が表示されない（alt テキストやファイル名だけが出る）</strong></summary>

画像のインライン表示には [Kitty graphics protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/) に対応したターミナルが必要です。**WezTerm**、**Kitty**、**Ghostty** のいずれかを使っているか確認してください。tmux などのマルチプレクサは、明示的に通過設定をしない限り画像エスケープシーケンスを破棄することがあります。

</details>

<details>
<summary><strong>動画が静止画 1 枚しか表示されない</strong></summary>

動画フレーム展開には `ffmpeg` が `$PATH` にインストールされている必要があります。なければ、最初のフレームを静止画として表示するフォールバックになります。パッケージマネージャでインストールしてください（例：`brew install ffmpeg`）。

</details>

<details>
<summary><strong>Mermaid ダイアグラムが描画されない</strong></summary>

Mermaid のレンダリングには [@mermaid-js/mermaid-cli](https://github.com/mermaid-js/mermaid-cli) の `mmdc` バイナリが必要です。グローバルに `mmdc` がない場合は `npx -y @mermaid-js/mermaid-cli` にフォールバックしますが、初回呼び出しが大幅に遅くなります。`npm install -g @mermaid-js/mermaid-cli` でグローバルインストールするのがおすすめです。

</details>

<details>
<summary><strong>日本語の折り返しが不自然</strong></summary>

デフォルトでは JIS X 4051 の禁則処理を文字単位で適用します。自然な単語境界に従うフレーズ単位の分割が必要なら [budoux.lua](https://github.com/delphinus/budoux.lua) をインストールしてください。プラグインが自動検出して使用します。

</details>

<details>
<summary><strong>コードブロックにシンタックスハイライトが付かない</strong></summary>

シンタックスハイライトには対応する treesitter パーサーが必要です。例えば Lua のハイライトには `:TSInstall lua`（[nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter)）または Neovim 0.11+ の組み込みパーサー管理を使ってインストールしてください。

</details>

## ライブラリとして使う

<details>
<summary><strong>プログラム API</strong></summary>

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

-- 画像を表示（Kitty Graphics Protocol 対応ターミナルが必要）
-- ウィンドウを閉じると自動的にクリーンアップされます。
local win = vim.api.nvim_get_current_win()
md.display_utils.setup_images(win, content, ns)
```

</details>

## 開発

### テストの実行

```bash
make test
```

`tests/*_test.lua` にマッチする全テストファイルを `nvim --headless` で実行します。新しいテストファイルは自動的に検出されます。

## ライセンス

MIT — [LICENSE](LICENSE) を参照。
