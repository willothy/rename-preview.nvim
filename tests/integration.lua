-- Headless integration test for rename-preview.nvim.
--
-- Exercises the model-building, conflict, diff and apply layers against real
-- buffers using a synthetic WorkspaceEdit (so no language server is required).
-- Run with:
--   nvim --headless --noplugin -u NONE -c "set rtp+=." -c "luafile tests/integration.lua"

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

local session_mod = require("rename-preview.session")
local conflict = require("rename-preview.conflict")
local apply_mod = require("rename-preview.apply")
local ui = require("rename-preview.ui")
local config = require("rename-preview.config")

-- Build a real buffer with a file name so URIs resolve.
local tmp = vim.fn.tempname() .. ".lua"
local content = {
  "local function oldName(x)", -- def, line 0
  "  return oldName(x - 1)", -- call, line 1
  "end", -- line 2
  "local y = oldName", -- read, line 3
  "local newName = 5", -- pre-existing collision with new name, line 4
}
vim.fn.writefile(content, tmp)
local bufnr = vim.fn.bufadd(tmp)
vim.fn.bufload(bufnr)
local uri = vim.uri_from_bufnr(bufnr)

local function range(line, scol, ecol)
  return { start = { line = line, character = scol }, ["end"] = { line = line, character = ecol } }
end

-- Synthetic rename edit: oldName -> newName at four sites.
local workspace_edit = {
  changes = {
    [uri] = {
      { range = range(0, 15, 22), newText = "newName" }, -- function oldName
      { range = range(1, 9, 16), newText = "newName" }, -- return oldName(
      { range = range(3, 10, 17), newText = "newName" }, -- = oldName
    },
  },
}

local definitions = { { uri = uri, range = range(0, 15, 22) } }

local session, err = session_mod.build({
  workspace_edit = workspace_edit,
  old_name = "oldName",
  new_name = "newName",
  offset_encoding = "utf-16",
  client_id = 1,
  definitions = definitions,
  config = config.options,
})

check("session builds", session ~= nil, err)
check("one file group", session and #session.files == 1)

local group = session.files[1]
check("three sites", group and #group.sites == 3, group and #group.sites)

-- Roles: first site should be the definition (from the definition location).
local def_site, call_site, read_site
for _, s in ipairs(group.sites) do
  if s.range.start.line == 0 then
    def_site = s
  elseif s.range.start.line == 1 then
    call_site = s
  elseif s.range.start.line == 3 then
    read_site = s
  end
end
check("definition role detected", def_site and def_site.role == "definition", def_site and def_site.role)
check("old_text captured", def_site and def_site.old_text == "oldName", def_site and def_site.old_text)
check("new_text captured", def_site and def_site.new_text == "newName")

-- Diff hunk should highlight the changed span and produce the right new line.
local hunk = def_site.hunk
check("hunk has new line", hunk and #hunk.new == 1)
check(
  "new line spliced correctly",
  hunk and hunk.new[1].text == "local function newName(x)",
  hunk and hunk.new[1].text
)

-- Conflict: `newName` already exists at line 5 → collision on the file group.
local nconf = conflict.count(session)
check("collision detected", nconf >= 1, nconf)
local found_collision = false
for _, c in ipairs(group.conflicts) do
  if c.kind == "collision" then
    found_collision = true
  end
end
check("collision is a file-level conflict", found_collision)

-- UI render should not error and should map lines to sites/files.
local origin = vim.api.nvim_get_current_win()
ui.open(session, origin, config.options)
local ui_buf
for _, b in ipairs(vim.api.nvim_list_bufs()) do
  if vim.bo[b].filetype == "rename-preview" then
    ui_buf = b
  end
end
check("preview buffer created", ui_buf ~= nil)
local rendered = vim.api.nvim_buf_get_lines(ui_buf, 0, -1, false)
local joined = table.concat(rendered, "\n")
check("preview shows old→new", joined:find("oldName", 1, true) and joined:find("newName", 1, true))
check("preview shows conflict marker", joined:find("⚠", 1, true) ~= nil)

-- Role labels are rendered as right-aligned virtual text, not buffer text.
local ui_ns = vim.api.nvim_create_namespace("rename_preview_ui")
local virt = ""
for _, m in ipairs(vim.api.nvim_buf_get_extmarks(ui_buf, ui_ns, 0, -1, { details = true })) do
  if m[4] and m[4].virt_text then
    for _, chunk in ipairs(m[4].virt_text) do
      virt = virt .. chunk[1]
    end
  end
end
check("preview shows role label", virt:find("definition", 1, true) ~= nil, virt)

-- Close the UI window/buffer cleanly.
for _, w in ipairs(vim.api.nvim_list_wins()) do
  local b = vim.api.nvim_win_get_buf(w)
  if vim.bo[b].filetype == "rename-preview" then
    vim.api.nvim_win_close(w, true)
  end
end

-- Apply: reject the read site, apply the other two.
read_site.accepted = false
local result = apply_mod.apply(session)
check("applied two edits", result.applied == 2, result.applied)
check("no stale skips", result.skipped == 0, result.skipped)

local after = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
check("definition renamed", after[1] == "local function newName(x)", after[1])
check("call renamed", after[2] == "  return newName(x - 1)", after[2])
check("rejected read NOT renamed", after[4] == "local y = oldName", after[4])

vim.fn.delete(tmp)

print(string.format("\n%d failures", failures))
if failures > 0 then
  vim.cmd("cq")
else
  vim.cmd("qa!")
end
