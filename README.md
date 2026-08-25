# omarchy-webapps

Run Omarchy web apps in the browser you actually use — Zen/Firefox Taskbar Tabs or Chromium `--app=`, instead of always Chromium.

## The problem

Omarchy ships `/usr/share/omarchy/bin/omarchy-launch-webapp`, which only understands
Chromium's `--app=` flag. For every other browser it silently falls back to
`chromium.desktop`, so with Zen (or any Gecko browser) as the default, web apps
never open in the browser you actually use. This project replaces that launcher
and routes to the best backend the chosen browser really supports.

## Quick start

```bash
# From repo
./install.sh

# After install
omarchy-webapps doctor
```

## Commands

| Command | Purpose |
|---------|---------|
| `omarchy-webapps status` | Show the detected browser and which backend it will use |
| `omarchy-webapps doctor` | Diagnose the whole path, including the PATH trap and browser prefs |
| `omarchy-webapps relink` | Point existing web app `.desktop` entries at this launcher (absolute) |
| `omarchy-webapps list` | List web apps the browser has registered (Taskbar Tabs backends) |
| `omarchy-webapps hypr-rules` | Print Hyprland window rules for per-app web app windows |
| `omarchy-webapps chrome-css install\|remove` | Install/remove the chrome-less styling for Gecko Taskbar Tabs |
| `omarchy-webapps path-shim install\|remove\|status` | Make packaged Omarchy callers that use the bare command name reach this launcher |
| `omarchy-webapps version` | Print the version |

Configuration lives in `~/.config/omarchy-webapps/config` (KEY=value):

| Key | Purpose |
|-----|---------|
| `browser=<name>.desktop` | Force a browser instead of the XDG default |
| `backend=<backend>` | Force `chromium-app` / `gecko-taskbartab` / `plain-window` |
| `launch_prefix=<cmd>` | Override the launch wrapper (default: `uwsm-app` if present) |

## Backends

| backend | command shape | notes |
|---------|---------------|-------|
| `chromium-app` | `<bin> --app=<url>` | what Omarchy ships |
| `gecko-taskbartab` | `<bin> -taskbar-tab <id> -new-window <url> -profile <p> -container 0` | Firefox Taskbar Tabs |
| `plain-window` | `<bin> --new-window <url>` | honest fallback |

Browser family mapping:

- **Chromium family** (`chromium-app`): chromium, chrome, brave, edge, vivaldi, opera, helium
- **Gecko family** (`gecko-taskbartab`, or `plain-window` without Taskbar Tabs): zen, firefox, librewolf, waterfox, floorp, mullvad

`gecko-taskbartab` reuses your normal profile — the same cookies, logins and
extensions as ordinary browsing — and gives each web app its own Wayland
`app_id`, so the compositor can style every one individually. See below.

## Browser support

Only **Zen** and **Chromium** are installed and tested on this machine
(2026-08-25). Firefox, LibreWolf, Waterfox, Floorp, Brave, Edge, Vivaldi and Opera
are supported *by code path only* and have **never been run**. The code is
expected to work, but treat those as untested.

## Gecko setup

For a Gecko browser (Zen, Firefox, …) to use Taskbar Tabs:

1. Add to `<profile>/user.js`:
   ```js
   user_pref("browser.taskbarTabs.enabled", true);
   ```
2. Restart the browser.

Optionally remove the web app chrome for a clean app look:

```bash
omarchy-webapps chrome-css install
```

This needs `toolkit.legacyUserProfileCustomizations.stylesheets=true` set in the
same `user.js`.

## Hyprland

Each web app gets its own Wayland `app_id`, `zen.webapp-<uuid>`, so it can be
styled individually without matching the whole browser. `omarchy-webapps
hypr-rules` prints:

```js
-- Web app windows get their own Wayland app_id: zen.webapp-<uuid>.
-- Put this in a file required AFTER any file that sets opacity by tag, since the
-- last matching rule wins for a given property.

o.window("^(zen\\.webapp-)", {
  border_size = 0,
  no_shadow = true,
  opacity = "1 1",
})
```

The ordering caveat matters: Hyprland takes the **last** matching rule per
property. If an earlier file sets opacity by tag, this rule must load after it or
the tag-based opacity wins. Note `class:zen` rules do **not** match web app
windows.

## The PATH trap

`~/.local/bin` does not reliably shadow Omarchy's bin:

| context | first on PATH | wins |
|---------|---------------|------|
| interactive shell | `~/bin` / `~/.local/bin` | the override |
| Hyprland keybindings | `~/bin` | the override |
| systemd user env / quickshell / `uwsm-app` | `/usr/share/omarchy/bin` | **the packaged script** |

There are three kinds of caller, and each needs a different answer.

**1. `.desktop` entries — solved by `relink`.** A bare
`Exec=omarchy-launch-webapp` can resolve to the packaged script, so `relink`
rewrites every web app entry to an **absolute path**. It is idempotent, and
backs originals up to `~/.local/state/omarchy-webapps/relink/`.

**2. Omarchy's protocol handlers — solved by `relink` too.** Handlers like
`omarchy-webapp-handler-zoom` call `omarchy-launch-webapp` by bare name
*internally*, so `relink` generates a thin wrapper that only prepends this
project's `bin` to PATH and delegates — upstream handler logic stays intact.
Wrappers are generated into `~/.local/state/omarchy-webapps/bin/`, never into the
checkout. A handler Omarchy does not ship (one you wrote yourself) has nothing to
wrap, so `relink` reports it and leaves it alone.

**3. Packaged callers you do not control — solved by `path-shim`.** Omarchy's
menu (`omarchy-menu.jsonc`) hard-codes bare `omarchy-launch-webapp` for its
"Learn" entries, and runs under the systemd/quickshell PATH. There is no
`.desktop` file to rewrite. `omarchy-webapps path-shim install` fixes this
properly:

```bash
omarchy-webapps path-shim install
```

It creates a directory containing **exactly one symlink**
(`omarchy-launch-webapp`) and prepends that directory to the graphical session
PATH via `~/.config/environment.d/60-omarchy-webapps.conf`. Shadowing one command
rather than reordering `/usr/share/omarchy/bin` wholesale is deliberate: putting
`~/bin` first would silently change which `omarchy-audio-output-switch` — and
every other Omarchy command — you get. New graphical sessions pick it up
automatically; already-running processes keep the PATH they started with, so
Hyprland keybindings change only after the next login. `path-shim remove` undoes
it.

## How it works

- Taskbar Tabs registry: `<profile>/taskbartabs/taskbartabs.json`, entries keyed
  by `scopes[].hostname`.
- **Host lookup** is what keeps a web app stable. Passing a Taskbar Tab `id` the
  browser does not already know makes it mint a brand new web app — new uuid,
  new `.desktop`, fresh icon fetch — on **every** launch. The launcher looks the
  host up first and reuses the existing tab.
- On a web app's first launch the browser writes its own `.desktop` entry; a
  small background watcher marks it `NoDisplay=true` so it does not duplicate the
  launcher entry that called us. Hiding rather than deleting keeps the
  `app_id` → icon mapping working.

## Tests

```bash
./tests/test.sh
```

Pure-bash, builds a disposable tree under `mktemp -d`, touches nothing real.

## Uninstall

```bash
./uninstall.sh
```

Removes the installed symlinks. Web app `.desktop` entries keep pointing at the
repo after that, so restore them from the newest backup under
`~/.local/state/omarchy-webapps/relink/` to get the original Omarchy behaviour
back.

## Licence

MIT — see [LICENSE](./LICENSE). © 2026 Zheng Zexi.