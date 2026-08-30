# md-render.nvim

Markdown rendered inside Neovim — no browser, and no rewriting of the
buffer you are editing. This file is the demo: change it on the left,
watch the right side catch up.

## Headings have a size now

### Every level gets its own

#### Four still beats body text

##### So is five

###### And six, where the ladder stops

Kitty 0.40's text sizing protocol draws a run of text at a multiple of
the base font size, and md-render paints every heading with it. The
scaled text goes straight to the terminal, over the plain heading that
stays in the buffer underneath — so `y`, `/` and `:w` still see the real
line, and a repaint by anything else degrades to a normal heading rather
than to a blank one.

| Level    | Scale |
|----------|------:|
| `#`      | 2.00x |
| `##`     | 1.75x |
| `###`    | 1.50x |
| `####`   | 1.40x |
| `#####`  | 1.25x |
| `######` | 1.17x |

> [!NOTE] Kitty only, on purpose
> The terminal is asked who it is and has to answer. Everywhere else the
> feature costs nothing and headings look exactly as they always did.

Not for you? `:MdRender textsize off`.

## Source and render, together

`:MdRender split` puts the source buffer and the rendered view in
adjacent windows. Direction follows the usual modifiers, so the layout
you want is the one you already know how to ask for:

- `:MdRender split` — horizontal
- `:vert MdRender split` — vertical, the README-next-to-code layout
- `:tab MdRender split` — inside a new tab

Edits propagate live, and the two panes are synchronized both ways: move
the cursor or scroll either side and the other one follows to the line
that matches.

### Everything else came along

**Bold**, ~~struck out~~, `inline code`, ==highlighted==, and
[links you can click](https://github.com/delphinus/md-render.nvim).

```lua
local SCALE = { 2.00, 1.75, 1.50, 1.40, 1.25, 1.17 }

--- Headings wrap at 1 / size of the usual width, so
--- every level scales, not just the ones that fit.
local function wrap_width(level, columns)
  return math.floor(columns / SCALE[level])
end
```

- [x] Tables that measure their own columns
- [x] Callouts, folds, `<details>`, images, video, Mermaid diagrams
- [x] CJK line breaking with kinsoku shori and BudouX
- [-] Every terminal — this one is up to the protocol, not to me

<details>
<summary>Where the fractional sizes come from</summary>

Kitty's `s=` multiplies the cells a run occupies, not just the font, so
every level stays at `s=2` — one extra row, never more — and the sizes
below 2x come from the protocol's fractional scale. A run has to declare
its width in whole cells while its text does not measure a whole number
of them, so one heading goes out as several runs, cut where the leftover
cell disappears: on an exact boundary where there is one, and after a
space where there is not, so the slack reads as a slightly wider word
gap instead of a hole in a word.

</details>

### 日本語も同じように

見出しも本文も扱いは変わりません。禁則処理は JIS X 4051 に沿っていて、
句読点や閉じ括弧が行頭に来ることはありません。budoux.lua を入れておくと、
文節の切れ目で折り返します。

---

*Read it like `less`: `nvim +"MdRender pager" whats-new.md`*
