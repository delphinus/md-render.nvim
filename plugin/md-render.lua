if vim.g.loaded_md_render then
  return
end
vim.g.loaded_md_render = true

vim.keymap.set("n", "<Plug>(md-render-preview)", function()
  require("md-render").preview.show()
end, { desc = "Markdown preview (toggle)" })

vim.keymap.set("n", "<Plug>(md-render-demo)", function()
  require("md-render").preview.show_demo()
end, { desc = "Markdown render demo" })
