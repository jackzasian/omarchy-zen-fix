#!/bin/bash

# Remove the symlinks this project installed. Web app .desktop entries that were
# rewritten by 'relink' keep pointing at the repo, so restore them from the
# newest backup under ~/.local/state/omarchy-webapps/relink/ if you want the
# original Omarchy behaviour back.

set -euo pipefail

SOURCE_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
BIN_DIR=${OW_LOCAL_BIN_DIR:-"${XDG_BIN_HOME:-$HOME/.local/bin}"}
STATE_DIR=${OW_STATE_DIR:-"${XDG_STATE_HOME:-$HOME/.local/state}/omarchy-webapps"}

for name in omarchy-webapps omarchy-launch-webapp; do
  dest="$BIN_DIR/$name"
  if [[ -L $dest && $(readlink -f -- "$dest") == "$SOURCE_ROOT"/* ]]; then
    rm -f -- "$dest"
    printf 'removed %s\n' "$dest"
  fi
done

latest=$(ls -1d "$STATE_DIR"/relink/* 2>/dev/null | tail -1 || true)
if [[ -n $latest ]]; then
  printf '\nOriginal .desktop entries are backed up in:\n  %s\n' "$latest"
  printf 'Restore with:  cp -a "%s"/*.desktop ~/.local/share/applications/\n' "$latest"
fi
