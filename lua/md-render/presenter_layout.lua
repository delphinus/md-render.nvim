--- Pure layout geometry + cycle math for presenter mode. No vim/state deps.
local M = {}

M.MIN_PCT = 20
M.MAX_PCT = 80

-- Cycle order by kind; left/right carry a percent.
local CYCLE = { "fit", "left", "right", "full" }

local function clamp_pct(p)
  if p < M.MIN_PCT then return M.MIN_PCT end
  if p > M.MAX_PCT then return M.MAX_PCT end
  return p
end

--- Parse a layout string into a layout table, or nil if unrecognized.
---@param str string
---@return {kind: string, pct: integer?}|nil
function M.parse_layout(str)
  if type(str) ~= "string" then return nil end
  local s = str:gsub("%s", ""):lower()
  if s == "full" then return { kind = "full" } end
  if s == "fit" then return { kind = "fit" } end
  local side, pct = s:match "^(left):(%d+)$"
  if not side then
    side, pct = s:match "^(right):(%d+)$"
  end
  if side then return { kind = side, pct = clamp_pct(tonumber(pct)) } end
  if s == "left" or s == "right" then return { kind = s, pct = 50 } end
  return nil
end

--- Serialize a layout table to its directive string form.
---@param layout {kind: string, pct: integer?}
---@return string
function M.serialize_layout(layout)
  if layout.kind == "left" or layout.kind == "right" then return layout.kind .. ":" .. tostring(layout.pct or 50) end
  return layout.kind
end

--- Next layout in the cycle (fit -> left:50 -> right:50 -> full -> fit).
---@param layout {kind: string, pct: integer?}
---@return {kind: string, pct: integer?}
function M.cycle(layout)
  local idx = 1
  for i, k in ipairs(CYCLE) do
    if k == layout.kind then
      idx = i
      break
    end
  end
  local next_kind = CYCLE[(idx % #CYCLE) + 1]
  if next_kind == "left" or next_kind == "right" then return { kind = next_kind, pct = 50 } end
  return { kind = next_kind }
end

--- Adjust the split percentage (left/right only), clamped. No-op otherwise.
---@param layout {kind: string, pct: integer?}
---@param delta integer
---@return {kind: string, pct: integer?}
function M.nudge(layout, delta)
  if layout.kind ~= "left" and layout.kind ~= "right" then return layout end
  return { kind = layout.kind, pct = clamp_pct((layout.pct or 50) + delta) }
end

--- Column bands for a split layout. `gap` cells separate diagram and text.
---@param kind "left"|"right"
---@param pct integer
---@param slide_w integer usable text-area width in cells
---@param gap integer
---@return {text: {indent: integer, max_width: integer}, diagram: {col: integer, max_cols: integer}}
function M.compute_bands(kind, pct, slide_w, gap)
  local d_cols = math.floor(slide_w * pct / 100)
  if kind == "left" then
    local indent = d_cols + gap
    return {
      diagram = { col = 0, max_cols = d_cols },
      text = { indent = indent, max_width = slide_w - indent },
    }
  end
  -- right
  return {
    diagram = { col = slide_w - d_cols, max_cols = d_cols },
    text = { indent = 0, max_width = slide_w - d_cols - gap },
  }
end

return M
