#!/bin/bash

# Install omarchy-webapps: symlink the commands into ~/.local/bin and point
# existing web app launchers at them.

set -euo pipefail

SOURCE_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
BIN_DIR=${OW_LOCAL_BIN_DIR:-"${XDG_BIN_HOME:-$HOME/.local/bin}"}

mkdir -p "$BIN_DIR"

link() {
  local target=$1 name=$2
  local dest="$BIN_DIR/$name"
  if [[ -e $dest && ! -L $dest ]]; then
    printf 'error: refusing to replace non-symlink: %s\n' "$dest" >&2
    exit 1
  fi
  ln -sfn -- "$target" "$dest"
  printf 'linked %s\n' "$dest"
}

link "$SOURCE_ROOT/omarchy-webapps" omarchy-webapps
link "$SOURCE_ROOT/bin/omarchy-launch-webapp" omarchy-launch-webapp

printf '\n'
"$SOURCE_ROOT/omarchy-webapps" relink
printf '\n'
"$SOURCE_ROOT/omarchy-webapps" doctor || true
