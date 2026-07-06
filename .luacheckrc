-- Luacheck configuration for md-render.nvim
-- Docs: https://luacheck.readthedocs.io/en/stable/config.html

-- Neovim embeds LuaJIT.
std = "luajit"
cache = true

-- Globals injected at runtime by Neovim and optional integrations.
read_globals = {
  "vim",
  "Snacks", -- folke/snacks.nvim (optional image backend)
}

-- `vim.<subtable>.foo = ...` assignments are legitimate. Declaring the mutable
-- subtables as writable globals stops luacheck reporting them as writes to a
-- read-only field of the `vim` global.
globals = {
  "vim.g",
  "vim.b",
  "vim.w",
  "vim.o",
  "vim.bo",
  "vim.wo",
  "vim.go",
  "vim.env",
  "vim.opt",
}

-- Line width is owned by StyLua (column_width in .stylua.toml). A few string
-- literals legitimately exceed it and cannot be wrapped.
ignore = { "631" }

exclude_files = { "tests/fixtures/" }

-- Tests intentionally destructure unused return values, shadow module upvalues,
-- and monkeypatch vim.* functions when mocking.
files["tests/"] = {
  ignore = {
    "211", -- unused local variable
    "212", -- unused argument
    "431", -- shadowing an upvalue
    "122", -- setting a read-only field of vim (mocking vim.notify, vim.api.*)
  },
}
