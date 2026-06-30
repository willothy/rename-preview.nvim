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
local conflict = require("rename-preview.conflict")

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

-- Collision detection must ignore the new name when it only appears in comments
-- or strings (a rename followed by a rename back used to falsely flag these).
local function collision_session(lines, new_name)
  -- A real, named file so the URI round-trips back to this buffer.
  local f = vim.fn.tempname() .. ".lua"
  vim.fn.writefile(lines, f)
  local cbuf = vim.fn.bufadd(f)
  vim.fn.bufload(cbuf)
  vim.bo[cbuf].filetype = "lua"
  if has_lua_parser then
    vim.treesitter.get_parser(cbuf, "lua"):parse()
  end
  local curi = vim.uri_from_bufnr(cbuf)
  -- Rename the `bar` declaration on line 2 (0-indexed line 1) to `new_name`.
  local session = session_mod.build({
    workspace_edit = { changes = { [curi] = { { range = range(1, 6, 9), newText = new_name } } } },
    old_name = "bar",
    new_name = new_name,
    offset_encoding = "utf-16",
    client_id = 1,
    definitions = {},
    config = config.options,
  })
  vim.fn.delete(f)
  return session
end

if has_lua_parser then
  -- `foo` appears only in a comment and a string → not a collision.
  local s_doc = collision_session({
    "-- foo is the old name",
    "local bar = 1",
    'local note = "foo"',
  }, "foo")
  check("comment/string occurrence is not a collision", conflict.count(s_doc) == 0, conflict.count(s_doc))
else
  print("ok   - (skipped comment/string collision check: no lua parser)")
end

-- A real code occurrence of the new name is still a collision.
local s_code = collision_session({
  "-- comment",
  "local bar = 1",
  "local foo = 2",
}, "foo")
check("real code occurrence is still a collision", conflict.count(s_code) >= 1, conflict.count(s_code))

vim.fn.delete(tmp)
vim.fn.delete(tmp2)

print(string.format("\n%d failures", failures))
if failures > 0 then
  vim.cmd("cq")
else
  vim.cmd("qa!")
end
