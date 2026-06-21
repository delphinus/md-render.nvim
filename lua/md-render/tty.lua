--- TTY discovery for md-render.nvim
--- Finds the controlling terminal using direct C calls (no external processes).
--- Supports macOS (libproc) and Linux (/proc filesystem). On Windows the
--- module's public API returns nil without invoking any FFI calls.

local ffi = require "ffi"
local uv = vim.uv or vim.loop

local M = {}

local IS_WINDOWS = ffi.os == "Windows"
local IS_OSX = ffi.os == "OSX"
local IS_LINUX = ffi.os == "Linux"

local _tty_path = nil
local _tty_detected = false

-- ============================================================================
-- FFI declarations
-- ============================================================================

local _ffi_declared = false

local function ensure_ffi()
  if _ffi_declared then return end
  _ffi_declared = true
  -- POSIX-only symbols: never declared on Windows where they don't exist
  -- in the default ffi.C namespace.
  if IS_WINDOWS then return end
  ffi.cdef [[
    int isatty(int fd);
    char *ttyname(int fd);
    int getsockopt(int sockfd, int level, int optname, void *optval, unsigned int *optlen);
  ]]
  if IS_OSX then
    ffi.cdef [[
      int proc_pidinfo(int pid, int flavor, uint64_t arg, void *buffer, int buffersize);

      /* Minimal proc_bsdinfo: only fields up to e_tdev are needed. */
      struct md_proc_bsdinfo {
        uint32_t pbi_flags;
        uint32_t pbi_status;
        uint32_t pbi_xstatus;
        uint32_t pbi_pid;
        uint32_t pbi_ppid;
        uint32_t pbi_uid;
        uint32_t pbi_gid;
        uint32_t pbi_ruid;
        uint32_t pbi_rgid;
        uint32_t pbi_svuid;
        uint32_t pbi_svgid;
        uint32_t rfu_1;
        char     pbi_comm[16];
        char     pbi_name[32];
        uint32_t pbi_nfiles;
        uint32_t pbi_pgid;
        uint32_t pbi_pjobc;
        uint32_t e_tdev;
        uint32_t e_tpgid;
        int32_t  pbi_nice;
        uint64_t pbi_start_tvsec;
        uint64_t pbi_start_tvusec;
      };

      char *devname(int dev, int type);
    ]]
  elseif IS_LINUX then
    ffi.cdef [[
      struct md_ucred {
        int pid;
        unsigned int uid;
        unsigned int gid;
      };
    ]]
  end
end

-- ============================================================================
-- Platform constants
-- ============================================================================

local SOL_LOCAL = 0 -- macOS: level for local socket options
local LOCAL_PEERPID = 0x002 -- macOS: retrieve peer pid
local SOL_SOCKET_LINUX = 1 -- Linux: SOL_SOCKET
local SO_PEERCRED = 17 -- Linux: retrieve peer credentials
local PROC_PIDTBSDINFO = 3 -- macOS: proc_pidinfo flavor
local S_IFCHR = 0x2000 -- character device mode

-- ============================================================================
-- Level 1: Direct TTY detection via isatty() + ttyname()
-- ============================================================================

--- Try to detect TTY from standard file descriptors.
---@return string?
function M._detect_direct()
  if IS_WINDOWS then return nil end
  ensure_ffi()
  -- Try stderr first (most likely to survive redirects), then stdout, stdin
  for _, fd in ipairs { 2, 1, 0 } do
    if ffi.C.isatty(fd) ~= 0 then
      local name = ffi.C.ttyname(fd)
      if name ~= nil then return ffi.string(name) end
    end
  end
  return nil
end

-- ============================================================================
-- Level 2: /dev/tty fallback
-- ============================================================================

--- Try opening /dev/tty directly.
---@return string?
function M._detect_dev_tty()
  if IS_WINDOWS then return nil end
  local f = io.open("/dev/tty", "w")
  if f then
    f:close()
    return "/dev/tty"
  end
  return nil
end

-- ============================================================================
-- Level 3: Socket peer discovery (after :restart)
-- ============================================================================

