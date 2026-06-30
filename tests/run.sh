#!/usr/bin/env bash
# Run the rename-preview.nvim test suite headlessly.
#
# Usage: tests/run.sh   (from the repository root, or anywhere — it cds itself)
set -euo pipefail

cd "$(dirname "$0")/.."

status=0
for t in tests/integration.lua tests/roles_conflicts.lua tests/lsp_e2e.lua; do
  echo "==> $t"
  if ! nvim --headless --noplugin -u NONE -c "set rtp+=." -c "luafile $t"; then
    status=1
  fi
  echo
done

if [ "$status" -eq 0 ]; then
  echo "All test files passed."
else
  echo "Some tests failed." >&2
fi
exit "$status"
