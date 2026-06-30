-- Treesitter role classification + overlap/stale conflict tests.
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
local roles = require("rename-preview.roles")
local util = require("rename-preview.util")
local config = require("rename-preview.config")
local session_mod = require("rename-preview.session")
local apply_mod = require("rename-preview.apply")

local has_lua_parser = pcall(vim.treesitter.get_parser, vim.api.nvim_create_buf(false, true), "lua")
print("-- treesitter lua parser available: " .. tostring(has_lua_parser))

-- Buffer for role classification.
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  "local count = 0",
  "count = count + 1",
  "print(count)",
})
vim.bo[buf].filetype = "lua"

local function range(line, scol, ecol)
  return { start = { line = line, character = scol }, ["end"] = { line = line, character = ecol } }
end

if has_lua_parser then
  -- Force a parse so get_node works.
  vim.treesitter.get_parser(buf, "lua"):parse()
  local write_role = roles.classify_syntactic(buf, range(1, 0, 5), "utf-16") -- LHS of `count = ...`
  check("write classified", write_role == "write", write_role)
  local read_role = roles.classify_syntactic(buf, range(2, 6, 11), "utf-16") -- print(count)
  check("read classified", read_role == "read", read_role)
else
  print("ok   - (skipped treesitter role checks: no lua parser)")
end

-- Overlap conflict detection: two edits that overlap.
local tmp = vim.fn.tempname() .. ".txt"
vim.fn.writefile({ "alpha beta gamma" }, tmp)
local fbuf = vim.fn.bufadd(tmp)
vim.fn.bufload(fbuf)
local uri = vim.uri_from_bufnr(fbuf)

local we_overlap = {
  changes = {
    [uri] = {
      { range = range(0, 0, 9), newText = "X" }, -- "alpha bet"
      { range = range(0, 6, 10), newText = "Y" }, -- "beta" overlaps
    },
  },
}
local session = session_mod.build({
  workspace_edit = we_overlap,
  old_name = "alpha",
  new_name = "X",
  offset_encoding = "utf-16",
  client_id = 1,
  definitions = {},
  config = config.options,
})
local overlap_found = false
for _, g in ipairs(session.files) do
  for _, s in ipairs(g.sites) do
    for _, c in ipairs(s.conflicts) do
      if c.kind == "overlap" then
        overlap_found = true
      end
    end
  end
end
check("overlap conflict detected", overlap_found)

-- Stale detection at apply time: mutate the buffer so old_text no longer matches.
local tmp2 = vim.fn.tempname() .. ".txt"
vim.fn.writefile({ "rename me here" }, tmp2)
local sbuf = vim.fn.bufadd(tmp2)
vim.fn.bufload(sbuf)
local uri2 = vim.uri_from_bufnr(sbuf)
local session2 = session_mod.build({
  workspace_edit = { changes = { [uri2] = { { range = range(0, 0, 6), newText = "RENAMED" } } } },
  old_name = "rename",
  new_name = "RENAMED",
  offset_encoding = "utf-16",
  client_id = 1,
  definitions = {},
  config = config.options,
})
-- Drift the buffer.
vim.api.nvim_buf_set_lines(sbuf, 0, -1, false, { "totally different content" })
local result = apply_mod.apply(session2)
check("stale edit skipped", result.skipped == 1 and result.applied == 0, ("applied=%d skipped=%d"):format(result.applied, result.skipped))

vim.fn.delete(tmp)
vim.fn.delete(tmp2)

print(string.format("\n%d failures", failures))
if failures > 0 then
  vim.cmd("cq")
else
  vim.cmd("qa!")
end
