# Slack Integration Architecture

This document describes the architecture and data flow of the CollavreSlack engine.

## Overview

The Slack integration enables bi-directional sync between Slack channels and Collavre Creatives:

**Messages:**
- **Slack → Collavre**: Messages posted in linked Slack channels appear as comments in the Creative
- **Collavre → Slack**: Comments posted in Collavre are sent to the linked Slack channel
- **Edit sync (bi-directional)**: Editing a message updates the corresponding message on the other side
- **Delete sync (bi-directional)**: Deleting a message deletes the corresponding message on the other side

**Reactions:**
- **Slack → Collavre**: Reactions added to Slack messages appear as CommentReactions in Collavre
- **Collavre → Slack**: CommentReactions added in Collavre are synced to the Slack message

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
| `creative_id` | integer | Linked Creative (unique - 1:1 relationship) |
| `slack_account_id` | integer | Parent Slack account |
| `channel_id` | string | Slack channel ID |
| `channel_name` | string | Slack channel name |
| `last_synced_at` | datetime | Last sync timestamp |

**Note:** Each Creative can only be linked to one Slack channel (1:1 relationship). To change the linked channel, delete the existing link first.

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

### SlackCommentLink

Links a Collavre Comment to its corresponding Slack message for reaction sync.

| Column | Type | Description |
|--------|------|-------------|
| `comment_id` | integer | Linked Comment |
| `slack_channel_link_id` | integer | Parent channel link |
| `message_ts` | string | Slack message timestamp |

This table enables bi-directional reaction sync by tracking which Comment corresponds to which Slack message.

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
6. `SlackCommentLink` created to link Comment with Slack message

## Reaction Flow

### Slack → Collavre

```
┌─────────────┐     ┌─────────────────────┐     ┌────────────────────┐
│   Slack     │────▶│  SlackEventsController│────▶│ SlackEventHandler  │
│ (reaction)  │     │  (verify signature)  │     │ (reaction_added)   │
└─────────────┘     └─────────────────────┘     └────────────────────┘
                                                          │
                                                          ▼
┌─────────────┐     ┌─────────────────────┐     ┌────────────────────┐
│  Comment    │◀────│SlackInboundReaction │◀────│  SlackCommentLink  │
│  Reaction   │     │       Job           │     │   (find comment)   │
└─────────────┘     └─────────────────────┘     └────────────────────┘
```

1. Slack sends `reaction_added` or `reaction_removed` event
2. `SlackEventsController` verifies signature
3. `SlackEventHandler` finds linked comment via `SlackCommentLink`
4. `SlackInboundReactionJob` creates/removes `CommentReaction`

### Collavre → Slack

```
┌─────────────┐     ┌─────────────────────┐     ┌────────────────────┐
│  Comment    │────▶│SlackReactionDispatch│────▶│  SlackReactionJob  │
│  Reaction   │     │  (after_commit)     │     │    (async)         │
└─────────────┘     └─────────────────────┘     └────────────────────┘
                                                          │
                                                          ▼
┌─────────────┐     ┌─────────────────────┐     ┌────────────────────┐
│   Slack     │◀────│    SlackClient      │◀────│  SlackCommentLink  │
│ (reaction)  │     │ (add/remove_reaction)│     │  (find message_ts) │
└─────────────┘     └─────────────────────┘     └────────────────────┘
```

1. `CommentReaction` created/destroyed in Collavre
2. `SlackReactionDispatchable` triggered via callback
3. `SlackReactionJob` finds Slack messages via `SlackCommentLink`
4. `SlackClient` adds/removes reaction on Slack

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

# Update a message
client.update_message(channel: "C123456", timestamp: "1234567890.123456", text: "Updated text")

# Delete a message
client.delete_message(channel: "C123456", timestamp: "1234567890.123456")

# Get message history
client.list_messages(channel: "C123456", oldest: timestamp)

# Add reaction to a message
client.add_reaction(channel: "C123456", timestamp: "1234567890.123456", name: "thumbsup")

# Remove reaction from a message
client.remove_reaction(channel: "C123456", timestamp: "1234567890.123456", name: "thumbsup")
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
| `SlackMessageUpdateJob` | Update messages on Slack when comments are edited |
| `SlackMessageDeleteJob` | Delete messages from Slack when comments are deleted |
| `SlackInboundMessageJob` | Process incoming Slack messages |
| `SlackInboundMessageUpdateJob` | Update comments when Slack messages are edited |
| `SlackInboundMessageDeleteJob` | Delete comments when Slack messages are deleted |
| `SlackReactionJob` | Send reactions to Slack |
| `SlackInboundReactionJob` | Process incoming Slack reactions |
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
  # Required scopes for full functionality including reactions
  config.scopes = "chat:write,channels:read,channels:history,reactions:read,reactions:write,users:read,users:read.email"
end
```

## Required Slack Event Subscriptions

For reaction sync to work, subscribe to these events in your Slack app's Event Subscriptions:

| Event | Description |
|-------|-------------|
| `message.channels` | Messages in public channels |
| `message.groups` | Messages in private channels |
| `reaction_added` | Reactions added to messages |
| `reaction_removed` | Reactions removed from messages |

## Collavre Permissions

The integration respects Collavre's hierarchical permission model. All Slack sync operations require `:feedback` permission on the Creative.

| Operation | Permission Check |
|-----------|------------------|
| Link/unlink channel | `creative.has_permission?(user, :feedback)` |
| Inbound message | `creative.has_permission?(mapped_user, :feedback)` |
| Inbound reaction | `creative.has_permission?(mapped_user, :feedback)` |
| Outbound message | Implicit (user created comment) |
| Outbound reaction | Implicit (user created reaction) |

**Fallback behavior:** When a Slack user cannot be mapped to a Collavre user, messages are attributed to the channel link creator (who must have `:feedback` permission).
