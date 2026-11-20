# md-render.nvim

[English version / 英語版はこちら](README.md)

ターミナルの中で完結する Neovim 用の Markdown レンダラーです。画像・動画・ダイアグラムを含む Markdown のバッファを、フローティングウィンドウ、タブ、ソースの隣の分割ウィンドウ、ソースと同じウィンドウ、`less` のようなページャーのいずれかで表示します。編集中のバッファには手を加えません。

<figure align="center">
  <img src="https://github.com/user-attachments/assets/6c51f971-84bb-49fe-aaff-21db40712187" width="900" height="685" alt="md-render.nvim ショーケース：インライン書式、テーブル、コールアウト、コードブロック、画像、動画、Mermaid ダイアグラム" />
</figure>

## 主な機能

- **Markdown をそのまま描画** — インライン書式、テーブル、GitHub / Obsidian のコールアウト、`<details>`、treesitter でハイライトしたコードブロック。コールアウト・`<details>`・省略したコードブロックやテーブルは、`<CR>` かクリックで折りたたみ・展開できます
- **画像と動画** — PNG・JPEG・WebP・GIF と MP4 / WebM / MOV を、ローカルからも Web からも、Kitty graphics protocol でインライン表示
- **ダイアグラム** — Mermaid と PlantUML のフェンスを画像として表示
- **拡大表示** — 画像・動画・ダイアグラムの上で `<CR>` を押すかクリックすると、エディタ全体に拡大して表示。Mermaid はその大きさで描き直すので、文字がぼやけません
- **リンク** — クリックで開き、マウスを乗せると完全な URL を表示。OSC 8 ハイパーリンクにも対応
- **日本語などの CJK** — JIS X 4051 の禁則処理、オプションの [BudouX](https://github.com/google/budoux) による文節での折り返し、行を連結するときに余計な空白を入れない
- **見出しの拡大表示** (実験的・Kitty 専用) — text sizing protocol で見出しを大きく表示
- **ピッカーのプレビュー** — [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) と [snacks.nvim](https://github.com/folke/snacks.nvim) に対応
- **ライブラリ API** — 自作のプラグインからレンダリングエンジンを使えます

https://github.com/user-attachments/assets/1ec8f1fc-bcbd-4333-8751-0372ff1bd73a

## 必要要件

- Neovim 0.12 以降
- 画像と動画には、[Kitty graphics protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/) に対応したターミナル ([WezTerm](https://wezfurlong.org/wezterm/)、[Kitty](https://sw.kovidgoyal.net/kitty/)、[Ghostty](https://ghostty.org/) など)
- 任意: `ffmpeg` (動画・アニメーション GIF)、[`mmdc`](https://github.com/mermaid-js/mermaid-cli) (Mermaid)、`plantuml` (PlantUML)、`curl` (Web 上の画像)、[budoux.lua](https://github.com/delphinus/budoux.lua) (CJK の文節での折り返し)、[nvim-web-devicons](https://github.com/nvim-tree/nvim-web-devicons) か [mini.icons](https://github.com/echasnovski/mini.icons) (アイコン)。詳しくは `:help md-render-dependencies`

## インストール

[lazy.nvim](https://github.com/folke/lazy.nvim) の場合:

```lua
{
  "delphinus/md-render.nvim",
  version = "*",
  dependencies = {
    { "nvim-tree/nvim-web-devicons", version = "*" }, -- 任意
    { "delphinus/budoux.lua", version = "*" }, -- 任意
  },
  keys = {
    { "<leader>mp", "<Plug>(md-render-preview)", desc = "Markdown preview (toggle)" },
    { "<leader>mt", "<Plug>(md-render-preview-tab)", desc = "Markdown preview in tab (toggle)" },
  },
}
```

このプラグインは自分ではキーマッピングを設定しません。`vim.pack` と mini.deps の場合は `:help md-render-installation` を参照してください。

## 使ってみる

全機能を見るには、プラグインに同梱のショーケースをページャーで開くか、`:MdRender demo` を実行します:

```sh
git clone https://github.com/delphinus/md-render.nvim
nvim +"MdRender pager" md-render.nvim/assets/showcase.md
```

| コマンド | 今の Markdown バッファを表示する場所 |
|---|---|
| `:MdRender` | フローティングウィンドウ |
| `:MdRender tab` | 新しいタブ |
| `:MdRender split` | ソースの隣の分割ウィンドウ。編集とカーソルにその場で追従 |
| `:MdRender toggle` | ソースと同じウィンドウ (その場で切り替え) |
| `:MdRender pager` | 画面全体。`q` で Neovim を終了 |

プレビューの中では:

| キー | 動作 |
|---|---|
| `<CR>` | カーソル位置の画像を拡大表示する。またはブロックを折りたたむ・展開する |
| クリック | 画像を拡大表示する、ブロックを折りたたむ・展開する、リンクを開く |
| `za` | カーソル位置のブロックを折りたたむ・展開する |
| `q` / `<Esc>` | フローティングウィンドウやタブを閉じる |

## ドキュメント

それ以外はすべてヘルプにあります。全コマンドとオプション、描画幅、実験的な機能、ピッカーとの連携、Lua API、ハイライトグループ、トラブルシューティングです。

- `:help md-render.jax` ([doc/md-render.jax](doc/md-render.jax))
- 英語のヘルプ: `:help md-render.txt` ([doc/md-render.txt](doc/md-render.txt))

## 開発

`make test` でテストを流します。ほかのテストの層については [tests/README.md](tests/README.md) を参照してください。

## ライセンス

MIT — [LICENSE](LICENSE) を参照。

`lua/md-render/vendor/` は原文のまま同梱している第三者のコードで、それぞれ独自の
ライセンスに従います。中身は Neovim の `vim.async` のコピー (Apache-2.0) で、0.13
に組み込まれている非同期ランタイムを Neovim 0.12 にも与えるためのものです。詳細は
[同ディレクトリの README](lua/md-render/vendor/README.md) を参照。
