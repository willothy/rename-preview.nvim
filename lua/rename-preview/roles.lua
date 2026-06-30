---@mod rename-preview.roles Semantic role classification for rename sites.
---
--- A "role" answers *how* a symbol is used at a given site: is it the
--- definition, a write, a read, or a call? We combine two signals:
---
---   1. The authoritative definition location(s) from `textDocument/definition`.
---   2. A Treesitter-based heuristic on the syntax node at each site.
---
--- When Treesitter has no parser for a buffer we degrade gracefully to the
--- generic "reference" role; the rest of the plugin never depends on roles
--- being precise.

local util = require("rename-preview.util")

local M = {}

--- Find the smallest named identifier node covering the LSP range start.
---@param bufnr integer
---@param range lsp.Range
---@param encoding "utf-8"|"utf-16"|"utf-32"
---@return TSNode|nil
local function node_at(bufnr, range, encoding)
  local has_parser = pcall(vim.treesitter.get_parser, bufnr)
  if not has_parser then
    return nil
  end
  local line = util.buf_line(bufnr, range.start.line)
  local byte_col = util.char_to_byte(line, range.start.character, encoding)
  local ok, node = pcall(vim.treesitter.get_node, {
    bufnr = bufnr,
    pos = { range.start.line, byte_col },
  })
  if not ok then
    return nil
  end
  return node
end

--- Return the field name under which `child` appears in `parent`, or nil.
---@param parent TSNode
---@param child TSNode
---@return string|nil
local function field_of(parent, child)
  local child_id = child:id()
  for _, field in ipairs({ "function", "name", "left", "target", "callee", "value", "field" }) do
    local nodes = parent:field(field)
    for _, n in ipairs(nodes) do
      if n:id() == child_id then
        return field
      end
      -- The call's function field is sometimes a member expression wrapping the
      -- identifier (e.g. `M.foo` in `M.foo()`); treat a descendant match too.
      if vim.treesitter.is_ancestor(n, child) then
        return field
      end
    end
  end
  return nil
end

local CALL_TYPES = { "call", "invocation", "function_call", "method_invocation" }
local ASSIGN_TYPES = { "assignment", "augmented_assignment", "assignment_statement" }
local DECL_TYPES = { "declaration", "parameter", "var_spec", "binding", "field_definition", "let" }

-- Assignment operator token types whose left side is a write target. Listed
-- explicitly (rather than pattern-matched) so classification stays predictable.
local ASSIGN_OPS = {
  ["="] = true,
  ["+="] = true,
  ["-="] = true,
  ["*="] = true,
  ["/="] = true,
  ["%="] = true,
  ["//="] = true,
  ["**="] = true,
  ["..="] = true,
  ["&="] = true,
  ["|="] = true,
  ["^="] = true,
  [">>="] = true,
  ["<<="] = true,
  [":="] = true,
}

--- True when a position (row, col) starts before the assignment operator child
--- of `assign_node`, i.e. it is on the left-hand (written) side.
---@param assign_node TSNode
---@param row integer
---@param col integer
---@return boolean
local function before_assignment_operator(assign_node, row, col)
  for child in assign_node:iter_children() do
    if ASSIGN_OPS[child:type()] then
      local orow, ocol = child:start()
      return row < orow or (row == orow and col < ocol)
    end
  end
  return false
end

---@param type_name string
---@param needles string[]
---@return boolean
local function type_matches(type_name, needles)
  for _, needle in ipairs(needles) do
    if type_name:find(needle, 1, true) then
      return true
    end
  end
  return false
end

--- Classify a single site using Treesitter. Returns nil when no useful syntactic
--- signal is available so the caller can fall back.
---@param bufnr integer
---@param range lsp.Range
---@param encoding "utf-8"|"utf-16"|"utf-32"
---@return string|nil role
function M.classify_syntactic(bufnr, range, encoding)
  local node = node_at(bufnr, range, encoding)
  if not node then
    return nil
  end

  local parent = node:parent()
  if not parent then
    return "read"
  end

  -- Call site: identifier is the function/callee of a call expression. The call
  -- may be the direct parent (`foo()`) or an ancestor when the callee is a
  -- member/index expression (`M.foo()`), so search a couple of levels up and
  -- match via the call's function field (field_of follows descendants).
  local call_search = node
  for _ = 1, 2 do
    local up = call_search:parent()
    if not up then
      break
    end
    if type_matches(up:type(), CALL_TYPES) then
      local field = field_of(up, node)
      if field == "function" or field == "callee" or field == "name" then
        return "call"
      end
      break
    end
    -- Only keep climbing through member/index wrappers around the callee.
    local t = up:type()
    if not (t:find("index", 1, true) or t:find("member", 1, true) or t:find("field", 1, true) or t:find("selector", 1, true)) then
      break
    end
    call_search = up
  end

  -- Walk a couple of ancestors to detect assignment targets / declarations,
  -- which can be nested (e.g. identifier → variable_list → assignment).
  local node_row, node_col = node:start()
  local cur = node
  for _ = 1, 3 do
    local up = cur:parent()
    if not up then
      break
    end
    local utype = up:type()
    if type_matches(utype, ASSIGN_TYPES) then
      -- Explicit field names take priority when the grammar provides them.
      local field = field_of(up, cur)
      if field == "left" or field == "target" then
        return "write"
      end
      -- Otherwise locate the assignment operator and treat anything starting
      -- before it as the left-hand (written) side. Works for grammars like Lua
      -- where the operator is an anonymous child between two list nodes.
      if before_assignment_operator(up, node_row, node_col) then
        return "write"
      end
    end
    if type_matches(utype, DECL_TYPES) then
      return "write"
    end
    cur = up
  end

  return "read"
end

--- Produce a stable key for a location so role maps can be looked up by position.
---@param uri string
---@param range lsp.Range
---@return string
function M.location_key(uri, range)
  return ("%s:%d:%d"):format(uri, range.start.line, range.start.character)
end

--- Build a set of definition position keys for quick membership tests.
---@param definitions lsp.Location[]
---@return table<string, true>
function M.definition_set(definitions)
  local set = {}
  for _, loc in ipairs(definitions) do
    set[M.location_key(loc.uri, loc.range)] = true
    -- Also index by line so near-miss columns (selection vs full range) match.
    set[("%s:%d"):format(loc.uri, loc.range.start.line)] = true
  end
  return set
end

--- Resolve the final role for a site given the definition set and a syntactic
--- classification. The definition signal always wins.
---@param uri string
---@param range lsp.Range
---@param def_set table<string, true>
---@param syntactic string|nil
---@return string role
function M.resolve(uri, range, def_set, syntactic)
  if def_set[M.location_key(uri, range)] or def_set[("%s:%d"):format(uri, range.start.line)] then
    return "definition"
  end
  return syntactic or "reference"
end

return M
