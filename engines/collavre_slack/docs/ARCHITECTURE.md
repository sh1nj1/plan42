# Slack Integration Architecture

This document describes the architecture and data flow of the CollavreSlack engine.

## Overview

The Slack integration enables bi-directional message sync between Slack channels and Collavre Creatives:

- **Slack → Collavre**: Messages posted in linked Slack channels appear as comments in the Creative
- **Collavre → Slack**: Comments posted in Collavre are sent to the linked Slack channel

## Data Models

### SlackAccount

Stores OAuth credentials for connected Slack workspaces.

| Column | Type | Description |
|--------|------|-------------|
| `user_id` | integer | Collavre user who connected the workspace |
| `team_id` | string | Slack workspace ID |
| `team_name` | string | Slack workspace name |
| `access_token` | string | Bot OAuth token |
| `authed_user_id` | string | Slack user ID who authorized |
| `scopes` | string | Granted OAuth scopes |

### SlackChannelLink

Links a Slack channel to a Collavre Creative.

| Column | Type | Description |
|--------|------|-------------|
| `creative_id` | integer | Linked Creative |
| `slack_account_id` | integer | Parent Slack account |
| `channel_id` | string | Slack channel ID |
| `channel_name` | string | Slack channel name |
| `is_active` | boolean | Whether sync is enabled |
| `last_synced_at` | datetime | Last sync timestamp |

### SlackUserMapping

Maps Slack users to Collavre users for mention conversion and message attribution.

| Column | Type | Description |
|--------|------|-------------|
| `slack_account_id` | integer | Parent Slack account |
| `slack_user_id` | string | Slack user ID |
| `collavre_user_id` | integer | Mapped Collavre user |

**Auto-mapping**: When a message arrives from an unmapped Slack user, the system automatically:
1. Fetches the user's email from Slack API
2. Finds a Collavre user with the same email
3. Creates a mapping for future messages

## Message Flow

### Slack → Collavre

```
┌─────────────┐     ┌─────────────────────┐     ┌────────────────────┐
│   Slack     │────▶│  SlackEventsController│────▶│ SlackEventHandler  │
│   (Event)   │     │  (verify signature)  │     │ (normalize event)  │
└─────────────┘     └─────────────────────┘     └────────────────────┘
                                                          │
                                                          ▼
┌─────────────┐     ┌─────────────────────┐     ┌────────────────────┐
│   Comment   │◀────│ SlackInboundMessage │◀────│  SlackChannelLink  │
│  (created)  │     │       Job           │     │    (find link)     │
└─────────────┘     └─────────────────────┘     └────────────────────┘
```

1. Slack sends event to `/slack/slack/events`
2. `SlackEventsController` verifies the request signature
3. `SlackEventHandler` normalizes the event payload
4. `SlackInboundMessageJob` processes asynchronously
5. Finds the linked Creative via `SlackChannelLink`
6. Creates a Comment in the Creative

### Collavre → Slack

```
┌─────────────┐     ┌─────────────────────┐     ┌────────────────────┐
│   Comment   │────▶│ SlackMessageDispatcher│────▶│  SlackMessageJob   │
│  (created)  │     │  (after_commit)     │     │    (async)         │
└─────────────┘     └─────────────────────┘     └────────────────────┘
                                                          │
                                                          ▼
┌─────────────┐     ┌─────────────────────┐     ┌────────────────────┐
│   Slack     │◀────│    SlackClient      │◀────│  SlackChannelLink  │
│  (message)  │     │  (post_message)     │     │    (find link)     │
└─────────────┘     └─────────────────────┘     └────────────────────┘
```

1. Comment created in Collavre
2. `SlackMessageDispatcher` triggered via callback
3. `SlackMessageJob` enqueued for async processing
4. Finds linked Slack channels via `SlackChannelLink`
5. `SlackClient` posts message to Slack

## Rate Limiting

The integration handles Slack's rate limits:

1. `SlackMessageJob` detects 429 responses
2. Reads `Retry-After` header from Slack
3. Reschedules job with appropriate delay
4. Logs rate limit events for monitoring

## Key Services

### SlackClient

HTTP client for Slack API communication.

```ruby
client = CollavreSlack::SlackClient.new(access_token: token)

# List channels
client.list_channels

# Post a message
client.post_message(channel: "C123456", text: "Hello!")

# Get message history
client.list_messages(channel: "C123456", oldest: timestamp)
```

### SlackIntegrationService

Business logic for managing integrations.

```ruby
service = CollavreSlack::SlackIntegrationService.new(
  user: current_user,
  slack_account: account
)

# Link a channel
link = service.link_channel(
  creative: creative,
  channel_id: "C123456",
  channel_name: "general"
)

# Unlink a channel
service.unlink_channel(link)
```

### SlackEventHandler

Normalizes incoming Slack events.

```ruby
handler = CollavreSlack::SlackEventHandler.new(payload: event_payload)
normalized = handler.call
# => { channel_id: "C123", user_id: "U456", text: "Hello", ts: "..." }
```

### MentionMapping

Converts mentions between Slack and Collavre formats.

```ruby
mapping = CollavreSlack::MentionMapping.new(slack_account: account)

# Slack → Collavre
collavre_text = mapping.slack_to_collavre("<@U123> hello")

# Collavre → Slack
slack_text = mapping.collavre_to_slack("@john hello")
```

## Background Jobs

| Job | Purpose |
|-----|---------|
| `SlackMessageJob` | Send messages to Slack (with rate limit handling) |
| `SlackInboundMessageJob` | Process incoming Slack messages |
| `SlackChannelSyncJob` | Resync channel history |

## API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/slack/auth/slack` | Start OAuth flow |
| `GET` | `/slack/auth/slack/callback` | OAuth callback |
| `GET` | `/slack/creatives/:id/slack_integrations` | List channel links |
| `POST` | `/slack/creatives/:id/slack_integrations` | Create channel link |
| `DELETE` | `/slack/creatives/:id/slack_integrations/:id` | Remove channel link |
| `POST` | `/slack/slack/events` | Slack event webhook |

## Configuration

Access configuration programmatically:

```ruby
CollavreSlack.config.client_id
CollavreSlack.config.client_secret
CollavreSlack.config.signing_secret
CollavreSlack.config.redirect_uri
CollavreSlack.config.scopes
```

Or configure in an initializer:

```ruby
# config/initializers/collavre_slack.rb
CollavreSlack.configure do |config|
  config.client_id = ENV["SLACK_CLIENT_ID"]
  config.client_secret = ENV["SLACK_CLIENT_SECRET"]
  config.signing_secret = ENV["SLACK_SIGNING_SECRET"]
  config.redirect_uri = ENV["SLACK_REDIRECT_URI"]
  config.scopes = "chat:write,channels:read,channels:history"
end
```
