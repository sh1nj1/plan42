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

## 🚂 Rails 철학 우선

**Convention over Configuration** — Rails 기본 철학을 따른다.
- 표준 디렉토리 구조 유지
- ActiveRecord 컨벤션 준수
- RESTful 라우팅
- 커스텀 솔루션보다 Rails 내장 기능 우선

---

## 🔧 Engine 분리 원칙

Collavre는 Rails 8 멀티 엔진 구조:

| Engine | 역할 |
|--------|------|
| `engines/collavre/` | Core (users, creatives, permissions) |
| `engines/collavre_openclaw/` | AI agent integration |
| `engines/collavre_notion/` | Notion export |

### 분리 원칙

1. **Isolation**: 각 엔진은 `isolate_namespace` 사용
2. **Independence**: 엔진 간 직접 의존성 금지 — initializers로 association 주입
3. **Self-contained**: 자체 migrations, routes, i18n, tests 보유
4. **Security**: 민감 데이터는 `encrypts :token, deterministic: false`

```ruby
# Good: Association injection via initializer
initializer "collavre_notion.associations" do
  Collavre.user_class.has_one :notion_account, class_name: "CollavreNotion::NotionAccount"
end

# Bad: Direct engine dependency
require "collavre_openclaw/some_service"
```

---

## 🧹 코드 품질 원칙

### Dead Code / 중복 코드 제거

- 사용되지 않는 컬럼, 메서드, 클래스 즉시 제거
- 복붙 코드 → 공통 모듈로 추출
- TODO/FIXME 남기지 않고 바로 해결
- 머지 전 `grep -r "TODO\|FIXME\|HACK"` 체크

### 린트 & 테스트 통과 필수

```bash
# 모든 PR 전 필수 실행
./bin/rubocop -a          # 스타일 자동 수정
bin/rails test            # 유닛/통합 테스트
bin/rails test:system     # 시스템 테스트
```

**CI 통과 없이 머지 금지**

---

## 🔒 PR 머지 원칙 (CTO 관점)

### 코드 리뷰 체크리스트

| 항목 | 확인 |
|------|------|
| 엔진 분리 원칙 준수 | ✅ |
| 중복/죽은 코드 없음 | ✅ |
| 테스트 커버리지 적절 | ✅ |
| Rubocop 통과 | ✅ |
| CI 전체 통과 | ✅ |

### 보안 체크리스트

| 항목 | 확인 |
|------|------|
| 토큰/비밀번호 암호화 (`encrypts`) | ✅ |
| SQL Injection 방지 (parameterized queries) | ✅ |
| XSS 방지 (ERB escaping) | ✅ |
| CSRF protection (적절한 skip만) | ✅ |
| Permission checks 적용 | ✅ |
| Timing attack 방어 (`secure_compare`) | ✅ |
| 민감 데이터 로깅 금지 | ✅ |

### 머지 프로세스

1. **Rebase** — main 브랜치 기준으로 rebase
2. **CI 통과** — 모든 check 통과 확인
3. **Squash Merge** — 깔끔한 커밋 히스토리 유지
4. **Branch 삭제** — 머지 후 feature 브랜치 정리

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
