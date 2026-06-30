---@mod rename-preview.incremental Incremental, type-as-you-go rename preview.
---
--- Drives the live preview shown while typing a new name on the command line,
--- in the spirit of inc-rename.nvim. The set of occurrence ranges for the
--- symbol is resolved once up front (it does not depend on the replacement
--- text), cached, and then overlaid with whatever is currently typed via
--- Neovim's command-preview mechanism — so no language-server request is made
--- per keystroke. On confirm, an authoritative rename is run through the normal
--- pipeline (see |rename-preview.execute|).

local lsp = require("rename-preview.lsp")
local diff = require("rename-preview.diff")
local execute = require("rename-preview.execute")
local util = require("rename-preview.util")

local M = {}

--- The user command that backs the command-preview callback.
M.command = "RenamePreview"

---@class RenamePreview.IncState
---@field ctx RenamePreview.LspContext
---@field old_name string
---@field origin_win integer
---@field ranges_by_uri table<string, lsp.Range[]>
---@field saved_inccommand string

---@type RenamePreview.IncState|nil
local pending = nil

--- Collect every occurrence range, grouped by URI, from a WorkspaceEdit.
---@param workspace_edit lsp.WorkspaceEdit|nil
---@return table<string, lsp.Range[]> ranges
function M.ranges_from_edit(workspace_edit)
  local by_uri = {}
  if not workspace_edit then
    return by_uri
  end

  local function add(uri, range)
    by_uri[uri] = by_uri[uri] or {}
    by_uri[uri][#by_uri[uri] + 1] = range
  end

  if workspace_edit.documentChanges then
    for _, change in ipairs(workspace_edit.documentChanges) do
      if change.textDocument and change.edits then
        for _, edit in ipairs(change.edits) do
          add(change.textDocument.uri, edit.range)
        end
      end
    end
  elseif workspace_edit.changes then
    for uri, edits in pairs(workspace_edit.changes) do
      for _, edit in ipairs(edits) do
        add(uri, edit.range)
      end
    end
  end

  return by_uri
end

--- Resolve the occurrence ranges for the symbol. A no-op rename
--- (`rename(old_name)`) is the primary source so the previewed ranges match the
--- edit that will actually be applied; references are a fallback for servers
--- that decline a same-name rename.
---@param ctx RenamePreview.LspContext
---@param old_name string
---@return table<string, lsp.Range[]>|nil ranges
local function collect_ranges(ctx, old_name)
  local workspace_edit = lsp.rename(ctx, old_name)
  local ranges = M.ranges_from_edit(workspace_edit)
  if next(ranges) then
    return ranges
  end

  local by_uri = {}
  for _, loc in ipairs(lsp.references(ctx, true)) do
    by_uri[loc.uri] = by_uri[loc.uri] or {}
    by_uri[loc.uri][#by_uri[loc.uri] + 1] = loc.range
  end
  if next(by_uri) then
    return by_uri
  end

  return nil
end

--- Split `s` into a prefix whose display width does not exceed `width` and the
--- remaining suffix, so a replacement can be laid exactly over an old span of
--- `width` cells regardless of multibyte content.
---@param s string
---@param width integer
---@return string prefix, integer prefix_width, string rest
local function split_display(s, width)
  local prefix, acc = "", 0
  local nchars = vim.fn.strchars(s)
  local i = 0
  while i < nchars do
    local ch = vim.fn.strcharpart(s, i, 1)
    local w = vim.fn.strdisplaywidth(ch)
    if acc + w > width then
      break
    end
    prefix = prefix .. ch
    acc = acc + w
    i = i + 1
  end
  return prefix, acc, vim.fn.strcharpart(s, i)
end

--- Lay the new name over a single occurrence. The part that fits within the old
--- span is overlaid in place; any overflow is inserted inline so following text
--- is pushed right rather than overdrawn, and a shorter name is padded so the
--- old text is fully covered.
---@param bufnr integer
---@param ns integer
---@param range lsp.Range
---@param new_name string
---@param encoding "utf-8"|"utf-16"|"utf-32"
local function overlay_site(bufnr, ns, range, new_name, encoding)
  local line = util.buf_line(bufnr, range.start.line)

  if range.start.line ~= range["end"].line then
    -- Multi-line spans are rare for renames; just mark the start.
    local s = util.char_to_byte(line, range.start.character, encoding)
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, range.start.line, s, {
      end_row = range["end"].line,
      end_col = util.char_to_byte(util.buf_line(bufnr, range["end"].line), range["end"].character, encoding),
      hl_group = "RenamePreviewIncNew",
      priority = 200,
    })
    return
  end

  local s = util.char_to_byte(line, range.start.character, encoding)
  local e = util.char_to_byte(line, range["end"].character, encoding)
  local old_width = vim.fn.strdisplaywidth(line:sub(s + 1, e))
  local prefix, prefix_width, rest = split_display(new_name, old_width)

  local overlay = { { prefix, "RenamePreviewIncNew" } }
  local pad = old_width - prefix_width
  if pad > 0 then
    -- Unhighlighted padding blanks the remainder of a shorter old name.
    overlay[#overlay + 1] = { (" "):rep(pad) }
  end
  pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, range.start.line, s, {
    virt_text = overlay,
    virt_text_pos = "overlay",
    hl_mode = "combine",
    priority = 200,
  })

  if rest ~= "" then
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, range.start.line, e, {
      virt_text = { { rest, "RenamePreviewIncNew" } },
      virt_text_pos = "inline",
      priority = 200,
    })
  end
