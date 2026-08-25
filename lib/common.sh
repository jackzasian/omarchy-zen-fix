#!/bin/bash
# shellcheck shell=bash
# Shared helpers. Sourced by bin/* and the omarchy-webapps dispatcher.

OW_NAME=omarchy-webapps
OW_CONFIG_DIR=${OW_CONFIG_DIR:-"${XDG_CONFIG_HOME:-$HOME/.config}/$OW_NAME"}
OW_CONFIG_FILE=${OW_CONFIG_FILE:-"$OW_CONFIG_DIR/config"}
OW_STATE_DIR=${OW_STATE_DIR:-"${XDG_STATE_HOME:-$HOME/.local/state}/$OW_NAME"}
OW_APPS_DIR=${OW_APPS_DIR:-"${XDG_DATA_HOME:-$HOME/.local/share}/applications"}
OW_PACKAGED_BIN=${OW_PACKAGED_BIN:-/usr/share/omarchy/bin}

say()  { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# Green/red only when stdout is a terminal, so logs and pipes stay clean.
if [[ -t 1 ]]; then
  ok_mark()   { printf '\033[32m[ok]\033[0m   %s\n' "$*"; }
  warn_mark() { printf '\033[33m[warn]\033[0m %s\n' "$*"; }
  bad_mark()  { printf '\033[31m[fail]\033[0m %s\n' "$*"; }
else
  ok_mark()   { printf '[ok]   %s\n' "$*"; }
  warn_mark() { printf '[warn] %s\n' "$*"; }
  bad_mark()  { printf '[fail] %s\n' "$*"; }
fi

load_config() {
  # Config is a plain KEY=value file; only known keys are honoured.
  [[ -f $OW_CONFIG_FILE ]] || return 0
  local key value
  while IFS='=' read -r key value; do
    key=${key%%#*}; key=${key// /}
    [[ -n $key ]] || continue
    value=${value%\"}; value=${value#\"}
    case "$key" in
    browser)       OW_BROWSER=${OW_BROWSER:-$value} ;;
    backend)       OW_BACKEND=${OW_BACKEND:-$value} ;;
    launch_prefix) OW_LAUNCH_PREFIX=${OW_LAUNCH_PREFIX-$value} ;;
    esac
  done <"$OW_CONFIG_FILE"
}

# Omarchy wraps launches in `uwsm-app` so they land in the right systemd scope.
# Outside Omarchy (or with uwsm absent) run the browser directly.
launch_prefix() {
  if [[ -n ${OW_LAUNCH_PREFIX+x} ]]; then
    printf '%s' "$OW_LAUNCH_PREFIX"
  elif command -v uwsm-app >/dev/null 2>&1; then
    printf 'setsid uwsm-app --'
  else
    printf 'setsid'
  fi
}

url_host() {
  python3 - "$1" <<'PY' 2>/dev/null
import sys
from urllib.parse import urlsplit
print((urlsplit(sys.argv[1]).hostname or "").lower())
PY
}