--- Get peer PID from a unix socket fd via getsockopt.
---@param fd integer
---@return integer? peer_pid
local function get_socket_peer_pid(fd)
  if IS_WINDOWS then return nil end
  ensure_ffi()
  if IS_OSX then
    local pid = ffi.new "int[1]"
    local len = ffi.new("unsigned int[1]", ffi.sizeof "int")
    if ffi.C.getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, pid, len) == 0 then
      local p = pid[0]
      if p > 1 then return p end
    end
  elseif IS_LINUX then
    local cred = ffi.new "struct md_ucred"
    local len = ffi.new("unsigned int[1]", ffi.sizeof "struct md_ucred")
    if ffi.C.getsockopt(fd, SOL_SOCKET_LINUX, SO_PEERCRED, cred, len) == 0 then
      local p = cred.pid
      if p > 1 then return p end
    end
  end
  return nil
end
M._get_socket_peer_pid = get_socket_peer_pid -- expose for testing

--- Get the TTY device path for a given PID (macOS).
---@param pid integer
---@return string?
local function get_pid_tty_darwin(pid)
  ensure_ffi()
  local info = ffi.new "struct md_proc_bsdinfo"
  local size = ffi.C.proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, info, ffi.sizeof(info))
  if size <= 0 then return nil end
  local dev = info.e_tdev
  -- 0 or 0xFFFFFFFF (-1 unsigned) means no controlling terminal
  if dev == 0 or dev == 0xFFFFFFFF then return nil end
  local name = ffi.C.devname(dev, S_IFCHR)
  if name == nil then return nil end
  return "/dev/" .. ffi.string(name)
end
M._get_pid_tty_darwin = get_pid_tty_darwin

--- Get the TTY device path for a given PID (Linux).
---@param pid integer
---@return string?
local function get_pid_tty_linux(pid)
  local f = io.open("/proc/" .. pid .. "/stat", "r")
  if not f then return nil end
  local content = f:read "*a"
  f:close()
  -- Format: pid (comm) state ppid pgrp session tty_nr ...
  -- comm can contain spaces/parens, so find the LAST ")"
  local after_comm = content:match "^.*%)%s+(.*)"
  if not after_comm then return nil end
  local fields = {}
  for field in after_comm:gmatch "%S+" do
    table.insert(fields, field)
    if #fields >= 5 then break end
  end
  -- fields[1]=state, [2]=ppid, [3]=pgrp, [4]=session, [5]=tty_nr
  local tty_nr = tonumber(fields[5])
  if not tty_nr or tty_nr == 0 then return nil end
  local major = bit.band(bit.rshift(tty_nr, 8), 0xFF)
  local minor = bit.bor(bit.band(tty_nr, 0xFF), bit.band(bit.rshift(tty_nr, 12), 0xFFF00))
  -- pts devices have major 136
  if major == 136 then return "/dev/pts/" .. minor end
  -- Other TTY types: try /dev/ttyN
  return "/dev/tty" .. minor
end
M._get_pid_tty_linux = get_pid_tty_linux

--- Get the TTY path for a PID (platform dispatch).
---@param pid integer
---@return string?
function M._get_pid_tty(pid)
  if IS_OSX then
    return get_pid_tty_darwin(pid)
  elseif IS_LINUX then
    return get_pid_tty_linux(pid)
  end
  return nil
end

--- Find the TUI process's TTY by checking socket peers on our fds.
--- After :restart, the TUI connects to our RPC socket. We find it by
--- calling getsockopt(LOCAL_PEERPID/SO_PEERCRED) on each of our fds.
---@return string?
function M._detect_socket_peer()
  if IS_WINDOWS then return nil end
  for fd = 3, 30 do
    local ok, peer_pid = pcall(get_socket_peer_pid, fd)
    if ok and peer_pid then
      local tty = M._get_pid_tty(peer_pid)
      if tty then
        -- Verify we can write to this TTY
        local f = io.open(tty, "w")
        if f then
          f:close()
          return tty
        end
      end
    end
  end
  return nil
end

-- ============================================================================
-- Public API
-- ============================================================================

--- Get the path to the controlling terminal.
--- Uses a three-level fallback: isatty/ttyname → /dev/tty → socket peer.
--- Result is cached; call reset() to re-detect.
---@return string?
function M.get_tty_path()
  if _tty_detected then return _tty_path end
  _tty_detected = true
  _tty_path = M._detect_direct() or M._detect_dev_tty() or M._detect_socket_peer()
  return _tty_path
end

--- Clear cached state (e.g. after :restart or for testing).
function M.reset()
  _tty_path = nil
  _tty_detected = false
end

return M
