---@mod rename-preview.ui The interactive rename preview window.
---
--- Renders a session into a scratch buffer shown in a floating window. The
--- buffer is non-modifiable; every change goes through `render`, which rebuilds
--- the line list, the line→target metadata used by the key handlers, and the
--- extmark highlight list. Keymaps act on whatever file/site the cursor is on.

local config = require("rename-preview.config")
local session_mod = require("rename-preview.session")
local conflict = require("rename-preview.conflict")
local apply_mod = require("rename-preview.apply")
local util = require("rename-preview.util")

local M = {}

local NS = vim.api.nvim_create_namespace("rename_preview_ui")

---@class RenamePreview.UiState
---@field session RenamePreview.Session
---@field bufnr integer
---@field winnr integer
---@field origin_win integer
---@field config RenamePreview.Config
---@field lines string[]
---@field meta table<integer, table>  0-indexed line → target metadata.
---@field marks table[]               Pending extmark specs.

---@type table<integer, RenamePreview.UiState>
local states = {}

---@param state RenamePreview.UiState
---@param text string
---@param meta table|nil
---@param marks table[]|nil
---@return integer lnum 0-indexed
local function add_line(state, text, meta, marks)
  state.lines[#state.lines + 1] = text
  local lnum = #state.lines - 1
  state.meta[lnum] = meta or { kind = "blank" }
  if marks then
    for _, m in ipairs(marks) do
      m.line = lnum
      state.marks[#state.marks + 1] = m
    end
  end
  return lnum
end

--- Render a line from a list of `{ text, hl, priority }` segments, accumulating
--- byte offsets so each segment's highlight lands on the right columns.
---@param state RenamePreview.UiState
---@param segments table[]
---@param meta table|nil
---@return integer lnum
local function add_segments(state, segments, meta)
  local text = ""
  local marks = {}
  for _, s in ipairs(segments) do
    local start = #text
    text = text .. (s.text or "")
    if s.hl then
      marks[#marks + 1] = { col_start = start, col_end = #text, hl = s.hl, priority = s.priority }
    end
  end
  return add_line(state, text, meta, marks)
end

local ARROW = " → "
local GUTTER = " │ "

---@param lnum0 integer 0-indexed source line
---@return string
local function lnum_label(lnum0)
  return ("%4d"):format(lnum0 + 1)
end

local BLANK_LNUM = "    "

--- Append the rendered before/after hunk for one site.
---@param state RenamePreview.UiState
---@param group RenamePreview.FileGroup
---@param site RenamePreview.Site
local function render_site(state, group, site)
  local accepted = site.accepted
  local has_conflict = #site.conflicts > 0
  local mark
  if has_conflict then
    mark = "⚠ "
  elseif accepted then
    mark = "● "
  else
    mark = "○ "
  end
  local mark_hl = has_conflict and "RenamePreviewConflictSign"
    or (accepted and "RenamePreviewAccepted" or "RenamePreviewRejected")

  local hunk = site.hunk
  local del_hl = accepted and "RenamePreviewDelete" or "RenamePreviewRejected"
  local add_hl = accepted and "RenamePreviewAdd" or "RenamePreviewRejected"
  local del_text_hl = accepted and "RenamePreviewDeleteText" or "RenamePreviewRejectedText"
  local add_text_hl = accepted and "RenamePreviewAddText" or "RenamePreviewRejectedText"

  local meta = { kind = "site", site = site, group = group }
  local start_lnum = site.range.start.line

  -- Old (deleted) lines.
  for i, pl in ipairs(hunk.old) do
    local label = (i == 1) and lnum_label(start_lnum) or BLANK_LNUM
    local segs = {
      { text = (i == 1) and mark or "  ", hl = (i == 1) and mark_hl or nil },
      { text = label, hl = "RenamePreviewLineNr" },
      { text = GUTTER, hl = "RenamePreviewLineNr" },
      { text = "- ", hl = del_hl },
    }
    -- Split the text so the changed span gets the stronger highlight.
    if pl.hl_start and pl.hl_end and pl.hl_end >= pl.hl_start then
      segs[#segs + 1] = { text = pl.text:sub(1, pl.hl_start), hl = del_hl, priority = 100 }
      segs[#segs + 1] =
        { text = pl.text:sub(pl.hl_start + 1, pl.hl_end), hl = del_text_hl, priority = 200 }
      segs[#segs + 1] = { text = pl.text:sub(pl.hl_end + 1), hl = del_hl, priority = 100 }
    else
      segs[#segs + 1] = { text = pl.text, hl = del_hl, priority = 100 }
    end
    add_segments(state, segs, meta)
  end

  -- New (added) lines, with the role label appended to the first one.
  local role_label = state.config.role_labels[site.role] or site.role
  for i, pl in ipairs(hunk.new) do
    local segs = {
      { text = "  " },
      { text = BLANK_LNUM, hl = "RenamePreviewLineNr" },
      { text = GUTTER, hl = "RenamePreviewLineNr" },
      { text = "+ ", hl = add_hl },
    }
    if pl.hl_start and pl.hl_end and pl.hl_end >= pl.hl_start then
      segs[#segs + 1] = { text = pl.text:sub(1, pl.hl_start), hl = add_hl, priority = 100 }
      segs[#segs + 1] =
        { text = pl.text:sub(pl.hl_start + 1, pl.hl_end), hl = add_text_hl, priority = 200 }
      segs[#segs + 1] = { text = pl.text:sub(pl.hl_end + 1), hl = add_hl, priority = 100 }
    else
      segs[#segs + 1] = { text = pl.text, hl = add_hl, priority = 100 }
    end
    if i == #hunk.new then
      segs[#segs + 1] = { text = "  [" .. role_label .. "]", hl = "RenamePreviewRole" }
    end
    add_segments(state, segs, meta)
  end

  -- Site-level conflicts.
  for _, c in ipairs(site.conflicts) do
    add_segments(state, {
      { text = "      " },
      { text = "⚠ " .. c.message, hl = "RenamePreviewConflict" },
    }, meta)
  end
end

--- Rebuild the entire preview buffer from the session state.
---@param state RenamePreview.UiState
local function render(state)
  state.lines = {}
  state.meta = {}
  state.marks = {}

  local session = state.session
  local accepted, total = session_mod.accepted_count(session)
  local nconf = conflict.count(session)
  local nfiles = #session.files

  -- Title.
  add_segments(state, {
    { text = "  Rename  " },
    { text = session.old_name, hl = "RenamePreviewOldName" },
    { text = ARROW, hl = "RenamePreviewTitle" },
    { text = session.new_name, hl = "RenamePreviewNewName" },
  }, { kind = "title" })

  -- Summary.
  local conf_text = nconf == 1 and "1 conflict" or (nconf .. " conflicts")
  local files_text = nfiles == 1 and "1 file" or (nfiles .. " files")
  add_segments(state, {
    { text = "  " },
    { text = ("%d/%d sites"):format(accepted, total), hl = "RenamePreviewFileCount" },
    { text = "  ·  ", hl = "RenamePreviewFileCount" },
    { text = files_text, hl = "RenamePreviewFileCount" },
    { text = "  ·  ", hl = "RenamePreviewFileCount" },
    { text = conf_text, hl = nconf > 0 and "RenamePreviewConflict" or "RenamePreviewFileCount" },
  }, { kind = "summary" })
  add_line(state, "")

  for _, group in ipairs(session.files) do
    local naccepted = 0
    for _, s in ipairs(group.sites) do
      if s.accepted then
        naccepted = naccepted + 1
      end
    end
    local fold = group.collapsed and "▸" or "▾"
    local box
    if naccepted == #group.sites then
      box = "[x]"
    elseif naccepted == 0 then
      box = "[ ]"
    else
      box = "[~]"
    end
    local count_text = (#group.sites == 1) and "1 site" or (#group.sites .. " sites")
    local header = {
      { text = " " .. fold .. " ", hl = "RenamePreviewFile" },
      { text = box .. " ", hl = naccepted > 0 and "RenamePreviewAccepted" or "RenamePreviewRejected" },
      { text = group.path, hl = "RenamePreviewFile" },
      { text = "  " .. count_text, hl = "RenamePreviewFileCount" },
    }
    if #group.conflicts > 0 then
      header[#header + 1] = { text = "  ⚠ " .. #group.conflicts, hl = "RenamePreviewConflict" }
    end
    add_segments(state, header, { kind = "file", group = group })

    -- File-level conflicts (e.g. name collisions).
    if not group.collapsed then
      for _, c in ipairs(group.conflicts) do
        add_segments(state, {
          { text = "     " },
          { text = "⚠ " .. c.message, hl = "RenamePreviewConflict" },
        }, { kind = "file", group = group })
      end
      for _, site in ipairs(group.sites) do
        render_site(state, group, site)
      end
    end
    add_line(state, "")
  end

  -- Hint footer.
  local km = state.config.keymaps
  local function key(k)
    return type(k) == "table" and k[1] or k
  end
  add_segments(state, {
    { text = "  " },
    { text = key(km.toggle), hl = "RenamePreviewKey" },
    { text = " toggle  ", hl = "RenamePreviewHint" },
    { text = key(km.accept_all), hl = "RenamePreviewKey" },
    { text = " all  ", hl = "RenamePreviewHint" },
    { text = key(km.reject_all), hl = "RenamePreviewKey" },
    { text = " none  ", hl = "RenamePreviewHint" },
    { text = key(km.jump), hl = "RenamePreviewKey" },
    { text = " jump  ", hl = "RenamePreviewHint" },
    { text = key(km.next_conflict), hl = "RenamePreviewKey" },
    { text = " conflict  ", hl = "RenamePreviewHint" },
    { text = key(km.apply), hl = "RenamePreviewKey" },
    { text = " apply  ", hl = "RenamePreviewHint" },
    { text = key(km.cancel), hl = "RenamePreviewKey" },
    { text = " cancel", hl = "RenamePreviewHint" },
  }, { kind = "hint" })

  -- Commit to the buffer.
  vim.bo[state.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, state.lines)
  vim.bo[state.bufnr].modifiable = false

  vim.api.nvim_buf_clear_namespace(state.bufnr, NS, 0, -1)
  for _, m in ipairs(state.marks) do
    pcall(vim.api.nvim_buf_set_extmark, state.bufnr, NS, m.line, m.col_start, {
      end_col = m.col_end,
      hl_group = m.hl,
      priority = m.priority or 150,
    })
  end
end

--- The metadata for the line the cursor is on.
---@param state RenamePreview.UiState
---@return table meta
local function cursor_meta(state)
  local lnum = vim.api.nvim_win_get_cursor(state.winnr)[1] - 1
  return state.meta[lnum] or { kind = "blank" }
end

--- Toggle accept state for the site or file under the cursor.
---@param state RenamePreview.UiState
local function action_toggle(state)
  local meta = cursor_meta(state)
  if meta.kind == "site" then
    meta.site.accepted = not meta.site.accepted
  elseif meta.kind == "file" then
    -- Flip the whole file based on its current majority state.
    local all_accepted = true
    for _, s in ipairs(meta.group.sites) do
      if not s.accepted then
        all_accepted = false
        break
      end
    end
    for _, s in ipairs(meta.group.sites) do
      s.accepted = not all_accepted
    end
  else
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(state.winnr)
  render(state)
  pcall(vim.api.nvim_win_set_cursor, state.winnr, cursor)
end

---@param state RenamePreview.UiState
---@param value boolean
local function set_all(state, value)
  for _, group in ipairs(state.session.files) do
    for _, site in ipairs(group.sites) do
      site.accepted = value
    end
  end
  local cursor = vim.api.nvim_win_get_cursor(state.winnr)
  render(state)
  pcall(vim.api.nvim_win_set_cursor, state.winnr, cursor)
end

---@param state RenamePreview.UiState
local function action_toggle_fold(state)
  local meta = cursor_meta(state)
  local group = meta.group
  if not group then
    return
  end
  group.collapsed = not group.collapsed
  render(state)
end

--- Preview the source location of the site under the cursor in the origin
--- window, without leaving the preview.
---@param state RenamePreview.UiState
local function action_jump(state)
  local meta = cursor_meta(state)
  local site = meta.site
  local group = meta.group
  if not site and group then
    site = group.sites[1]
  end
  if not site then
    return
  end
  if not (state.origin_win and vim.api.nvim_win_is_valid(state.origin_win)) then
    return
  end
  local bufnr = util.uri_bufload(site.uri)
  vim.api.nvim_win_set_buf(state.origin_win, bufnr)
  local line = site.range.start.line
  local lcontent = util.buf_line(bufnr, line)
  local col = util.char_to_byte(lcontent, site.range.start.character, state.session.offset_encoding)
  pcall(vim.api.nvim_win_set_cursor, state.origin_win, { line + 1, col })
  vim.api.nvim_win_call(state.origin_win, function()
    vim.cmd("normal! zz")
  end)
end

--- Move the cursor to the next/previous line that carries a conflict.
---@param state RenamePreview.UiState
---@param dir 1|-1
local function action_conflict(state, dir)
  local conflict_lines = {}
  for lnum, meta in pairs(state.meta) do
    local has = false
    if meta.kind == "site" and meta.site and #meta.site.conflicts > 0 then
      has = true
    elseif meta.kind == "file" and meta.group and #meta.group.conflicts > 0 then
      has = true
    end
    if has then
      conflict_lines[#conflict_lines + 1] = lnum
    end
  end
  if #conflict_lines == 0 then
    util.notify("No conflicts", vim.log.levels.INFO)
    return
  end
  table.sort(conflict_lines)
  local cur = vim.api.nvim_win_get_cursor(state.winnr)[1] - 1
  local target
  if dir == 1 then
    for _, l in ipairs(conflict_lines) do
      if l > cur then
        target = l
        break
      end
    end
    target = target or conflict_lines[1]
  else
    for i = #conflict_lines, 1, -1 do
      if conflict_lines[i] < cur then
        target = conflict_lines[i]
        break
      end
    end
    target = target or conflict_lines[#conflict_lines]
  end
  vim.api.nvim_win_set_cursor(state.winnr, { target + 1, 0 })
end

---@param state RenamePreview.UiState
local function close(state)
  states[state.bufnr] = nil
  if vim.api.nvim_win_is_valid(state.winnr) then
    vim.api.nvim_win_close(state.winnr, true)
  end
  if vim.api.nvim_buf_is_valid(state.bufnr) then
    vim.api.nvim_buf_delete(state.bufnr, { force = true })
  end
end

--- Confirm and apply the accepted sites.
---@param state RenamePreview.UiState
local function action_apply(state)
  local session = state.session
  local accepted = session_mod.accepted_count(session)
  if accepted == 0 then
    util.notify("No sites selected; nothing to apply", vim.log.levels.WARN)
    return
  end

  -- Warn when accepted sites still carry conflicts.
  local accepted_conflicts = 0
  for _, group in ipairs(session.files) do
    for _, site in ipairs(group.sites) do
      if site.accepted then
        accepted_conflicts = accepted_conflicts + #site.conflicts
      end
    end
    -- File-level collisions count against any accepted site in the file.
    for _, s in ipairs(group.sites) do
      if s.accepted then
        accepted_conflicts = accepted_conflicts + #group.conflicts
        break
      end
    end
  end

  if accepted_conflicts > 0 then
    local choice = vim.fn.confirm(
      ("%d conflict(s) affect the selected sites. Apply anyway?"):format(accepted_conflicts),
      "&Apply\n&Cancel",
      2
    )
    if choice ~= 1 then
      return
    end
  end

  local cfg = state.config
  close(state)
  local result = apply_mod.apply(session)

  local msg = ("Renamed to `%s`: %d edit(s) across %d file(s)"):format(
    session.new_name,
    result.applied,
    result.files
  )
  if result.skipped > 0 then
    msg = msg .. ("\nSkipped %d stale edit(s):\n  %s"):format(
      result.skipped,
      table.concat(result.skipped_detail, "\n  ")
    )
    util.notify(msg, vim.log.levels.WARN)
  else
    util.notify(msg, vim.log.levels.INFO)
  end

  if cfg.on_apply then
    pcall(cfg.on_apply, session)
  end
end

--- Register a keymap that may be a single lhs or a list of lhs.
---@param bufnr integer
---@param lhs string|string[]
---@param fn function
---@param desc string
local function map(bufnr, lhs, fn, desc)
  local list = type(lhs) == "table" and lhs or { lhs }
  for _, l in ipairs(list) do
    vim.keymap.set("n", l, fn, { buffer = bufnr, nowait = true, silent = true, desc = desc })
  end
end

--- Open the preview window for a built session.
---@param session RenamePreview.Session
---@param origin_win integer
---@param cfg RenamePreview.Config
function M.open(session, origin_win, cfg)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].filetype = "rename-preview"

  local cols = vim.o.columns
  local rows = vim.o.lines
  local width = cfg.width <= 1 and math.floor(cols * cfg.width) or math.floor(cfg.width)
  local height = cfg.height <= 1 and math.floor(rows * cfg.height) or math.floor(cfg.height)
  width = math.max(40, math.min(width, cols - 4))
  height = math.max(10, math.min(height, rows - 4))

  local winnr = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((rows - height) / 2),
    col = math.floor((cols - width) / 2),
    style = "minimal",
    border = cfg.border,
    title = " rename-preview ",
    title_pos = "center",
  })
  vim.wo[winnr].wrap = false
  vim.wo[winnr].cursorline = true

  local state = {
    session = session,
    bufnr = bufnr,
    winnr = winnr,
    origin_win = origin_win,
    config = cfg,
    lines = {},
    meta = {},
    marks = {},
  }
  states[bufnr] = state

  local km = cfg.keymaps
  map(bufnr, km.toggle, function()
    action_toggle(state)
  end, "Toggle accept/reject")
  map(bufnr, km.accept_all, function()
    set_all(state, true)
  end, "Accept all")
  map(bufnr, km.reject_all, function()
    set_all(state, false)
  end, "Reject all")
  map(bufnr, km.toggle_fold, function()
    action_toggle_fold(state)
  end, "Toggle fold")
  map(bufnr, km.jump, function()
    action_jump(state)
  end, "Jump to source")
  map(bufnr, km.next_conflict, function()
    action_conflict(state, 1)
  end, "Next conflict")
  map(bufnr, km.prev_conflict, function()
    action_conflict(state, -1)
  end, "Previous conflict")
  map(bufnr, km.apply, function()
    action_apply(state)
  end, "Apply rename")
  map(bufnr, km.cancel, function()
    close(state)
  end, "Cancel")

  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(winnr),
    once = true,
    callback = function()
      if states[bufnr] then
        states[bufnr] = nil
      end
    end,
  })

  render(state)
  -- Place the cursor on the first file header for immediate interaction.
  for lnum, meta in pairs(state.meta) do
    if meta.kind == "file" then
      pcall(vim.api.nvim_win_set_cursor, winnr, { lnum + 1, 0 })
      break
    end
  end
end

return M
