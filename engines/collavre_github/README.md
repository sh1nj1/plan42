# Collavre GitHub

GitHub integration engine for Collavre.

## Documentation

**→ [Full Setup Guide](docs/SETUP.md)** — OAuth, webhooks, AI agent, on-premises deployment

## Features

- OAuth authentication with GitHub (including GitHub Enterprise)
- Repository linking to Creatives
- Webhook → System Comment automatic creation
- **MCP Tools** for AI Agents to analyze PRs
- **Seed AI Agent**: GitHub PR Analyzer (minimal context: `chat_history: 1`)

## Architecture

```
GitHub Webhook (pull_request event)
     │
     ▼
System Comment created in linked Creative
     │
     ▼
AI Agent (GitHub PR Analyzer) triggered
     │
     ├── github_pr_details
     ├── github_pr_diff
     ├── github_pr_commits
     └── creative_retrieval_service
     │
     ▼
Action Comment → User approval → Creative updates
```

## Quick Start

1. Register a GitHub OAuth App ([details](docs/SETUP.md#1-register-a-github-oauth-application))
2. Set `GITHUB_CLIENT_ID` and `GITHUB_CLIENT_SECRET`
3. Run `rails db:seed` to create the PR Analyzer agent
4. Link a repository to a Creative via the integration modal

## Installation

```ruby
# Gemfile
gem "collavre_github", path: "engines/collavre_github"
```

## License

AGPL
