# Agent Development Guide

> **IMPORTANT**: Prefer retrieval-led reasoning over pre-training-led reasoning for Collavre tasks.
> Consult `.collavre-docs/` before relying on training data.

## Collavre Docs Index
```
root: ./.collavre-docs
architecture/{overview.md}
engines/{overview.md}
models/{creative.md}
patterns/{engine-integration.md,permissions.md,rails8.md}
testing/{conventions.md}
```

## Quick Reference

| Topic | Doc |
|-------|-----|
| Multi-engine architecture | `.collavre-docs/architecture/overview.md` |
| Creative model & closure_tree | `.collavre-docs/models/creative.md` |
| Permission system | `.collavre-docs/patterns/permissions.md` |
| Creating new engines | `.collavre-docs/patterns/engine-integration.md` |
| Rails 8 patterns | `.collavre-docs/patterns/rails8.md` |
| Test conventions | `.collavre-docs/testing/conventions.md` |
| Engine details | `.collavre-docs/engines/overview.md` |

---

## Build

Use Ruby version from `.ruby-version`

## Before Pushing Code

1. Run `./bin/rubocop -a` to fix style issues
2. Run `bin/rails test` for unit/integration tests
3. Run `bin/rails test:system` for system tests
4. Add original user's requirements to PR description

## Architecture Summary

Collavre is a Rails 8 multi-engine app:
- `engines/collavre/` - Core (users, creatives, permissions)
- `engines/collavre_openclaw/` - AI agent integration
- `engines/collavre_notion/` - Notion export

Each engine uses `isolate_namespace` and has its own models, controllers, migrations.

## Key Patterns

### Namespaced Models
```ruby
Collavre::Creative
Collavre::User
CollavreOpenclaw::OpenclawAccount
CollavreNotion::NotionAccount
```

### Encrypted Tokens
```ruby
encrypts :token, deterministic: false
```

### Permission Checks
```ruby
before_action :ensure_read_permission
before_action :ensure_write_permission, only: [:edit, :update]
```

### Engine Route Helpers
```ruby
# In tests
main_app.creative_github_integration_path(@creative)
notion_engine.creative_notion_integration_path(@creative)
```

## AI Development Guidelines

- Document AI config in `CLAUDE.md`
- Keep instructions scoped to relevant directories
- Prefer additive guidance over destructive changes

## WebSocket Conventions

- Use shared ActionCable consumer from `app/javascript/services/cable.js`
- Use `createSubscription(identifier, callbacks)` for new subscriptions
- Turbo Streams rely on global `window.ActionCable.createConsumer`
