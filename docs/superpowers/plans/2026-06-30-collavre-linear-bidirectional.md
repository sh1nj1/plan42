# Collavre ⇄ Linear Bidirectional Integration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a new `collavre_linear` Rails engine that keeps a Collavre Creative subtree and a Linear Project/Issue tree in continuous two-way sync — authoring/edits in Collavre propagate out to Linear, and Linear changes propagate back into Collavre.

**Architecture:** A standalone engine (depends only on `collavre` core), modeled on the proven patterns from `collavre_github` (inbound webhooks, OAuth account, link model, `IntegrationRegistry`/`IntegrationSettings`, HMAC verify, row-lock idempotency) and `collavre_notion` (outbound exporter, background jobs, `to_prepare` association injection, SHA-256 dirty tracking). The two reference engines are each *one-directional*; this engine fuses them and adds the four net-new pieces neither has: (1) **auto-trigger outbound on Creative change**, (2) **OAuth `actor=app` + refresh-token lifecycle**, (3) **bidirectional echo-loop suppression**, (4) **a sync state machine with conflict resolution**.

**Tech Stack:** Ruby on Rails 8 engine, Linear GraphQL API (`https://api.linear.app/graphql`), OAuth 2.0 (`actor=app`), `graphql-client` or raw `Net::HTTP` + GraphQL strings, `OpenSSL::HMAC` (SHA-256) for webhook verification, ActiveJob for outbound queueing, `ActiveRecord.encrypts` for token-at-rest, Minitest + WebMock for tests.

## Global Constraints

- Engine dependency direction is one-way: `collavre_linear` depends on `collavre` core **only**. Core must never reference `CollavreLinear::*`. (Use `to_prepare` to inject associations into `Collavre::Creative` / `User`; never edit those classes.)
- i18n: every user-facing string in `config/locales/en.yml` **and** `config/locales/ko.yml`. No bare strings.
- All commit messages in **English**, Conventional Commits (`feat:`, `fix:`, `test:`, `docs:`). PR description in **English**.
- Migrations live inside the engine (`engines/collavre_linear/db/migrate/`), registered via the engine's `paths["db/migrate"]` initializer.
- New env vars must be added to: `.kamal/secrets`, `env.template`, `.env.*`, and `config/deploy.yml`. Env vars: `LINEAR_CLIENT_ID`, `LINEAR_CLIENT_SECRET`, `LINEAR_WEBHOOK_SECRET` (fallback), `LINEAR_OAUTH_REDIRECT_URI`.
- Secrets resolution order is **DB (`Collavre::IntegrationSettings::Resolver`) > ENV > `Rails.application.credentials`** — same as `collavre_github`. Register keys with `Collavre::IntegrationSettings::Registry`.
- Rubocop must pass (pre-push hook). Tests run via host app `rake test`; engine tests under `engines/collavre_linear/test/`.
- Do all work in a dedicated git worktree (`../plan42-worktree{N}`), per repo rules. Squash-merge; delete worktree after merge.
- No PC-specific hostnames (e.g. `*.tailadceed.ts.net`) in any PR/commit/webhook config committed to git.
- Token attribution: authorize with `actor=app` so our writes are attributed to the integration, enabling echo suppression by `actor.id`.

---

## Part A — Gap Analysis: what a *complete* bidirectional engine needs beyond the two reference engines

This is the answer to "추가로 필요한 것을 판단" — the components that **neither** `collavre_github` nor `collavre_notion` provides and must be built net-new:

| # | Capability | github | notion | Why it's new for Linear |
|---|-----------|:------:|:------:|-------------------------|
| 1 | **Auto-trigger outbound on Creative lifecycle** | ❌ | ❌ (manual UI button only) | Notion only exports when a user clicks "Export". True sync requires `after_commit` on Creative create/update/move/destroy → enqueue outbound job. Net-new: a Creative observer subscribed via `to_prepare`. |
| 2 | **OAuth `actor=app` + refresh-token lifecycle** | partial | ❌ (`refresh_token!` is a stub) | Linear access tokens expire in **24h** and *do* issue refresh tokens. Need real refresh-before-expiry + 401-retry. Net-new vs both. |
| 3 | **Structured inbound: Linear entity → Creative CRUD** | ❌ (webhooks only make feed comments / sync md files) | ❌ (no inbound at all) | github never creates/updates a *Creative* from a webhook; it posts comments or syncs files. We must map `Issue/Project/Comment` create/update/remove → create/update/archive the linked Creative. Net-new. |
| 4 | **Echo-loop suppression (both directions)** | scope-validation only | n/a | Must (a) tag/record our own outbound writes and (b) drop inbound webhooks whose `actor.id` == our app. github relies on event-type isolation; that's insufficient when the same entity round-trips. Net-new combination. |
| 5 | **Sync state machine + conflict resolution** | ❌ | SHA-256 hash only | Two writers (Collavre user + Linear user) can edit the same entity concurrently. Need per-link sync state (`synced/dirty/syncing/conflict`), a `local_version`/`remote_updated_at` pair, and a documented policy (last-write-wins by timestamp, field-level for status). Net-new. |
| 6 | **GraphQL client** | ❌ (Octokit/REST) | ❌ (Notion REST) | Linear is GraphQL-only. Need a thin client wrapping mutations (`issueCreate`, `issueUpdate`, `projectCreate`, `commentCreate`) + queries, with complexity-aware error handling. Net-new. |
| 7 | **Field/value mapping layer** | n/a | text-only | Linear `state`/`priority`/`assignee`/`labels` ↔ Collavre `progress`/metadata/comments. Need an explicit, tested mapper (e.g. progress 100% ↔ a "Done"-type workflow state). Net-new. |
| 8 | **Webhook replay protection** | ❌ | n/a | Linear requires `webhookTimestamp` within ±60s. github does HMAC but no timestamp window. Net-new check. |
| 9 | **Team/Project topology handling** | repo is flat | flat | Issues are single-team (`teamId` required); Projects span teams (`teamIds[]`). The link model and "where do I create this" logic must capture a target `team_id` + optional `project_id`. Net-new. |

