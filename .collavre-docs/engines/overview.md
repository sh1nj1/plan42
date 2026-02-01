# Collavre Engines

## Core Engine (`engines/collavre/`)

The main application engine containing:

### Models
- `Collavre::User` - Authentication, profile
- `Collavre::Creative` - Hierarchical content (closure_tree)
- `Collavre::Permission` - Access control
- `Collavre::Comment` - Threaded comments
- `Collavre::Invitation` - Sharing invites
- `Collavre::InboxItem` - Notification inbox

### Controllers
- `Collavre::SessionsController` - Login/logout
- `Collavre::UsersController` - User management
- `Collavre::CreativesController` - CRUD + tree operations
- `Collavre::CommentsController` - Comment management

### Key Services
- `Collavre::TreeBuilder` - Builds creative tree structure
- `Collavre::MarkdownExporter` - Export to markdown

---

## OpenClaw Engine (`engines/collavre_openclaw/`)

AI agent integration via OpenClaw Gateway.

### Models
- `CollavreOpenclaw::OpenclawAccount` - API credentials
- `CollavreOpenclaw::PendingCallback` - Async request tracking

### Key Classes
- `CollavreOpenclaw::OpenclawAdapter` - API client
- `CollavreOpenclaw::AiClientExtension` - Rails AI integration
- `CollavreOpenclaw::CallbackProcessorJob` - Handle async responses

### Routes
```
/openclaw/accounts     # Account management
/openclaw/callbacks    # Webhook receiver
```

### OpenAI Compatibility
Exposes `/v1/chat/completions` endpoint compatible with OpenAI SDK.

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
