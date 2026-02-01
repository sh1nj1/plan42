# Collavre Notion Engine

Notion integration plugin engine for Collavre. Provides OAuth connection, page linking, and creative export/sync to Notion.

## Documentation

- [Setup Guide](docs/SETUP.md) - Step-by-step instructions for creating and configuring a Notion integration
- [Architecture](docs/ARCHITECTURE.md) - Technical documentation about the integration

## Installation

### 1. Add to Gemfile

```ruby
# Gemfile
gem "collavre_notion", path: "engines/collavre_notion"
```

### 2. Add JavaScript Import (Required)

The JavaScript must be explicitly imported in your host application:

```javascript
// app/javascript/application.js
import "collavre_notion"
```

This is required because the host app controls which integrations are loaded. Without this import, the Notion integration modal will not work.

### 3. Configure Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `NOTION_CLIENT_ID` | Yes | OAuth Client ID |
| `NOTION_CLIENT_SECRET` | Yes | OAuth Client Secret |

### 4. Run Migrations

```bash
rails db:migrate
```

## Automatic Configuration

The following are automatically configured by the engine:

- **Routes**: Mounted at `/notion` (no manual `mount` needed in `routes.rb`)
- **OAuth Callback**: Handles `/auth/notion/callback`
- **Migrations**: Database migrations are automatically included
- **i18n**: Locale files (en, ko) are automatically loaded
- **Integration Registry**: Automatically registers with `Collavre::IntegrationRegistry`

## Features

- OAuth 2.0 connection to Notion workspaces
- Export a creative tree to a Notion page
- Sync linked pages with updated creative content
- Manage linked page connections per creative
