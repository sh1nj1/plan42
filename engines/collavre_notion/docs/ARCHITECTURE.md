# Notion Integration Architecture

This document describes the architecture and data flow of the CollavreNotion engine.

## Overview

The Notion integration exports Collavre creative trees to Notion pages and keeps linked pages in sync.

Key flows:

- **OAuth connection**: Connect a Notion workspace and store credentials.
- **Export**: Create a new Notion page from a creative tree.
- **Sync**: Update the linked Notion page when a creative changes.

## Data Models

### NotionAccount

Stores OAuth credentials and workspace metadata for a Collavre user.

| Column | Description |
|--------|-------------|
| `user_id` | Collavre user who connected Notion |
| `notion_uid` | Notion user ID |
| `workspace_name` | Notion workspace name |
| `workspace_id` | Notion workspace ID |
| `bot_id` | Notion bot ID |
| `token` | OAuth access token |
| `token_expires_at` | Token expiration (if present) |

### NotionPageLink

Links a Collavre creative to a Notion page.

| Column | Description |
|--------|-------------|
| `creative_id` | Linked creative |
| `notion_account_id` | Parent Notion account |
| `page_id` | Notion page ID |
| `page_title` | Notion page title |
| `page_url` | Notion page URL |
| `parent_page_id` | Optional parent page ID |
| `last_synced_at` | Last sync timestamp |

### NotionBlockLink

Tracks block IDs created in Notion for each creative node.

| Column | Description |
|--------|-------------|
| `notion_page_link_id` | Parent page link |
| `creative_id` | Linked creative |
| `block_id` | Notion block ID |
| `content_hash` | Hash of exported content |

## Key Services

### NotionClient

Low-level HTTP client for the Notion API (search, create, update, append blocks).

### NotionService

High-level orchestration for export/sync operations. It:

- Finds or creates `NotionPageLink`
- Builds Notion blocks via `NotionCreativeExporter`
- Updates page properties and blocks

### NotionCreativeExporter

Converts a creative tree into Notion-compatible blocks.

## Background Jobs

| Job | Purpose |
|-----|---------|
| `NotionExportJob` | Export creative to Notion (async) |
| `NotionSyncJob` | Sync creative updates to an existing Notion page |

## API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/notion/creatives/:id/notion_integration` | Integration status | 
| `PATCH` | `/notion/creatives/:id/notion_integration` | Export or sync | 
| `DELETE` | `/notion/creatives/:id/notion_integration` | Remove link(s) | 
| `GET/POST` | `/auth/notion/callback` | OAuth callback | 
