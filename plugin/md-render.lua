if vim.g.loaded_md_render then return end
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

vim.keymap.set("n", "<Plug>(md-render-auto)", function()
  require("md-render").preview.auto_toggle()
end, { desc = "Markdown render auto-toggle on insert mode" })

vim.keymap.set("n", "<Plug>(md-render-split)", function()
  require("md-render").preview.split()
end, { desc = "Markdown render in a split window" })

vim.keymap.set("n", "<Plug>(md-render-demo)", function()
  require("md-render").preview.show_demo()
end, { desc = "Markdown render demo" })

local cmd = require "md-render.command"

vim.api.nvim_create_user_command("MdRender", cmd.dispatch, {
  nargs = "*",
  complete = cmd.complete,
  bar = true,
  desc = "Markdown render — :MdRender [float|tab|pager|toggle|split|auto on|off|toggle|demo]",
})

--- Register a deprecated v3 shim that forwards to the new dispatcher.
--- These will be removed in v4.0.0.
local function shim(old, new_form, fargs, opts)
  vim.api.nvim_create_user_command(
    old,
    cmd.deprecated(old, new_form, function(args)
      cmd.dispatch(vim.tbl_extend("force", args, { fargs = fargs }))
    end),
    vim.tbl_extend("force", { desc = "[deprecated] use :" .. new_form }, opts or {})
  )
end

shim("MdRenderTab", "MdRender tab", { "tab" })
shim("MdRenderToggle", "MdRender toggle", { "toggle" })
shim("MdRenderSplit", "MdRender split", { "split" }, { bar = true })
shim("MdRenderPager", "MdRender pager", { "pager" })
shim("MdRenderDemo", "MdRender demo", { "demo" })

vim.api.nvim_create_user_command(
  "MdRenderAuto",
  cmd.deprecated("MdRenderAuto", "MdRender auto [on|off|toggle]", function(args)
    local a = (args.args or ""):lower()
    cmd.dispatch(vim.tbl_extend("force", args, {
      fargs = a == "" and { "auto" } or { "auto", a },
    }))
  end),
  {
    nargs = "?",
    complete = function()
      return { "on", "off", "toggle" }
    end,
    desc = "[deprecated] use :MdRender auto [on|off|toggle]",
  }
)
