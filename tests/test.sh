#!/bin/bash

# Tests for omarchy-webapps. Pure-bash, no network, no subagents.
# Builds a disposable tree under mktemp -d; never touches the real
# ~/.config/zen profile or ~/.local/share/applications.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT

# shellcheck source=lib/browsers.sh
source "$ROOT/lib/browsers.sh"

passes=0
fails=0
ok()  { printf 'ok   %s\n' "$1"; passes=$((passes + 1)); }
bad() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }

t_browser_family() {
  local b f
  for b in chromium chrome brave edge vivaldi opera helium; do
    f=$(ow_browser_family "$b.desktop")
    [[ $f == chromium ]] || { bad "ow_browser_family $b -> $f (want chromium)"; return; }
  done
  for b in zen firefox librewolf waterfox floorp; do
    f=$(ow_browser_family "$b.desktop")
    [[ $f == gecko ]] || { bad "ow_browser_family $b -> $f (want gecko)"; return; }
  done
  f=$(ow_browser_family "totally-junk.desktop")
  [[ $f == unknown ]] || { bad "ow_browser_family junk -> $f (want unknown)"; return; }
  ok "ow_browser_family maps chromium/gecko families + junk"
}

t_taskbartab_lookup() {
  local prof="$TMP/prof"
  mkdir -p "$prof/taskbartabs"
  cat >"$prof/taskbartabs/taskbartabs.json" <<'JSON'
{"taskbarTabs":[{"name":"GitHub","id":"11111111-1111-1111-1111-111111111111","userContextId":0,"scopes":[{"hostname":"github.com"}]}]}
JSON
  local out
  out=$(ow_taskbartab_lookup "$prof" "https://github.com/") || { bad "taskbartab lookup known host failed"; return; }
  [[ $out == $'11111111-1111-1111-1111-111111111111\t0' ]] || { bad "taskbartab lookup returned '$out'"; return; }
  if ow_taskbartab_lookup "$prof" "https://unknown.example/"; then
    bad "taskbartab lookup unknown host should fail"; return
  fi
  printf '{not valid json' >"$prof/taskbartabs/taskbartabs.json"
  if ow_taskbartab_lookup "$prof" "https://github.com/"; then
    bad "taskbartab lookup malformed registry should fail"; return
  fi
  ok "ow_taskbartab_lookup host match + unknown/malformed fail"
}

t_gecko_default_profile() {
  local root="$TMP/profroot"
  mkdir -p "$root/prof-a" "$root/prof-b" "$root/prof-c"

  cat >"$root/installs.ini" <<INI
[InstallABC]
Default=$root/prof-b
INI
  cat >"$root/profiles.ini" <<'INI'
[Profile0]
Name=a
IsRelative=1
Path=prof-a
Default=1
INI
  [[ $(ow_gecko_default_profile "$root") == "$root/prof-b" ]] || { bad "default profile should prefer installs.ini"; return; }

  rm -f "$root/installs.ini"
  cat >"$root/profiles.ini" <<'INI'
[Profile0]
Name=a
IsRelative=1
Path=prof-a
[Profile1]
Name=b
IsRelative=1
Path=prof-b
Default=1
INI
  [[ $(ow_gecko_default_profile "$root") == "$root/prof-b" ]] || { bad "default profile should prefer Default=1"; return; }

  cat >"$root/profiles.ini" <<'INI'
[Profile0]
Name=a
IsRelative=1
Path=prof-a
[Profile1]
Name=b
IsRelative=1
Path=prof-missing
Default=1
INI
  [[ $(ow_gecko_default_profile "$root") == "$root/prof-a" ]] || { bad "default profile should skip missing dirs"; return; }
  ok "ow_gecko_default_profile priority + ignores missing dirs"
}

