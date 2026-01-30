# Slack App Configuration Guide

This guide explains how to create and configure a Slack App for integration with Collavre.

## Prerequisites

- A Slack workspace where you have admin privileges
- Your Collavre application deployed with a publicly accessible URL (for OAuth callbacks and event subscriptions)

## Step 1: Create a Slack App

1. Go to [Slack API Apps](https://api.slack.com/apps)
2. Click **Create New App**
3. Choose **From scratch**
4. Enter an App Name (e.g., "Collavre Integration")
5. Select the workspace where you want to develop the app
6. Click **Create App**

## Step 2: Configure OAuth & Permissions

### Add Redirect URL

1. In your app settings, go to **OAuth & Permissions**
2. Under **Redirect URLs**, click **Add New Redirect URL**
3. Add your callback URL: `https://your-domain.com/slack/auth/slack/callback`
4. Click **Save URLs**

### Add OAuth Scopes

Under **Scopes** > **Bot Token Scopes**, add the following:

| Scope | Purpose |
|-------|---------|
| `chat:write` | Post messages to channels |
| `channels:read` | List public channels |
| `channels:history` | Read message history from public channels |
| `groups:read` | List private channels the bot is a member of |
| `groups:history` | Read message history from private channels |
| `im:read` | List direct message channels |
| `mpim:read` | List group direct message channels |
| `users:read` | Read user information for mention mapping |
| `users:read.email` | Read user email addresses for auto-mapping |
| `reactions:read` | Read reactions on messages |
| `reactions:write` | Add/remove reactions on messages |

**Note:** The default scopes used by the engine are:
```
chat:write,channels:read,channels:history,groups:read,im:read,mpim:read,users:read,users:read.email,reactions:read,reactions:write
```

You can customize these via the `SLACK_SCOPES` environment variable.

## Step 3: Configure Event Subscriptions

1. Go to **Event Subscriptions**
2. Toggle **Enable Events** to **On**
3. Enter your Request URL: `https://your-domain.com/slack/slack/events`
4. Slack will send a verification challenge - the engine handles this automatically
5. Wait for the URL to be verified (green checkmark)

### Subscribe to Bot Events

Under **Subscribe to bot events**, add:

| Event | Description |
|-------|-------------|
| `message.channels` | Messages posted to public channels |
| `message.groups` | Messages posted to private channels |
| `message.im` | Direct messages to the bot |
| `message.mpim` | Messages in group DMs |
| `reaction_added` | Reactions added to messages (for reaction sync) |
| `reaction_removed` | Reactions removed from messages (for reaction sync) |

6. Click **Save Changes**

## Step 4: Get App Credentials

### Client ID and Client Secret

1. Go to **Basic Information**
2. Under **App Credentials**, find:
   - **Client ID** → Use for `SLACK_CLIENT_ID`
   - **Client Secret** → Use for `SLACK_CLIENT_SECRET`

### Signing Secret

1. Still on **Basic Information**
2. Under **App Credentials**, find:
   - **Signing Secret** → Use for `SLACK_SIGNING_SECRET`

## Step 5: Install App to Workspace (Development)

1. Go to **Install App**
2. Click **Install to Workspace**
3. Review the permissions and click **Allow**

For distribution to other workspaces, you'll need to submit for App Directory review or enable OAuth installation.

## Step 6: Configure Environment Variables

Add these environment variables to your Collavre deployment:

```bash
# Required
SLACK_CLIENT_ID=your-client-id
SLACK_CLIENT_SECRET=your-client-secret
SLACK_SIGNING_SECRET=your-signing-secret
SLACK_REDIRECT_URI=https://your-domain.com/slack/auth/slack/callback

# Optional (defaults shown)
SLACK_SCOPES=chat:write,channels:read,channels:history,groups:read,im:read,mpim:read,users:read,users:read.email,reactions:read,reactions:write
```

### Environment Variable Reference

| Variable | Required | Description |
|----------|----------|-------------|
| `SLACK_CLIENT_ID` | Yes | OAuth Client ID from Slack app settings |
| `SLACK_CLIENT_SECRET` | Yes | OAuth Client Secret from Slack app settings |
| `SLACK_SIGNING_SECRET` | Yes | Used to verify incoming webhook requests |
| `SLACK_REDIRECT_URI` | Yes | OAuth callback URL (must match Slack app config) |
| `SLACK_SCOPES` | No | OAuth scopes to request (comma-separated) |

## Step 7: Mount the Engine (if not already done)

In your `config/routes.rb`:

```ruby
Rails.application.routes.draw do
  # Mount the Slack engine
  mount CollavreSlack::Engine => "/slack", as: :slack_engine

  # ... other routes
end
```

## Verification Checklist

- [ ] Slack App created
- [ ] OAuth Redirect URL added and matches `SLACK_REDIRECT_URI`
- [ ] Required Bot Token Scopes added (including `reactions:read` and `reactions:write`)
- [ ] Event Subscriptions enabled and verified
- [ ] Bot events subscribed (message.channels, reaction_added, reaction_removed, etc.)
- [ ] Environment variables configured
- [ ] Engine mounted in routes

## Troubleshooting

### OAuth Error: "Invalid redirect_uri"

Ensure the `SLACK_REDIRECT_URI` environment variable exactly matches the URL configured in your Slack app's OAuth settings.

### Event URL Verification Failed

1. Check that your server is publicly accessible
2. Verify the URL path is correct: `/slack/slack/events`
3. Check server logs for any errors during the challenge

### "Invalid signature" on Events

1. Verify `SLACK_SIGNING_SECRET` is correct
2. Ensure it's the Signing Secret, not the Client Secret
3. Check that your server's clock is synchronized (requests older than 5 minutes are rejected)

### Channels Not Appearing

1. The bot must be invited to private channels to see them
2. Ensure `channels:read` and `groups:read` scopes are granted
3. Try re-authenticating the Slack connection

## User Mapping

The integration automatically maps Slack users to Collavre users based on email address.

### How It Works

1. When a message arrives from Slack, the system first checks for an existing `SlackUserMapping` record
2. If no mapping exists, it fetches the Slack user's email address via the API
3. It looks for a Collavre user with the same email
4. If found, it automatically creates a mapping for future messages

### Requirements

- The `users:read.email` scope must be granted
- Slack users must have their email visible in their profile
- The email must match exactly between Slack and Collavre

### Manual Mapping

For users whose emails don't match, you can create mappings manually in the database:

```ruby
CollavreSlack::SlackUserMapping.create!(
  slack_account: slack_account,
  slack_user_id: "U12345678",
  collavre_user: user
)
```

### Fallback Behavior

If no user can be matched, messages are attributed to the user who created the channel link.

## Collavre Permissions

The Slack integration respects Collavre's permission model:

| Action | Required Permission |
|--------|---------------------|
| Link a Slack channel to a Creative | `:feedback` |
| Unlink a Slack channel | `:feedback` |
| Receive messages from Slack | `:feedback` (checked per user) |
| Send messages to Slack | `:feedback` (implicit via comment creation) |
| Receive reactions from Slack | `:feedback` (checked per user) |
| Send reactions to Slack | `:feedback` (implicit via reaction creation) |

**Note:** Messages from unmapped Slack users (no matching email) are attributed to the channel link creator, who must have `:feedback` permission.

## Security Notes

- Never commit credentials to version control
- Use environment variables or a secrets manager
- The Signing Secret is used to verify that incoming webhooks are from Slack
- OAuth tokens are stored in the `slack_accounts` table and should be treated as sensitive data
