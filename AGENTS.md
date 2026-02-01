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

**모든 사용자 노출 텍스트는 반드시 i18n을 사용하고, EN/KO 두 언어 모두 작성해야 함.**

### 규칙

1. **하드코딩 금지**: 뷰, 플래시 메시지, 에러 메시지에 문자열 직접 사용 금지
2. **양쪽 언어 필수**: `config/locales/en.yml`과 `config/locales/ko.yml` 모두 작성
3. **엔진별 분리**: 각 엔진은 자체 locale 파일 사용 (`engines/<name>/config/locales/`)

### 예시

```erb
<%# Bad: 하드코딩 %>
<h1>Settings</h1>
<%= flash[:notice] = "Saved successfully" %>

<%# Good: i18n 사용 %>
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

### 엔진 i18n 구조

```
engines/collavre_openclaw/config/locales/
├── en.yml
└── ko.yml
```

### 체크리스트

| 항목 | 확인 |
|------|------|
| 모든 UI 텍스트가 `t()` 사용 | ✅ |
| en.yml 작성 완료 | ✅ |
| ko.yml 작성 완료 | ✅ |
| 키 네이밍 일관성 (snake_case) | ✅ |

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