t_relink() {
  local apps="$TMP/apps" state="$TMP/state" unrelated_orig newline second backup_dir
  mkdir -p "$apps"
  printf 'Exec=omarchy-launch-webapp https://github.com/\n' >"$apps/GitHub.desktop"
  printf 'Exec=/home/jackz/bin/omarchy-launch-webapp https://x.com/\n' >"$apps/X.desktop"
  printf 'Exec=/home/jackz/bin/omarchy-launch-webapp https://example.com/omarchy-launch-webapp x\n' >"$apps/Edge.desktop"
  printf 'Exec=not-omarchy-tool --flag\n' >"$apps/Unrelated.desktop"
  unrelated_orig=$(cat "$apps/Unrelated.desktop")

  env OW_APPS_DIR="$apps" OW_STATE_DIR="$state" "$ROOT/omarchy-webapps" relink --dry-run >/dev/null
  [[ $(cat "$apps/GitHub.desktop") == 'Exec=omarchy-launch-webapp https://github.com/' ]] \
    || { bad "relink --dry-run should change nothing"; return; }
  [[ $(cat "$apps/X.desktop") == 'Exec=/home/jackz/bin/omarchy-launch-webapp https://x.com/' ]] \
    || { bad "relink --dry-run should change nothing (shim)"; return; }
  [[ $(cat "$apps/Edge.desktop") == 'Exec=/home/jackz/bin/omarchy-launch-webapp https://example.com/omarchy-launch-webapp x' ]] \
    || { bad "relink --dry-run should change nothing (edge)"; return; }
  [[ ! -e "$state/relink" ]] || { bad "relink --dry-run should write no backup"; return; }

  env OW_APPS_DIR="$apps" OW_STATE_DIR="$state" "$ROOT/omarchy-webapps" relink >/dev/null
  newline=$(grep -m1 '^Exec=' "$apps/GitHub.desktop")
  [[ $newline == "Exec=$ROOT/bin/omarchy-launch-webapp https://github.com/" ]] \
    || { bad "relink should rewrite bare name to absolute path (got '$newline')"; return; }
  newline=$(grep -m1 '^Exec=' "$apps/X.desktop")
  [[ $newline == "Exec=$ROOT/bin/omarchy-launch-webapp https://x.com/" ]] \
    || { bad "relink should rewrite absolute shim path (got '$newline')"; return; }
  newline=$(grep -m1 '^Exec=' "$apps/Edge.desktop")
  [[ $newline == "Exec=$ROOT/bin/omarchy-launch-webapp https://example.com/omarchy-launch-webapp x" ]] \
    || { bad "relink should not mangle a URL containing the shim path (got '$newline')"; return; }
  [[ $(cat "$apps/Unrelated.desktop") == "$unrelated_orig" ]] \
    || { bad "relink should leave unrelated entries untouched"; return; }

  backup_dir=$(ls -1d "$state"/relink/* 2>/dev/null | tail -1) || true
  [[ -n $backup_dir && -f "$backup_dir/GitHub.desktop" && -f "$backup_dir/X.desktop" ]] \
    || { bad "relink should write a backup"; return; }

  second=$(env OW_APPS_DIR="$apps" OW_STATE_DIR="$state" "$ROOT/omarchy-webapps" relink 2>&1 || true)
  [[ $second == *"Done: 0 entry/entries"* ]] || { bad "relink should be idempotent (got: $second)"; return; }
  ok "relink rewrites absolute + idempotent + backup + unrelated untouched + dry-run"
}

t_gecko_has_taskbartabs() {
  local d="$TMP/noja"
  mkdir -p "$d/browser"
  if ow_gecko_has_taskbartabs "$d"; then
    bad "has_taskbartabs should fail for missing omni.ja"; return
  fi
  printf 'this is not a zip\n' >"$d/browser/omni.ja"
  if ow_gecko_has_taskbartabs "$d"; then
    bad "has_taskbartabs should fail for a non-jar omni.ja"; return
  fi
  ok "ow_gecko_has_taskbartabs fails on missing/non-jar"
}

t_browser_family
t_taskbartab_lookup
t_gecko_default_profile
t_relink
t_gecko_has_taskbartabs

printf '\n'
if ((fails)); then
  printf 'FAIL: %d of %d cases failed\n' "$fails" "$((passes + fails))"
  exit 1
fi
printf 'ok: all %d cases passed\n' "$passes"