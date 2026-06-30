-- rename-preview.nvim command registration.
--
-- This file is sourced automatically by Neovim. It only registers the user
-- command and guards against double-loading; all behaviour lives in the
-- `rename-preview` Lua modules and is loaded lazily on first use.

if vim.g.loaded_rename_preview then
  return
end
vim.g.loaded_rename_preview = true

vim.api.nvim_create_user_command("RenamePreview", function(opts)
  local args = opts.fargs
  require("rename-preview").rename({ new_name = args[1] })
end, {
  nargs = "?",
  desc = "Preview and selectively apply an LSP rename",
})
