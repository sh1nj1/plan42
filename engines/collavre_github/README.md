# Collavre GitHub

GitHub integration engine for Collavre.

## Features

- OAuth authentication with GitHub
- Repository linking to Creatives
- Webhook → System Comment automatic creation
- **MCP Tools** for AI Agents to analyze PRs
- **Seed AI Agent**: GitHub PR Analyzer

## Architecture

```
GitHub Webhook (push, pull_request, etc.)
     │
     ▼
System Comment created in linked Creative
     │
     ▼
comment_created event dispatched
     │
     ▼
AI Agent (GitHub PR Analyzer) triggered
     │
     ├── github_pr_details - Get PR info
     ├── github_pr_diff - Get code changes
     ├── github_pr_commits - Get commit messages
     └── creative_retrieval_service - Get task tree
     │
     ▼
Action Comment response (JSON format)
     │
     ▼
User approval → Creative updates
```

## MCP Tools

Tools for AI Agents to interact with GitHub:

| Tool | Description |
|------|-------------|
| `github_pr_details` | Get PR title, body, author, files, additions/deletions |
| `github_pr_diff` | Get PR diff with truncation support (default: 10K chars) |
| `github_pr_commits` | Get list of commit messages in the PR |

### Tool Parameters

All tools require:
- `creative_id` - The Creative with GitHub integration
- `repo` - Repository full name (e.g., `owner/repo`)
- `pr_number` - Pull request number

The tools automatically find the GitHub account through:
```
Creative → RepositoryLink → GithubAccount → GitHub API
```

## Seed AI Agent

Running `rails db:seed` creates the **GitHub PR Analyzer** agent:

- **Name**: GitHub PR Analyzer
- **Email**: `github-pr-analyzer@collavre.local`
- **Trigger**: GitHub PR merged events (system comments)
- **Tools**: github_pr_details, github_pr_diff, github_pr_commits, creative_retrieval_service, creative_update_service
- **Output**: Action comments for updating Creative progress

### Routing Expression

```liquid
event_name == "comment_created" and chat.comment.user_id == nil and chat.comment.content contains "GitHub: Pull Request merged"
```

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

1. Connect GitHub account via OAuth
2. Link repository to a Creative
3. Webhook events automatically create system comments
4. AI Agent analyzes PRs and suggests task updates
5. User approves action comments to update Creatives

## License

AGPL
