-- rename-preview.nvim command registration.
--
-- This file is sourced automatically by Neovim. It only registers the user
-- command and guards against double-loading; all behaviour lives in the
-- `rename-preview` Lua modules and is loaded lazily on first use.

if vim.g.loaded_rename_preview then
  return
end
vim.g.loaded_rename_preview = true

-- A single command drives the whole rename. With no argument it launches the
-- interactive flow (which re-enters this command pre-filled with the symbol);
-- with an argument it confirms the rename. The `preview` callback renders the
-- live, type-as-you-go preview via |command-preview|.
vim.api.nvim_create_user_command("RenamePreview", function(opts)
  if vim.trim(opts.args) == "" then
    require("rename-preview").rename()
  else
    require("rename-preview.incremental").confirm(opts)
  end
end, {
  nargs = "?",
  preview = function(opts, ns, _preview_buf)
    return require("rename-preview.incremental").preview(opts, ns)
  end,
  desc = "Rename the symbol under the cursor with a live, reviewable preview",
})
