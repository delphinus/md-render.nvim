if vim.g.loaded_md_render then
  return
end
vim.g.loaded_md_render = true

vim.keymap.set("n", "<Plug>(md-render-preview)", function()
  require("md-render").preview.show()
end, { desc = "Markdown preview (toggle)" })

vim.keymap.set("n", "<Plug>(md-render-preview-tab)", function()
  require("md-render").preview.show_tab()
end, { desc = "Markdown preview in tab (toggle)" })

vim.keymap.set("n", "<Plug>(md-render-toggle)", function()
  require("md-render").preview.toggle()
end, { desc = "Markdown render toggle (same window)" })

vim.keymap.set("n", "<Plug>(md-render-demo)", function()
  require("md-render").preview.show_demo()
end, { desc = "Markdown render demo" })

vim.api.nvim_create_user_command("MdRender", function()
  require("md-render").preview.show()
end, { desc = "Markdown preview in floating window (toggle)" })

vim.api.nvim_create_user_command("MdRenderTab", function()
  require("md-render").preview.show_tab()
end, { desc = "Markdown preview in tab (toggle)" })

vim.api.nvim_create_user_command("MdRenderToggle", function()
  require("md-render").preview.toggle()
end, { desc = "Toggle between source and render mode (same window)" })

vim.api.nvim_create_user_command("MdRenderPager", function()
  require("md-render").preview.show_pager()
end, { desc = "Markdown pager mode (q to quit)" })

vim.api.nvim_create_user_command("MdRenderDemo", function()
  require("md-render").preview.show_demo()
end, { desc = "Markdown render demo" })
