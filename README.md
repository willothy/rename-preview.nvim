# rename-preview.nvim

> Safe symbol rename for Neovim. See every affected call site **before** you
> commit to an LSP rename — then accept or reject each one.

LSP rename is powerful but blind: you type a new name, hit enter, and your
language server quietly rewrites dozens of files. `rename-preview.nvim` puts a
review step in the middle. Rename a public API and walk every call site,
grouped by how the symbol is used, with conflicts flagged, before a single byte
is changed.

## Features

- **Changed-files list** — every file the rename touches, with per-file counts
  and a fold to collapse the noise.
- **Inline diff preview** — a precise before/after for each rename site, with
  the changed span highlighted.
- **Conflict detection** — name collisions (the new name already exists in a
  file), overlapping server edits, and stale edits (the buffer changed under
  you) are surfaced up front and re-checked at apply time.
- **References grouped by semantic role** — each site is labelled
  `definition` / `write` / `read` / `call` using the server's definition
  information plus Treesitter, so you can tell a declaration from a call at a
  glance.
- **Accept / reject individual sites** — toggle any single site, a whole file,
  or everything. Only what you accept is applied.

## Demo

Rename a widely-used function and review the blast radius:

```
╭───────────────────────── rename-preview ──────────────────────────╮
│                                                                    │
│  getUser  →  fetchUser                                             │
│  7 of 9 sites  ·  3 files  ·  1 conflict                          │
│  ────────────────────────────────────────────────────────────    │
│                                                                    │
│ ▌[x] ▾ src/api/user.lua                                 3 sites ⚠1 │
│ ▌    ⚠ `fetchUser` already exists at line 88 in this file         │
│ ▌ ✓  12 │ - function M.getUser(id)                                │
│ ▌       │ + function M.fetchUser(id)                  definition   │
│ ▌ ·  40 │ -   return M.getUser(id)                                │
│ ▌       │ +   return M.fetchUser(id)                        call   │
│ ▌[x] ▾ src/handlers.lua                                    4 sites │
│ ▌  ...                                                             │
╰─ <Space> toggle · a/x all/none · o jump · ]c conflict · ⏎ apply ──╯
```

The window fits its content, growing only up to the configured `width`/`height`
(see below); taller renames scroll while the keymap hints — pinned to the
window footer — stay visible.

The accent bar down the left edge is colour-coded per card — green when every
site is accepted, dim when none are, amber when partial, red when a conflict is
present. The site under the cursor is highlighted as a whole. Role labels
(`definition`, `call`, `write`, `read`) sit pinned to the right edge.

## Requirements

- Neovim 0.10+ (developed against 0.13).
- A language server with rename support attached to the buffer.
- Treesitter parsers are optional; they improve role classification but the
  plugin degrades gracefully without them.

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "willothy/rename-preview.nvim",
  config = function()
    require("rename-preview").setup()
    vim.keymap.set("n", "<leader>rn", require("rename-preview").rename, { desc = "Rename (preview)" })
  end,
}
```

With [packer.nvim](https://github.com/wbthomason/packer.nvim):

```lua
use({
  "willothy/rename-preview.nvim",
  config = function()
    require("rename-preview").setup()
  end,
})
```

## Usage

- `:RenamePreview` — rename the symbol under the cursor (prompts for the new
  name).
- `:RenamePreview <newname>` — skip the prompt.
- `require("rename-preview").rename()` — the Lua entry point; map it to a key.

Inside the preview window:

| Key       | Action                                   |
| --------- | ---------------------------------------- |
| `<Space>` | Toggle accept/reject (site, or whole file on a header) |
| `a`       | Accept all sites                         |
| `x`       | Reject all sites                         |
| `<Tab>`   | Collapse / expand the file under cursor  |
| `o`       | Preview the source location in your window |
| `]c` / `[c` | Jump to next / previous conflict        |
| `<CR>`    | Apply the accepted sites                 |
| `q` / `<Esc>` | Cancel without changing anything     |

All keys are configurable (see below).

## Configuration

`setup()` takes an options table. Defaults shown:

```lua
require("rename-preview").setup({
  border = "rounded",          -- any nvim_open_win border value
  width = 0.8,                  -- fraction of columns (<=1) or absolute count
  height = 0.8,                 -- fraction of lines (<=1) or absolute count
  auto_apply_no_conflicts = false, -- skip the UI for a single conflict-free site
  detect_collisions = true,    -- scan files for pre-existing uses of the new name
  role_labels = {              -- relabel the semantic roles however you like
    definition = "definition",
    declaration = "declaration",
    write = "write",
    read = "read",
    call = "call",
    reference = "reference",
  },
  keymaps = {
    toggle = "<Space>",
    accept_all = "a",
    reject_all = "x",
    toggle_fold = "<Tab>",
    jump = "o",
    next_conflict = "]c",
    prev_conflict = "[c",
    apply = "<CR>",
    cancel = { "q", "<Esc>" },
  },
  on_apply = nil,              -- function(session) called after a successful apply
})
```

### Highlights

Every visual element links to a standard group by default, so the preview
matches your colour scheme out of the box. Override any of them after `setup()`:

```lua
vim.api.nvim_set_hl(0, "RenamePreviewNewName", { fg = "#a6e3a1", bold = true })
```

See `:help rename-preview-highlights` for the full list.

## How it works

1. The symbol under the cursor is resolved via `textDocument/prepareRename`
   (falling back to a hand-written identifier scan).
2. `textDocument/rename` computes the full `WorkspaceEdit` — but it is **not**
   applied.
3. `textDocument/definition` and Treesitter are used to label each edit with a
   semantic role.
4. Conflicts are computed across the edit set.
5. You review and curate the edits; only the accepted subset is applied, with a
   final staleness re-check so a buffer that changed during review can never be
   silently corrupted.

## Testing

```sh
tests/run.sh
```

The suite runs headlessly and includes a live end-to-end test against `clangd`
when it is installed.

## License

MIT
