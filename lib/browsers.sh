#!/bin/bash
# shellcheck shell=bash
# Browser detection and backend selection.
#
# Three backends, in descending order of how app-like the result is:
#
#   chromium-app      <bin> --app=<url>
#                     What Omarchy ships. A real SSB window, shared profile.
#
#   gecko-taskbartab  <bin> -taskbar-tab <id> -new-window <url> -profile <p> -container 0
#                     Firefox's Taskbar Tabs. Shared profile (same cookies, logins
#                     and extensions as normal browsing) and a per-app Wayland
#                     app_id of the form <prgname>.webapp-<uuid>, so a compositor
#                     can style each web app individually. Needs the browser to
#                     ship modules/taskbartabs/ and to have browser.taskbarTabs.enabled
#                     set. Zen 1.21+ qualifies.
#
#   plain-window      <bin> --new-window <url>
#                     Honest fallback: an ordinary browser window. Used for Gecko
#                     builds without Taskbar Tabs, and for anything unrecognised.

ow_browser_desktop() {
  # Explicit override wins, then config, then the XDG default browser.
  if [[ -n ${OW_BROWSER:-} ]]; then
    printf '%s' "$OW_BROWSER"
    return
  fi
  xdg-settings get default-web-browser 2>/dev/null
}

# Resolve a .desktop id to the program it runs, following the first Exec token.
ow_desktop_binary() {
  local desktop=$1 dir line bin
  for dir in "${XDG_DATA_HOME:-$HOME/.local/share}/applications" \
             "$HOME/.nix-profile/share/applications" \
             /usr/local/share/applications /usr/share/applications; do
    [[ -f "$dir/$desktop" ]] || continue
    line=$(grep -m1 '^Exec=' "$dir/$desktop") || continue
    bin=${line#Exec=}
    bin=${bin%% *}
    # Exec may be a bare name or an absolute path.
    if [[ $bin == /* ]]; then
      [[ -x $bin ]] && { printf '%s' "$bin"; return 0; }
    else
      command -v "$bin" 2>/dev/null && return 0
    fi
  done
  return 1
}

ow_browser_family() {
  case "${1,,}" in
  *chromium*|*chrome*|*brave*|*edge*|*vivaldi*|*opera*|*helium*) printf 'chromium' ;;
  *zen*|*firefox*|*librewolf*|*waterfox*|*floorp*|*mullvad*)     printf 'gecko' ;;
  *)                                                             printf 'unknown' ;;
  esac
}

# Gecko builds keep chrome resources in <dir>/browser/omni.ja. Taskbar Tabs is
# present only if that archive carries the modules; checking the archive is more
# reliable than a version comparison, since forks renumber releases.
ow_gecko_has_taskbartabs() {
  local program_dir=$1
  local omni="$program_dir/browser/omni.ja" listing
  [[ -f $omni ]] || return 1
  # omni.ja is an "optimized" jar: Mozilla reorders it so Gecko can mmap it, which
  # leaves a central directory `unzip` dislikes -- it prints the entries fine but
  # exits 2. Capture first and test separately so `set -o pipefail` in a caller
  # cannot turn that warning into a false negative.
  listing=$(unzip -l "$omni" 2>/dev/null) || true
  [[ $listing == *"modules/taskbartabs/"* ]]
}

# Finding the real Gecko install is the fiddly part: a distro or a user can put a
# wrapper script behind the .desktop entry (proxy flags, sandboxing, a launcher),
# and the wrapper lives in ~/.local/bin or /usr/bin, nowhere near browser/omni.ja.
# So try, in order: the binary's own directory, the SYSTEM .desktop entry (user
# overrides are usually the wrapper), any absolute path mentioned inside the
# wrapper script, and finally the conventional install locations.
ow_gecko_program_dir() {
  local bin=$1 hint=$2 real dir candidate

  real=$(readlink -f -- "$bin" 2>/dev/null) || real=$bin
  dir=$(dirname -- "$real")
  [[ -f "$dir/browser/omni.ja" ]] && { printf '%s' "$dir"; return 0; }

  local sys_line sys_bin
  for sys_line in /usr/local/share/applications /usr/share/applications; do
    [[ -f "$sys_line/$hint.desktop" ]] || continue
    sys_bin=$(grep -m1 '^Exec=' "$sys_line/$hint.desktop" | sed 's/^Exec=//' | awk '{print $1}')
    [[ -n $sys_bin ]] || continue
    sys_bin=$(readlink -f -- "$sys_bin" 2>/dev/null) || continue
    candidate=$(dirname -- "$sys_bin")
    [[ -f "$candidate/browser/omni.ja" ]] && { printf '%s' "$candidate"; return 0; }
  done

  if [[ -f $real ]] && file -b "$real" 2>/dev/null | grep -qi 'text\|script'; then
    while read -r candidate; do
      candidate=$(dirname -- "$candidate")
      [[ -f "$candidate/browser/omni.ja" ]] && { printf '%s' "$candidate"; return 0; }
    done < <(grep -oE '/[A-Za-z0-9_./-]+' "$real" 2>/dev/null | sort -u)
  fi

  for candidate in "/opt/$hint-bin" "/opt/$hint" "/usr/lib/$hint" "/usr/lib64/$hint" "/usr/share/$hint"; do
    [[ -f "$candidate/browser/omni.ja" ]] && { printf '%s' "$candidate"; return 0; }
  done

  return 1
}

# The executable to actually run inside a resolved program directory. Taskbar Tabs
# flags go to the real Gecko binary -- the same one the browser writes into the
# desktop entries it generates -- not to a wrapper that may rewrite arguments.
ow_gecko_binary_in() {
  local dir=$1 hint=$2 candidate
  for candidate in "$dir/$hint-bin" "$dir/$hint" "$dir/firefox-bin" "$dir/firefox"; do
    [[ -x $candidate && -f $candidate ]] && { printf '%s' "$candidate"; return 0; }
  done
  for candidate in "$dir"/*-bin; do
    [[ -x $candidate && -f $candidate ]] && { printf '%s' "$candidate"; return 0; }
  done
  return 1
}

# Gecko profile roots differ per fork: Zen uses ~/.config/zen, Firefox ~/.mozilla/firefox.
ow_gecko_profile_root() {
  local family_hint=$1 root
  for root in \
    "${XDG_CONFIG_HOME:-$HOME/.config}/$family_hint" \
    "$HOME/.$family_hint" \
    "$HOME/.mozilla/$family_hint"; do
    [[ -f "$root/profiles.ini" ]] && { printf '%s' "$root"; return 0; }
  done
  return 1
}

# The profile the browser actually launches: the install's locked default first,
# then profiles.ini's Default=1, then the first profile that exists on disk.
ow_gecko_default_profile() {
  OW_ROOT="$1" python3 - <<'PY' 2>/dev/null
import configparser, os, sys

root = os.environ["OW_ROOT"]

def read(name):
    cp = configparser.RawConfigParser(strict=False)
    cp.optionxform = str
    try:
        cp.read(os.path.join(root, name))
    except Exception:
        return None
    return cp

installs = read("installs.ini")
if installs:
    for section in installs.sections():
        path = installs[section].get("Default")
        if path:
            print(path if os.path.isabs(path) else os.path.join(root, path))
            sys.exit(0)

profiles = read("profiles.ini")
if profiles:
    fallback = None
    for section in profiles.sections():
        if not section.startswith("Profile"):
            continue
        path = profiles[section].get("Path")
        if not path:
            continue
        full = path if profiles[section].get("IsRelative", "1") != "1" else os.path.join(root, path)
        if not os.path.isdir(full):
            continue
        if profiles[section].get("Default") == "1":
            print(full)
            sys.exit(0)
        fallback = fallback or full
    if fallback:
        print(fallback)
        sys.exit(0)
sys.exit(1)
PY
}

# Reuse the Taskbar Tab already registered for this host. Passing an id the
# browser does not know makes it mint a brand new web app -- new uuid, new
# desktop entry, fresh icon fetch -- on every single launch, so this lookup is
# what keeps a web app stable across invocations.
ow_taskbartab_lookup() {
  local profile=$1 url=$2
  OW_REGISTRY="$profile/taskbartabs/taskbartabs.json" OW_URL="$url" python3 - <<'PY' 2>/dev/null
import json, os, sys
from urllib.parse import urlsplit

host = (urlsplit(os.environ["OW_URL"]).hostname or "").lower()
if not host:
    sys.exit(1)
try:
    with open(os.environ["OW_REGISTRY"]) as fh:
        data = json.load(fh)
except (OSError, ValueError):
    sys.exit(1)

for tab in data.get("taskbarTabs", []):
    for scope in tab.get("scopes", []):
        if (scope.get("hostname") or "").lower() == host:
            print("%s\t%s" % (tab.get("id", ""), tab.get("userContextId", 0)))
            sys.exit(0)
sys.exit(1)
PY
}

# Sets: OW_R_DESKTOP OW_R_BIN OW_R_FAMILY OW_R_BACKEND OW_R_PROFILE
ow_resolve_browser() {
  OW_R_DESKTOP=$(ow_browser_desktop)
  OW_R_BIN=""; OW_R_FAMILY="unknown"; OW_R_BACKEND="plain-window"; OW_R_PROFILE=""; OW_R_PROGRAM_DIR=""

  [[ -n $OW_R_DESKTOP ]] || return 1
  OW_R_BIN=$(ow_desktop_binary "$OW_R_DESKTOP") || return 1
  OW_R_FAMILY=$(ow_browser_family "$OW_R_DESKTOP")

  case "$OW_R_FAMILY" in
  chromium)
    OW_R_BACKEND="chromium-app"
    ;;
  gecko)
    local program_dir hint root real_bin
    hint=${OW_R_DESKTOP%.desktop}; hint=${hint,,}

    if root=$(ow_gecko_profile_root "$hint"); then
      OW_R_PROFILE=$(ow_gecko_default_profile "$root") || OW_R_PROFILE=""
    fi

    if program_dir=$(ow_gecko_program_dir "$OW_R_BIN" "$hint") \
       && ow_gecko_has_taskbartabs "$program_dir" \
       && [[ -n $OW_R_PROFILE ]]; then
      OW_R_BACKEND="gecko-taskbartab"
      OW_R_PROGRAM_DIR=$program_dir
      if real_bin=$(ow_gecko_binary_in "$program_dir" "$hint"); then
        OW_R_BIN=$real_bin
      fi
    else
      OW_R_BACKEND="plain-window"
    fi
    ;;
  esac

  # An explicit backend in config overrides detection.
  [[ -n ${OW_BACKEND:-} ]] && OW_R_BACKEND=$OW_BACKEND
  return 0
}
