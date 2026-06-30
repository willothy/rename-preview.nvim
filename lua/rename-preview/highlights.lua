---@mod rename-preview.highlights Highlight group definitions.

local M = {}

--- Highlight groups owned by the plugin, each linked to a sensible default so
--- the preview inherits the user's colour scheme. Users may override any of
--- these after setup.
M.groups = {
  RenamePreviewTitle = { link = "Title" },
  RenamePreviewOldName = { link = "DiffDelete" },
  RenamePreviewNewName = { link = "DiffAdd" },
  RenamePreviewFile = { link = "Directory" },
  RenamePreviewFileCount = { link = "Comment" },
  RenamePreviewLineNr = { link = "LineNr" },
  RenamePreviewAdd = { link = "DiffAdd" },
  RenamePreviewDelete = { link = "DiffDelete" },
  RenamePreviewAddText = { link = "DiffText" },
  RenamePreviewDeleteText = { link = "DiffText" },
  RenamePreviewRole = { link = "Type" },
  RenamePreviewConflict = { link = "DiagnosticError" },
  RenamePreviewConflictSign = { link = "DiagnosticSignError" },
  RenamePreviewAccepted = { link = "DiagnosticOk" },
  RenamePreviewRejected = { link = "Comment" },
  RenamePreviewRejectedText = { link = "Comment" },
  RenamePreviewHint = { link = "Comment" },
  RenamePreviewKey = { link = "Special" },
}

--- Define all highlight groups with `default = true` so they never clobber an
--- explicit user override.
function M.setup()
  for name, spec in pairs(M.groups) do
    local def = vim.tbl_extend("force", { default = true }, spec)
    vim.api.nvim_set_hl(0, name, def)
  end
end

return M