**Reused as-is (no new design needed):** engine skeleton & gemspec; `to_prepare` association injection; `IntegrationRegistry.register` + `creative_menu_partial`; `IntegrationSettings::Registry/Resolver` secret resolution; OAuth callback→account-save→setup-wizard flow; `ActiveRecord.encrypts` token storage; HMAC verify with `secure_compare`; `with_lock` row-level idempotency on inbound; WebMock test harness with stub helpers; per-link `webhook_secret` auto-generation.

---

## Part B — Architecture decisions to lock before coding (review gate)

These should be confirmed (ideally via `/plan-eng-review`) before Task 1, because they shape the schema:

1. **Mapping granularity.** `Creative subtree` ↔ `Linear Project` at the root, child Creatives ↔ `Issues`, grandchildren ↔ `sub-issues` (`parentId`), Creative comments ↔ Issue `comments`. Depth beyond Linear's ~10 levels flattens to sub-issues of the deepest mapped issue.
2. **Source of truth per field.** Default **last-write-wins by timestamp** (`updatedFrom` on inbound, `updated_at` on outbound). Title/description = LWW. Status/priority/labels = field-locked to whichever side changed last (never merged). Document in `docs/linear_integration.md`.

   **Field mapping (decided 2026-06-30 — schema-verified: `creative.data` is `jsonb`/`json` `default {}` `null:false`, GIN-indexed on PG; `schema.rb:228`):**
   | Linear field | Collavre storage | Direction & notes |
   |---|---|---|
   | `title` | `creative.title` | LWW both ways |
   | `description` | `creative.description` | LWW both ways (markdown-canonical) |
   | `state` (workflow status) | `creative.data["linear"]["state"]` | **NOT** `progress`. `progress` is auto-derived from children and **cannot be written on linked creatives** (`creative.rb:299-303`) — storing state in `data` decouples the two. Tradeoff: Linear "Done" does **not** roll into Collavre progress; accepted. |
   | `priority` (0–4) | `creative.sequence` (closure_tree sibling order) | **Intentional (정순오, 2026-07-01):** Linear priority *is* Collavre sort order, bidirectional. Inbound: `sequence = priority==0 ? 5 : priority` (Urgent first, None last). Outbound: sibling rank → nearest priority bucket. See ✅ below. |
   | `labels` | `creative.data["linear"]["labels"]` (array of `{id,name}`) | LWW; stored as metadata, mirror Linear label ids. |
   | `assignee` | `creative.data["linear"]["assignee"]` | Display-only mirror (Collavre has no 1:1 assignee model); inbound-informational. |

   ✅ **`priority ↔ sequence` — DECIDED intentional (정순오, 2026-07-01).** Linear `priority` maps to Collavre's sibling **sort order** (`sequence`), bidirectionally, by design: high-priority issues sort first among siblings, and reordering siblings in Collavre re-prioritizes in Linear. `Collavre::Creative` declares `has_closure_tree order: :sequence` (`creative.rb:29`; `schema.rb:233`, `integer default 0 null:false`), so `sequence` **is** the live sibling-order field — that overlap is the intent, not a collision to avoid.
   - **Inbound (Linear → Collavre):** `sequence = (priority == 0 ? 5 : priority)` — Urgent(1) sorts first … Low(4) … None(0) sinks to 5/last. Ties (many issues share a priority) are allowed; closure_tree breaks ties by id. Write **through closure_tree's reorder path, not a raw `update_column`**, so the tree stays consistent (bare inserts otherwise append `max+1`).
   - **Outbound (Collavre → Linear):** push priority **only on explicit sibling-reorder events** (not on insert-driven renumbering, to avoid spurious priority churn); map the linked Creative's new rank among its linked siblings to the nearest priority bucket (1–4; unranked → 0/None).
   - **Accepted lossy edge (documented, not a bug):** `priority` is a 5-value enum while `sequence` is a dense total order, so *within-bucket* ordering is **not** representable in Linear `priority`. (Linear's own within-priority manual order is a separate `sortOrder` float that this mapping intentionally does not touch — if lossless ordering is ever wanted, `sortOrder` is the future seam.) Document in `docs/linear_integration.md`.

   🔒 **`data["linear"]` must survive `update_metadata` — via a vendor-neutral registry, not a hardcoded key.** `update_metadata` (`creatives_controller.rb:410`) rebuilds `data` from the client payload and re-injects **only** `%w[markdown_source content_type editor]` from the existing record — **every other `data` key the client omits is dropped**. Storing Linear sync state under `data["linear"]` without protection means any client metadata edit (context config, trigger toggle, etc.) silently wipes the mapping. **Do NOT hardcode `"linear"` in core** (violates vendor-neutral core — memory `collavre_core_vendor_neutral`). Instead: add a **core** extension point `Collavre::Creative.reserved_metadata_keys` (returns the base `%w[markdown_source content_type editor]` plus any keys registered by engines), and have `update_metadata` preserve all of them. The `collavre_linear` engine registers `"linear"` via `to_prepare` at boot. This is a hard correctness requirement — a new **Task 2b** (core reserved-keys registry) precedes storing anything in `data`.
3. **Conflict outcome.** On detected concurrent edit (both `local_dirty` and a newer `remote_updated_at`), mark link `conflict`, post a system comment to the Creative's Main topic, and **stop auto-sync for that link** until a human resolves (no silent data loss). Mirrors the memory lesson on data-corruption-only fixes.
4. **Echo identity.** Store our integration's Linear `actor.id` (the OAuth app/application actor id, captured at install) on the `LinearAccount`. Inbound drops any event where `actor.id == account.app_actor_id`.
5. **Outbound trigger scope.** Only Creatives within a subtree that has a `LinearProjectLink` at/above them trigger outbound (ancestor lookup, like github's `creative.ancestors` scope check). Avoids syncing the whole workspace.
6. **Archive vs delete.** Linear `remove` action → Collavre Creative **archive/soft-delete** decision (Collavre delete reparents children — see memory `collavre_delete_reparents`); choose archive-marker to avoid destructive reparenting from a webhook.

---

## Part C — File structure

```
engines/collavre_linear/
├── collavre_linear.gemspec                 # deps: rails >=8, collavre
├── lib/collavre_linear.rb
├── lib/collavre_linear/version.rb
├── lib/collavre_linear/engine.rb           # initializers: routes, migrations, registry, associations, creative-observer
├── config/routes.rb                        # webhook, oauth callback, setup wizard, per-creative link/unlink/resync
├── config/initializers/integration_settings.rb
├── config/locales/{en,ko}.yml
├── db/migrate/
│   ├── XXXXXX_create_linear_accounts.rb
│   ├── XXXXXX_create_linear_project_links.rb
│   ├── XXXXXX_create_linear_issue_links.rb
│   └── XXXXXX_create_linear_comment_links.rb
├── app/models/collavre_linear/
│   ├── application_record.rb
│   ├── account.rb                          # OAuth token + refresh + app_actor_id
│   ├── project_link.rb                     # Creative(root) ↔ Linear project + team_id + webhook_secret + sync_state
│   ├── issue_link.rb                        # Creative ↔ Linear issue (+ parent_issue_id, local_version, remote_updated_at, sync_state)
│   └── comment_link.rb                      # Collavre comment ↔ Linear comment id
├── app/services/collavre_linear/
│   ├── client.rb                            # GraphQL wrapper (mutations + queries)
│   ├── oauth_token_service.rb              # exchange / refresh / revoke
│   ├── webhook_provisioner.rb             # webhookCreate/Update via API
│   ├── field_mapper.rb                     # progress↔state, priority, labels, assignee
│   ├── creative_exporter.rb               # Creative(subtree) → GraphQL mutations (outbound)
│   ├── inbound_applier.rb                 # webhook payload → Creative CRUD (inbound)
│   └── echo_guard.rb                       # records our writes; tests inbound actor
├── app/jobs/collavre_linear/
│   ├── outbound_sync_job.rb               # enqueued by observer; calls creative_exporter
│   └── inbound_apply_job.rb               # enqueued by webhook; calls inbound_applier
├── app/observers/collavre_linear/
│   └── creative_sync_observer.rb          # after_commit hooks (wired in engine.rb to_prepare)
├── app/controllers/collavre_linear/
│   ├── application_controller.rb
│   ├── auth_controller.rb                  # OAuth callback + setup wizard
│   ├── webhooks_controller.rb             # HMAC + timestamp verify → enqueue inbound_apply_job
│   └── creatives/integrations_controller.rb # link/unlink/resync
├── app/views/collavre_linear/
│   ├── auth/setup.html.erb
│   └── integrations/_modal.html.erb
└── test/
    ├── test_helper.rb                      # WebMock + stub helpers (GraphQL + OAuth + webhook)
    ├── services/collavre_linear/{client,field_mapper,creative_exporter,inbound_applier,echo_guard,oauth_token_service}_test.rb
    ├── controllers/collavre_linear/{webhooks_controller,auth_controller,integrations_controller}_test.rb
    ├── jobs/collavre_linear/{outbound_sync_job,inbound_apply_job}_test.rb
    └── integration/round_trip_test.rb      # Collavre edit → Linear → webhook back → no echo
```

---

## Part D — Task plan

Each task ends in an independently testable, committable deliverable. TDD: write the failing test, watch it fail, implement, watch it pass, commit. Run engine tests with:
`cd ~/project/soonoh/plan42 && bin/rails test engines/collavre_linear/test/...` (from host app root, mise-activated shell — see memory `plan42_mise_prepush_env`).

### Task 0: Worktree + engine skeleton

**Files:**
- Create: `engines/collavre_linear/collavre_linear.gemspec`, `lib/collavre_linear.rb`, `lib/collavre_linear/version.rb`, `lib/collavre_linear/engine.rb`, `config/routes.rb`, `test/test_helper.rb`
- Modify: host `Gemfile` (add `gem "collavre_linear", path: "engines/collavre_linear"`), host `config/routes.rb` (mount), `config/application.rb` if engines are auto-required.

**Interfaces:**
- Produces: `CollavreLinear::Engine`, `CollavreLinear::VERSION`, mounted at `/linear`.

- [ ] **Step 1:** Create worktree: `git worktree add ../plan42-worktree9 -b feat/collavre-linear` (pick free N).
- [ ] **Step 2:** Copy `collavre_notion` skeleton files (gemspec, `lib/`, `engine.rb`) as a starting template; rename `Notion`→`Linear`, `notion`→`linear`. Set `VERSION = "0.1.0"`.
- [ ] **Step 3:** In `engine.rb`, add the four standard initializers (routes mount, `paths["db/migrate"]` append, `IntegrationRegistry.register(:linear, …)`, `to_prepare` association injection) — copy the exact shape from `engines/collavre_github/lib/collavre_github/engine.rb`. Registry entry:
```ruby
Collavre::IntegrationRegistry.register(:linear, {
  label: I18n.t("collavre_linear.integration.label", default: "Linear"),
  icon: "linear",
  description: I18n.t("collavre_linear.integration.description", default: "Two-way sync of projects, issues and comments"),
  routes: CollavreLinear::Engine.routes.url_helpers,
  creative_menu_partial: "collavre_linear/integrations/modal"
})
```
- [ ] **Step 4:** Write a smoke test `test/engine_loads_test.rb` asserting `CollavreLinear::Engine` is defined and `Collavre::IntegrationRegistry.find(:linear)` returns the entry. Run → fails (not wired). Wire until pass.
- [ ] **Step 5:** Add `en.yml`/`ko.yml` with the `integration.label`/`description` keys (both languages). Commit: `feat: scaffold collavre_linear engine`.

### Task 1: LinearAccount model + token-at-rest

**Files:** Create `app/models/collavre_linear/account.rb`, `application_record.rb`, `db/migrate/XXXXXX_create_linear_accounts.rb`, `test/models/collavre_linear/account_test.rb`.

**Interfaces:**
- Produces: `CollavreLinear::Account` with `belongs_to :user`, encrypted `access_token`/`refresh_token`, columns `linear_uid` (unique), `app_actor_id`, `token_expires_at`, `workspace_id`, `workspace_name`.

- [ ] **Step 1:** Write failing test: creating an Account encrypts the token (raw DB column != plaintext) and enforces unique `linear_uid`.
```ruby
test "encrypts access_token and enforces unique linear_uid" do
  a = CollavreLinear::Account.create!(user: @user, linear_uid: "u1", access_token: "secret-token")
  raw = CollavreLinear::Account.connection.select_value(
    "SELECT access_token FROM linear_accounts WHERE id = #{a.id}")
  refute_equal "secret-token", raw
  assert_raises(ActiveRecord::RecordNotUnique) do
    CollavreLinear::Account.create!(user: @other_user, linear_uid: "u1", access_token: "x")
  end
end
```
- [ ] **Step 2:** Run → fail (no table/model). 
- [ ] **Step 3:** Write migration (table `linear_accounts`: `user_id` FK unique index, `linear_uid` unique, `app_actor_id`, `access_token`, `refresh_token`, `token_expires_at`, `workspace_id`, `workspace_name`, timestamps). Write model with `encrypts :access_token, :refresh_token` and `token_expired?`/`token_expiring_soon?(within: 5.minutes)` helpers.
- [ ] **Step 4:** Run migration into dummy/test DB, run test → pass.
- [ ] **Step 5:** Commit: `feat: add LinearAccount with encrypted tokens`.

### Task 2: Link models (project / issue / comment) with sync state

**Files:** Create `project_link.rb`, `issue_link.rb`, `comment_link.rb` + 3 migrations + model tests.

**Interfaces:**
- `ProjectLink`: `belongs_to :creative` (root), `belongs_to :account`; columns `linear_project_id`, `team_id`, `webhook_secret` (auto-gen `SecureRandom.hex(20)`), `sync_state` (enum: `synced/dirty/syncing/conflict`, default `synced`), `last_synced_at`. Unique `(creative_id, linear_project_id)`.
- `IssueLink`: `belongs_to :creative`, `belongs_to :project_link`; columns `linear_issue_id`, `parent_issue_id` (nullable), `local_version` (int, default 0), `remote_updated_at` (datetime), `content_hash` (string), `sync_state`. Unique `(creative_id)` and unique `(linear_issue_id)`.
- `CommentLink`: maps a Collavre comment id ↔ `linear_comment_id`.

- [ ] **Step 1:** Failing test: `IssueLink` requires a `project_link`, auto-fills nothing else; `ProjectLink#webhook_secret` auto-generates on validation; `sync_state` enum rejects unknown values.
- [ ] **Step 2:** Run → fail.
- [ ] **Step 3:** Write 3 migrations + 3 models (`before_validation :ensure_webhook_secret` on ProjectLink; enum `sync_state`). Add `scope :auto_syncable, -> { where(sync_state: %i[synced dirty]) }`.
- [ ] **Step 4:** Run → pass.
- [ ] **Step 5:** Wire associations into core via `to_prepare` in `engine.rb` (`Creative.has_many :linear_issue_links`, `:linear_project_links`; `User.has_one :linear_account`). Add a test asserting `creative.linear_issue_links` reflection exists.
- [ ] **Step 6:** Commit: `feat: add Linear link models with sync state`.

### Task 2b: Core reserved-metadata-keys registry (vendor-neutral seam)

**Why:** Linear sync state lives in `creative.data["linear"]`, but `update_metadata` (`creatives_controller.rb:410`) drops any `data` key not in `%w[markdown_source content_type editor]`. Core must let engines protect their own namespaces **without** naming them in core (memory `collavre_core_vendor_neutral`). This is the only core edit in the whole plan; keep it minimal and generic.

**Files:** Modify (core) `engines/collavre/app/models/collavre/creative.rb` (add class-level registry), `engines/collavre/app/controllers/collavre/creatives_controller.rb:410` (use the registry). Add core test.

**Interfaces:**
- Produces: `Collavre::Creative.reserved_metadata_keys` → frozen base array `%w[markdown_source content_type editor]` merged with `Collavre::Creative.registered_reserved_metadata_keys` (a mutable set engines append to via `register_reserved_metadata_key(key)`).

- [ ] **Step 1:** Failing **core** test: `Collavre::Creative.register_reserved_metadata_key("x")` makes `reserved_metadata_keys` include `"x"`; `update_metadata` preserves an existing `data["x"]` across a client payload that omits it. (Test lives in core, uses no engine names beyond a dummy `"x"`.)
- [ ] **Step 2:** Run → fail.
- [ ] **Step 3:** Add the registry (class attribute + registrar) to `Creative`; rewrite the `creatives_controller.rb:410` loop to iterate `Collavre::Creative.reserved_metadata_keys`. Keep the three built-ins as the default.
- [ ] **Step 4:** Run core test + existing metadata tests → green (no regression).
- [ ] **Step 5:** In `collavre_linear` `engine.rb` `to_prepare`, call `Collavre::Creative.register_reserved_metadata_key("linear")`. Add an engine test asserting `"linear"` is protected. Commit (core): `feat: add reserved-metadata-key registry for engine metadata`; commit (engine) with Task 2 or separately.

### Task 3: GraphQL client wrapper

**Files:** Create `app/services/collavre_linear/client.rb`, `test/services/collavre_linear/client_test.rb`.

**Interfaces:**
- Consumes: `CollavreLinear::Account` (for bearer token), `IntegrationSettings::Resolver` for endpoint override.
- Produces: `Client.new(account)` with methods `create_issue(team_id:, title:, description:, parent_id: nil, project_id: nil, state_id: nil, assignee_id: nil, label_ids: [], priority: nil)`, `update_issue(id, **fields)`, `create_project(name:, team_ids:)`, `update_project(id, **fields)`, `create_comment(issue_id:, body:)`, `viewer_and_app_actor` (returns `{user_id:, app_actor_id:, organization_id:}`), `register_webhook(url:, secret:, team_id:, resource_types:)`. Each returns a parsed hash; raises `CollavreLinear::Client::Error` on GraphQL `errors`.

- [ ] **Step 1:** Failing test using WebMock stub of `POST https://api.linear.app/graphql` returning a canned `issueCreate` payload; assert `create_issue` returns the new issue id and sends `Authorization: Bearer <token>` + the `issueCreate` mutation in the request body.
```ruby
test "create_issue posts issueCreate mutation and returns id" do
  stub_request(:post, "https://api.linear.app/graphql")
    .with(headers: { "Authorization" => "Bearer tok" })
    .to_return(status: 200, body: {
      data: { issueCreate: { success: true, issue: { id: "iss-1", identifier: "ENG-1" } } }
    }.to_json, headers: { "Content-Type" => "application/json" })
  res = CollavreLinear::Client.new(@account).create_issue(team_id: "t1", title: "Hi")
  assert_equal "iss-1", res[:id]
  assert_requested :post, "https://api.linear.app/graphql",
    body: /issueCreate/, times: 1
end
```
- [ ] **Step 2:** Run → fail.
- [ ] **Step 3:** Implement `Client` with `Net::HTTP` POST, JSON `{query:, variables:}`; mutation string constants (`ISSUE_CREATE`, `ISSUE_UPDATE`, `PROJECT_CREATE`, `PROJECT_UPDATE`, `COMMENT_CREATE`, `WEBHOOK_CREATE`, `VIEWER`); raise on `body["errors"]`; endpoint resolved via `Resolver.get(:linear_api_endpoint) || "https://api.linear.app/graphql"`. **Confirm each `*Input` field name against the Apollo schema reference before finalizing** (per research note — schema is source of truth).
- [ ] **Step 4:** Run → pass. Add a test for the GraphQL-`errors` path raising `Client::Error`.
- [ ] **Step 5:** Commit: `feat: add Linear GraphQL client`.

### Task 4: OAuth token service (exchange + refresh + actor=app)

**Files:** Create `oauth_token_service.rb` + test; `auth_controller.rb` + test; `config/initializers/integration_settings.rb`.

**Interfaces:**
- Produces: `OAuthTokenService.authorize_url(state:, creative_id:)` (includes `actor=app`, scopes `read,write,issues:create,comments:create`), `.exchange(code)` → `{access_token, refresh_token, expires_in}`, `.refresh(account)` (refreshes if `token_expiring_soon?`, persists, returns account). `AuthController#callback` creates/updates `Account`, captures `app_actor_id` via `Client#viewer_and_app_actor`.

- [ ] **Step 1:** Failing test: `authorize_url` contains `actor=app`, the registered scopes, `client_id`, `redirect_uri`, and the `state`.
- [ ] **Step 2:** Run → fail.
- [ ] **Step 3:** Implement service reading `LINEAR_CLIENT_ID/SECRET/REDIRECT_URI` via Resolver→ENV→credentials. `exchange` POSTs to `https://api.linear.app/oauth/token`; `refresh` uses `grant_type=refresh_token`. Register settings keys (`linear_webhook_secret` sensitive, `linear_api_endpoint`).
- [ ] **Step 4:** Failing test for `refresh`: account near expiry + stubbed token endpoint → new token persisted, `token_expires_at` advanced. Implement → pass.
- [ ] **Step 5:** Failing controller test: `GET /linear/auth/callback?code=...` with stubbed exchange + `viewer` query creates an `Account` with `app_actor_id` set. Implement `AuthController#callback` + `#setup` wizard (copy github's session `creative_id` pattern). → pass.
- [ ] **Step 6:** Add env vars to `.kamal/secrets`, `env.template`, `.env.*`, `config/deploy.yml`. Commit: `feat: add Linear OAuth with actor=app and refresh`.

### Task 5: Field mapper (progress ↔ state, priority, labels)

**Files:** Create `field_mapper.rb` + test.

**Interfaces:**
- Produces: `FieldMapper.creative_to_issue_attrs(creative)` → `{title:, description:, priority:, state_id:?, label_ids:?}` — reads `state`/`labels` from `creative.data["linear"]` and **`priority` from `creative.sequence`** (rank→bucket, per the `priority ↔ sequence` decision); `FieldMapper.issue_to_creative_attrs(issue_payload)` → `{title:, description:, sequence:, data_linear: {state:, labels:, assignee:}}` where **`sequence = priority==0 ? 5 : priority`** and state/labels merge into `creative.data["linear"]`. **No `progress` read/write** (decision B2: `progress` is auto-derived and unwritable on linked creatives — `creative.rb:299-303`).

- [ ] **Step 1:** Failing test: outbound — a Creative with `sequence = 2` maps to `priority: 2`. Inbound — an issue payload with `priority: 1` yields `sequence: 1`, `priority: 0` yields `sequence: 5`, and `state`/`labels` produce the nested `data_linear` hash; `progress` untouched.
- [ ] **Step 2:** Run → fail.
- [ ] **Step 3:** Implement mapper. `priority ↔ sequence` per the decision (inbound `priority==0 ? 5 : priority`; outbound rank→nearest bucket); keep `state`/`labels` field-locked (decision B2/B3) — only translate, never merge. Pure functions, no I/O (workflow-state catalogue passed in for any name↔id resolution). **Note:** the mapper only *computes* the sequence value; the applier (Task 10) must **write it via closure_tree's reorder path**, not a raw column update.
- [ ] **Step 4:** Run → pass. Commit: `feat: add Linear field mapper`.

### Task 6: Echo guard

**Files:** Create `echo_guard.rb` + test.

**Interfaces:**
- Produces: `EchoGuard.record_outbound(link, linear_id)` (stamps `link.last_outbound_at`/marks an in-flight token), and `EchoGuard.our_event?(account, payload)` → true when `payload.dig("actor","id") == account.app_actor_id`. Inbound applier calls `our_event?` and drops matches.

- [ ] **Step 1:** Failing test: a webhook payload whose `actor.id` equals `account.app_actor_id` → `our_event?` true; a different actor → false.
- [ ] **Step 2:** Run → fail.
- [ ] **Step 3:** Implement. (Primary suppression = actor id; `last_outbound_at` window is a secondary guard for the brief gap before `app_actor_id` is known.)
- [ ] **Step 4:** Run → pass. Commit: `feat: add Linear echo-loop guard`.

### Task 7: Creative exporter (outbound) + outbound job

**Files:** Create `creative_exporter.rb`, `app/jobs/collavre_linear/outbound_sync_job.rb` + tests.

**Interfaces:**
- Consumes: `Client`, `FieldMapper`, `EchoGuard`, link models.
- Produces: `CreativeExporter.new(creative).sync!` — resolves the governing `ProjectLink` (self-or-ancestor), creates-or-updates the `IssueLink` (create when no `linear_issue_id`, else `update_issue`), sets `parent_id` from the parent Creative's `IssueLink`, updates `content_hash`/`remote_updated_at`/`local_version`, marks `sync_state: :synced`, records echo token. `OutboundSyncJob.perform(creative_id)` loads + calls it; guarded by `with_lock` on the link.

- [ ] **Step 1:** Failing test: a Creative under a linked project, no IssueLink yet → `sync!` calls `client.create_issue` with mapped attrs and the parent's `linear_issue_id` as `parent_id`, then persists an `IssueLink` + `content_hash`. (Stub Client.)
- [ ] **Step 2:** Run → fail.
- [ ] **Step 3:** Implement exporter. Skip the API call when `content_hash` unchanged (dirty-tracking, copy notion's SHA-256 approach). On `Client::Error` raise so the job retries.
- [ ] **Step 4:** Failing test for update path (existing IssueLink + changed description → `update_issue`). Implement → pass.
- [ ] **Step 5:** Job test: `OutboundSyncJob.perform_later` enqueues; perform calls exporter; concurrent perform is serialized by `with_lock` (assert no double-create). Implement → pass.
- [ ] **Step 6:** Commit: `feat: add Linear outbound exporter and sync job`.

### Task 8: Creative observer → auto-trigger outbound (the net-new piece #1)

**Files:** Create `app/observers/collavre_linear/creative_sync_observer.rb`; wire in `engine.rb` `to_prepare`; test.

**Interfaces:**
- Produces: on `Creative` `after_commit` (create/update/destroy) **and** `after_save` on parent_id change, if the Creative is within a linked subtree → mark its `IssueLink` (or create a pending one) `sync_state: :dirty` and `OutboundSyncJob.perform_later(creative.id)`. Destroy → enqueue an archive/remove job. Move (parent_id change) → re-parent in Linear.

- [ ] **Step 1:** Failing test: updating a Creative under a linked project enqueues `OutboundSyncJob` once; updating an unlinked Creative enqueues nothing. Use `assert_enqueued_with`.
- [ ] **Step 2:** Run → fail.
- [ ] **Step 3:** Implement observer module with `after_commit`; wire via `to_prepare` (`Collavre::Creative.include CollavreLinear::CreativeSyncObserver` or `set_callback`). Guard against infinite loops: observer must **not** fire for changes applied by `InboundApplier` (use a thread-local / attribute flag `creative.skip_linear_sync`). 
- [ ] **Step 4:** Run → pass. Add a test that a Creative mutated with `skip_linear_sync = true` enqueues nothing (inbound suppression).
- [ ] **Step 5:** Commit: `feat: auto-trigger Linear outbound on Creative changes`.

### Task 9: Webhook controller (HMAC + timestamp) + inbound job

**Files:** Create `webhooks_controller.rb`, `app/jobs/collavre_linear/inbound_apply_job.rb` + tests; `config/routes.rb` `post "webhook"`.

**Interfaces:**
- Produces: `POST /linear/webhook` — reads raw body, verifies `Linear-Signature` HMAC-SHA256 (`secure_compare`), verifies `webhookTimestamp` within ±60s, drops `EchoGuard.our_event?`, then `InboundApplyJob.perform_later(raw_payload)` and `head :ok`. Bad signature → `:unauthorized`; stale timestamp → `:unauthorized`; bad JSON → `:bad_request`.

- [ ] **Step 1:** Failing test: valid signature + fresh timestamp + non-echo actor → `200` and `InboundApplyJob` enqueued. Wrong signature → `401`, no enqueue.
```ruby
test "valid webhook enqueues inbound job" do
  payload = { action: "update", type: "Issue", actor: { id: "human-1" },
              webhookTimestamp: (Time.now.to_f*1000).to_i, data: { id: "iss-1" },
              updatedFrom: { title: "old" } }.to_json
  sig = OpenSSL::HMAC.hexdigest("SHA256", @project_link.webhook_secret, payload)
  assert_enqueued_with(job: CollavreLinear::InboundApplyJob) do
    post "/linear/webhook", params: payload,
      headers: { "Content-Type" => "application/json", "Linear-Signature" => sig }
  end
  assert_response :ok
end
```
- [ ] **Step 2:** Run → fail.
- [ ] **Step 3:** Implement controller. `webhook_secret` resolution: `ProjectLink#webhook_secret` matched by payload org/team → fallback `Resolver.get(:linear_webhook_secret)` → ENV. Timestamp window ±60_000 ms.
- [ ] **Step 4:** Add timestamp-replay test (`webhookTimestamp` 5 min old → 401) and echo test (actor.id == app_actor_id → 200 but **no** enqueue). Implement → pass.
- [ ] **Step 5:** Commit: `feat: add Linear webhook controller with HMAC and replay protection`.

### Task 10: Inbound applier (Linear → Creative CRUD, the net-new piece #3)

**Files:** Create `inbound_applier.rb` + test.

**Interfaces:**
- Consumes: payload, `IssueLink`/`ProjectLink`/`CommentLink`, `FieldMapper`.
- Produces: `InboundApplier.new(payload).apply!` — resolves the link by `linear_issue_id`/`linear_project_id`; `create` → create child Creative under the mapped parent; `update` → update the linked Creative's description/progress **with `skip_linear_sync = true`** (prevents echo via observer); `remove` → archive marker (no destructive reparent, decision B6); comment events → append/update Collavre comment via `CommentLink`. Conflict: if local `sync_state == :dirty` and `payload` is newer → set `:conflict`, post system comment, skip apply.

- [ ] **Step 1:** Failing test: inbound `Issue.update` with new title applies to the linked Creative and sets `skip_linear_sync` so no outbound job is enqueued.
- [ ] **Step 2:** Run → fail.
- [ ] **Step 3:** Implement applier (create/update/remove/comment branches). Use `updatedFrom` to apply only changed fields. Wrap in `link.with_lock`.
- [ ] **Step 4:** Failing conflict test: link `dirty` + newer remote → `sync_state` becomes `conflict`, a system comment is posted, Creative unchanged. Implement → pass.
- [ ] **Step 5:** `InboundApplyJob` test: perform calls applier. Commit: `feat: apply Linear inbound events to Creatives`.

### Task 11: Webhook provisioner + integrations controller + modal UI

**Files:** Create `webhook_provisioner.rb`, `creatives/integrations_controller.rb`, `views/.../integrations/_modal.html.erb`, `auth/setup.html.erb` + tests; `config/routes.rb` resources.

**Interfaces:**
- Produces: `WebhookProvisioner.ensure_for(project_link:, webhook_url:)` (idempotent `webhookCreate` for the team, stores returned id); `IntegrationsController#create` (links a Creative subtree to a Linear team+project, provisions webhook, kicks an initial full export), `#destroy` (unlink + deregister), `#resync`.

- [ ] **Step 1:** Failing test: linking a Creative to a team provisions exactly one webhook (stub `webhookCreate`) and enqueues an initial `OutboundSyncJob` for the subtree root.
- [ ] **Step 2:** Run → fail.
- [ ] **Step 3:** Implement provisioner (idempotent: skip if a `ProjectLink` for the team already has a webhook id) + controller (permission check `creative.has_permission?(Current.user, :admin)`, like github).
- [ ] **Step 4:** Build the `_modal.html.erb` (connect button → OAuth, team/project picker) + `setup.html.erb` wizard. i18n both locales. Render test asserts the modal shows for an admin.
- [ ] **Step 5:** Commit: `feat: add Linear webhook provisioning and link/unlink UI`.

### Task 12: Round-trip integration test + docs

**Files:** Create `test/integration/round_trip_test.rb`; `docs/linear_integration.md`; update `docs/features_summary.md`.

- [ ] **Step 1:** Integration test: (a) create a Creative in a linked subtree → assert `issueCreate` called; (b) simulate Linear webhook echoing **our** actor.id → assert no Creative change, no job; (c) simulate webhook from a **human** actor updating the issue → assert Creative updated and **no** outbound job (skip_linear_sync). This proves the loop is closed and echo-free.
- [ ] **Step 2:** Run the full engine suite → green. Run host `rake test` for the engine path. Run Rubocop.
- [ ] **Step 3:** Write `docs/linear_integration.md` (setup: OAuth app creation, env vars, scopes, webhook URL; the mapping table; conflict policy from Part B). Add a one-liner to `docs/features_summary.md`.
- [ ] **Step 4:** Commit: `docs: document Linear integration and add round-trip test`.

### Task 13: Ship

- [ ] **Step 1:** Squash-merge prep: rebase on latest `main`, run full `rake test` (mise-activated shell), Rubocop, `npm run build` if any JS added.
- [ ] **Step 2:** Push via `gh auth token` HTTPS if SSH resolves to the wrong identity (memory `plan42_push_ssh_vs_gh_token`); JS-only fixups may use `--no-verify` only if pre-push contends with parallel agents.
- [ ] **Step 3:** Open PR (English description), request review from a reviewer agent. After merge: delete worktree (kill preview server first), update local `main`.

---

## Self-Review

**Spec coverage (Part A gaps → tasks):** auto-trigger outbound → Task 8; OAuth actor=app+refresh → Task 4; inbound entity→Creative CRUD → Task 10; echo suppression both ways → Task 6 + (outbound stamp in Task 7, inbound drop in Task 9/10); sync state machine + conflict → Task 2 (schema) + Task 10 (conflict path); GraphQL client → Task 3; field mapper → Task 5; webhook replay protection → Task 9; team/project topology → Task 2 (`team_id`/`project_id`) + Task 11. All nine covered.

**Type consistency:** `IssueLink` fields (`local_version`, `remote_updated_at`, `content_hash`, `sync_state`, `parent_issue_id`) defined in Task 2 and consumed unchanged in Tasks 7/10. `Client` method signatures defined in Task 3 and called with the same names in Tasks 4/7/11. `skip_linear_sync` flag introduced in Task 8 and relied on in Task 10. `EchoGuard.our_event?(account, payload)` defined Task 6, called Task 9/10. Consistent.

**Part B review outcomes (2026-07-01 eng-review, schema-verified):**
- **Field mapping locked:** `title`/`description` on native columns (LWW); `state`/`labels`/`assignee` under `creative.data["linear"]`; **`priority` on `creative.sequence`**. `progress` explicitly **not** synced (unwritable on linked creatives, `creative.rb:299-303`).
- **`priority → sequence` CONFIRMED intentional (정순오, 2026-07-01).** Linear priority = Collavre sibling sort order, bidirectional by design (inbound `priority==0 ? 5 : priority`; outbound rank→bucket). Accepted lossy edge: within-bucket order not representable in Linear `priority` (Linear `sortOrder` is the future lossless seam). Applier must write `sequence` via closure_tree's reorder path.
- **New Task 2b added:** core reserved-metadata-key registry so `data["linear"]` survives `update_metadata`, kept vendor-neutral (no engine name in core).

**Open items still requiring confirmation before Task 3 finalizes:** exact Linear `*Input` field names (validate against Apollo schema reference at implementation time). Decisions B1/B3/B4/B5/B6 stand as written unless 정순오 objects.
