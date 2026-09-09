-- Run: nvim --headless -u NONE --noplugin -l tests/presenter_store_test.lua
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

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

local function test(name, fn)
  local ok, err = pcall(fn)
  if not ok then
    fail_count = fail_count + 1
    print("ERROR: " .. name .. ": " .. tostring(err))
  end
end

local store = require "md-render.presenter_store"

--- Point the store at a throwaway cache root for the duration of `fn`.
local function with_root(fn)
  local saved = store.root
  store.root = vim.fn.tempname()
  local ok, err = pcall(fn)
  vim.fn.delete(store.root, "rf")
  store.root = saved
  if not ok then error(err) end
end

local DIAGRAM_A = "flowchart LR\n  A --> B"
local DIAGRAM_B = "flowchart TD\n  X --> Y"

-- ============================================================================
-- key
-- ============================================================================

test("key: the same diagram source always hashes to the same key", function()
  assert_eq(store.key(DIAGRAM_A), store.key(DIAGRAM_A), "stable across calls")
end)

test("key: different diagram sources hash to different keys", function()
  assert_eq(store.key(DIAGRAM_A) ~= store.key(DIAGRAM_B), true, "A and B differ")
end)

test("key: survives the diagram moving to another slide", function()
  local P = require "md-render.presenter"
  local before = P.find_diagrams(P.segment({ "# One", "```mermaid", DIAGRAM_A, "```" })[1])
  -- Same diagram, now the second slide and several rows further down.
  local after = P.find_diagrams(P.segment({
    "# Zero",
    "text",
    "---",
    "# One",
    "```mermaid",
    DIAGRAM_A,
    "```",
  })[2])
  assert_eq(after[1].open_row ~= before[1].open_row, true, "precondition: the source row moved")
  assert_eq(store.key(after[1].source), store.key(before[1].source), "the key did not move with it")
end)

-- ============================================================================
-- cache_file
-- ============================================================================

test("cache_file: a deck path maps to a stable file under the cache root", function()
  with_root(function()
    local first = store.cache_file "/home/me/deck.md"
    assert_eq(first, store.cache_file "/home/me/deck.md", "same deck, same file")
    assert_eq(vim.startswith(first, store.root), true, "lives under the cache root")
    assert_eq(first:sub(-5), ".json", "is a .json file")
  end)
end)

test("cache_file: different decks map to different files", function()
  with_root(function()
    assert_eq(store.cache_file "/home/me/a.md" ~= store.cache_file "/home/me/b.md", true, "a and b differ")
  end)
end)

test("cache_file: a buffer with no file on disk has no cache file", function()
  assert_eq(store.cache_file "", nil, "empty path")
  assert_eq(store.cache_file(nil), nil, "absent path")
end)

-- ============================================================================
-- load / save
-- ============================================================================

test("load: a deck that has never been presented reads as empty", function()
  with_root(function()
    assert_eq(store.load "/home/me/never.md", {}, "no file yet")
  end)
end)

test("save then load round-trips the layouts", function()
  with_root(function()
    local entries = {
      [store.key(DIAGRAM_A)] = { kind = "left", pct = 40 },
      [store.key(DIAGRAM_B)] = { kind = "full" },
    }
    assert_eq(store.save("/home/me/deck.md", entries), true, "save reports success")
    assert_eq(store.load "/home/me/deck.md", entries, "load returns what was saved")
  end)
end)

test("save: a deck with no file on disk is not persisted", function()
  with_root(function()
    assert_eq(store.save("", { x = { kind = "full" } }), false, "nothing to key the cache on")
  end)
end)

test("save: an empty table leaves no cache file behind", function()
  with_root(function()
    store.save("/home/me/deck.md", { [store.key(DIAGRAM_A)] = { kind = "full" } })
    store.save("/home/me/deck.md", {})
    assert_eq(vim.fn.filereadable(store.cache_file "/home/me/deck.md"), 0, "the file is removed, not left as {}")
  end)
end)

test("load: a corrupt cache file reads as empty rather than throwing", function()
  with_root(function()
    local path = store.cache_file "/home/me/deck.md"
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    vim.fn.writefile({ "{ this is not json" }, path)
    assert_eq(store.load "/home/me/deck.md", {}, "falls back to empty")
  end)
end)

-- ============================================================================
-- prune
-- ============================================================================

test("prune: drops entries whose diagram is no longer in the deck", function()
  local live = store.key(DIAGRAM_A)
  local orphan = store.key(DIAGRAM_B)
  local entries = { [live] = { kind = "full" }, [orphan] = { kind = "left", pct = 40 } }
  assert_eq(store.prune(entries, { DIAGRAM_A }), { [live] = { kind = "full" } }, "only the live diagram survives")
end)

test("prune: an empty deck drops everything", function()
  local entries = { [store.key(DIAGRAM_A)] = { kind = "full" } }
  assert_eq(store.prune(entries, {}), {}, "nothing is live")
end)

print(string.format("presenter_store_test: %d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
