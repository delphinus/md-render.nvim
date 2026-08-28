-- Neovim side of the terminal end-to-end test (see tests/terminal_test.py).
--
-- Opens the fixture in a preview with scaled headings either on or off, then
-- writes a signal file so the driver knows the screen has settled instead of
-- guessing with a fixed sleep.
--
-- Environment:
--   MD_RENDER_E2E_ENABLED  "1" to turn scaled headings on
--   MD_RENDER_E2E_SIGNAL   path to create once the preview has settled
--   MD_RENDER_E2E_DIAG     path to write plugin-side diagnostics to

local plugin_root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(plugin_root)
vim.opt.termguicolors = true

local text_size = require "md-render.text_size"
text_size.setup { enabled = vim.env.MD_RENDER_E2E_ENABLED == "1" }

local function write(path, body)
  if not path then return end
  local f = io.open(path, "w")
  if not f then return end
  f:write(body)
  f:close()
end

vim.defer_fn(function()
  local diag = { "supports=" .. tostring(text_size.supports()) }

  vim.cmd("edit " .. plugin_root .. "/tests/fixtures/text_size_e2e.md")
  vim.bo.filetype = "markdown"
  local ok, err = pcall(function()
    require("md-render").preview.show()
  end)
  table.insert(diag, "show_ok=" .. tostring(ok) .. " err=" .. tostring(err))

  -- Let the paint debounce settle before the driver reads the screen.
  vim.defer_fn(function()
    local session
    for _, s in pairs(require("md-render").preview._sessions) do
      session = s
    end
    table.insert(diag, "placements=" .. tostring(session and #session.content.text_placements))
    table.insert(diag, "drawn=" .. tostring(session and session.text_size_state and session.text_size_state.last_drawn))
    -- `placements` minus `drawn` is the count that never reached the screen,
    -- and a short terminal is the usual reason: the float scrolls the later
    -- headings out of view. `lines` is here so that is visible at a glance.
    table.insert(diag, "columns=" .. vim.o.columns)
    table.insert(diag, "lines=" .. vim.o.lines)
    table.insert(diag, "max_width=" .. tostring(session and session.opts.max_width))

    write(vim.env.MD_RENDER_E2E_DIAG, table.concat(diag, "\n") .. "\n")
    write(vim.env.MD_RENDER_E2E_SIGNAL, "ready\n")
  end, 2000)
end, 1000)
