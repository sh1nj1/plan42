# Collavre Engines

## Core Engine (`engines/collavre/`)

The main application engine containing:

### Models
- `Collavre::User` - Authentication, profile
- `Collavre::Creative` - Hierarchical content (closure_tree)
- `Collavre::CreativeShare` - Access control (permission per creative per user)
- `Collavre::Comment` - Threaded comments
- `Collavre::Invitation` - Sharing invites
- `Collavre::InboxItem` - Notification inbox
- `Collavre::Topic` - Comment grouping
- `Collavre::Tag` - Creative tags
- `Collavre::Label` - Creative labels
- `Collavre::Task` - Tasks linked to creatives
- `Collavre::ActivityLog` - Audit log entries
- `Collavre::CalendarEvent` - Calendar integrations
- `Collavre::Session` - User sessions
- `Collavre::Device` - Push notification devices

### Controllers
- `Collavre::SessionsController` - Login/logout
- `Collavre::UsersController` - User management
- `Collavre::CreativesController` - CRUD + tree operations
- `Collavre::CommentsController` - Comment management
- `Collavre::TasksController` - Task management
- `Collavre::TopicsController` - Topic management
- `Collavre::CalendarEventsController` - Calendar events
- `Collavre::ContactsController` - Contacts

### Key Services
- `Collavre::Creatives::TreeBuilder` - Builds creative tree structure
- `Collavre::MarkdownConverter` - Convert markdown content
- `Collavre::MarkdownImporter` - Import from markdown
- `Collavre::Creatives::FilterPipeline` - Filtering creatives
- `Collavre::AiAgentService` - AI agent coordination
- `Collavre::McpService` - MCP tool management

---

## OpenClaw Engine (`engines/collavre_openclaw/`)

AI agent integration via OpenClaw Gateway.

### Models
- `CollavreOpenclaw::PendingCallback` - Async request tracking

### Key Classes
- `CollavreOpenclaw::OpenclawAdapter` - API client
- `CollavreOpenclaw::AiClientExtension` - Rails AI integration
- `CollavreOpenclaw::CallbackProcessorJob` - Handle async responses
- `CollavreOpenclaw::WebsocketClient` - WebSocket connection to OpenClaw Gateway
- `CollavreOpenclaw::ConnectionManager` - Manages WebSocket lifecycle

### Routes
```
/openclaw/callbacks    # Webhook receiver
```

---

## Notion Engine (`engines/collavre_notion/`)

Export creative trees to Notion.

### Models
- `CollavreNotion::NotionAccount` - OAuth tokens
- `CollavreNotion::NotionPageLink` - Creative ↔ Notion page mapping
- `CollavreNotion::NotionBlockLink` - Block-level sync tracking

### Key Classes
- `CollavreNotion::NotionClient` - Notion API wrapper
- `CollavreNotion::NotionCreativeExporter` - Tree export logic
- `CollavreNotion::NotionService` - High-level operations

### Routes
```
/notion/creative/:id/notion_integration  # Integration UI
/auth/notion/callback                    # OAuth callback
```

### Jobs
- `NotionExportJob` - Async export
- `NotionSyncJob` - Sync updates

---

## GitHub Engine (`engines/collavre_github/`)

Connect GitHub repositories and receive webhook events.

### Models
- `CollavreGithub::Account` - OAuth tokens and GitHub credentials
- `CollavreGithub::RepositoryLink` - Creative ↔ GitHub repository mapping

### Key Classes
- `CollavreGithub::Client` - GitHub API wrapper
- `CollavreGithub::WebhookProvisioner` - Manage repository webhooks
- `CollavreGithub::Tools::GithubPrDetailsService` - Fetch PR details
- `CollavreGithub::Tools::GithubPrDiffService` - Fetch PR diffs
- `CollavreGithub::Tools::GithubPrCommitsService` - Fetch PR commits

### Routes
```
/github/...                  # GitHub integration UI
/auth/github/callback        # OAuth callback
```

---

## Slack Engine (`engines/collavre_slack/`)

Sync comments with Slack channels.

### Models
- `CollavreSlack::SlackAccount` - OAuth tokens per workspace
- `CollavreSlack::SlackChannelLink` - Creative ↔ Slack channel mapping
- `CollavreSlack::SlackCommentLink` - Comment ↔ Slack message mapping
- `CollavreSlack::SlackMessageLog` - Sent message audit log
- `CollavreSlack::SlackUserMapping` - Collavre user ↔ Slack user mapping

### Key Classes
- `CollavreSlack::SlackClient` - Slack API wrapper
- `CollavreSlack::SlackEventHandler` - Process inbound Slack events
- `CollavreSlack::SlackMessageDispatcher` - Send messages to Slack
- `CollavreSlack::SlackIntegrationService` - High-level operations

### Routes
```
/slack/...    # Slack integration UI and webhooks
```

---

## Completion API Engine (`engines/collavre_completion_api/`)

OpenAI-compatible chat completion API.

### Routes
```
/api/v1/chat/completions    # Chat completion endpoint
/api/v1/models              # Available models list
```

---

## Plan Engine (`engines/collavre_plan/`)

Plans timeline and tagging for creatives.

### Models
- `Collavre::Plan` - Plan record (tagged to creatives)

### Key Classes
- `Collavre::Creatives::PlanTagger` - Tag creatives with a plan

### Routes
```
/plans                       # Plans index
/creative_plan               # Plan association for a creative
```
