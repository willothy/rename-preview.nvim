# rename-preview.nvim

> Safe symbol rename for Neovim. See every affected call site **before** you
> commit to an LSP rename — then accept or reject each one.

LSP rename is powerful but blind: you type a new name, hit enter, and your
language server quietly rewrites dozens of files. `rename-preview.nvim` puts a
review step in the middle. Rename a public API and walk every call site,
grouped by how the symbol is used, with conflicts flagged, before a single byte
is changed.

## Features

- **Live, type-as-you-go preview** — every affected site updates in place as you
  type the new name on the command line, à la inc-rename.nvim. Confirm to open
  the review window, or apply straight away.
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

Rename a widely-used type and review the blast radius:

<img width="660" height="411" alt="Screenshot 2026-06-30 at 8 41 57 AM" src="https://github.com/user-attachments/assets/9ea11366-59dd-4a56-81f1-e23e4990d465" />

The window fits its content, growing only up to the configured `width`/`height`
(see below).

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

- `require("rename-preview").rename()` — the entry point; map it to a key.
- `:RenamePreview` — same thing from the command line.
- `:RenamePreview <newname>` — rename straight to `<newname>`, no typing step.

Triggering a rename opens the command line pre-filled with the symbol under the
cursor. As you type the new name, every affected site visible on screen is
overlaid live with the result. Press `<CR>` to confirm — which opens the review
window below (or applies immediately when `review = false`) — or `<Esc>` to
cancel.

> Requires Neovim's `'inccommand'` to be enabled for the live preview; it is the
> default, and the plugin turns it on for the duration of the rename if needed.

Inside the review window:

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
  review = true,               -- on confirm: open the review window (false = apply now)
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

### noice.nvim

Because the interactive rename is driven by the `:RenamePreview` command, you can
let [noice.nvim](https://github.com/folke/noice.nvim) render the typing stage as
a floating input box at the cursor — the same treatment its `inc_rename` preset
gives inc-rename.nvim. Add a `cmdline` format entry that matches the command:

```lua
require("noice").setup({
  cmdline = {
    format = {
      rename_preview = {
        pattern = "^:%s*RenamePreview%s+",
        icon = "󰑕",
        conceal = true, -- hide ":RenamePreview " so only the name shows
        opts = {
          relative = "cursor",
          size = { min_width = 20 },
          position = { row = -3, col = 0 },
        },
      },
    },
  },
})
```

The live in-buffer preview is unaffected — noice only restyles where the name is
typed. The `icon` needs a Nerd Font; change it to taste.

## How it works

1. The symbol under the cursor is resolved via `textDocument/prepareRename`
   (falling back to a hand-written identifier scan), and its occurrence ranges
   are fetched once.
2. While you type, those ranges are overlaid with the current name through
   Neovim's [command preview](https://neovim.io/doc/user/map.html#%3Acommand-preview)
   — no language-server request per keystroke.
3. On confirm, `textDocument/rename` computes the full authoritative
   `WorkspaceEdit` — but it is **not** applied.
4. `textDocument/definition` and Treesitter are used to label each edit with a
   semantic role.
5. Conflicts are detected across the edit set — name collisions, overlapping
   server edits, and stale edits.
6. You review and curate the edits; only the accepted subset is applied, with a
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
