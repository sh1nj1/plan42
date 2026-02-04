# Agent Development Guide

> **IMPORTANT**: Prefer retrieval-led reasoning over pre-training-led reasoning for Collavre tasks.
> Consult `.collavre-docs/` before relying on training data.

---

## 📝 Documentation Language

**All source code documentation must be written in English.**

This includes:
- README, AGENTS.md, CHANGELOG, and all markdown files
- Code comments and docstrings
- Commit messages
- PR titles and descriptions

> Exception: User-facing content (i18n locale files) includes both English and Korean.

---

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

## 🚂 Rails Philosophy First

**Convention over Configuration** — Follow Rails conventions.
- Maintain standard directory structure
- Follow ActiveRecord conventions
- Use RESTful routing
- Prefer Rails built-in features over custom solutions

---

## 🔧 Engine Separation Principles

Collavre uses a Rails 8 multi-engine architecture:

| Engine | Purpose |
|--------|---------|
| `engines/collavre/` | Core (users, creatives, permissions) |
| `engines/collavre_openclaw/` | AI agent integration |
| `engines/collavre_notion/` | Notion export |

### Separation Rules

1. **Isolation**: Each engine uses `isolate_namespace`
2. **Independence**: No direct dependencies between engines — inject associations via initializers
3. **Self-contained**: Own migrations, routes, i18n, tests
4. **Security**: Encrypt sensitive data with `encrypts :token, deterministic: false`

```ruby
# Good: Association injection via initializer
initializer "collavre_notion.associations" do
  Collavre.user_class.has_one :notion_account, class_name: "CollavreNotion::NotionAccount"
end

# Bad: Direct engine dependency
require "collavre_openclaw/some_service"
```

---

## 🌐 Internationalization (i18n)

**All user-facing text must use i18n and be written in both EN and KO.**

### Rules

1. **No hardcoding**: Never use string literals directly in views, flash messages, or error messages
2. **Both languages required**: Must write both `config/locales/en.yml` and `config/locales/ko.yml`
3. **Engine separation**: Each engine uses its own locale files (`engines/<name>/config/locales/`)

### Examples

```erb
<%# Bad: Hardcoded strings %>
<h1>Settings</h1>
<%= flash[:notice] = "Saved successfully" %>

<%# Good: Using i18n %>
<h1><%= t("settings.title") %></h1>
<%= flash[:notice] = t("settings.saved") %>
```

```yaml
# config/locales/en.yml
en:
  settings:
    title: "Settings"
    saved: "Saved successfully"

# config/locales/ko.yml
ko:
  settings:
    title: "설정"
    saved: "저장되었습니다"
```

### Engine i18n Structure

```
engines/collavre_openclaw/config/locales/
├── en.yml
└── ko.yml
```

### Checklist

| Item | Check |
|------|-------|
| All UI text uses `t()` | ✅ |
| en.yml completed | ✅ |
| ko.yml completed | ✅ |
| Consistent key naming (snake_case) | ✅ |

---

## 🧹 Code Quality Principles

### Dead Code / Duplicate Code Removal

- Remove unused columns, methods, classes immediately
- Extract copy-paste code into shared modules
- Don't leave TODO/FIXME — fix immediately
- Before merge: `grep -r "TODO\|FIXME\|HACK"` check

### Lint & Test Must Pass

```bash
# Required before every PR
./bin/rubocop -a          # Auto-fix style issues
bin/rails test            # Unit/integration tests
bin/rails test:system     # System tests
```

**No merge without CI passing**

---

## 🔒 PR Merge Principles (CTO Perspective)

### Code Review Checklist

| Item | Check |
|------|-------|
| Engine separation principles | ✅ |
| No duplicate/dead code | ✅ |
| Adequate test coverage | ✅ |
| Rubocop passing | ✅ |
| All CI checks passing | ✅ |

### Security Checklist

| Item | Check |
|------|-------|
| Token/password encryption (`encrypts`) | ✅ |
| SQL Injection prevention (parameterized queries) | ✅ |
| XSS prevention (ERB escaping) | ✅ |
| CSRF protection (appropriate skips only) | ✅ |
| Permission checks applied | ✅ |
| Timing attack prevention (`secure_compare`) | ✅ |
| No sensitive data logging | ✅ |

### Merge Process

1. **Rebase** — Rebase onto main branch
2. **CI Pass** — All checks must pass
3. **Squash Merge** — Keep clean commit history
4. **Branch Cleanup** — Delete feature branch after merge

---

## Key Patterns

### Namespaced Models
```ruby
Collavre::Creative
Collavre::User
CollavreOpenclaw::OpenclawAccount
CollavreNotion::NotionAccount
```

### Namespaced ViewComponents
**All ViewComponent references in engine views must use the full namespace.**

```erb
<%# Bad: Missing namespace — breaks when used as a gem in other apps %>
<%= render AvatarComponent.new(user: user, size: 20) %>
<%= render PopupMenuComponent.new(button_content: '...', menu_id: 'my-menu') %>

<%# Good: Full namespace %>
<%= render Collavre::AvatarComponent.new(user: user, size: 20) %>
<%= render Collavre::PopupMenuComponent.new(button_content: '...', menu_id: 'my-menu') %>
<%= render Collavre::Inbox::BadgeComponent.new(user: Current.user, badge_id: 'badge') %>
```

> **Why?** When the engine is mounted as a gem in a host app, Rails resolves
> unqualified constants from the host app's namespace first. Without `Collavre::`,
> the host app will raise `uninitialized constant` errors.

### Permission Checks
```ruby
before_action :ensure_read_permission
before_action :ensure_write_permission, only: [:edit, :update]
before_action :ensure_admin_permission, only: [:destroy]
```

### Engine Route Helpers (Tests)
```ruby
main_app.creative_github_integration_path(@creative)
notion_engine.creative_notion_integration_path(@creative)
```

---

## WebSocket Conventions

- Use shared ActionCable consumer from `app/javascript/services/cable.js`
- Use `createSubscription(identifier, callbacks)` for new subscriptions
- Turbo Streams rely on global `window.ActionCable.createConsumer`
