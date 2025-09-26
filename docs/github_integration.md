# GitHub Integration Setup

This application lets creatives connect a GitHub account, choose repositories,
and receive automated pull request analysis through the `/github/webhook`
endpoint. Follow the steps below to configure both the OAuth login and the
webhook delivery for production and local development.

## 1. Register GitHub OAuth applications

GitHub requires an OAuth application per callback URL. Create one for your
production host and a second for local testing.

### Production
1. Open <https://github.com/settings/developers> → **OAuth Apps** → **New OAuth
   App**.
2. Fill in the details for your product (homepage URL, description, logo).
3. Set **Authorization callback URL** to
   `https://YOUR_PRODUCTION_HOST/auth/github/callback`.
4. After saving, copy the generated **Client ID** and **Client Secret**.
5. Store the credentials so Rails can load them:
   - Using credentials (preferred):
     ```bash
     bin/rails credentials:edit --environment production
     ```
     ```yaml
     github:
       client_id: YOUR_CLIENT_ID
       client_secret: YOUR_CLIENT_SECRET
     ```
   - Or set the environment variables `GITHUB_CLIENT_ID` and
     `GITHUB_CLIENT_SECRET` in your hosting platform.
6. Restart the app. OmniAuth only registers the GitHub strategy when both values
   are present. The OAuth flow requests the `repo`, `read:org`, and
   `admin:repo_hook` scopes so Plan42 can read repository metadata and manage
   webhooks on your behalf.

### Localhost (`localhost:3000`)
1. Create another OAuth app with **Authorization callback URL**
   `http://localhost:3000/auth/github/callback`.
2. Export the credentials before starting the Rails server:
   ```bash
   export GITHUB_CLIENT_ID=your_local_client_id
   export GITHUB_CLIENT_SECRET=your_local_client_secret
   ```
3. Launch the app (`bin/dev` or `rails server`) and use the “Sign in with
   GitHub” button. GitHub will redirect back to
   `/auth/github/callback` on your localhost instance.

> Tip: If you use Rails credentials for development, run
> `bin/rails credentials:edit --environment development` and add the same
> `github.client_id` and `github.client_secret` keys instead of exporting
> environment variables.

## 2. Webhook automation and manual fallback

The webhook notifies Plan42 when pull requests change so Gemini can analyse the
creative paths linked to the repository. When you link a repository in the
integration modal, Plan42 now calls the GitHub API to create (or update) a
webhook pointing at `/github/webhook` with a repository-specific secret. No
additional setup is required in the GitHub UI during normal operation.

If automation fails or you need to recreate the hook manually, use the
configuration below as a reference.

### Required settings for manual setup
1. **Payload URL:**
   * Production: `https://YOUR_PRODUCTION_HOST/github/webhook`
   * Local testing (via tunnel): e.g. `https://<random>.ngrok.app/github/webhook`
2. **Content type:** `application/json`.
3. **Secret:** Use the per-repository secret shown in the integration modal.
4. **Events:** Select **Let me select individual events** and check **Pull
   requests**. All other events can remain unchecked.
5. Save the webhook and click **Recent Deliveries** to confirm GitHub receives a
   `200 OK` response.

### Store the webhook secret in Rails
Add the secret next to your other GitHub credentials so the webhook controller
can validate `X-Hub-Signature-256`:

```bash
bin/rails credentials:edit --environment production
```
```yaml
github:
  client_id: ...
  client_secret: ...
  webhook_secret: YOUR_WEBHOOK_SECRET
```

or export an environment variable before booting the app:

```bash
export GITHUB_WEBHOOK_SECRET=YOUR_WEBHOOK_SECRET
```

Local development can use the same approach with the development credentials
file or shell exports.

### Forwarding webhooks locally
GitHub must reach a public URL. Use one of these tools to tunnel requests to
`localhost:3000`:

* **ngrok:** `ngrok http http://localhost:3000`
* **GitHub CLI:** `gh webhook forward --url http://localhost:3000/github/webhook`
* **Smee.io:** Create a channel and run the relay client locally.

Update the webhook’s payload URL to the tunnel URL, restart the tunnel when it
changes, and resend recent deliveries from the GitHub UI for quick testing.

## 3. Link repositories inside Plan42
1. Open the **GitHub Integration** modal from the creative menu.
2. Authenticate with GitHub if prompted and authorize the Plan42 OAuth app.
3. Choose the organization and repositories you want to link.
4. Save. The selections create `GithubRepositoryLink` records used by the webhook
   processor to map pull requests to creatives.

Once everything is configured, each pull request event triggers Gemini analysis
and posts a summary as a comment on the linked creative.

## 4. Manually trigger the webhook for local testing

You can simulate a GitHub delivery against your local server without waiting
for GitHub to send a real event. The helper script below generates a
fully-signed `curl` command using the webhook secret stored in your
credentials/environment.

```bash
script/github_webhook_curl --repo owner/repo "PR title" "PR description"
```

* `--repo` can be omitted if you have already linked a repository — the script
  picks the first `GithubRepositoryLink` it finds.
* Use `--number` to set the pull request number shown in the payload and
  `--action` to test other supported webhook actions (defaults to `opened`).
* Override the default URL (`http://localhost:3000/github/webhook`) with
  `--url` when tunnelling through a service like ngrok.

The script prints the command to run along with a valid `X-Hub-Signature-256`
header so the `Github::WebhooksController` accepts the request.
