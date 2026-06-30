---@mod rename-preview.execute Run an authoritative rename to completion.
---
--- Given a resolved LSP context and a chosen new name, request the real rename
--- WorkspaceEdit, build the preview session, and then either open the review
--- window or apply directly. This is the shared back end behind both the
--- prompt-driven entry point and the incremental command.

local config = require("rename-preview.config")
local lsp = require("rename-preview.lsp")
local session_mod = require("rename-preview.session")
local conflict = require("rename-preview.conflict")
local apply_mod = require("rename-preview.apply")
local ui = require("rename-preview.ui")
local util = require("rename-preview.util")

local M = {}

---@class RenamePreview.ExecuteOpts
---@field ctx RenamePreview.LspContext
---@field old_name string
---@field new_name string
---@field origin_win integer
---@field mode "review"|"apply"|nil  How to finish; defaults to the `review` config option.

--- Request the authoritative rename for `new_name`, build the session, and
--- finish according to `mode` (or the `review` config option when unset). The
--- LSP requests are issued asynchronously, so this returns immediately and the
--- window opens (or the rename applies) once the server responds.
---@param opts RenamePreview.ExecuteOpts
function M.run(opts)
  local mode = opts.mode or (config.options.review and "review" or "apply")

  lsp.rename(opts.ctx, opts.new_name, function(workspace_edit, err)
    if not workspace_edit then
      util.notify(err or "Rename failed", vim.log.levels.ERROR)
      return
    end

    lsp.definition(opts.ctx, function(definitions)
      local session, serr = session_mod.build({
        workspace_edit = workspace_edit,
        old_name = opts.old_name,
        new_name = opts.new_name,
        offset_encoding = opts.ctx.offset_encoding,
        client_id = opts.ctx.client.id,
        definitions = definitions,
        config = config.options,
      })
      if not session then
        util.notify(serr or "Nothing to rename", vim.log.levels.WARN)
        return
      end

      if mode == "apply" then
        apply_mod.commit(session, config.options)
        return
      end

      -- Review mode: a single, conflict-free site may be applied without the
      -- window when the user has opted into that shortcut.
      local _, total = session_mod.accepted_count(session)
      if config.options.auto_apply_no_conflicts and total == 1 and conflict.count(session) == 0 then
        apply_mod.commit(session, config.options)
        return
      end

      ui.open(session, opts.origin_win, config.options)
    end)
  end)
end

return M
