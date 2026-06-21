-- Minimal init.lua for visual tests.
-- Loads md-render.nvim from the current working directory,
-- opens the test markdown file, and triggers preview after images load.

-- Add plugin to runtimepath
local plugin_root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(plugin_root)

-- Load the plugin
vim.cmd "runtime plugin/md-render.lua"

-- Open the test markdown file
vim.cmd("edit " .. plugin_root .. "/tests/fixtures/visual_test.md")

-- Wait briefly for buffer to settle, then show preview
vim.defer_fn(function()
  require("md-render").preview.show()

  -- Write a signal file after images have had time to load.
  -- Do NOT call redraw! here — on WezTerm, redraw! clears all Kitty
  -- graphics placements and only the animation timer re-places them.
  -- Instead, just wait long enough for all async image operations to
  -- complete and the animation timer to re-place everything.
  local signal = vim.env.VISUAL_TEST_SIGNAL
  if not signal then return end

  vim.defer_fn(function()
    local f = io.open(signal, "w")
    if f then
      f:write "ready\n"
      f:close()
    end
  end, 5000)
end, 500)
