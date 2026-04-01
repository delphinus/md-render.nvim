-- Scenario script for pty integration test.
-- Runs inside Neovim (via pty_capture.py) to exercise image module
-- and emit Kitty Graphics Protocol sequences to the terminal.
--
-- This script is NOT run directly — it's launched by pty_image_test.lua
-- via pty_capture.py.

package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local image = require "md-render.image"

local test_png = vim.fn.getcwd() .. "/tests/fixtures/test_4x4.png"

-- The pty should have TERM_PROGRAM=WezTerm set by pty_capture.py,
-- so supports_kitty() should return true.

-- 1. Transmit an image
local id = image.transmit_image(test_png)
if id then
  -- 2. Write a marker so the test can find the transmit sequence
  io.write("__TRANSMIT_OK:" .. id .. "__\n")

  -- 3. Delete the image
  image.delete_image(id)
  io.write("__DELETE_OK:" .. id .. "__\n")
else
  io.write("__TRANSMIT_FAIL__\n")
end

-- 4. Test delete_all
image.delete_all()
io.write("__DELETE_ALL_OK__\n")

io.write("__SCENARIO_DONE__\n")
io.flush()
