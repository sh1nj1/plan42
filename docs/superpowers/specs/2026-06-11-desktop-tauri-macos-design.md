# Collavre Desktop (Tauri, macOS) — Design

Date: 2026-06-11
Status: Draft (awaiting approval)
Worktree: `plan42-worktree221` / branch `feat/desktop-tauri-macos`

## Goal

Ship Collavre as a locally-installed macOS desktop app that runs the **server +
database together** in one bundle. The user double-clicks the app; it boots the
bundled Rails server backed by SQLite and local-disk Active Storage, then shows
the UI in a native webview. No external services required.

"Open externally or not" (CEO's A vs B) is a single bind/setting, not two
products: default bind `127.0.0.1` (closed); a toggle binds `0.0.0.0` (open to
LAN/Tailscale).

First deliverable: **locally-runnable `.app` on Apple Silicon**. Code signing,
notarization, `.dmg`, auto-update, and Windows/Linux are explicit follow-ups.

## Why the stack fits (verified against plan42)

- DB is files: `database.yml` selects `sqlite3` whenever `DATABASE_URL` is unset
  — primary/cache/queue/cable all have sqlite branches. No DB server process.
- No Redis: `solid_queue` + `solid_cache` + `solid_cable`. Jobs run in-process
  (Solid Queue in Puma), so **one process = the whole app**.
- UI is server-rendered (Hotwire/Turbo/ViewComponent) → a webview pointed at
  `localhost:<port>` is sufficient; no separate JS app to host.
- Active Storage `:local` Disk service is already wired and auto-selected when
  no S3 credentials are present.

## Architecture

Two units with one clear interface (HTTP over loopback):

### 1. Tauri shell (Rust)
- Minimal window using the OS webview. No custom frontend.
- On launch: choose a free ephemeral port, spawn the Rails **sidecar**
  (`externalBin`), poll `GET /up` until healthy, then load
  `http://127.0.0.1:<port>`.
- On quit: graceful shutdown of the sidecar (SIGTERM, then SIGKILL fallback).
- Owns: window lifecycle, port selection, health-gating, process supervision.

### 2. Rails sidecar (bundled Ruby + app)
- Runs in a new **`desktop` Rails environment** that inherits production
  behavior (Solid stack, eager load, asset serving) but overrides for loopback:
  - `force_ssl = false`, `assume_ssl = false` (production hardcodes these `true`;
    they would redirect the http webview to https and break it).
  - adapter = sqlite3, Active Storage = `:local`.
  - bind host from env (default `127.0.0.1`, toggle `0.0.0.0`).
- Boots via the vendored Ruby, not the dev machine's rbenv.

### Data & first-run provisioning
- All mutable state lives under `~/Library/Application Support/Collavre/`
  (the `.app` bundle is read-only / signed and cannot hold the DB):
  - `storage/*.sqlite3` (primary, cache, queue, cable)
  - `storage/` Active Storage blobs
  - `credentials/` — generated `SECRET_KEY_BASE` + Active Record encryption
    keys, created on first run and persisted (boot needs `SECRET_KEY_BASE` or
    `RAILS_MASTER_KEY`).
- First run: provision secrets → `db:prepare` (create + migrate) → seed minimal
  bootstrap if needed.
- `RAILS_ROOT` stays in the bundle (read-only code); `storage`/DB paths are
  redirected to app-support via env (`DATABASE` paths + Active Storage root).

## Packaging (Ruby runtime)

Chosen: **vendored portable Ruby + standalone bundle**, copied into
`.app/Contents/Resources`. Battle-tested and debuggable; native gems compiled
for arm64. (Tebako single-binary is the elegant alternative but carries higher
risk with Rails runtime paths / asset pipeline — deferred.)

- Relocatable arm64 Ruby 3.4.4 prefix (ruby-build into a fixed prefix, or
  traveling-ruby-style).
- `bundle install --standalone` so the app loads gems without a system Bundler.
- Native gems requiring care: `sqlite3`, `bcrypt`, `nokogiri`, `ffi`,
  `image_processing` → **libvips** binary must be bundled (or image variants
  disabled in desktop v1).
- **Gemfile fix**: `sqlite3` is currently `groups: [:development, :test]`; the
  desktop bundle must include it in the desktop/production group.

## Known risks / deferrals

- **libvips bundling** is the fiddliest native dep. v1 fallback: disable image
  variant processing in `desktop` env if bundling slips.
- **OAuth client secrets** (Google/GitHub/Notion) can't be safely embedded in a
  distributed binary. Desktop v1 uses password auth; OAuth via PKCE/loopback is
  a follow-up.
- **Code signing / notarization** deferred — v1 runs locally (right-click-open
  to bypass Gatekeeper for our own testing).
- Bundle size ~150–200MB.

## De-risk implementation order

1. **Headless boot** — add `desktop` env; boot Rails with sqlite + local storage
   + no SSL + generated secret, data under app-support. Confirm the full app
   works at `http://127.0.0.1:<port>`. No Tauri yet. ← validates everything.
2. **Vendored Ruby boot** — vendor portable arm64 Ruby + standalone bundle; boot
   the same with vendored Ruby instead of rbenv.
3. **Tauri shell** — spawn sidecar, health-gate `/up`, webview, graceful quit.
4. **Package `.app`** — sidecar + Ruby + libvips in Resources; run by
   double-click from `/Applications`.
5. **Follow-ups** — codesign + notarize + `.dmg`; auto-update; CI matrix;
   Windows/Linux.

## Out of scope (v1)

Cloud sync, multi-device merge/CRDT, OAuth, signing/notarization, auto-update,
Windows/Linux builds, App Store distribution.
