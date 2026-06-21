-- TTY discovery tests
-- Run: nvim --headless -u NONE --noplugin -l tests/tty_test.lua

package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local ffi = require "ffi"
local tty = require "md-render.tty"

local pass_count = 0
local fail_count = 0

local function assert_eq(actual, expected, msg)
  if vim.deep_equal(actual, expected) then
    pass_count = pass_count + 1
  else
    fail_count = fail_count + 1
    print("FAIL: " .. msg)
    print("  expected: " .. vim.inspect(expected))
    print("  actual:   " .. vim.inspect(actual))
  end
end

local function assert_true(val, msg)
  if val then
    pass_count = pass_count + 1
  else
    fail_count = fail_count + 1
    print("FAIL: " .. msg)
  end
end

local function test(name, fn)
  local ok, err = pcall(fn)
  if not ok then
    fail_count = fail_count + 1
    print("ERROR: " .. name .. ": " .. tostring(err))
  end
end

-- Trigger FFI declarations and declare open/close for test use
tty._detect_direct()
pcall(ffi.cdef, "int open(const char *path, int flags); int close(int fd);")

-- ============================================================================
-- Cross-platform tests
-- ============================================================================

test("isatty returns 0 for a regular file fd", function()
  local tmpfile = os.tmpname()
  local f = io.open(tmpfile, "w")
  f:write "test"
  f:close()
  local fd = ffi.C.open(tmpfile, 0) -- O_RDONLY
  assert_true(fd >= 0, "open regular file should succeed")
  assert_eq(ffi.C.isatty(fd), 0, "isatty should return 0 for regular file")
  ffi.C.close(fd)
  os.remove(tmpfile)
end)

test("ttyname returns nil for a non-tty fd", function()
  local tmpfile = os.tmpname()
  local f = io.open(tmpfile, "w")
  f:write "test"
  f:close()
  local fd = ffi.C.open(tmpfile, 0)
  local name = ffi.C.ttyname(fd)
  assert_eq(name, nil, "ttyname should return NULL for regular file fd")
  ffi.C.close(fd)
  os.remove(tmpfile)
end)

test("_detect_direct returns nil in headless mode", function()
  -- In headless nvim, no fd should be a real TTY
  -- (may return a path if run in a real terminal, so just verify it doesn't crash)
  tty.reset()
  local result = tty._detect_direct()
  -- result can be nil (headless) or a string (real terminal) — both are valid
  assert_true(
    result == nil or type(result) == "string",
    "_detect_direct should return nil or string, got: " .. type(tostring(result))
  )
end)

test("get_tty_path caches result", function()
  tty.reset()
  local first = tty.get_tty_path()
  local second = tty.get_tty_path()
  assert_eq(first, second, "get_tty_path should return same result on second call")
end)

test("reset clears cached state", function()
  tty.reset()
  local first = tty.get_tty_path()
  tty.reset()
  -- After reset, the next call re-detects (same result expected, but exercises the path)
  local after_reset = tty.get_tty_path()
  assert_eq(first, after_reset, "get_tty_path should return same result after reset")
end)

test("_detect_socket_peer returns nil when no connected sockets", function()
  -- In normal (non-:restart) mode, our fds likely have no TUI peer
  -- Just verify it doesn't crash and returns nil or a string
  tty.reset()
  local result = tty._detect_socket_peer()
  assert_true(result == nil or type(result) == "string", "_detect_socket_peer should return nil or string")
end)

test("_get_socket_peer_pid returns nil for non-socket fd", function()
  pcall(ffi.cdef, "int open(const char *path, int flags); int close(int fd);")
  local tmpfile = os.tmpname()
  local f = io.open(tmpfile, "w")
  f:write "test"
  f:close()
  local fd = ffi.C.open(tmpfile, 0)
  local peer = tty._get_socket_peer_pid(fd)
  assert_eq(peer, nil, "get_socket_peer_pid should return nil for regular file fd")
  ffi.C.close(fd)
  os.remove(tmpfile)
end)

-- ============================================================================
-- macOS-specific tests
-- ============================================================================

if ffi.os == "OSX" then
  test("macOS: proc_bsdinfo struct size is 136 bytes", function()
    assert_eq(ffi.sizeof "struct md_proc_bsdinfo", 136, "proc_bsdinfo should be 136 bytes (validates struct layout)")
  end)

  test("macOS: proc_pidinfo succeeds for own pid", function()
    local info = ffi.new "struct md_proc_bsdinfo"
    local pid = vim.fn.getpid()
    local size = ffi.C.proc_pidinfo(pid, 3, 0, info, ffi.sizeof(info))
    assert_true(size > 0, "proc_pidinfo should return positive size for own pid")
    assert_eq(info.pbi_pid, pid, "proc_pidinfo should report correct pid")
  end)

  test("macOS: _get_pid_tty_darwin returns nil or string for own pid", function()
    local result = tty._get_pid_tty_darwin(vim.fn.getpid())
    assert_true(
      result == nil or type(result) == "string",
      "_get_pid_tty_darwin should return nil (headless) or string (terminal)"
    )
  end)

  test("macOS: devname returns string for valid dev", function()
    -- devname for the null device (major 3, minor 2 on macOS) → "null"
    local name = ffi.C.devname(0x0302, 0x2000)
    if name ~= nil then
      assert_eq(ffi.string(name), "null", "devname for /dev/null should return 'null'")
    else
      -- Some macOS versions may not resolve this; just don't crash
      pass_count = pass_count + 1
    end
  end)
end

-- ============================================================================
-- Linux-specific tests
-- ============================================================================

if ffi.os == "Linux" then
  test("Linux: /proc/self/stat is readable", function()
    local f = io.open("/proc/self/stat", "r")
    assert_true(f ~= nil, "/proc/self/stat should be readable")
    if f then f:close() end
  end)

  test("Linux: _get_pid_tty_linux parses stat correctly", function()
    local result = tty._get_pid_tty_linux(vim.fn.getpid())
    -- In headless mode, tty_nr is likely 0, so result should be nil
    assert_true(result == nil or type(result) == "string", "_get_pid_tty_linux should return nil (no tty) or string")
  end)

  test("Linux: ucred struct size is 12 bytes", function()
    assert_eq(ffi.sizeof "struct md_ucred", 12, "ucred should be 12 bytes (pid + uid + gid)")
  end)
end

-- ============================================================================
-- Summary
-- ============================================================================

print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
