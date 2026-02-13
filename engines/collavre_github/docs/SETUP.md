# GitHub Integration Setup Guide

Complete guide for setting up the Collavre GitHub integration, including OAuth authentication, webhook configuration, and AI-powered PR analysis.

## Overview

The `collavre_github` engine provides:

- **OAuth authentication** with GitHub (including GitHub Enterprise)
- **Repository linking** to Creatives
- **Webhook processing** for PR events → automatic system comments
- **AI Agent** (GitHub PR Analyzer) for automated PR analysis
- **MCP Tools** for AI agents to query PR details, diffs, and commits

### Architecture

```
GitHub Webhook (pull_request event)
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
     ├── github_pr_details  - PR info (title, body, files)
     ├── github_pr_diff     - Code changes (truncated)
     ├── github_pr_commits  - Commit messages
     └── creative_retrieval_service - Task tree
     │
     ▼
Action Comment with suggested Creative updates
     │
     ▼
User approval → Creative progress updated
```

---

## 1. Register a GitHub OAuth Application

Each deployment (production, staging, localhost) requires its own OAuth app because GitHub enforces a single callback URL per app.

### Steps

1. Go to **GitHub → Settings → Developer settings → OAuth Apps → New OAuth App**
   - For GitHub Enterprise: `https://github.example.com/settings/developers`
2. Fill in:
   - **Application name**: `Collavre` (or your preferred name)
   - **Homepage URL**: `https://your-collavre-domain.com`
   - **Authorization callback URL**: `https://your-collavre-domain.com/auth/github/callback`
3. Save and copy the **Client ID** and **Client Secret**

### On-Premises / Self-Hosted Notes

When deploying Collavre on-premises for a customer:

- The **customer** must register the OAuth app under their own GitHub organization or account
- The callback URL must point to the customer's Collavre instance
- For **GitHub Enterprise Server**, the API endpoint differs (`https://github.company.com/api/v3`)
- You cannot reuse the upstream OAuth app — callback URLs are tied to the app

---

## 2. Configure Credentials

### Option A: Rails Credentials (Recommended)

```bash
bin/rails credentials:edit --environment production
```

```yaml
github:
  client_id: YOUR_CLIENT_ID
  client_secret: YOUR_CLIENT_SECRET
  webhook_secret: YOUR_WEBHOOK_SECRET  # optional fallback
```

### Option B: Environment Variables

```bash
export GITHUB_CLIENT_ID=your_client_id
export GITHUB_CLIENT_SECRET=your_client_secret
export GITHUB_WEBHOOK_SECRET=your_webhook_secret  # optional
```

> **Note**: OmniAuth only registers the GitHub strategy when both `client_id` and `client_secret` are present. The OAuth flow requests `repo`, `read:org`, and `admin:repo_hook` scopes.

### Localhost Development

1. Create a **separate** OAuth app with callback URL: `http://localhost:3000/auth/github/callback`
2. Set credentials via environment variables or `bin/rails credentials:edit --environment development`

---

## 3. Webhook Configuration

### Automatic Setup

When you link a repository in the integration modal, Collavre automatically creates a webhook via the GitHub API pointing to `/github/webhook` with a per-repository secret. No manual setup required.

### Manual Setup (Fallback)

If automatic webhook creation fails:

1. Go to your repository → **Settings → Webhooks → Add webhook**
2. Configure:
   - **Payload URL**: `https://your-collavre-domain.com/github/webhook`
   - **Content type**: `application/json`
   - **Secret**: Use the per-repository secret shown in the integration modal
   - **Events**: Select **Let me select individual events** → check **Pull requests**
3. Save and verify with **Recent Deliveries** (expect `200 OK`)

### Local Development with Webhooks

GitHub must reach a public URL. Use a tunnel:

```bash
# ngrok
ngrok http http://localhost:3000

# GitHub CLI
gh webhook forward --url http://localhost:3000/github/webhook

# Smee.io
# Create a channel at smee.io and run the relay client
```

Update the webhook payload URL to your tunnel URL.

### Testing Webhooks Locally

Simulate a GitHub webhook delivery without waiting for a real event:

```bash
script/github_webhook_curl --repo owner/repo "PR title" "PR description"
```

Options:
- `--repo` — repository (optional if a `GithubRepositoryLink` exists)
- `--number` — PR number
- `--action` — webhook action (default: `opened`)
- `--url` — target URL (default: `http://localhost:3000/github/webhook`)

The script generates a valid `X-Hub-Signature-256` header.

---

## 4. Link Repositories to Creatives

1. Open a Creative → **Integrations menu → GitHub**
2. Authenticate with GitHub if prompted
3. Select organization and repositories to link
4. Save — creates `GithubRepositoryLink` records

PR events for linked repositories will automatically create system comments on the Creative.

---

## 5. AI Agent: GitHub PR Analyzer

### Seed Agent

Running `rails db:seed` creates the PR Analyzer agent:

| Setting | Value |
|---------|-------|
| **Name** | GitHub PR Analyzer |
| **Email** | `github-pr-analyzer@collavre.local` |
| **Trigger** | System comments containing "GitHub: Pull Request Merged" |
| **Context** | `chat_history: 1`, `chat_history_size: 1000` (minimal) |
| **Tools** | `github_pr_details`, `github_pr_diff`, `github_pr_commits`, `creative_retrieval_service`, `creative_update_service` |

### Routing Expression

```liquid
event_name == "comment_created" and comment.user_id == nil and comment.content contains "GitHub: Pull Request Merged"
```

### MCP Tools

| Tool | Description | Key Parameters |
|------|-------------|----------------|
| `github_pr_details` | PR title, body, author, files, additions/deletions | `creative_id`, `repo`, `pr_number` |
| `github_pr_diff` | Full PR diff (truncated to 10K chars by default) | `creative_id`, `repo`, `pr_number` |
| `github_pr_commits` | List of commit messages | `creative_id`, `repo`, `pr_number` |

Tools resolve the GitHub account via: `Creative → RepositoryLink → GithubAccount → GitHub API`

---

## 6. OmniAuth Configuration

Ensure your host app has the OmniAuth initializer:

```ruby
# config/initializers/omniauth.rb
Rails.application.config.middleware.use OmniAuth::Builder do
  provider :github,
           Rails.application.credentials.dig(:github, :client_id),
           Rails.application.credentials.dig(:github, :client_secret),
           scope: "repo,read:org,admin:repo_hook"
end
```

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| "Sign in with GitHub" button missing | Check that `GITHUB_CLIENT_ID` and `GITHUB_CLIENT_SECRET` are set |
| OAuth callback fails | Verify callback URL matches exactly (including trailing slash) |
| Webhook returns 401 | Check webhook secret matches the per-repository secret |
| PR Analyzer not triggering | Verify routing expression matches the system comment format |
| GitHub Enterprise API errors | Ensure API endpoint is configured for your GHE instance |
