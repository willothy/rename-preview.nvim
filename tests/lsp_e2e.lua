-- End-to-end LSP test driving the real request layer through clangd.
local failures = 0
local function check(name, cond, detail)
  if cond then
    print("ok   - " .. name)
  else
    failures = failures + 1
    print("FAIL - " .. name .. (detail and ("  (" .. tostring(detail) .. ")") or ""))
  end
end

if vim.fn.executable("clangd") == 0 then
  print("ok   - (skipped: clangd not available)")
  vim.cmd("qa!")
  return
end

require("rename-preview").setup({})
local lsp = require("rename-preview.lsp")
local session_mod = require("rename-preview.session")
local config = require("rename-preview.config")

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local file = dir .. "/main.c"
vim.fn.writefile({
  "int add(int a, int b) {",
  "    return a + b;",
  "}",
  "",
  "int main(void) {",
  "    int s = add(1, 2);",
  "    return add(s, 3);",
  "}",
}, file)

vim.cmd.edit(file)
local bufnr = vim.api.nvim_get_current_buf()
local winnr = vim.api.nvim_get_current_win()
vim.bo[bufnr].filetype = "c"

local client_id = vim.lsp.start({
  name = "clangd",
  cmd = { "clangd", "--background-index=false" },
  root_dir = dir,
}, { bufnr = bufnr })

check("clangd started", client_id ~= nil)
if not client_id then
  print(string.format("\n%d failures", failures))
  vim.cmd("cq")
  return
end

-- Wait for the server to initialise and process didOpen.
local client = vim.lsp.get_client_by_id(client_id)
vim.wait(15000, function()
  return client and client.initialized and client:supports_method("textDocument/rename", bufnr)
end, 50)
check("rename capability advertised", client and client:supports_method("textDocument/rename", bufnr))

-- Give clangd a moment to parse the TU so rename returns all sites.
vim.wait(2000, function()
  return false
end, 50)

-- Cursor on `add` in the definition (line 1, col 4).
vim.api.nvim_win_set_cursor(winnr, { 1, 4 })

local ctx, cerr = lsp.context(bufnr, winnr)
check("context built", ctx ~= nil, cerr)

-- Async prepareRename.
local prange, old_name, prep_done
lsp.prepare(ctx, function(r, name)
  prange, old_name, prep_done = r, name, true
end)
vim.wait(5000, function()
  return prep_done == true
end, 25)
check("prepare resolved range", prange ~= nil)
check("old name resolved to add", old_name == "add", old_name)

-- Async rename.
local we, rerr, rename_done
lsp.rename(ctx, "sum", function(edit, err)
  we, rerr, rename_done = edit, err, true
end)
vim.wait(5000, function()
  return rename_done == true
end, 25)
check("rename returned a workspace edit", we ~= nil, rerr)

-- Async definition.
local defs, def_done
lsp.definition(ctx, function(locations)
  defs, def_done = locations, true
end)
vim.wait(5000, function()
  return def_done == true
end, 25)
check("definition returned", defs and #defs >= 1, defs and #defs)

local session = session_mod.build({
  workspace_edit = we,
  old_name = old_name,
  new_name = "sum",
  offset_encoding = ctx.offset_encoding,
  client_id = client_id,
  definitions = defs,
  config = config.options,
})
check("session built from real edit", session ~= nil)

local total = 0
local def_seen = false
for _, g in ipairs(session.files) do
  for _, s in ipairs(g.sites) do
    total = total + 1
    if s.role == "definition" then
      def_seen = true
    end
  end
end
-- `add` appears 3 times: definition + 2 calls.
check("three rename sites found", total == 3, total)
check("definition role marked from LSP", def_seen)

client:stop(true)
vim.fn.delete(dir, "rf")

print(string.format("\n%d failures", failures))
if failures > 0 then
  vim.cmd("cq")
else
  vim.cmd("qa!")
end
