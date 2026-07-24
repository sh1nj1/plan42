# Host Application Architecture

This document describes the architectural patterns used in the host application (`collavre`) to support on-premise separation.

## 1. Engine Integration
The host application is designed to be a "shell" that loads core features and optionally loads custom "on-premise" modules as Rails Engines.

### Dynamic Loading
- **Gemfile**: Automatically iterates over the `engines/` directory and loads any local engines found there.
- **Initializer**: `config/initializers/local_engines.rb` configures these engines to:
  - Override host views (Prepend view paths).
  - Add migrations to the main schema.
  - Load I18n locales.
  - overriding static assets (favicons, logos).

## 2. Shared Considerations

### Database
- All engines share the **same database** as the host.
- Engine migrations are run via standard `rails db:migrate`.
- Namespacing tables (e.g., `example_custom_projects`) is strictly recommended for engine-specific data to avoid collisions.

### Assets & Javascript
- **Esbuild**: The build script (`script/build.cjs`) automatically discovers and compiles entry points from `engines/*/app/javascript/*.*`.
- **CSS**: Engines should expose their own CSS files if needed, or override partials that include CSS classes.

### Testing
- **Unified Testing**:
  - `rake test`: Runs tests for both the host application and all engines.
  - `rails test`: Runs host application tests only.
  - `rails test engines/`: Runs tests for all engines.
  - `npm test`: Runs Jest tests for both host and engines (configured in `jest.config.cjs`).

## 3. Best Practices for Host Development
- **Partials**: Extracted common UI elements (like `shared/footer`, `shared/navbar`) into partials to make them easily overridable by engines.
- **I18n**: Use `t('app.key')` helper everywhere. Do not hardcode strings. This allows engines to change terminology (e.g., "Plan" vs "Project").
- **Helpers**: Use `method_defined?` checks if calling engine-specific helpers or use a hook pattern.

## 4. Multi-Engine Structure

Collavre uses a Rails 8 multi-engine architecture:

```
collavre/
├── app/                          # Host app (minimal, mostly mounts engines)
├── engines/
│   ├── collavre/                 # Core engine (users, creatives, permissions)
│   ├── collavre_openclaw/        # OpenClaw AI agent integration
│   ├── collavre_notion/          # Notion export integration
│   ├── collavre_github/          # GitHub integration (OAuth, webhooks, PR tools)
│   ├── collavre_slack/           # Slack integration (channel sync, message dispatch)
│   ├── collavre_completion_api/  # OpenAI-compatible chat completion API
│   └── collavre_plan/            # Plans timeline and tagging
```

### Engine Responsibilities

- **Core (`engines/collavre/`)** — User authentication/authorization, the
  Creative model (hierarchical content with closure_tree), the permission system
  (read/write/admin per creative), comments, attachments, inbox, and real-time
  updates via ActionCable.
- **OpenClaw (`engines/collavre_openclaw/`)** — AI agent integration via the
  OpenClaw Gateway, an OpenAI-compatible API adapter, and async callback handling
  with nonce authentication.
- **Notion (`engines/collavre_notion/`)** — Notion OAuth, creative-tree export to
  Notion pages, and block-level sync tracking.
- **GitHub (`engines/collavre_github/`)** — GitHub OAuth, repository link
  management, and webhook provisioning + PR tool services.
- **Slack (`engines/collavre_slack/`)** — Slack OAuth and channel linking,
  comment/reaction dispatch to Slack channels, and inbound event handling.
- **Completion API (`engines/collavre_completion_api/`)** — an OpenAI-compatible
  `/v1/chat/completions` and `/v1/models` endpoint, mounted at the root path.
- **Plan (`engines/collavre_plan/`)** — plan tagging on creatives, the plans
  timeline view, and navigation/toolbar view extensions.

> For a per-engine breakdown of models, controllers, services, and routes, see
> [engines.md](engines.md). To build a new engine, see
> [engine_development.md](engine_development.md).

### Namespace Pattern

Each engine uses `isolate_namespace`:
```ruby
module CollavreNotion
  class Engine < ::Rails::Engine
    isolate_namespace CollavreNotion
  end
end
```

Models are namespaced: `Collavre::Creative`, `CollavreOpenclaw::OpenclawAccount`.

### Cross-Engine Associations

Engines inject associations into core models via initializers rather than taking
a direct dependency:
```ruby
initializer "collavre_notion.user_associations" do
  Rails.application.config.to_prepare do
    Collavre.user_class.has_one :notion_account, class_name: "CollavreNotion::NotionAccount"
  end
end
```
