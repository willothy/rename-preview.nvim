---@mod rename-preview rename-preview.nvim — a safe symbol-rename preview UX.
---
--- Public entry point. `setup()` wires configuration and highlights; `rename()`
--- drives the whole flow: resolve the symbol, ask for a new name, compute the
--- WorkspaceEdit, build the preview model, and open the interactive window.

local config = require("rename-preview.config")
local highlights = require("rename-preview.highlights")
local lsp = require("rename-preview.lsp")
local execute = require("rename-preview.execute")
local incremental = require("rename-preview.incremental")
local util = require("rename-preview.util")

local M = {}

--- Configure the plugin and register highlight groups.
---@param opts RenamePreview.Config|nil
---@return RenamePreview.Config
function M.setup(opts)
  local cfg = config.setup(opts)
  highlights.setup()
  -- Re-link highlights whenever the colour scheme changes so the preview keeps
  -- matching the active theme.
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("RenamePreviewHighlights", { clear = true }),
    callback = highlights.setup,
  })
  return cfg
end

--- Rename the symbol under the cursor.
---
--- With no `new_name`, this drives the interactive rename: the command line
--- opens pre-filled with the current name and every affected site is previewed
--- live as you type (see |rename-preview-incremental|). On confirm the rename is
--- run to completion — opening the review window or applying directly per the
--- `review` option.
---
--- With `new_name`, the interactive step is skipped and the rename runs straight
--- away (useful for scripting).
---@param opts {new_name?: string}|nil
function M.rename(opts)
  opts = opts or {}

  if not opts.new_name then
    incremental.start()
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local winnr = vim.api.nvim_get_current_win()

  local ctx, err = lsp.context(bufnr, winnr)
  if not ctx then
    util.notify(err or "Rename unavailable here", vim.log.levels.WARN)
    return
  end

  lsp.prepare(ctx, function(range, old_name, perr)
    if not range then
      util.notify(perr or "Could not resolve a symbol to rename", vim.log.levels.WARN)
      return
    end
    execute.run({ ctx = ctx, old_name = old_name, new_name = opts.new_name, origin_win = winnr })
  end)
end

return M
