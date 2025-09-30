# Permission Cache Configuration

The permission system uses application-wide caching to improve performance by avoiding repeated database queries for permission checks.

## Configuration

### Cache Expiry Time

The cache expiry time can be configured via the `PERMISSION_CACHE_EXPIRES_IN` environment variable.

**Default:** 7 days

**Supported formats:**
- `7.days` - Time duration format
- `24.hours` - Hours format  
- `30.minutes` - Minutes format
- `3600` - Raw seconds (numeric)

### Examples

```bash
# Set cache to expire in 3 days
export PERMISSION_CACHE_EXPIRES_IN="3.days"

# Set cache to expire in 12 hours
export PERMISSION_CACHE_EXPIRES_IN="12.hours" 

# Set cache to expire in 1 hour (3600 seconds)
export PERMISSION_CACHE_EXPIRES_IN="3600"
```

## How It Works

1. **Caching**: Permission results are stored in `Rails.cache` with keys like `creative_permission:#{creative_id}:#{user_id}:#{permission}`

2. **Inheritance**: Child creatives inherit permissions from parent creatives, and these results are cached independently

3. **Selective Invalidation**: When a `CreativeShare` is created, updated, or deleted, only the affected cache keys are cleared:
   - The specific creative + user combination (all permission levels)
   - All descendants of that creative + user (to handle inheritance)

4. **Performance**: Provides significant performance improvement for users with many creatives (estimated ~33-48KB memory usage per 1000 creatives per user)

## Cache Keys

Cache keys follow the format: `creative_permission:#{creative_id}:#{user_id}:#{permission}`

Examples:
- `creative_permission:123:456:read` 
- `creative_permission:123:456:write`
- `creative_permission:789:456:admin`

## Development

In development, you may want to use shorter cache times for testing:

```bash
export PERMISSION_CACHE_EXPIRES_IN="5.minutes"
```
