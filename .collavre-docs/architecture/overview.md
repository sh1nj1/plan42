# Collavre Architecture Overview

## Multi-Engine Structure

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

## Engine Responsibilities

### Core Engine (`engines/collavre/`)
- User authentication and authorization
- Creative model (hierarchical content with closure_tree)
- Permission system (read/write/admin per creative)
- Comments, attachments, inbox
- Real-time updates via ActionCable

### OpenClaw Engine (`engines/collavre_openclaw/`)
- AI agent integration via OpenClaw Gateway
- OpenAI-compatible API adapter
- Async callback handling with nonce authentication

### Notion Engine (`engines/collavre_notion/`)
- Notion OAuth integration
- Creative tree export to Notion pages
- Block-level sync tracking

### GitHub Engine (`engines/collavre_github/`)
- GitHub OAuth integration
- Repository link management
- Webhook provisioning and PR tool services

### Slack Engine (`engines/collavre_slack/`)
- Slack OAuth and channel linking
- Comment/reaction dispatch to Slack channels
- Inbound event handling

### Completion API Engine (`engines/collavre_completion_api/`)
- Exposes an OpenAI-compatible `/v1/chat/completions` endpoint
- Exposes a `/v1/models` endpoint
- Mounts at the root path

### Plan Engine (`engines/collavre_plan/`)
- Plan tagging on creatives
- Plans timeline view
- Navigation and toolbar view extensions

## Namespace Pattern

Each engine uses `isolate_namespace`:
```ruby
module CollavreNotion
  class Engine < ::Rails::Engine
    isolate_namespace CollavreNotion
  end
end
```

Models are namespaced: `Collavre::Creative`, `CollavreOpenclaw::OpenclawAccount`

## Cross-Engine Associations

Engines inject associations into core models via initializers:
```ruby
initializer "collavre_notion.user_associations" do
  Rails.application.config.to_prepare do
    Collavre.user_class.has_one :notion_account, class_name: "CollavreNotion::NotionAccount"
  end
end
```
