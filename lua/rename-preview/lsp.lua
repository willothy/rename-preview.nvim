---@mod rename-preview.lsp LSP request orchestration.
---
--- This module is responsible for talking to language servers: selecting a
--- rename-capable client, resolving the symbol under the cursor, and gathering
--- the `textDocument/rename`, `textDocument/references` and
--- `textDocument/definition` results that the preview is built from.

local util = require("rename-preview.util")

local M = {}

---@class RenamePreview.LspContext
---@field client vim.lsp.Client
---@field bufnr integer
---@field position lsp.Position
---@field offset_encoding "utf-8"|"utf-16"|"utf-32"

--- Select a client attached to `bufnr` that advertises rename support. When
--- several qualify we prefer the first that also supports `prepareRename` so we
--- can resolve an accurate symbol range.
---@param bufnr integer
---@return vim.lsp.Client|nil
local function pick_rename_client(bufnr)
  local clients = vim.lsp.get_clients({ bufnr = bufnr, method = "textDocument/rename" })
  if #clients == 0 then
    return nil
  end
  for _, client in ipairs(clients) do
    if client:supports_method("textDocument/prepareRename", bufnr) then
      return client
    end
  end
  return clients[1]
end

--- Build the request context for a rename initiated at the given window/cursor.
---@param bufnr integer
---@param winnr integer
---@return RenamePreview.LspContext|nil ctx, string|nil err
function M.context(bufnr, winnr)
  local client = pick_rename_client(bufnr)
  if not client then
    return nil, "No active language server supports rename for this buffer"
  end

  local cursor = vim.api.nvim_win_get_cursor(winnr)
  local row = cursor[1] - 1
  local col = cursor[2]
  local line = util.buf_line(bufnr, row)
  -- Convert the byte column under the cursor into the client's offset encoding.
  local character
  local ok, conv = pcall(vim.str_utfindex, line, client.offset_encoding, col, false)
  if ok and type(conv) == "number" then
    character = conv
  else
    ok, conv = pcall(vim.str_utfindex, line, col)
    character = (ok and conv) or col
  end

  return {
    client = client,
    bufnr = bufnr,
    position = { line = row, character = character },
    offset_encoding = client.offset_encoding,
  }
end

--- Resolve the identifier under the cursor by manual token scanning. This is
--- how the new name is pre-filled and how `old_name` is determined; it never
--- touches the language server, so it cannot block. No regex is used: we walk
--- outward from the cursor over identifier bytes.
---@param ctx RenamePreview.LspContext
---@return lsp.Range|nil range, string|nil placeholder, string|nil err
function M.cursor_symbol(ctx)
  local line = util.buf_line(ctx.bufnr, ctx.position.line)
  local cursor_byte = util.char_to_byte(line, ctx.position.character, ctx.offset_encoding)
  -- Position is 0-indexed byte offset; Lua strings are 1-indexed.
  local idx = cursor_byte + 1
  local len = #line

  if idx > len then
    idx = len
  end
  if idx < 1 then
    idx = 1
  end

  -- If the cursor sits just past the identifier, step back onto it.
  if idx > 1 and not util.is_ident_byte(line:byte(idx) or 0) and util.is_ident_byte(line:byte(idx - 1) or 0) then
    idx = idx - 1
  end

  if not util.is_ident_byte(line:byte(idx) or 0) then
    return nil, nil, "No identifier under the cursor"
  end

  local s = idx
  while s > 1 and util.is_ident_byte(line:byte(s - 1) or 0) do
    s = s - 1
  end
  local e = idx
  while e < len and util.is_ident_byte(line:byte(e + 1) or 0) do
    e = e + 1
  end

  local word = line:sub(s, e)
  local start_char = vim.str_utfindex(line, ctx.offset_encoding, s - 1, false)
  local end_char = vim.str_utfindex(line, ctx.offset_encoding, e, false)
  local range = {
    start = { line = ctx.position.line, character = start_char },
    ["end"] = { line = ctx.position.line, character = end_char },
  }
  return range, word, nil
end

--- Extract the buffer text covered by a single-line range (used to recover the
--- old name when prepareRename returns a bare range without a placeholder).
---@param ctx RenamePreview.LspContext
---@param range lsp.Range
---@return string
local function range_text(ctx, range)
  local line = util.buf_line(ctx.bufnr, range.start.line)
  local s = util.char_to_byte(line, range.start.character, ctx.offset_encoding)
  local e = util.char_to_byte(line, range["end"].character, ctx.offset_encoding)
  return line:sub(s + 1, e)
end

