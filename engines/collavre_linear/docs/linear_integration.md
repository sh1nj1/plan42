# Linear Integration Setup Guide

Complete guide for the `collavre_linear` engine: bidirectional sync between
Collavre Creatives and Linear issues, including OAuth authentication, webhook
provisioning, the field-mapping contract, and the conflict policy.

## Overview

The `collavre_linear` engine provides:

- **OAuth authentication** with Linear (per-user `Account` with encrypted tokens)
- **Project/subtree linking** — a `ProjectLink` binds a Creative subtree root to a
  Linear team/project; every Creative inside that subtree syncs to a Linear issue
- **Outbound sync** — creating/updating/moving/destroying a linked Creative pushes
  the change to Linear (`issueCreate` / `issueUpdate` / `issueArchive`)
- **Inbound webhooks** — HMAC-signed Linear webhooks apply issue/comment changes
  back to local Creatives
- **Echo suppression** — our own events are dropped on the way back in so the loop
  is closed and echo-free

### Sync loop (closed, echo-free)

```
Collavre Creative change
     │  (CreativeSyncObserver after_commit, unless skip_linear_sync)
     ▼
OutboundSyncJob → CreativeExporter → Client.issueCreate/issueUpdate
     │
     ▼                                        Linear
     └────────────────────────────────────────┘
                                              │  webhook (HMAC-signed)
                                              ▼
                            WebhooksController  ── EchoGuard.our_event? ──▶ 200 ack, DROP
                                              │       (actor.id == app_actor_id)
                                              ▼ (human actor)
                            InboundApplyJob → InboundApplier
                                              │  sets creative.skip_linear_sync = true
                                              ▼  → NO re-export echo
                                        Creative updated
```

## Setup

### 1. Create the Linear OAuth application

In Linear: **Settings → API → OAuth applications → Create new**.

- **Redirect URI**: must match `LINEAR_OAUTH_REDIRECT_URI` (the host's
  `/linear/auth/callback` — the engine is mounted at `/linear`).
- **Scopes requested** by the engine (`OAuthTokenService::OAUTH_SCOPES`):
  `read,write,issues:create,comments:create`.
- Note the **Client ID** and **Client secret**.

### 2. Environment variables

Defined in `env.template` / `.kamal/secrets` / `config/deploy.yml`:

| Variable | Purpose |
|---|---|
| `LINEAR_CLIENT_ID` | OAuth application client id |
| `LINEAR_CLIENT_SECRET` | OAuth application client secret |
| `LINEAR_WEBHOOK_SECRET` | Fallback HMAC secret used to verify inbound webhooks when no per-`ProjectLink` secret matches |
| `LINEAR_OAUTH_REDIRECT_URI` | OAuth callback URL (`https://<host>/linear/auth/callback`) |

When `Collavre::IntegrationSettings::Resolver` defines `linear_webhook_secret` /
`linear_api_endpoint`, those take precedence over the ENV values.

### 3. Webhook

- **URL**: `POST https://<host>/linear/webhook` (machine-to-machine, no user
  session, CSRF disabled).
- **Resource types** provisioned (`WebhookProvisioner::RESOURCE_TYPES`):
  `Issue`, `Project`, `Comment`.
- **Security pipeline** (all before any work is enqueued):
  1. Verify `Linear-Signature` = `HMAC-SHA256(webhook_secret, raw_body)` with a
     constant-time compare — bad/missing → `401`.
  2. Verify `webhookTimestamp` is within ±60s of now (replay protection) → `401`
     if stale.
  3. `EchoGuard.our_event?(account, payload)` — if the webhook `actor.id` equals
     the account's stored `app_actor_id`, ack `200` but enqueue nothing.

## Field mapping

Handled by the pure (no-I/O) `FieldMapper`. Native fields use **Last-Writer-Wins
(LWW)**; structured Linear metadata is stored under `creative.data["linear"]`.

| Linear field | Collavre target | Direction | Notes |
|---|---|---|---|
| `title` | `creative.description` (title derived via `creative_snippet`) | ↔ | LWW; Creative has no title column |
| `description` | `creative.description` | ↔ | LWW |
| `priority` (0–4) | **`creative.sequence`** | ↔ | Intentional bidirectional. Inbound: `sequence = (priority == 0 ? 5 : priority)`. Outbound: `sequence 1–4 → priority 1–4`, `5`/nil/out-of-range → priority `0` (None). Lossy edge: within-bucket dense ordering is not representable in Linear's 5-value enum |
| `state` | `creative.data["linear"]["state"]` | ↔ | not a native Creative field |
| `labels` | `creative.data["linear"]["labels"]` | ↔ | from `labels.nodes` inbound |
| `assignee` | `creative.data["linear"]["assignee"]` | ↔ | stored under `data["linear"]` |
| — (Creative `progress`) | — | **not synced** | `FieldMapper` never reads or writes `progress` |
| comments | `Collavre::Comment` ↔ `CommentLink` | ↔ | inbound comments created with `skip_dispatch: true` |
| issue archive/remove | `creative.data["linear"]["archived"] = true` | inbound | **no destroy, no reparent of children** (decision B6) |

## Conflict policy

- **Baseline**: LWW on native fields.
- **Field lock**: status/priority/labels are treated as governed fields; the
  applier compares the remote `updatedAt` (falling back to `webhookTimestamp`)
  against the link's `remote_updated_at`.
- **Conflict trigger**: the local `IssueLink` is `dirty` (has un-synced local
  edits) **and** the remote payload is strictly newer than `remote_updated_at`.
  - When `remote_updated_at` is `nil` there is no baseline → the apply proceeds
    (no spurious conflict).
- **On conflict**: the link is flipped to the `conflict` state, the remote field
  apply is **skipped** (no data loss / no overwrite of local edits), and a system
  comment is posted to the Creative's Main topic explaining the collision. Auto
  sync halts until the conflict is resolved and re-synced.

## Echo suppression (loop guard)

Two guards keep the loop echo-free:

1. **Primary (inbound)** — `EchoGuard.our_event?(account, payload)` compares the
   webhook `actor.id` against `account.app_actor_id`; our own bounced-back events
   are acked and dropped before any job is enqueued.
2. **Inbound-apply guard** — every Creative mutated by `InboundApplier` gets
   `creative.skip_linear_sync = true` before save, so the `CreativeSyncObserver`
   `after_commit` does not re-export the inbound change back to Linear.
3. **Secondary** — `EchoGuard.record_outbound(link)` stamps `last_outbound_at`
   after each outbound push (timestamp-window guard for the brief period before
   `app_actor_id` is populated).

## Tests

- `test/integration/round_trip_test.rb` — keystone proof the loop is closed and
  echo-free: (a) outbound create → `issueCreate`, (b) our-own-actor webhook →
  no-op, (c) human webhook → Creative updated with no re-export.
- Per-component tests live under `test/services`, `test/jobs`, `test/controllers`,
  `test/observers`.
