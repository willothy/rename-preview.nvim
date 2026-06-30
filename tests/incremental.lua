-- Tests for the incremental (type-as-you-go) overlay rendering.
local failures = 0
local function check(name, cond, detail)
  if cond then
    print("ok   - " .. name)
  else
    failures = failures + 1
    print("FAIL - " .. name .. (detail and ("  (" .. tostring(detail) .. ")") or ""))
  end
end

require("rename-preview").setup({})
local incremental = require("rename-preview.incremental")

local function range(line, scol, ecol)
  return { start = { line = line, character = scol }, ["end"] = { line = line, character = ecol } }
end

--- Collect the concatenated virtual text drawn for a buffer in a namespace.
local function virt_for(bufnr, ns)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })) do
    local d = m[4]
    if d and d.virt_text then
      local pos = d.virt_text_pos
      local text = ""
      for _, c in ipairs(d.virt_text) do
        text = text .. c[1]
      end
      out[#out + 1] = { row = m[2], col = m[3], pos = pos, text = text }
    end
  end
  return out
end

-- Put a real buffer into the current window so the overlay's "is it visible"
-- check passes.
local tmp = vim.fn.tempname() .. ".lua"
vim.fn.writefile({
  "local function getUser(id)", -- getUser at cols 15..22
  "  return getUser(id - 1)", -- getUser at cols 9..16
  "end",
}, tmp)
vim.cmd.edit(tmp)
local bufnr = vim.api.nvim_get_current_buf()
local uri = vim.uri_from_bufnr(bufnr)

local ranges = { [uri] = { range(0, 15, 22), range(1, 9, 16) } }
local ns = vim.api.nvim_create_namespace("inc_test")

-- 1) Replacement longer than the old span is split across an overlay chunk and
--    an inline overflow chunk; concatenated in document order they spell it out.
incremental.render_overlays(ns, ranges, "fetchUser", "utf-16")
local v = virt_for(bufnr, ns)
local joined = ""
for _, m in ipairs(v) do
  joined = joined .. m.text
end
check("overlays spell out the new name", joined:find("fetchUser", 1, true), joined)
check("an overlay chunk per occurrence", #v >= 2, #v)

-- 2) Longer new name: there must be an inline chunk (the overflow) so following
--    text is pushed, not overdrawn.
vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
incremental.render_overlays(ns, ranges, "aMuchLongerName", "utf-16")
local v2 = virt_for(bufnr, ns)
local saw_inline = false
local saw_overlay = false
for _, m in ipairs(v2) do
  if m.pos == "inline" then
    saw_inline = true
  end
  if m.pos == "overlay" then
    saw_overlay = true
  end
end
check("longer name uses overlay + inline overflow", saw_inline and saw_overlay)

-- 3) Shorter new name: overlay text must be padded to cover the old span fully
--    (old display width 7 for "getUser").
vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
incremental.render_overlays(ns, ranges, "u", "utf-16")
local v3 = virt_for(bufnr, ns)
local padded_ok = false
for _, m in ipairs(v3) do
  if m.pos == "overlay" and vim.fn.strdisplaywidth(m.text) == 7 then
    padded_ok = true
  end
end
check("shorter name padded to cover old span", padded_ok)

-- 4) Empty name draws nothing.
vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
incremental.render_overlays(ns, ranges, "", "utf-16")
check("empty name draws no overlay", #virt_for(bufnr, ns) == 0)

-- 5) ranges_from_edit handles both WorkspaceEdit shapes.
local from_changes = incremental.ranges_from_edit({
  changes = { ["file:///a.lua"] = { { range = range(0, 0, 3) }, { range = range(2, 1, 4) } } },
})
check("changes form yields all ranges", from_changes["file:///a.lua"] and #from_changes["file:///a.lua"] == 2)

local from_doc = incremental.ranges_from_edit({
  documentChanges = {
    { textDocument = { uri = "file:///b.lua" }, edits = { { range = range(1, 0, 2) } } },
    { kind = "rename", oldUri = "file:///b.lua", newUri = "file:///c.lua" }, -- ignored
  },
})
check("documentChanges form yields edit ranges", from_doc["file:///b.lua"] and #from_doc["file:///b.lua"] == 1)
check("resource ops are skipped", from_doc["file:///c.lua"] == nil)

check("nil edit yields empty table", next(incremental.ranges_from_edit(nil)) == nil)

vim.fn.delete(tmp)

print(string.format("\n%d failures", failures))
if failures > 0 then
  vim.cmd("cq")
else
  vim.cmd("qa!")
end