--- Resolve the symbol range and old name via `textDocument/prepareRename`
--- (asynchronous, so it never blocks the editor). Servers may answer with a
--- Range, a `{ range, placeholder }` table, or a `{ defaultBehavior = true }`
--- marker; an explicit error means the position is not renameable. When
--- prepareRename is unsupported or declines, we fall back to the identifier
--- under the cursor.
---@param ctx RenamePreview.LspContext
---@param callback fun(range: lsp.Range|nil, old_name: string|nil, err: string|nil)
function M.prepare(ctx, callback)
  if not ctx.client:supports_method("textDocument/prepareRename", ctx.bufnr) then
    callback(M.cursor_symbol(ctx))
    return
  end

  local params = {
    textDocument = { uri = vim.uri_from_bufnr(ctx.bufnr) },
    position = ctx.position,
  }
  local ok = ctx.client:request("textDocument/prepareRename", params, function(err, result)
    if err then
      callback(nil, nil, err.message or "Cannot rename the symbol under the cursor")
      return
    end
    if result then
      -- { range, placeholder }
      if result.placeholder then
        callback(result.range, result.placeholder, nil)
        return
      end
      -- A bare Range: recover the name from the buffer.
      if result.start and result["end"] then
        callback(result, range_text(ctx, result), nil)
        return
      end
      -- { defaultBehavior = true } → fall through to the cursor scan.
    end
    callback(M.cursor_symbol(ctx))
  end, ctx.bufnr)
  if not ok then
    callback(M.cursor_symbol(ctx))
  end
end

--- Request the rename WorkspaceEdit for a new name. Asynchronous: the result is
--- delivered to `callback` so triggering a rename never blocks the editor, even
--- while the server is still starting up.
---@param ctx RenamePreview.LspContext
---@param new_name string
---@param callback fun(edit: lsp.WorkspaceEdit|nil, err: string|nil)
function M.rename(ctx, new_name, callback)
  local params = {
    textDocument = { uri = vim.uri_from_bufnr(ctx.bufnr) },
    position = ctx.position,
    newName = new_name,
  }
  local ok = ctx.client:request("textDocument/rename", params, function(err, result)
    if err then
      callback(nil, err.message or "Rename request failed")
    elseif not result then
      callback(nil, "Language server returned no edits for this rename")
    else
      callback(result, nil)
    end
  end, ctx.bufnr)
  if not ok then
    callback(nil, "Failed to send rename request")
  end
end

--- Request all references for the symbol (async). Used as a fallback source of
--- occurrence ranges for the incremental preview when the server does not
--- return edits for a no-op rename. Delivers an empty list when unsupported.
---@param ctx RenamePreview.LspContext
---@param include_declaration boolean
---@param callback fun(locations: lsp.Location[])
function M.references(ctx, include_declaration, callback)
  if not ctx.client:supports_method("textDocument/references", ctx.bufnr) then
    callback({})
    return
  end
  local params = {
    textDocument = { uri = vim.uri_from_bufnr(ctx.bufnr) },
    position = ctx.position,
    context = { includeDeclaration = include_declaration },
  }
  local ok = ctx.client:request("textDocument/references", params, function(_, result)
    callback(type(result) == "table" and result or {})
  end, ctx.bufnr)
  if not ok then
    callback({})
  end
end

--- Request the definition location(s) for the symbol (async; used to mark the
--- definition role). Normalises `Location`, `Location[]` and `LocationLink[]`.
---@param ctx RenamePreview.LspContext
---@param callback fun(locations: lsp.Location[])
function M.definition(ctx, callback)
  if not ctx.client:supports_method("textDocument/definition", ctx.bufnr) then
    callback({})
    return
  end
  local params = {
    textDocument = { uri = vim.uri_from_bufnr(ctx.bufnr) },
    position = ctx.position,
  }
  local ok = ctx.client:request("textDocument/definition", params, function(_, result)
    callback(M.normalize_locations(result))
  end, ctx.bufnr)
  if not ok then
    callback({})
  end
end

--- Normalise a definition response (`Location`, `Location[]`, `LocationLink[]`,
--- or nil) into a flat list of `{ uri, range }`.
---@param result any
---@return lsp.Location[]
function M.normalize_locations(result)
  if not result then
    return {}
  end
  if result.uri or result.targetUri then
    result = { result }
  end

  local locations = {}
  for _, item in ipairs(result) do
    if item.uri then
      locations[#locations + 1] = { uri = item.uri, range = item.range }
    elseif item.targetUri then
      locations[#locations + 1] = {
        uri = item.targetUri,
        range = item.targetSelectionRange or item.targetRange,
      }
    end
  end
  return locations
end

return M
