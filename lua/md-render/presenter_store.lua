--- Presenter layout cache: where a diagram's layout lives when it is *not*
--- written into the document.
---
--- md-render renders into a separate buffer and never mutates the one you are
--- editing; the presenter's `L` / `<` / `>` keys would break that rule if they
--- persisted by inserting `[//]: # (diagram: ...)` comments. They write here
--- instead, and committing a layout back into the document stays an explicit,
--- per-slide act (see `presenter.commit_layout`).
---
--- Entries are keyed by a hash of the diagram's own source text, so a layout
--- survives the slide being reordered or the prose around it being rewritten.
--- Editing the diagram itself is what drops its layout.
local M = {}

--- Cache root. Overridable so tests do not touch the user's real cache.
---@type string|nil
M.root = nil

---@return string
local function cache_root()
  return M.root or (vim.fn.stdpath "cache" .. "/md-render/presenter")
end

---@param s string
---@return string
local function digest(s)
  return vim.fn.sha256(s):sub(1, 16)
end

--- Cache key for a diagram, derived from its source text.
---@param source string the diagram body, without its fences
---@return string
function M.key(source)
  return digest(source or "")
end

--- Where this deck's layouts are cached. nil when the buffer has no file on
--- disk, which is also what makes `save` a no-op for scratch buffers.
---@param deck_path string|nil absolute path of the Markdown file
---@return string|nil
function M.cache_file(deck_path)
  if type(deck_path) ~= "string" or deck_path == "" then return nil end
  return cache_root() .. "/" .. digest(deck_path) .. ".json"
end

--- Read a deck's cached layouts. Missing or unreadable caches read as empty:
--- a corrupt file should cost you your layouts, not your presentation.
---@param deck_path string|nil
---@return table<string, {kind: string, pct: integer?}>
function M.load(deck_path)
  local path = M.cache_file(deck_path)
  if not path or vim.fn.filereadable(path) == 0 then return {} end
  local ok, decoded = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
  end)
  if not ok or type(decoded) ~= "table" then return {} end
  return decoded
end

--- Write a deck's layouts. An empty table removes the file rather than
--- leaving `{}` behind, so clearing every layout also clears the cache entry.
---@param deck_path string|nil
---@param entries table<string, {kind: string, pct: integer?}>
---@return boolean written
function M.save(deck_path, entries)
  local path = M.cache_file(deck_path)
  if not path then return false end
  if vim.tbl_isempty(entries) then
    vim.fn.delete(path)
    return true
  end
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local ok, encoded = pcall(vim.json.encode, entries)
  if not ok then return false end
  return pcall(vim.fn.writefile, { encoded }, path) == true
end

--- Drop entries for diagrams the deck no longer contains, so a cache cannot
--- outgrow the file it belongs to.
---@param entries table<string, {kind: string, pct: integer?}>
---@param live_sources string[] every diagram source currently in the deck
---@return table<string, {kind: string, pct: integer?}>
function M.prune(entries, live_sources)
  local live = {}
  for _, source in ipairs(live_sources) do
    live[M.key(source)] = true
  end
  local kept = {}
  for k, v in pairs(entries) do
    if live[k] then kept[k] = v end
  end
  return kept
end

return M
