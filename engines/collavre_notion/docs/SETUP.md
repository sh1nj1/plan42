# Notion Integration Setup

This guide walks through configuring the Notion integration for Collavre.

## 1. Create a Notion Integration

1. Visit [Notion Integrations](https://www.notion.so/my-integrations).
2. Click **New integration**.
3. Provide a name (e.g., "Collavre") and select the workspace.
4. Copy the **Internal Integration Token** if you need it for testing; production uses OAuth.

## 2. Configure OAuth

1. In the integration settings, enable **OAuth**.
2. Add the redirect URL:

```
https://<your-domain>/auth/notion/callback
```

3. Save the **Client ID** and **Client Secret**.

## 3. Configure Environment Variables

Set the following variables in your deployment environment:

- `NOTION_CLIENT_ID`
- `NOTION_CLIENT_SECRET`

## 4. Share Pages with the Integration

Notion only exposes pages that have been shared with the integration:

1. Open the target Notion page.
2. Click **Share**.
3. Invite your integration.

## 5. Verify in Collavre

1. Open a creative.
2. Select **Integrations → Notion**.
3. Sign in and connect your workspace.
4. Export or sync the creative to confirm everything works.
