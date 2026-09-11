# Vendored code

Third-party code, kept here so the rest of the tree is all first-party. Nothing
in this directory is edited by hand.

## `async/` — `vim.async`

A copy of Neovim's `vim.async`, used on Neovim 0.12.

`vim.async` landed on master in [`ce8a897`][commit] (2026-08-25) and is not in
any 0.12 release. 0.12 does carry an earlier, private cut of the same idea in
`runtime/lua/vim/_async.lua`, but it is a much smaller thing — `run` / `await` /
`join`, no cancellation, no semaphore, and no way to await a task — and it
disagrees with `vim.async` about when a task resumes. Papering over that in a
shim meant every call site was limited to the intersection of the two.

So 0.12 gets this copy instead, and both versions run the same code.
`md-render.async` picks whichever is available: the built-in `vim.async` when
Neovim has it, this copy otherwise. Once 0.13 is the floor, delete this
directory and the `require` fallback with it.

### Provenance

| | |
|---|---|
| Upstream | `runtime/lua/vim/async.lua` and `runtime/lua/vim/async/` in [neovim/neovim][neovim] |
| Revision | see `async/REVISION` |
| Licence | Apache-2.0 — `LICENSE-neovim.txt` |

Neovim in turn vendored this from [lewis6991/async.nvim][async.nvim] (MIT).
Taking Neovim's copy rather than the original is deliberate: it is the exact
code 0.13 users get, so the two halves of the fallback cannot drift apart, and
re-syncing is a plain diff against a Neovim checkout.

### Changes from upstream

Require paths only, rewritten from `vim.async.*` to `md-render.vendor.async.*`.
`async/_util.lua` holds the two error helpers `vim.async` reaches for in
`vim._core.util`, copied out of the block upstream marks as generated. No logic
is changed, and nothing is added.

### Re-syncing

```sh
scripts/vendor-async.sh ~/src/neovim            # defaults to origin/master
scripts/vendor-async.sh ~/src/neovim v0.13.0    # or a tag
```

Then run the tests against both ends of the supported range — the copy is only
worth having if it behaves like the built-in one:

```sh
make test                                        # whatever nvim is on PATH
make test NVIM="/path/to/nvim-0.12 --headless -u NONE --noplugin"
```

[commit]: https://github.com/neovim/neovim/commit/ce8a897f985b2cfd1194f6c03fe5388f9bc6d6bf
[neovim]: https://github.com/neovim/neovim
[async.nvim]: https://github.com/lewis6991/async.nvim
