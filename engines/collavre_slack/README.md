# Collavre Slack Engine

Slack integration plugin engine for Collavre. Provides OAuth installation, channel linking, and bi-directional chat sync.

## Documentation

- [Setup Guide](docs/SETUP.md) - Step-by-step instructions for creating and configuring a Slack App
- [Architecture](docs/ARCHITECTURE.md) - Technical documentation about the integration

## Installation

### 1. Add to Gemfile

```ruby
# Gemfile
gem "collavre_slack", path: "engines/collavre_slack"
```

### 2. Add JavaScript Import (Required)

The JavaScript must be explicitly imported in your host application:

```javascript
// app/javascript/application.js
import "collavre_slack"
```

This is required because the host app controls which integrations are loaded. Without this import, the Slack integration modal and badge functionality will not work.

### 3. Add Stylesheet (Required)

Include the Slack integration stylesheet in your layout:

```erb
<%# app/views/layouts/application.html.erb %>
<%= stylesheet_link_tag "collavre_slack/slack_integration" %>
```

### 4. Configure Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `SLACK_CLIENT_ID` | Yes | OAuth Client ID |
| `SLACK_CLIENT_SECRET` | Yes | OAuth Client Secret |
| `SLACK_SIGNING_SECRET` | Yes | Webhook signature verification |
| `SLACK_REDIRECT_URI` | Yes | OAuth callback URL |
| `SLACK_SCOPES` | No | OAuth scopes (has sensible defaults) |

### 5. Run Migrations

```bash
rails db:migrate
```

## Automatic Configuration

The following are automatically configured by the engine:

- **Routes**: Mounted at `/slack` (no manual `mount` needed in `routes.rb`)
- **Asset Paths**: Stylesheets are automatically added to Propshaft asset paths
- **Migrations**: Database migrations are automatically included
- **i18n**: Locale files (en, ko) are automatically loaded
- **Integration Registry**: Automatically registers with `Collavre::IntegrationRegistry`

## Slack App Setup

1. Create a Slack App at [api.slack.com/apps](https://api.slack.com/apps)
2. Configure OAuth scopes and redirect URL
3. Set up Event Subscriptions

See [docs/SETUP.md](docs/SETUP.md) for detailed instructions.

## Features

- OAuth 2.0 installation flow
- Channel linking to Creatives
- Bi-directional message sync (Slack ↔ Collavre)
- User mention mapping
- Rate limit handling with automatic retry
- Request signature verification for security
