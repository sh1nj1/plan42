# Collavre Desktop (macOS, Tauri)

Package Collavre as a locally-installed macOS app that runs the **server +
SQLite database together** in one bundle. Double-click → the bundled Rails
server boots on SQLite with local-disk Active Storage, and the UI shows in a
native webview. No external services.

"Open to the network or not" is a single setting, not two products: the sidecar
binds `127.0.0.1` by default (closed); set `COLLAVRE_BIND_HOST=0.0.0.0` to open
it to the LAN/Tailscale. Binding alone is not enough — Rails rejects any request
whose `Host` header is not loopback, so for open mode you must **also** pass the
externally reachable host(s) via `COLLAVRE_ALLOWED_HOSTS` (comma-separated),
otherwise remote clients get a 403 from HostAuthorization even though Puma is
listening. Example:

```
COLLAVRE_BIND_HOST=0.0.0.0 COLLAVRE_ALLOWED_HOSTS=192.168.1.42,xxx.tailadceed.ts.net bin/desktop-server
```

A **Finder-launched `.app` inherits an empty environment**, so those env vars
can't reach it that way. For the installed app, put the same settings in
`~/Library/Application Support/net.collavre.desktop/Collavre/config.json` — the
Tauri shell reads it on launch and exports the recognized keys into the
sidecar's environment **only when they aren't already set**, so an explicit env
var still wins. The file is parsed as strict JSON (no comments or trailing
commas):

```json
{
  "allowed_hosts": ["xxx.tailadceed.ts.net"],
  "bind_host": "0.0.0.0",
  "port": 4000
}
```

- `allowed_hosts` — a JSON array, or a `"a,b"` comma-separated string.
- `bind_host` — omit to stay on loopback (`127.0.0.1`); set `"0.0.0.0"` to open.
- `port` — omit for an ephemeral port.

A missing or malformed file is the normal closed-loopback case and is ignored
(the app never fails to launch over a bad config).

## Layout

```
tools/desktop-app/
  README.md
  src-tauri/                 # Tauri (Rust) shell
    Cargo.toml
    tauri.conf.json
    build.rs
    src/{main,lib}.rs        # free port → spawn sidecar → health-gate /up → webview
    capabilities/default.json
    dist/index.html          # placeholder (real UI is the server-rendered app)
  scripts/
    provision-secrets.rb     # first-run SECRET_KEY_BASE (stable; keys derive from it)
    bundle-ruby.sh           # vendor portable Ruby + app gems
    build-macos.sh           # stage app + precompile assets + tauri build
```

The `desktop` **Rails** environment lives in the app tree, not here, because
Rails must load it:

- `config/environments/desktop.rb` — inherits production; disables SSL forcing,
  forces `:local` Active Storage, logs under the data dir.
- `config/database.yml` (`desktop:`) — production's 4-DB SQLite layout, relocated
  under `COLLAVRE_DATA_DIR`.
- `config/{cable,cache,queue,recurring}.yml` (`desktop:`) — reuse production Solid.
- `bin/desktop-server` — the sidecar launcher (provision secret → `db:prepare` →
  Puma with Solid Queue in-process).

## Data location

All mutable state lives under the OS app-data dir (the `.app` is read-only):

```
~/Library/Application Support/net.collavre.desktop/Collavre/
  desktop-{primary,cache,queue,cable}.sqlite3
  storage/            # Active Storage blobs
  credentials/secret_key_base
  config.json         # optional: open-mode settings for a Finder-launched .app
  log/desktop.log
```

## Run without packaging (verified)

The whole desktop env runs from a dev checkout — no Tauri, no vendored Ruby:

```bash
PORT=4000 bin/desktop-server
# → boots RAILS_ENV=desktop on SQLite, /up returns 200, no https redirect
```

This is the de-risk step and is verified working end-to-end.

## Build the .app (follow-up — heavy)

```bash
brew install ruby-build vips node
cargo install tauri-cli --version '^2'
tools/desktop-app/scripts/build-macos.sh
# → "src-tauri/target/release/bundle/macos/Collavre Desktop.app"
```

The build runs `npm ci` before `assets:precompile` because jsbundling-rails
drives esbuild from `node_modules` — Node.js is a build prerequisite.

The app icon is generated during the build from `public/icon-*.png` (the app's
own brand icon) into the git-ignored `src-tauri/icons/` — nothing to prepare.

First launch: right-click → **Open** (the build is unsigned; Gatekeeper).

## Known follow-ups (out of v1 scope)

- **libvips bundling** — the fiddliest native dep; if it slips, disable image
  variants in the `desktop` env.
- **OAuth** — client secrets can't ship in a distributed binary; desktop v1 uses
  password auth (PKCE/loopback OAuth later).
- **Signing / notarization / .dmg / auto-update** — deferred.
- **Windows / Linux** — deferred (the Rust shell and Rails env are already
  cross-platform; packaging scripts are macOS-only for now).
- **Relocatable Ruby** — the vendored Ruby is happiest when the app lives at a
  stable path (`/Applications/Collavre Desktop.app`).
