# cli-openai-proxy requirement: support `type: "config"` items

**Sender**: Collavre (plan42) / Agent Gateway integration

**Recipient**: cli-openai-proxy

**Baseline**: cli-openai-proxy `main` after provision-sync, Collavre `feat/agent-gateway-integration`

**Status**: implementation request defining the v1 scope

---

## 1. Background

Collavre provisions two items for every AI Agent workspace.

| Item | Contents | Current status |
| --- | --- | --- |
| `skill: collavre` | Collavre CLI skill (`SKILL.md`, `scripts/collavre`, `references/`) | **Working** — approval, install, upgrade, and deletion verified by browser E2E |
| `config: collavre` | Workspace-specific `config.json` containing the Collavre base URL and callback token | **Unsupported** — the proxy reports `unsupported` |

Installing only `skill: collavre` provides the CLI executable but does not tell it which Collavre instance or credential to use. The script reads `{ url, token }` from `~/.config/collavre/config.json` (`skills/collavre/scripts/collavre:11-16`). A `config` provisioning item is the only channel that places this workspace-specific file, so provisioning is incomplete without this type.

This request adds one item type while preserving the proxy's existing design principles: the manifest never selects paths, installation only places files, and artifacts are never executed.

---

## 2. Collavre's published contract

The public manifest is served from `GET /agents/:agent_id/workspaces/:token/provision.json` with a rate limit of 60 requests per minute:

```json
{
  "schema": "agent-provisioning/v1",
  "items": [
    { "type": "skill",  "name": "collavre", "url": "https://<app-host>/agents/provision/skill/<sha256>.tar.gz", "sha256": "…" },
    { "type": "config", "name": "collavre", "url": "https://<app-host>/agents/provision/config/<agent>/<token>/<sha256>.tar.gz", "sha256": "…" }
  ]
}
```

The config `.tar.gz` contains exactly one file:

```text
config.json   (mode 0600, uid/gid 0, mtime 0, approximately 150 bytes)
```

```json
{
  "url": "https://collavre.example.com",
  "token": "<Doorkeeper access token — public scope, non-expiring, rotatable>"
}
```

- The tarball is deterministic: entries are sorted and mtime, uid, and gid are zero. Identical contents therefore produce the same SHA-256; token rotation changes the digest.
- Artifacts are served from the manifest host, satisfying the default host policy without `PROVISION_ALLOWLIST`.
- Artifact URLs include the digest. Collavre returns 404 when the requested digest does not match the current bytes, so each URL is valid only for its manifest revision.
- Config artifacts use `Cache-Control: private, no-store`; skill artifacts use immutable caching.

---

## 3. Requirements

### R1 (MUST): support `type: "config"`

Add `config` to `SUPPORTED_PROVISION_TYPES` (`src/provision/types.ts:47`). Status responses must preserve `type: "config"`; the Collavre UI renders the `skill:collavre` and `config:collavre` rows by type.

**Acceptance**: syncing the manifest in section 2 reports the config item as `pending_approval` in the default mode or `installed` in auto mode, rather than `unsupported`.

### R2 (MUST): install to `{CONFIG_ROOT}/{name}`

- `CONFIG_ROOT` defaults to `$HOME/.config` and can be overridden with `PROVISION_CONFIG_DIR`.
- `name` uses the skill name pattern (`[a-z0-9][a-z0-9_-]{0,63}`) and remains one directory segment. Reuse the existing path policy.
- The resulting path for `config: collavre` is `~/.config/collavre/config.json`.

Do not use `XDG_CONFIG_HOME` for v1. The bundled CLI currently reads the fixed `os.homedir()/.config` path (`skills/collavre/scripts/collavre:11`). If both sides should adopt XDG semantics instead, the CLI must be changed first.

The item name is intentionally the same as the skill name. Type is part of the ownership and approval key, so `skill:collavre` and `config:collavre` must remain isolated.

**Acceptance**: `~/.config/collavre/config.json` exists after installation and matches the artifact. `PROVISION_CONFIG_DIR` moves the installation under its configured root. Names containing `../`, `/`, or uppercase characters return `invalid_item`.

### R3 (MUST): worker scoping is a prerequisite

The config item contains a workspace-specific credential. Installing it under the gateway process's HOME while `/v1/provision/*` is excluded from worker forwarding (`src/server/index.ts:201-207`) causes both functional and security failures:

- User A's callback token is installed under the gateway HOME.
- A per-user worker cannot see the file.
- Engines running as the gateway user can see another workspace's token.

Worker-scoped provisioning must therefore ship before or together with the config type. Do not deploy the config type alone.

Required behavior:

- Forward `/v1/provision/*` by signed identity, like `/v1/auth/*`.
- Resolve `PROVISION_CONFIG_DIR`, `PROVISION_SKILLS_DIR`, and `PROVISION_STATE_DIR` from the worker HOME.
- Register a worker auth session's `provisioning_url` inside that worker instead of replacing the gateway-global manifest (`src/provision/sync.ts:755-763`).

**Acceptance**: two workspaces authenticated with different identity headers each receive their own `config.json` under their own HOME and cannot see the other's token.

### R4 (MUST): enforce 0700 directories and 0600 files

Config files contain credentials. The final config directory must be owner-only mode 0700 and `config.json` must be mode 0600. Enforce these modes even when an archive contains more permissive modes.

**Acceptance**: `stat` reports `drwx------` for `collavre/` and `-rw-------` for `config.json`.

### R5 (MUST): prevent secret disclosure

