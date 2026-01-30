# Collavre Slack Engine

Slack integration plugin engine for Collavre. Provides OAuth installation, channel linking, and bi-directional chat sync.

## Documentation

- [Setup Guide](docs/SETUP.md) - Step-by-step instructions for creating and configuring a Slack App
- [Architecture](docs/ARCHITECTURE.md) - Technical documentation about the integration

## Quick Start

1. Create a Slack App at [api.slack.com/apps](https://api.slack.com/apps)
2. Configure OAuth scopes and redirect URL
3. Set up Event Subscriptions
4. Configure environment variables
5. Mount the engine in your routes

See [docs/SETUP.md](docs/SETUP.md) for detailed instructions.

## Required Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `SLACK_CLIENT_ID` | Yes | OAuth Client ID |
| `SLACK_CLIENT_SECRET` | Yes | OAuth Client Secret |
| `SLACK_SIGNING_SECRET` | Yes | Webhook signature verification |
| `SLACK_REDIRECT_URI` | Yes | OAuth callback URL |
| `SLACK_SCOPES` | No | OAuth scopes (has sensible defaults)

## Mounting the Engine

```ruby
# config/routes.rb
mount CollavreSlack::Engine => "/slack", as: :slack_engine
```

## Features

- OAuth 2.0 installation flow
- Channel linking to Creatives
- Bi-directional message sync (Slack ↔ Collavre)
- User mention mapping
- Rate limit handling with automatic retry
- Request signature verification for security