end

--- Draw the live overlay for `new_name` on every occurrence in `ranges_by_uri`
--- that is currently visible in a window. Extracted from `preview` so it can be
--- exercised directly in tests.
---@param ns integer Namespace to draw into.
---@param ranges_by_uri table<string, lsp.Range[]>
---@param new_name string
---@param encoding "utf-8"|"utf-16"|"utf-32"
function M.render_overlays(ns, ranges_by_uri, new_name, encoding)
  if new_name == "" then
    return
  end

  -- Only buffers shown in a window can display the overlay.
  local shown = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    shown[vim.api.nvim_win_get_buf(win)] = true
  end

  for uri, ranges in pairs(ranges_by_uri) do
    local bufnr = vim.uri_to_bufnr(uri)
    if shown[bufnr] and vim.api.nvim_buf_is_loaded(bufnr) then
      for _, range in ipairs(ranges) do
        overlay_site(bufnr, ns, range, new_name, encoding)
      end
    end
  end
end

--- Command-preview callback: overlay the typed name on every occurrence that is
--- currently visible in a window. Invoked by Neovim as the command line changes.
---@param opts table Command callback opts; `opts.args` is the typed name.
---@param ns integer Preview namespace (cleared by Neovim between calls).
---@return integer status 1 = in-place preview.
function M.preview(opts, ns)
  local st = pending
  if not st then
    return 0
  end
  M.render_overlays(ns, st.ranges_by_uri, vim.trim(opts.args or ""), st.ctx.offset_encoding)
  return 1
end

--- Restore any temporary state. Safe to call multiple times.
---
--- The 'inccommand' restore is deferred to the next event-loop tick: changing
--- it from within the CmdlineLeave callback (where this often runs) is rejected
--- with E474 while the command line is still unwinding.
function M.cleanup()
  local saved = pending and pending.saved_inccommand or nil
  pending = nil
  if saved ~= nil then
    vim.schedule(function()
      -- Skip if a new incremental session has since taken over the option.
      if not pending then
        pcall(function()
          vim.o.inccommand = saved
        end)
      end
    end)
  end
end

--- Command callback: run the authoritative rename for the confirmed name. Falls
--- back to resolving the symbol at the cursor when the command was invoked
--- directly rather than via `start()`.
---@param opts table Command callback opts; `opts.args` is the confirmed name.
function M.confirm(opts)
  local new_name = vim.trim(opts.args or "")
  local st = pending
  M.cleanup()

  if st then
    if new_name == "" or new_name == st.old_name then
      return
    end
    execute.run({
      ctx = st.ctx,
      old_name = st.old_name,
      new_name = new_name,
      origin_win = st.origin_win,
    })
    return
  end

  -- Direct `:RenamePreviewInc name` invocation without a cached session.
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
  if new_name == "" or new_name == old_name then
    return
  end
  execute.run({
    ctx = ctx,
    old_name = old_name,
    new_name = new_name,
    origin_win = winnr,
  })
end

--- Start an incremental rename: resolve and cache the symbol's occurrences, then
--- drop into the command line pre-filled with the current name so the live
--- preview tracks each keystroke.
function M.start()
  M.cleanup()

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

  local ranges_by_uri = collect_ranges(ctx, old_name)
  if not ranges_by_uri then
    util.notify("Rename is not available for this symbol", vim.log.levels.WARN)
    return
  end

  pending = {
    ctx = ctx,
    old_name = old_name,
    origin_win = winnr,
    ranges_by_uri = ranges_by_uri,
    saved_inccommand = vim.o.inccommand,
  }

  -- Command preview requires 'inccommand' to be enabled.
  if vim.o.inccommand == "" then
    vim.o.inccommand = "nosplit"
  end

  -- Clean up if the user aborts the command line (e.g. <Esc>) instead of
  -- confirming; on confirm, M.confirm performs the cleanup itself.
  vim.api.nvim_create_autocmd("CmdlineLeave", {
    once = true,
    callback = function()
      if vim.v.event.abort then
        M.cleanup()
      end
    end,
  })

  vim.api.nvim_feedkeys((":%s %s"):format(M.command, old_name), "n", false)
end

return M
