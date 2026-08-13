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
- `port` — omit to use the stable default, `4000`.

A missing or malformed file is the normal closed-loopback case and is ignored
(the app never fails to launch over a bad config).

## Port policy

The desktop shell uses `http://127.0.0.1:4000` when no valid `PORT` setting is
provided. This origin is deliberately stable so local firewall rules and future
PKCE/loopback OAuth callback registrations can target one URL. A valid `PORT`
environment variable or `config.json` `port` value is an explicit override; an
OAuth client using one must register that alternate callback URL.

The shell never silently falls back to an ephemeral port when the selected port
is occupied. Starting on a different port would appear to work while breaking
registered callbacks and firewall rules. Port-collision recovery is a separate
user-facing concern and must preserve an explicitly configured, registered
origin.

## Layout

```
tools/desktop-app/
  README.md
  src-tauri/                 # Tauri (Rust) shell
    Cargo.toml
    tauri.conf.json
    build.rs
    src/{main,lib}.rs        # stable port → spawn sidecar → health-gate /up → webview
    capabilities/default.json
    dist/index.html          # placeholder (real UI is the server-rendered app)
  scripts/
    provision-secrets.rb     # first-run SECRET_KEY_BASE (stable; keys derive from it)
    bundle-ruby.sh           # vendor portable Ruby + app gems
    bundle-proxy.sh          # bundle a pinned npm proxy + private Node runtime
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
  proxy/config.json   # public proxy port + bundled version; never credentials
  log/desktop.log
  log/desktop-proxy.log
```

## cli-openai-proxy

The desktop release embeds one Apple-Silicon Node runtime and one exact
published `cli-openai-proxy` version. It does not use Homebrew, a global npm
install, or the user's `node` binary at runtime.

For a reproducible release build, supply the official archive and its checksum:

```bash
CLI_OPENAI_PROXY_VERSION=0.1.0
NODE_RUNTIME_URL=https://nodejs.org/dist/v<node-version>/node-v<node-version>-darwin-arm64.tar.xz
NODE_RUNTIME_SHA256=<official-node-sha256>
tools/desktop-app/scripts/build-macos.sh
```

`bundle-proxy.sh` downloads the official Node archive only over HTTPS, verifies
its supplied SHA-256, requires a Darwin ARM64 runtime, then resolves and locks
the exact npm package before `npm ci` installs it. The generated lockfile keeps
the resolved tarball integrity values inside the signed application bundle.

For a local DMG build, no Node runtime environment variables are required. The
script downloads and verifies its pinned official Apple-Silicon Node archive
(`v22.13.0`). Set `NODE_RUNTIME_DIR` only for a pre-verified expanded official
archive, or set both `NODE_RUNTIME_URL` and `NODE_RUNTIME_SHA256` to use a
different verified official archive.

Tauri exposes internal setup commands for the first-run wizard:

- `desktop_proxy_status` returns installation/process status and the public
  port/version only. It never returns either secret.
- `desktop_proxy_complete_setup` detects executable availability for Claude
  Code/Codex without running either CLI, then sends Keychain-held proxy secrets
  directly to a short-lived, loopback-only Rails registration endpoint. It
  registers the local Gateway and creates presets only for detected adapters.

The setup UI calls `desktop_proxy_complete_setup` only after explicit consent
and a locally created or signed-in administrator account. On later launches, a
registered proxy is restarted automatically and the normal Collavre home opens.
The proxy keeps the user's `HOME` and an executable-only PATH so existing
Claude/Codex logins remain usable, but its own mutable provision state stays
under the Collavre app-data directory. No existing provider credential or
configuration is read, displayed, or sent externally.

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

This is a local development build. Use the release script below for a signed
and notarized distribution build.

## Publish a desktop release

`script/release-desktop.sh` is the single operator entry point. The canonical
version is `src-tauri/tauri.conf.json`; the script keeps Cargo's manifest and
lockfile package versions in sync, proposes a semantic bump from all bundled
source commits, then requires an explicit version that advances the current
version and final confirmation before creating the version commit.

It runs the desktop Rust and Rails test suites, creates the Apple-Silicon DMG,
checks its code signature, submits and staples it with Apple notarization,
writes a SHA-256 checksum, and only then creates a GitHub Release. The Git tag
format is `desktop-v<semver>` and release notes are generated from bundled
source commits since the preceding desktop tag. If publication fails after the
version commit, rerun `script/release-desktop.sh --resume <version>` from that clean
release checkout; it safely rebases an unpushed release commit onto current
`origin/main` before rebuilding.

Run it only from a clean, current `main` checkout on an Apple-Silicon Mac:

```bash
export APPLE_SIGNING_IDENTITY='Developer ID Application: Example, Inc. (TEAMID)'
export APPLE_ID='releases@example.com'
export APPLE_APP_SPECIFIC_PASSWORD='xxxx-xxxx-xxxx-xxxx'
export APPLE_TEAM_ID='TEAMID'
script/release-desktop.sh
```

The release script defaults to a pinned, verified official Apple-Silicon Node
archive. To use a different runtime archive, set both `NODE_RUNTIME_URL` and
`NODE_RUNTIME_SHA256` before running it.

The Apple signing identity and App Store app-specific password must be stored
only in the protected release environment or the release operator's keychain;
they are never committed. The GitHub CLI must already be authenticated with
permission to push `main`, tags, and releases.

## Known follow-ups (out of v1 scope)

- **libvips bundling** — the fiddliest native dep; if it slips, disable image
  variants in the `desktop` env.
- **OAuth** — client secrets can't ship in a distributed binary; desktop v1 uses
  password auth (PKCE/loopback OAuth later).
- **Auto-update** — deferred.
- **Windows / Linux** — deferred (the Rust shell and Rails env are already
  cross-platform; packaging scripts are macOS-only for now).
- **Relocatable Ruby** — the vendored Ruby is happiest when the app lives at a
  stable path (`/Applications/Collavre Desktop.app`).
