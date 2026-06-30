-- End-to-end test for the incremental confirm path through a real server.
-- Uses auto_apply_no_conflicts = true: a multi-site, conflict-free rename must
-- apply directly without opening the review window.
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

require("rename-preview").setup({ auto_apply_no_conflicts = true })
local incremental = require("rename-preview.incremental")

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local file = dir .. "/main.c"
vim.fn.writefile({
  "int add(int a, int b) {",
  "    return a + b;",
  "}",
  "",
  "int main(void) {",
  "    return add(add(1, 2), 3);",
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

local client = vim.lsp.get_client_by_id(client_id)
vim.wait(15000, function()
  return client and client.initialized and client:supports_method("textDocument/rename", bufnr)
end, 50)
vim.wait(2000, function()
  return false
end, 50)

-- Cursor on `add` in the definition.
vim.api.nvim_win_set_cursor(winnr, { 1, 4 })

-- pending is nil here, so confirm() takes the direct-invocation fallback:
-- resolve the symbol at the cursor and run the authoritative rename. The rename
-- runs asynchronously, so wait for the edit to land.
incremental.confirm({ args = "sum" })
vim.wait(5000, function()
  return vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] == "int sum(int a, int b) {"
end, 25)

local after = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
check("definition renamed", after[1] == "int sum(int a, int b) {", after[1])
check("nested calls renamed", after[6] == "    return sum(sum(1, 2), 3);", after[6])

-- auto_apply_no_conflicts must skip the review window entirely.
local preview_open = false
for _, w in ipairs(vim.api.nvim_list_wins()) do
  if vim.bo[vim.api.nvim_win_get_buf(w)].filetype == "rename-preview" then
    preview_open = true
  end
end
check("review window was not opened", not preview_open)

client:stop(true)
vim.fn.delete(dir, "rf")

print(string.format("\n%d failures", failures))
if failures > 0 then
  vim.cmd("cq")
else
  vim.cmd("qa!")
end
