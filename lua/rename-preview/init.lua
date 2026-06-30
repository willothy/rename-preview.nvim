---@mod rename-preview rename-preview.nvim — a safe symbol-rename preview UX.
---
--- Public entry point. `setup()` wires configuration and highlights; `rename()`
--- drives the whole flow: resolve the symbol, ask for a new name, compute the
--- WorkspaceEdit, build the preview model, and open the interactive window.

local config = require("rename-preview.config")
local highlights = require("rename-preview.highlights")
local lsp = require("rename-preview.lsp")
local session_mod = require("rename-preview.session")
local conflict = require("rename-preview.conflict")
local apply_mod = require("rename-preview.apply")
local diff = require("rename-preview.diff")
local ui = require("rename-preview.ui")
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

--- Build the session and either auto-apply (when configured and unambiguous) or
--- open the preview window.
---@param ctx RenamePreview.LspContext
---@param old_name string
---@param new_name string
---@param origin_win integer
local function run_preview(ctx, old_name, new_name, origin_win)
  local workspace_edit, err = lsp.rename(ctx, new_name)
  if not workspace_edit then
    util.notify(err or "Rename failed", vim.log.levels.ERROR)
    return
  end

  local definitions = lsp.definition(ctx)
  local session, serr = session_mod.build({
    workspace_edit = workspace_edit,
    old_name = old_name,
    new_name = new_name,
    offset_encoding = ctx.offset_encoding,
    client_id = ctx.client.id,
    definitions = definitions,
    config = config.options,
  })
  if not session then
    util.notify(serr or "Nothing to rename", vim.log.levels.WARN)
    return
  end

  local _, total = session_mod.accepted_count(session)
  if config.options.auto_apply_no_conflicts and total == 1 and conflict.count(session) == 0 then
    local result = apply_mod.apply(session)
    util.notify(
      ("Renamed to `%s`: %d edit(s) across %d file(s)"):format(new_name, result.applied, result.files),
      vim.log.levels.INFO
    )
    if config.options.on_apply then
      pcall(config.options.on_apply, session)
    end
    return
  end

  ui.open(session, origin_win, config.options)
end

--- Start a rename preview at the cursor.
---@param opts {new_name?: string}|nil When `new_name` is given the input prompt is skipped.
function M.rename(opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_get_current_buf()
  local winnr = vim.api.nvim_get_current_win()

  local ctx, err = lsp.context(bufnr, winnr)
  if not ctx then
    util.notify(err or "Rename unavailable here", vim.log.levels.WARN)
    return
  end

  local range, placeholder, perr = lsp.prepare(ctx)
  if not range then
    util.notify(perr or "Could not resolve a symbol to rename", vim.log.levels.WARN)
    return
  end

  local old_name = placeholder or diff.extract(ctx.bufnr, range, ctx.offset_encoding)

  if opts.new_name then
    run_preview(ctx, old_name, opts.new_name, winnr)
    return
  end

  vim.ui.input({ prompt = "New name: ", default = old_name }, function(input)
    if not input or input == "" or input == old_name then
      return
    end
    run_preview(ctx, old_name, input, winnr)
  end)
end

return M
