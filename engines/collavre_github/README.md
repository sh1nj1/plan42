# Collavre GitHub

GitHub integration engine for Collavre.

## Features

- OAuth authentication with GitHub
- Repository linking to Creatives
- Webhook management for receiving events (push, pull_request, etc.)
- Pull request analysis with AI

## Installation

Add to your Gemfile:

```ruby
gem "collavre_github", path: "engines/collavre_github"
```

## Configuration

### OAuth Setup

1. Create a GitHub OAuth App at https://github.com/settings/developers
2. Set callback URL to: `https://your-domain.com/auth/github/callback`
3. Add credentials:

```bash
bin/rails credentials:edit
```

```yaml
github:
  client_id: your_client_id
  client_secret: your_client_secret
  webhook_secret: optional_fallback_secret
```

### OmniAuth Configuration

In `config/initializers/omniauth.rb`:

```ruby
Rails.application.config.middleware.use OmniAuth::Builder do
  provider :github,
           Rails.application.credentials.dig(:github, :client_id),
           Rails.application.credentials.dig(:github, :client_secret),
           scope: "repo,read:org"
end
```

## Usage

Once installed, users can:

1. Connect their GitHub account via OAuth
2. Link repositories to Creatives
3. Receive webhook events for pull requests and other events
4. AI agents can respond to GitHub events

## License

AGPL