The current status view exposes only an item's SHA-256, not its artifact URL (`itemSourceView`, `src/provision/sync.ts:98-110`), and installer errors do not include response bodies or URLs. Lock this behavior with explicit regression tests because the config URL contains a manifest token and the file contains a callback token.

- `GET /v1/provision` must not contain artifact URLs or file contents anywhere in its JSON.
- `last_error`, item `error`, and server logs must not contain artifact URLs or bodies; an HTTP status code is sufficient.

### R6 (MUST): do not cache and refetch the manifest on every sync

- Config artifacts use `Cache-Control: private, no-store`, and artifact bytes must not remain outside staging.
- Each sync must fetch the manifest first and use only URLs from that revision. Reusing a previous URL fails with 404 after token rotation.

**Acceptance**: rotating a token and syncing installs the new digest successfully, including on retry paths, without reusing a stale URL.

### R7 (MUST): preserve content-hash idempotency

Do not reinstall unchanged contents. A changed SHA-256, caused by token rotation or a base URL change, upgrades the item without additional approval because approval remains name-scoped.

**Acceptance**: an unchanged sync preserves mtime. After Collavre runs `rotate_tokens!`, the next sync replaces the token in `config.json` without another approval.

### R8 (MUST): replace atomically

Use the skill installer's stage-and-rename behavior. A CLI process must see either the complete old JSON or the complete new JSON; a failed upgrade leaves the old config untouched.

**Acceptance**: reading `config.json` at any point during replacement always returns valid old or new JSON, never a partial file or empty directory.

### R9 (MUST): preserve user-owned files on removal

When the manifest removes the item or an administrator calls `DELETE /v1/provision/items/config/collavre`, remove only files recorded by the lockfile. Remove the directory only when it is empty. User-created files under `~/.config/collavre/` must remain.

### R10 (SHOULD): track config ownership at file granularity

Applying the skill rule “Refusing to replace untracked directory” directly to config will often fail because one manual CLI run creates `~/.config/collavre/` (`skills/collavre/scripts/collavre:27-30`).

Requested behavior:

- An existing directory alone is not a conflict. Adopt the directory without claiming ownership so removal does not delete it.
- Refuse to overwrite an untracked target file with `Refusing to replace untracked file "config.json"`.
- Provide an administrator recovery path, such as `POST /v1/provision/items/config/collavre/approve` with `{ "adopt": true }`, to transfer a manual config into proxy ownership.

If file-level ownership is too large for v1, a clear failure plus an explicit adopt mechanism is the minimum acceptable alternative. A fail-closed state with no recovery path is not sufficient.

### R11 (SHOULD): reuse skill TOFU semantics

The first `(config, collavre)` item is `pending_approval`. Upgrades after approval are automatic. DELETE revokes approval. `PROVISION_AUTOAPPLY=auto` installs immediately. The Collavre UI already implements this state machine.

### R12 (MUST): reuse archive validation

Apply the skill limits and checks: 1 MiB per file, 10 MiB total and decompression bounds, traversal rejection, symbolic and hard link rejection, non-regular file rejection, binary rejection, and no execution during install.

The pipe-download-into-shell text scan in `installer.ts:82` exists because skills are prompt-loaded instructions. It is optional for config payloads. Keeping it is harmless for Collavre's JSON; excluding it is semantically reasonable.

---

## 4. Related behavior found during E2E

The DELETE response differs from `docs/provisioning.md`. The document says an item still present in the manifest returns immediately as `pending_approval`, but the actual DELETE response omits the item until the next sync. Collavre can only display `not_synced` in this interval. Please align either the implementation with the document or the document with the implementation so the UI can follow one contract.

---

## 5. Joint acceptance scenario

1. Start a worker-mode proxy with `PROVISION_SYNC=1`. Collavre logs workspace A in with signed identity headers and a `provisioning_url`.
2. `GET /v1/provision` reports both `skill:collavre` and `config:collavre` as `pending_approval`.
3. Approve both. Worker A's HOME contains `~/.claude/skills/collavre/` and `~/.config/collavre/config.json` with mode 0600.
4. Run the Collavre CLI in worker A and verify it calls the Collavre API with the config URL and token.
5. Repeat for workspace B. Worker B's HOME contains only B's token and cannot see A's token.
6. Rotate the token in Collavre and sync. The config updates without another approval and the CLI still succeeds.
7. Create `~/.config/collavre/notes.txt` manually, then call `DELETE /v1/provision/items/config/collavre`. Only `config.json` is removed; `notes.txt` and the directory remain.
8. Remove the config item from the manifest and sync. Its status becomes `removed`.

---

## 6. Open questions for the proxy team

1. Do you agree with `{CONFIG_ROOT}/{name}`, `PROVISION_CONFIG_DIR`, and ignoring `XDG_CONFIG_HOME` for v1?
2. Are identical names under different types (`skill:collavre` and `config:collavre`) isolated safely in lockfile and approval keys?
3. Should R10 use file-level ownership, or a failure plus an adopt flag?
4. Can worker scoping and config support ship in one release? If releases must be separate, prevent config installation until worker scoping is active.
5. Should the R12 pipe-download text scan apply to config items?

---

## 7. Collavre readiness

- Manifest and artifact endpoints, deterministic tar generation, SHA-256 verification, token rotation, and status/approval UI are implemented on `feat/agent-gateway-integration`.
- The current proxy reports config as `unsupported` while continuing to install the skill; browser E2E confirms incremental deployment is safe.
- Collavre now publishes the config item as `config:collavre`, matching the requested installation path.
