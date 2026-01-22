# Notion Integration

The Notion integration allows users to export their creative trees to Notion pages, keeping their project structure synchronized between the application and Notion workspace.

## Features

- **OAuth Authentication**: Secure authentication with Notion using OAuth 2.0
- **Creative Export**: Export creative trees as structured Notion pages with headings and bullet points
- **Tree Structure Mapping**: Maintains hierarchical structure from creatives to Notion blocks
- **Progress Tracking**: Optional export of completion percentages
- **Synchronization**: Update existing Notion pages when creative content changes
- **Multi-page Support**: Link multiple Notion pages to a single creative

## Architecture

### Models

- `NotionAccount`: Stores user's Notion OAuth credentials and workspace information
- `NotionPageLink`: Links creatives to specific Notion pages, tracks sync status

### Services

- `NotionClient`: Low-level HTTP client for Notion API interactions
- `NotionService`: High-level service for managing Notion operations with error handling
- `NotionCreativeExporter`: Converts creative tree structures to Notion block format

### Controllers

- `NotionAuthController`: Handles OAuth callback from Notion
- `Creatives::NotionIntegrationsController`: Manages integration CRUD operations

### Background Jobs

- `NotionExportJob`: Asynchronous creative export to Notion
- `NotionSyncJob`: Synchronizes existing Notion pages with creative updates

## Setup

### 1. Notion App Configuration

1. Create a new integration at https://www.notion.so/my-integrations
2. Set the redirect URI to: `https://yourdomain.com/auth/notion/callback`
3. Request the following capabilities:
   - Read content
   - Update content and comments
   - Insert content

### 2. Environment Configuration

Add your Notion OAuth credentials:

```ruby
# config/credentials.yml.enc
notion:
  client_id: your_notion_client_id
  client_secret: your_notion_client_secret
```

Or use environment variables:
```bash
NOTION_CLIENT_ID=your_notion_client_id
NOTION_CLIENT_SECRET=your_notion_client_secret
```

### 3. Database Migration

The integration requires two new tables:

```bash
rails db:migrate
```

This creates:
- `notion_accounts` table for storing user OAuth tokens
- `notion_page_links` table for creative-to-page relationships

## Usage

### User Workflow

1. **Connect Account**: User clicks "Notion" in the integrations menu
2. **OAuth Flow**: User authorizes the application with their Notion account
3. **Export Creative**: User selects export options (new page or subpage)
4. **Background Processing**: Export job creates structured Notion page
5. **Sync Updates**: User can sync changes back to Notion

### Export Format

Creatives are exported as structured Notion blocks:

- **Levels 1-3**: Converted to Notion headings (heading_1, heading_2, heading_3)
- **Levels 4+**: Converted to bulleted list items
- **Progress**: Optionally appended as percentages
- **Rich Content**: Images and attachments are referenced

## API Integration

### Notion API Endpoints Used

- `POST /v1/pages` - Create new pages
- `PATCH /v1/pages/{page_id}` - Update page properties  
- `GET /v1/blocks/{block_id}/children` - Retrieve page blocks
- `PATCH /v1/blocks/{block_id}/children` - Update page content
- `POST /v1/search` - Search for pages (future feature)

### Rate Limiting

The Notion API has rate limits:
- 3 requests per second average
- Burst allowance up to 10 requests

The integration handles rate limiting with:
- Background job processing
- Exponential backoff on 429 responses
- Queue-based processing for bulk operations

## Error Handling

### Authentication Errors
- **401 Unauthorized**: Token expired or invalid - user needs to re-authenticate
- **403 Forbidden**: Insufficient permissions - check integration capabilities

### API Errors  
- **400 Bad Request**: Invalid block structure or content
- **404 Not Found**: Page deleted or access revoked
- **429 Rate Limited**: Automatic retry with backoff

### Connection Errors
- Network timeouts: 30-second timeout with retry
- Service unavailable: Graceful degradation

## Testing

### Model Tests
```bash
rails test test/models/notion_account_test.rb
rails test test/models/notion_page_link_test.rb
```

### Controller Tests
```bash
rails test test/controllers/creatives/notion_integrations_controller_test.rb
```

### Service Tests
```bash
rails test test/services/notion_creative_exporter_test.rb
```

### Manual Testing

1. Set up test Notion workspace
2. Configure OAuth credentials
3. Create test creatives with various content types
4. Test export and sync workflows
5. Verify block structure in Notion

## Security Considerations

### Token Storage
- OAuth tokens encrypted at rest
- Tokens include workspace scope limitations
- Automatic token refresh handling

### Data Privacy
- Only exports explicitly selected creatives
- Respects creative permission levels
- No access to other Notion workspace content

### API Security
- HTTPS-only communication
- CSRF protection on endpoints
- User permission validation

## Monitoring

### Logging
- OAuth authentication events
- Export/sync job status
- API error responses
- Rate limiting incidents

### Metrics
- Export success/failure rates
- API response times
- Active integration count
- Sync frequency patterns

## Future Enhancements

### Planned Features
- **Bi-directional Sync**: Import changes from Notion back to creatives
- **Bulk Export**: Export multiple creative trees at once
- **Template Support**: Use Notion page templates for exports
- **Database Integration**: Export as Notion databases instead of pages
- **Real-time Sync**: WebSocket-based live synchronization

### API Improvements
- **Notion AI Integration**: Use Notion AI for content enhancement
- **Formula Support**: Export calculated fields and formulas
- **Relation Mapping**: Link related creatives across pages
- **Version History**: Track and compare changes over time

## Troubleshooting

### Common Issues

**"Not connected" error**
- Check OAuth configuration
- Verify redirect URI matches exactly
- Ensure user completed auth flow

**Export fails silently**
- Check background job queue
- Verify Notion workspace permissions
- Review application logs for errors

**Sync not updating**
- Confirm page still exists in Notion
- Check if user revoked integration access
- Verify creative permissions haven't changed

### Debug Mode

Enable debug logging for detailed API interaction logs:

```ruby
# In development.rb or production.rb
Rails.logger.level = :debug
```

This logs all Notion API requests, responses, and timing information.
