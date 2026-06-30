---@mod rename-preview.diff Inline before/after preview computation.
---
--- For each rename site we render a compact before/after pair built directly
--- from the buffer contents and the edit's replacement text. Single-line edits
--- (the common case) carry precise byte columns so the changed span can be
--- highlighted; multi-line edits fall back to a whole-region display.

local util = require("rename-preview.util")

local M = {}

---@class RenamePreview.PreviewLine
---@field text string
---@field hl_start integer|nil 0-indexed byte column where the change begins.
---@field hl_end integer|nil   0-indexed byte column where the change ends (exclusive).

---@class RenamePreview.Hunk
---@field old RenamePreview.PreviewLine[]
---@field new RenamePreview.PreviewLine[]
---@field multiline boolean

--- Extract the original text covered by `range` from a loaded buffer.
---@param bufnr integer
---@param range lsp.Range
---@param encoding "utf-8"|"utf-16"|"utf-32"
---@return string text, string[] lines
function M.extract(bufnr, range, encoding)
  if range.start.line == range["end"].line then
    local line = util.buf_line(bufnr, range.start.line)
    local s = util.char_to_byte(line, range.start.character, encoding)
    local e = util.char_to_byte(line, range["end"].character, encoding)
    return line:sub(s + 1, e), { line }
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, range.start.line, range["end"].line + 1, false)
  local first = lines[1] or ""
  local last = lines[#lines] or ""
  local s = util.char_to_byte(first, range.start.character, encoding)
  local e = util.char_to_byte(last, range["end"].character, encoding)
  local region = vim.deepcopy(lines)
  region[1] = first:sub(s + 1)
  region[#region] = last:sub(1, e)
  return table.concat(region, "\n"), lines
end

--- Build the before/after hunk for one edit.
---@param bufnr integer
---@param range lsp.Range
---@param new_text string
---@param encoding "utf-8"|"utf-16"|"utf-32"
---@return RenamePreview.Hunk
function M.hunk(bufnr, range, new_text, encoding)
  if range.start.line == range["end"].line then
    local line = util.buf_line(bufnr, range.start.line)
    local s = util.char_to_byte(line, range.start.character, encoding)
    local e = util.char_to_byte(line, range["end"].character, encoding)
    local prefix = line:sub(1, s)
    local suffix = line:sub(e + 1)

    local old_line = { text = line, hl_start = s, hl_end = e }
    -- A replacement that itself contains newlines turns one line into several.
    if new_text:find("\n", 1, true) then
      local parts = vim.split(prefix .. new_text .. suffix, "\n", { plain = true })
      local new_lines = {}
      for _, p in ipairs(parts) do
        new_lines[#new_lines + 1] = { text = p }
      end
      return { old = { old_line }, new = new_lines, multiline = true }
    end

    local new_line_text = prefix .. new_text .. suffix
    local new_line = { text = new_line_text, hl_start = s, hl_end = s + #new_text }
    return { old = { old_line }, new = { new_line }, multiline = false }
  end

  -- Multi-line original range: show each original line, then the spliced result.
  local _, orig_lines = M.extract(bufnr, range, encoding)
  local first = orig_lines[1] or ""
  local last = orig_lines[#orig_lines] or ""
  local s = util.char_to_byte(first, range.start.character, encoding)
  local e = util.char_to_byte(last, range["end"].character, encoding)
  local spliced = first:sub(1, s) .. new_text .. last:sub(e + 1)

  local old_disp = {}
  for _, l in ipairs(orig_lines) do
    old_disp[#old_disp + 1] = { text = l }
  end
  local new_disp = {}
  for _, p in ipairs(vim.split(spliced, "\n", { plain = true })) do
    new_disp[#new_disp + 1] = { text = p }
  end
  return { old = old_disp, new = new_disp, multiline = true }
end

return M
