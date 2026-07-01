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
  `read,write,issues:create,comments:create`. `admin` is intentionally NOT
  requested: Linear rejects it for app actors ("App users can't request admin
  scopes") and we authorize with `actor: "app"`. `admin` would only be needed to
  auto-create webhooks via the API; instead the inbound webhook is set up
  **manually** (see the Webhook section) — the integration modal shows a
  one-time setup guide after linking.
- Note the **Client ID** and **Client secret**.

### 2. Environment variables

Defined in `env.template` / `.kamal/secrets` / `config/deploy.yml`:

| Variable | Purpose |
|---|---|
| `LINEAR_CLIENT_ID` | OAuth application client id |
| `LINEAR_CLIENT_SECRET` | OAuth application client secret |
| `LINEAR_OAUTH_REDIRECT_URI` | OAuth callback URL (`https://<host>/linear/auth/callback`) |

When `Collavre::IntegrationSettings::Resolver` defines `linear_api_endpoint`,
that takes precedence over the ENV value.

The webhook signing secret is **not** an env/admin setting: it is generated per
`ProjectLink` when a Creative is linked (shared across a team's links) and can be
rolled from the modal's **Regenerate secret** button. Inbound deliveries verify
only against that stored secret — there is no fallback.

### 3. Webhook (manual, one-time)

Because we don't hold the `admin` scope, the webhook is **not** auto-provisioned.
After linking a Creative to a Linear project, the integration modal shows a
one-time setup guide. A Linear workspace admin creates the webhook by hand:

1. Open **linear.app/settings/api → Webhooks → New webhook**.
2. **URL**: `https://<host>/linear/webhook`.
3. **Signing secret**: the per-`ProjectLink` secret shown in the modal (the only
   secret inbound verification accepts; use **Regenerate secret** to roll it).
4. **Events**: `Issue`, `Project`, `Comment` (`WebhookProvisioner::RESOURCE_TYPES`).

Webhook mechanics:

- **URL**: `POST https://<host>/linear/webhook` (machine-to-machine, no user
  session, CSRF disabled).
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
| `assignee` | `creative.data["linear"]["assignee"]` | inbound | Linear → Collavre only; `FieldMapper` does not send `assignee_id` outbound (needs cross-system user-identity mapping — follow-up) |
| — (Creative `progress`) | — | **not synced** | `FieldMapper` never reads or writes `progress` |
| comments | `Collavre::Comment` ↔ `CommentLink` | ↔ | Outbound: a human, non-private, non-placeholder Main-topic comment on a linked creative is pushed via `CommentSyncObserver` → `OutboundCommentSyncJob`/`OutboundCommentUpdateJob`/`OutboundCommentDeleteJob` → `Client#create_comment`/`#update_comment`/`#delete_comment` (create/edit/delete all propagate). Inbound comments created with `skip_dispatch: true`; inbound edits/removals set `skip_linear_sync` to avoid echo. See Known limitations for what outbound omits |
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

## Known limitations

- **Outbound comment sync covers human Main-topic chat only.** A local comment
  is pushed to Linear (`CommentSyncObserver` → `OutboundCommentSyncJob` /
  `OutboundCommentUpdateJob` / `OutboundCommentDeleteJob`) only when it is in the
  creative's **Main topic**, posted by a **human** (`user.ai_user?` excluded),
  **non-private**, and not the streaming `"..."` placeholder, on a creative that
  already has an `IssueLink`. **Create, edit, and delete all propagate**: edits
  fire on `after_update_commit` when `content` changed and a `CommentLink` exists
  (`Client#update_comment`); deletes fire on `after_destroy_commit`, keyed on the
  `CommentLink` id since the comment row is already gone (`Client#delete_comment`,
  then the link is torn down). Inbound-originated edits/removals set
  `skip_linear_sync` so they do not echo back out (an edit would otherwise re-wrap
  the author-name prefix into itself). Deliberate omissions, each a planned
  follow-up:
  - **AI agent turns are not synced.** An agent comment is created as a `"..."`
    placeholder and mutated in place as tokens stream, so an after-create hook
    would post `"..."` and never settle; a token-settled hook is the follow-up.
  - **Non-Main topics are not synced.** A Linear issue has one flat comment list,
    so only the Main topic mirrors out to avoid cross-posting every side thread.
  - A comment posted **before** the creative is linked is not back-filled.

- **Pure sibling drag/drop reorders do not push to Linear.** Priority maps to
  `Creative#sequence`, but `Collavre::Creatives::Reorderer#resequence!` persists
  new sequence values with `update_column`, which bypasses the `after_save`
  callback the outbound observer relies on — so a reorder that changes only order
  (no parent change) does not enqueue an `OutboundSyncJob`, and Linear priority
  stays stale until the next normal save. The clean fix needs a vendor-neutral
  post-resequence hook in core `Reorderer` (mirroring the reserved-metadata-key
  registry seam) that the engine observer can subscribe to; this is a follow-up
  rather than an engine-local change, since core must not reference the engine.

- **Moving a linked Creative under a *newly-created* in-subtree parent can race.**
  If the child's outbound update runs before the new parent's create, the update
  sends no `parentId` and advances the content hash, so the Linear issue stays
  under its old parent until a manual re-sync. Child *creates* already defer via
  `ParentNotExportedError`; the update path needs the same deferral. Follow-up.

## Tests

- `test/integration/round_trip_test.rb` — keystone proof the loop is closed and
  echo-free: (a) outbound create → `issueCreate`, (b) our-own-actor webhook →
  no-op, (c) human webhook → Creative updated with no re-export.
- Per-component tests live under `test/services`, `test/jobs`, `test/controllers`,
  `test/observers`.
