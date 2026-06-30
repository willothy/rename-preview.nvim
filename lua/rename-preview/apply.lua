---@mod rename-preview.apply Apply the accepted subset of a rename session.

local util = require("rename-preview.util")
local diff = require("rename-preview.diff")

local M = {}

---@class RenamePreview.ApplyResult
---@field applied integer   Number of sites applied.
---@field skipped integer   Number of accepted sites skipped because the buffer drifted.
---@field files integer     Number of files touched.
---@field skipped_detail string[] Human-readable notes about each skipped site.

--- Re-extract the current text at a site and compare it to the value captured
--- when the preview was built. A mismatch means the buffer changed underneath
--- us, so the edit is unsafe to apply blindly.
---@param site RenamePreview.Site
---@param encoding "utf-8"|"utf-16"|"utf-32"
---@return boolean ok
local function still_valid(site, encoding)
  local bufnr = util.uri_bufload(site.uri)
  if site.range["end"].line >= vim.api.nvim_buf_line_count(bufnr) then
    return false
  end
  local current = diff.extract(bufnr, site.range, encoding)
  return current == site.old_text
end

--- Apply the accepted sites of a session to their buffers. Sites whose buffer
--- text has drifted since the preview are skipped and reported rather than
--- silently corrupting the file.
---@param session RenamePreview.Session
---@return RenamePreview.ApplyResult
function M.apply(session)
  local encoding = session.offset_encoding
  ---@type table<integer, lsp.TextEdit[]>
  local edits_by_buf = {}
  local touched_files = {}
  local applied, skipped = 0, 0
  local skipped_detail = {}

  for _, group in ipairs(session.files) do
    for _, site in ipairs(group.sites) do
      if site.accepted then
        if still_valid(site, encoding) then
          local bufnr = group.bufnr
          edits_by_buf[bufnr] = edits_by_buf[bufnr] or {}
          local list = edits_by_buf[bufnr]
          list[#list + 1] = { range = site.range, newText = site.new_text }
          touched_files[group.uri] = true
          applied = applied + 1
        else
          skipped = skipped + 1
          skipped_detail[#skipped_detail + 1] =
            ("%s:%d (text changed)"):format(group.path, site.range.start.line + 1)
        end
      end
    end
  end

  for bufnr, edits in pairs(edits_by_buf) do
    vim.lsp.util.apply_text_edits(edits, bufnr, encoding)
  end

  -- Resource operations (file create/rename/delete) accompany the rename and
  -- are applied only when the user is actually carrying the rename through
  -- (i.e. at least one text edit landed). They are not individually rejectable.
  if applied > 0 and session.resource_ops and #session.resource_ops > 0 then
    M.apply_resource_ops(session.resource_ops, encoding)
  end

  return {
    applied = applied,
    skipped = skipped,
    files = vim.tbl_count(touched_files),
    skipped_detail = skipped_detail,
  }
end

--- Apply file create/rename/delete operations from a WorkspaceEdit.
---@param ops RenamePreview.ResourceOp[]
---@param encoding "utf-8"|"utf-16"|"utf-32"
function M.apply_resource_ops(ops, encoding)
  for _, op in ipairs(ops) do
    -- Rebuild the minimal documentChange shape vim.lsp.util expects and reuse
    -- the core applier so option flags (overwrite/ignoreIfExists/recursive) are
    -- honoured exactly as the protocol specifies.
    local change
    if op.kind == "create" then
      change = { kind = "create", uri = op.uri, options = op.options }
    elseif op.kind == "rename" then
      change = { kind = "rename", oldUri = op.old_uri, newUri = op.new_uri, options = op.options }
    elseif op.kind == "delete" then
      change = { kind = "delete", uri = op.uri, options = op.options }
    end
    if change then
      vim.lsp.util.apply_workspace_edit({ documentChanges = { change } }, encoding)
    end
  end
end

--- Apply the accepted sites, report the outcome to the user, and run the
--- `on_apply` callback. Shared by the review window and the direct-apply paths.
---@param session RenamePreview.Session
---@param cfg RenamePreview.Config
---@return RenamePreview.ApplyResult
function M.commit(session, cfg)
  local result = M.apply(session)

  local msg = ("Renamed to `%s`: %d edit(s) across %d file(s)"):format(
    session.new_name,
    result.applied,
    result.files
  )
  if result.skipped > 0 then
    msg = msg
      .. ("\nSkipped %d stale edit(s):\n  %s"):format(result.skipped, table.concat(result.skipped_detail, "\n  "))
    util.notify(msg, vim.log.levels.WARN)
  else
    util.notify(msg, vim.log.levels.INFO)
  end

  if cfg.on_apply then
    pcall(cfg.on_apply, session)
  end

  return result
end

return M
