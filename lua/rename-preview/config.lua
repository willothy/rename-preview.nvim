---@mod rename-preview.config Configuration handling.

local M = {}

---@class RenamePreview.Keymaps
---@field toggle string|string[]      Toggle accept/reject for the site/file under cursor.
---@field accept_all string|string[]  Accept every rename site.
---@field reject_all string|string[]  Reject every rename site.
---@field toggle_fold string|string[] Collapse/expand the file under cursor.
---@field jump string|string[]        Jump to the source location under cursor.
---@field next_conflict string|string[] Move to the next conflicting site.
---@field prev_conflict string|string[] Move to the previous conflicting site.
---@field apply string|string[]       Apply the accepted rename sites.
---@field cancel string|string[]      Close the preview without applying.

---@class RenamePreview.Config
---@field border string|string[]      Border style for the preview window.
---@field width number                Fractional (<=1) or absolute window width.
---@field height number               Fractional (<=1) or absolute window height.
---@field review boolean              Open the review window on confirm; when false, apply immediately.
---@field auto_apply_no_conflicts boolean Apply directly (skip the review window) when the rename has no conflicts.
---@field detect_collisions boolean    Run name-collision conflict detection.
---@field role_labels table<string,string> Display labels per semantic role.
---@field keymaps RenamePreview.Keymaps
---@field on_apply fun(session: RenamePreview.Session)|nil Callback after a successful apply.

---@type RenamePreview.Config
local defaults = {
  border = "rounded",
  width = 0.8,
  height = 0.8,
  review = true,
  auto_apply_no_conflicts = false,
  detect_collisions = true,
  role_labels = {
    definition = "definition",
    declaration = "declaration",
    write = "write",
    read = "read",
    call = "call",
    reference = "reference",
  },
  keymaps = {
    toggle = "<Space>",
    accept_all = "a",
    reject_all = "x",
    toggle_fold = "<Tab>",
    jump = "o",
    next_conflict = "]c",
    prev_conflict = "[c",
    apply = "<CR>",
    cancel = { "q", "<Esc>" },
  },
  on_apply = nil,
}

---@type RenamePreview.Config
M.options = vim.deepcopy(defaults)

--- Merge user options over the defaults. Returns the resolved config.
---@param opts RenamePreview.Config|nil
---@return RenamePreview.Config
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  return M.options
end

--- The default configuration table (for documentation/tests).
---@return RenamePreview.Config
function M.defaults()
  return vim.deepcopy(defaults)
end

return M
