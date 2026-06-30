---@mod rename-preview.session Build the preview model from LSP results.

local util = require("rename-preview.util")
local roles = require("rename-preview.roles")
local conflict = require("rename-preview.conflict")
local diff = require("rename-preview.diff")

local M = {}

---@class RenamePreview.Site
---@field id integer                 Stable, session-unique id.
---@field uri string
---@field range lsp.Range            LSP range of the edit (in `offset_encoding`).
---@field new_text string            Replacement text from the WorkspaceEdit.
---@field old_text string            Original text covered by `range`.
---@field role string                Semantic role (definition/write/read/call/reference).
---@field accepted boolean           Whether this site will be applied.
---@field conflicts RenamePreview.Conflict[]
---@field hunk RenamePreview.Hunk    Precomputed before/after preview.

---@class RenamePreview.FileGroup
---@field uri string
---@field path string                Display path.
---@field bufnr integer
---@field collapsed boolean          UI fold state.
---@field sites RenamePreview.Site[]
---@field conflicts RenamePreview.Conflict[] File-level conflicts (e.g. collisions).

---@class RenamePreview.ResourceOp
---@field kind "create"|"rename"|"delete"
---@field uri string|nil
---@field old_uri string|nil
---@field new_uri string|nil
---@field options table|nil

---@class RenamePreview.Session
---@field old_name string
---@field new_name string
---@field offset_encoding "utf-8"|"utf-16"|"utf-32"
---@field client_id integer
---@field files RenamePreview.FileGroup[]
---@field resource_ops RenamePreview.ResourceOp[]

--- Normalise a WorkspaceEdit into per-URI TextEdit lists plus a resource-op list.
--- Handles both `changes` and `documentChanges` representations.
---@param workspace_edit lsp.WorkspaceEdit
---@return table<string, lsp.TextEdit[]> edits_by_uri, RenamePreview.ResourceOp[] resource_ops, string[] order
local function normalize(workspace_edit)
  local edits_by_uri = {}
  local order = {}
  local resource_ops = {}

  local function ensure(uri)
    if not edits_by_uri[uri] then
      edits_by_uri[uri] = {}
      order[#order + 1] = uri
    end
    return edits_by_uri[uri]
  end

  if workspace_edit.documentChanges then
    for _, change in ipairs(workspace_edit.documentChanges) do
      if change.kind == "create" then
        resource_ops[#resource_ops + 1] = { kind = "create", uri = change.uri, options = change.options }
      elseif change.kind == "rename" then
        resource_ops[#resource_ops + 1] =
          { kind = "rename", old_uri = change.oldUri, new_uri = change.newUri, options = change.options }
      elseif change.kind == "delete" then
        resource_ops[#resource_ops + 1] = { kind = "delete", uri = change.uri, options = change.options }
      elseif change.textDocument and change.edits then
        local bucket = ensure(change.textDocument.uri)
        for _, edit in ipairs(change.edits) do
          bucket[#bucket + 1] = edit
        end
      end
    end
  elseif workspace_edit.changes then
    for uri, edits in pairs(workspace_edit.changes) do
      local bucket = ensure(uri)
      for _, edit in ipairs(edits) do
        bucket[#bucket + 1] = edit
      end
    end
  end

  return edits_by_uri, resource_ops, order
end

--- Construct the full session model from a rename WorkspaceEdit and the
--- reference/definition locations used for role grouping.
---@param opts {workspace_edit: lsp.WorkspaceEdit, old_name: string, new_name: string, offset_encoding: string, client_id: integer, definitions: lsp.Location[], config: RenamePreview.Config}
---@return RenamePreview.Session|nil session, string|nil err
function M.build(opts)
  local edits_by_uri, resource_ops, order = normalize(opts.workspace_edit)
  if vim.tbl_isempty(edits_by_uri) and #resource_ops == 0 then
    return nil, "The language server produced no edits"
  end

  local def_set = roles.definition_set(opts.definitions)
  local encoding = opts.offset_encoding
  local next_id = 0

  ---@type RenamePreview.FileGroup[]
  local files = {}
  for _, uri in ipairs(order) do
    local edits = edits_by_uri[uri]
    local bufnr = util.uri_bufload(uri)

    ---@type RenamePreview.Site[]
    local sites = {}
    for _, edit in ipairs(edits) do
      next_id = next_id + 1
      local old_text = diff.extract(bufnr, edit.range, encoding)
      local syntactic = roles.classify_syntactic(bufnr, edit.range, encoding)
      local role = roles.resolve(uri, edit.range, def_set, syntactic)
      sites[#sites + 1] = {
        id = next_id,
        uri = uri,
        range = edit.range,
        new_text = edit.newText,
        old_text = old_text,
        role = role,
        accepted = true,
        conflicts = {},
        hunk = diff.hunk(bufnr, edit.range, edit.newText, encoding),
      }
    end

    table.sort(sites, function(a, b)
      return util.range_lt(a.range, b.range)
    end)

    files[#files + 1] = {
      uri = uri,
      path = util.display_path(uri),
      bufnr = bufnr,
      collapsed = false,
      sites = sites,
      conflicts = {},
    }
  end

  table.sort(files, function(a, b)
    return a.path < b.path
  end)

  for _, group in ipairs(files) do
    conflict.analyze(group, opts.new_name, encoding, opts.config.detect_collisions)
  end

  return {
    old_name = opts.old_name,
    new_name = opts.new_name,
    offset_encoding = encoding,
    client_id = opts.client_id,
    files = files,
    resource_ops = resource_ops,
  }, nil
end

--- Count accepted sites across the session.
---@param session RenamePreview.Session
---@return integer accepted, integer total
function M.accepted_count(session)
  local accepted, total = 0, 0
  for _, group in ipairs(session.files) do
    for _, site in ipairs(group.sites) do
      total = total + 1
      if site.accepted then
        accepted = accepted + 1
      end
    end
  end
  return accepted, total
end

return M
