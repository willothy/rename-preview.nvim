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

--- Synchronously issue an LSP request for a single client, returning the result
--- or an error. Uses `client:request` and waits on the response so the caller
--- can compose several requests sequentially without nesting callbacks.
---@param client vim.lsp.Client
---@param method string
---@param params table
---@param bufnr integer
---@param timeout_ms integer|nil
---@return any result, string|nil err
local function request_sync(client, method, params, bufnr, timeout_ms)
  local done, response, request_err
  local ok, request_id = client:request(method, params, function(err, result)
    request_err = err
    response = result
    done = true
  end, bufnr)

  if not ok then
    return nil, ("Failed to send %s request"):format(method)
  end

  local completed = vim.wait(timeout_ms or 4000, function()
    return done == true
  end, 10)

  if not completed then
    if request_id then
      client:cancel_request(request_id)
    end
    return nil, ("%s request timed out"):format(method)
  end

  if request_err then
    return nil, request_err.message or ("%s request failed"):format(method)
  end

  return response, nil
end

--- Resolve the symbol range and placeholder text via `textDocument/prepareRename`.
--- Servers may answer with a Range, a `{ range, placeholder }` table, or a
--- `{ defaultBehavior = true }` marker. When prepareRename is unsupported we
--- fall back to the identifier under the cursor.
---@param ctx RenamePreview.LspContext
---@return lsp.Range|nil range, string|nil placeholder, string|nil err
function M.prepare(ctx)
  local params = {
    textDocument = { uri = vim.uri_from_bufnr(ctx.bufnr) },
    position = ctx.position,
  }

  if ctx.client:supports_method("textDocument/prepareRename", ctx.bufnr) then
    local result, err = request_sync(ctx.client, "textDocument/prepareRename", params, ctx.bufnr)
    if err then
      return nil, nil, err
    end
    if result then
      -- { range, placeholder }
      if result.placeholder then
        return result.range, result.placeholder, nil
      end
      -- A bare Range.
      if result.start and result["end"] then
        return result, nil, nil
      end
      -- { defaultBehavior = true } → fall through to cursor-word resolution.
    end
  end

  return M.cursor_symbol(ctx)
end

--- Resolve the identifier under the cursor by manual token scanning. Used as a
--- placeholder/range fallback when prepareRename is unavailable. No regex is
--- used: we walk outward from the cursor over identifier bytes.
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

--- Request the rename WorkspaceEdit for a new name.
---@param ctx RenamePreview.LspContext
---@param new_name string
---@return lsp.WorkspaceEdit|nil edit, string|nil err
function M.rename(ctx, new_name)
  local params = {
    textDocument = { uri = vim.uri_from_bufnr(ctx.bufnr) },
    position = ctx.position,
    newName = new_name,
  }
  local result, err = request_sync(ctx.client, "textDocument/rename", params, ctx.bufnr)
  if err then
    return nil, err
  end
  if not result then
    return nil, "Language server returned no edits for this rename"
  end
  return result, nil
end

--- Request all references for the symbol. Used as a fallback source of
--- occurrence ranges for the incremental preview when the server does not
--- return edits for a no-op rename. Returns an empty list when unsupported.
---@param ctx RenamePreview.LspContext
---@param include_declaration boolean
---@return lsp.Location[] locations
function M.references(ctx, include_declaration)
  if not ctx.client:supports_method("textDocument/references", ctx.bufnr) then
    return {}
  end
  local params = {
    textDocument = { uri = vim.uri_from_bufnr(ctx.bufnr) },
    position = ctx.position,
    context = { includeDeclaration = include_declaration },
  }
  local result = request_sync(ctx.client, "textDocument/references", params, ctx.bufnr)
  if type(result) ~= "table" then
    return {}
  end
  return result
end

--- Request the definition location(s) for the symbol (used to mark the
--- definition role). Normalises `Location`, `Location[]` and `LocationLink[]`.
---@param ctx RenamePreview.LspContext
---@return lsp.Location[] locations
function M.definition(ctx)
  if not ctx.client:supports_method("textDocument/definition", ctx.bufnr) then
    return {}
  end
  local params = {
    textDocument = { uri = vim.uri_from_bufnr(ctx.bufnr) },
    position = ctx.position,
  }
  local result = request_sync(ctx.client, "textDocument/definition", params, ctx.bufnr)
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
