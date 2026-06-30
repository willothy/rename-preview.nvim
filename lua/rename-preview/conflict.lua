---@mod rename-preview.conflict Conflict detection for rename sites.
---
--- Three classes of conflict are detected:
---
---   * `overlap`   – two edits in the same file touch overlapping ranges. The
---                   language server produced an inconsistent edit; applying
---                   both would corrupt the buffer.
---   * `collision` – the new name already exists as a distinct identifier in a
---                   file we are editing. The rename may shadow or merge with an
---                   unrelated symbol of the same name.
---   * `stale`     – an edit range falls outside the current buffer contents,
---                   meaning the buffer changed after the edits were computed.
---
--- Collision scanning is done with a hand-written identifier tokenizer (no
--- regex) so it behaves predictably across languages.

local util = require("rename-preview.util")

local M = {}

---@class RenamePreview.Conflict
---@field kind "overlap"|"collision"|"stale"
---@field message string
---@field lnum integer|nil 0-indexed line the conflict points at, when applicable.

--- Find whole-identifier occurrences of `word` in `line`, returning their
--- 0-indexed byte start columns. A match must be bounded by non-identifier
--- bytes (or the line edges) on both sides.
---@param line string
---@param word string
---@return integer[] columns
local function find_word(line, word)
  local cols = {}
  if word == "" then
    return cols
  end
  local wlen = #word
  local llen = #line
  local from = 1
  while from <= llen do
    local s = line:find(word, from, true)
    if not s then
      break
    end
    local e = s + wlen - 1
    local before_ok = s == 1 or not util.is_ident_byte(line:byte(s - 1))
    local after_ok = e == llen or not util.is_ident_byte(line:byte(e + 1))
    if before_ok and after_ok then
      cols[#cols + 1] = s - 1 -- 0-indexed
    end
    from = s + 1
  end
  return cols
end

--- True when a (line, byte-col) position falls inside any of the given edit
--- ranges for `bufnr`.
---@param edits RenamePreview.Site[]
---@param lnum integer 0-indexed
---@param byte_col integer 0-indexed
---@param encoding "utf-8"|"utf-16"|"utf-32"
---@param line string
---@return boolean
local function covered_by_edit(edits, lnum, byte_col, encoding, line)
  for _, site in ipairs(edits) do
    local r = site.range
    if r.start.line <= lnum and lnum <= r["end"].line then
      local start_byte = util.char_to_byte(line, r.start.character, encoding)
      local end_byte = util.char_to_byte(line, r["end"].character, encoding)
      local on_start_line = lnum == r.start.line
      local on_end_line = lnum == r["end"].line
      local after_start = (not on_start_line) or byte_col >= start_byte
      local before_end = (not on_end_line) or byte_col < end_byte
      if after_start and before_end then
        return true
      end
    end
  end
  return false
end

--- Detect overlapping edits within a single file's site list.
---@param sites RenamePreview.Site[]
local function detect_overlaps(sites)
  -- Sort a shallow copy so the *same* site objects are annotated in place
  -- (a deep copy would attach conflicts to throwaway clones).
  local sorted = {}
  for _, s in ipairs(sites) do
    sorted[#sorted + 1] = s
  end
  table.sort(sorted, function(a, b)
    return util.range_lt(a.range, b.range)
  end)
  for i = 2, #sorted do
    local prev, cur = sorted[i - 1], sorted[i]
    if util.ranges_overlap(prev.range, cur.range) then
      local msg = "overlapping edit produced by the language server"
      cur.conflicts[#cur.conflicts + 1] = { kind = "overlap", message = msg, lnum = cur.range.start.line }
      prev.conflicts[#prev.conflicts + 1] = { kind = "overlap", message = msg, lnum = prev.range.start.line }
    end
  end
end

--- Build a predicate that reports whether a (0-indexed) buffer position sits
--- inside a comment or string, using the buffer's base Treesitter tree. This
--- excludes documentation and prose — `---@param foo`, `// foo`, `"foo"` — from
--- collision detection, since language servers never rename those, so a name
--- left there after a rename is not a real conflict. Degrades to "never inside"
--- when no parser is available.
---@param bufnr integer
---@return fun(lnum: integer, col: integer): boolean
local function comment_or_string_predicate(bufnr)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok or not parser then
    return function()
      return false
    end
  end
  local trees = parser:parse()
  local root = trees and trees[1] and trees[1]:root()
  if not root then
    return function()
      return false
    end
  end

  return function(lnum, col)
    local node = root:named_descendant_for_range(lnum, col, lnum, col)
    while node do
      local t = node:type()
      if t:find("comment", 1, true) or t:find("string", 1, true) then
        return true
      end
      node = node:parent()
    end
    return false
  end
end

--- Scan a file's buffer for pre-existing occurrences of `new_name` that are not
--- part of the rename. Each such occurrence is recorded as a collision on the
--- file group (attached to the nearest preceding site, or the group itself).
--- Occurrences inside comments and strings are ignored — language servers do
--- not rename those, so they are not real conflicts (this is what made a rename
--- followed by a rename back falsely report the original name as a collision).
---@param group RenamePreview.FileGroup
---@param new_name string
---@param encoding "utf-8"|"utf-16"|"utf-32"
local function detect_collisions(group, new_name, encoding)
  local bufnr = util.uri_bufload(group.uri)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, line_count, false)
  local in_comment_or_string = comment_or_string_predicate(bufnr)

  for lnum0 = 0, #lines - 1 do
    local line = lines[lnum0 + 1]
    for _, col in ipairs(find_word(line, new_name)) do
      if not covered_by_edit(group.sites, lnum0, col, encoding, line) and not in_comment_or_string(lnum0, col) then
        group.conflicts[#group.conflicts + 1] = {
          kind = "collision",
          message = ("`%s` already exists at line %d in this file"):format(new_name, lnum0 + 1),
          lnum = lnum0,
        }
      end
    end
  end
end

--- Detect edits whose range falls outside the current buffer.
---@param group RenamePreview.FileGroup
local function detect_stale(group)
  local bufnr = util.uri_bufload(group.uri)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  for _, site in ipairs(group.sites) do
    if site.range["end"].line >= line_count then
      site.conflicts[#site.conflicts + 1] = {
        kind = "stale",
        message = "edit points past the end of the file; the buffer may have changed",
        lnum = site.range.start.line,
      }
    end
  end
end

--- Run all conflict detectors over one file group, mutating site/group conflict
--- lists in place.
---@param group RenamePreview.FileGroup
---@param new_name string
---@param encoding "utf-8"|"utf-16"|"utf-32"
---@param detect_collisions_enabled boolean
function M.analyze(group, new_name, encoding, detect_collisions_enabled)
  group.conflicts = group.conflicts or {}
  for _, site in ipairs(group.sites) do
    site.conflicts = site.conflicts or {}
  end

  detect_overlaps(group.sites)
  detect_stale(group)
  if detect_collisions_enabled then
    detect_collisions(group, new_name, encoding)
  end
end

--- Total number of conflicts (site-level + group-level) across a session.
---@param session RenamePreview.Session
---@return integer
function M.count(session)
  local n = 0
  for _, group in ipairs(session.files) do
    n = n + #(group.conflicts or {})
    for _, site in ipairs(group.sites) do
      n = n + #(site.conflicts or {})
    end
  end
  return n
end

return M
