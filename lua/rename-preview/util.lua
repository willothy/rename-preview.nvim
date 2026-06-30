---@mod rename-preview.util Internal helpers shared across the plugin.

local M = {}

--- Convert an LSP character offset (in the given offset encoding) to a 0-indexed
--- byte offset within `line`.
---
--- Neovim changed the signature of `vim.str_byteindex` between releases, so we
--- probe both forms. The returned value is clamped to the bounds of `line` so
--- callers can safely use it to slice strings even when a server reports a
--- column past the end of the line.
---@param line string
---@param character integer 0-indexed character offset
---@param encoding "utf-8"|"utf-16"|"utf-32"
---@return integer byte 0-indexed byte offset
function M.char_to_byte(line, character, encoding)
  if character <= 0 then
    return 0
  end

  local ok, byte = pcall(vim.str_byteindex, line, encoding, character, false)
  if not ok then
    -- Legacy signature: vim.str_byteindex(line, index, use_utf16)
    ok, byte = pcall(vim.str_byteindex, line, character, encoding == "utf-16")
  end

  if not ok or type(byte) ~= "number" then
    -- Final fallback: treat the offset as a byte offset directly.
    byte = math.min(character, #line)
  end

  return math.min(byte, #line)
end

--- Read a single 0-indexed line from a (loaded) buffer, returning "" when the
--- line is out of range.
---@param bufnr integer
---@param lnum integer 0-indexed line number
---@return string
function M.buf_line(bufnr, lnum)
  local lines = vim.api.nvim_buf_get_lines(bufnr, lnum, lnum + 1, false)
  return lines[1] or ""
end

--- Slice the byte range described by an LSP range out of a single line of text.
--- Only valid when `range.start.line == range['end'].line`.
---@param line string
---@param range lsp.Range
---@param encoding "utf-8"|"utf-16"|"utf-32"
---@return integer start_byte, integer end_byte 0-indexed, end exclusive
function M.range_byte_cols(line, range, encoding)
  local start_byte = M.char_to_byte(line, range.start.character, encoding)
  local end_byte = M.char_to_byte(line, range["end"].character, encoding)
  return start_byte, end_byte
end

--- Ensure the buffer backing `uri` is loaded, returning its bufnr. Buffers are
--- added without switching to them so the preview never disrupts the user's
--- window layout.
---@param uri string
---@return integer bufnr
function M.uri_bufload(uri)
  local bufnr = vim.uri_to_bufnr(uri)
  if not vim.api.nvim_buf_is_loaded(bufnr) then
    vim.fn.bufload(bufnr)
  end
  return bufnr
end

--- A path suitable for display: relative to cwd when possible, otherwise the
--- home-shortened absolute path.
---@param uri string
---@return string
function M.display_path(uri)
  local path = vim.uri_to_fname(uri)
  local rel = vim.fn.fnamemodify(path, ":.")
  if rel ~= path then
    return rel
  end
  return vim.fn.fnamemodify(path, ":~")
end

--- Sort two LSP ranges in document order (start position, then end position).
---@param a lsp.Range
---@param b lsp.Range
---@return boolean a_before_b
function M.range_lt(a, b)
  if a.start.line ~= b.start.line then
    return a.start.line < b.start.line
  end
  if a.start.character ~= b.start.character then
    return a.start.character < b.start.character
  end
  if a["end"].line ~= b["end"].line then
    return a["end"].line < b["end"].line
  end
  return a["end"].character < b["end"].character
end

--- True when two single-or-multi-line LSP ranges overlap (share at least one
--- character position). Touching ranges (end of one == start of next) do not
--- count as overlapping.
---@param a lsp.Range
---@param b lsp.Range
---@return boolean
function M.ranges_overlap(a, b)
  local function pos_lt(p, q)
    if p.line ~= q.line then
      return p.line < q.line
    end
    return p.character < q.character
  end
  -- a starts before b ends AND b starts before a ends
  return pos_lt(a.start, b["end"]) and pos_lt(b.start, a["end"])
end

--- True when `range` describes a position equal to or containing `pos`.
---@param range lsp.Range
---@param pos lsp.Position
---@return boolean
function M.range_contains_pos(range, pos)
  local function pos_le(p, q)
    if p.line ~= q.line then
      return p.line < q.line
    end
    return p.character <= q.character
  end
  return pos_le(range.start, pos) and pos_le(pos, range["end"])
end

--- Identifier character predicate used by the manual token scanner. Matches the
--- conventional `[A-Za-z0-9_]` identifier class plus high bytes so UTF-8
--- identifiers (e.g. accented characters) are kept whole.
---@param byte integer
---@return boolean
function M.is_ident_byte(byte)
  return (byte >= 48 and byte <= 57) -- 0-9
    or (byte >= 65 and byte <= 90) -- A-Z
    or (byte >= 97 and byte <= 122) -- a-z
    or byte == 95 -- _
    or byte >= 128 -- UTF-8 continuation / multibyte
end

--- Notify helper that namespaces messages under the plugin title.
---@param msg string
---@param level integer|nil vim.log.levels.*
function M.notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "rename-preview" })
end

return M
