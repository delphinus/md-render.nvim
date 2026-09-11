#!/usr/bin/env bash
# Re-sync the vendored copy of vim.async from a Neovim checkout.
#
# The copy exists so Neovim 0.12 — the floor this plugin supports — gets the
# same async runtime 0.13 has built in. It is upstream's code unmodified apart
# from require paths, so re-syncing is a copy plus a substitution; see
# lua/md-render/vendor/README.md.
#
# Usage: scripts/vendor-async.sh <path-to-neovim-checkout> [ref]
set -euo pipefail

nvim_repo=${1:?usage: $0 <path-to-neovim-checkout> [ref]}
ref=${2:-origin/master}
root=$(cd "$(dirname "$0")/.." && pwd)
dest=$root/lua/md-render/vendor/async

mkdir -p "$dest"

show() { git -C "$nvim_repo" show "$ref:runtime/lua/vim/$1"; }

show async.lua >"$dest.lua"
for mod in _core _event _future _queue _runtime _semaphore; do
  show "async/$mod.lua" >"$dest/$mod.lua"
done

# vim.async reaches outside its own tree for two error helpers, which upstream
# keeps in a marked block inside an otherwise unrelated grab bag of a file.
# Take the block, not the file.
# The marker contains slashes, so address it with sed's \%...% delimiter form.
marker='Generated from async.nvim/lua/async/_errors.lua'
helpers=$(show _core/util.lua | sed -n "\%$marker: start%,\%$marker: end%p")
grep -q '_stringify_error' <<<"$helpers" || {
  echo "error: the _errors block in _core/util.lua no longer looks as expected" >&2
  exit 1
}
{
  echo "-- Extracted from runtime/lua/vim/_core/util.lua; see ../README.md."
  echo
  echo "local M = {}"
  echo
  echo "$helpers"
  echo
  echo "return M"
} >"$dest/_util.lua"

# Point the copy's requires at where it now lives.
perl -pi -e "
  s{require\('vim\.async\.}{require('md-render.vendor.async.}g;
  s{require\('vim\._core\.util'\)}{require('md-render.vendor.async._util')}g;
" "$dest.lua" "$dest"/*.lua

git -C "$nvim_repo" rev-parse "$ref" >"$dest/REVISION"
echo "Vendored vim.async from $nvim_repo at $(cat "$dest/REVISION")"
