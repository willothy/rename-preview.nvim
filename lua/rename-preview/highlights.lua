---@mod rename-preview.highlights Highlight group definitions.

local M = {}

--- Highlight groups owned by the plugin, each linked to a sensible default so
--- the preview inherits the user's colour scheme. Users may override any of
--- these after setup.
M.groups = {
  RenamePreviewTitle = { link = "Title" },
  RenamePreviewOldName = { link = "DiffDelete" },
  RenamePreviewNewName = { link = "DiffAdd" },
  RenamePreviewArrow = { link = "Operator" },
  RenamePreviewSeparator = { link = "FloatBorder" },
  RenamePreviewFile = { link = "Directory" },
  RenamePreviewFileCount = { link = "Comment" },
  RenamePreviewLineNr = { link = "LineNr" },
  RenamePreviewAdd = { link = "DiffAdd" },
  RenamePreviewDelete = { link = "DiffDelete" },
  RenamePreviewAddText = { link = "DiffText" },
  RenamePreviewDeleteText = { link = "DiffText" },
  RenamePreviewConflict = { link = "DiagnosticError" },
  RenamePreviewConflictSign = { link = "DiagnosticSignError" },
  RenamePreviewAccepted = { link = "DiagnosticOk" },
  RenamePreviewRejected = { link = "Comment" },
  RenamePreviewHint = { link = "Comment" },
  RenamePreviewKey = { link = "Special" },
  RenamePreviewCursorLine = { link = "CursorLine" },

  -- State accent bar shown down the left edge of each card.
  RenamePreviewBarAccepted = { link = "DiagnosticOk" },
  RenamePreviewBarRejected = { link = "NonText" },
  RenamePreviewBarConflict = { link = "DiagnosticError" },
  RenamePreviewBarPartial = { link = "DiagnosticWarn" },

  -- Per-role labels.
  RenamePreviewRoleDefinition = { link = "Function" },
  RenamePreviewRoleDeclaration = { link = "Function" },
  RenamePreviewRoleCall = { link = "Function" },
  RenamePreviewRoleWrite = { link = "DiagnosticWarn" },
  RenamePreviewRoleRead = { link = "Comment" },
  RenamePreviewRoleReference = { link = "Comment" },
}

--- Map a semantic role to its highlight group.
---@param role string
---@return string
function M.role_group(role)
  local groups = {
    definition = "RenamePreviewRoleDefinition",
    declaration = "RenamePreviewRoleDeclaration",
    call = "RenamePreviewRoleCall",
    write = "RenamePreviewRoleWrite",
    read = "RenamePreviewRoleRead",
    reference = "RenamePreviewRoleReference",
  }
  return groups[role] or "RenamePreviewRoleReference"
end

--- Define all highlight groups with `default = true` so they never clobber an
--- explicit user override.
function M.setup()
  for name, spec in pairs(M.groups) do
    local def = vim.tbl_extend("force", { default = true }, spec)
    vim.api.nvim_set_hl(0, name, def)
  end

  -- Rejected diff text is dimmed and struck through to read as "won't apply".
  -- Strikethrough cannot be expressed through a link, so the comment colour is
  -- resolved explicitly; this re-runs on every ColorScheme via setup().
  local comment = vim.api.nvim_get_hl(0, { name = "Comment", link = false })
  vim.api.nvim_set_hl(0, "RenamePreviewRejectedText", {
    fg = comment.fg,
    strikethrough = true,
    default = true,
  })
end

return M
