# 통합 설계: Shell Creative + Permission Cache

## 두 접근법 비교

### main 브랜치 (Shell Creative with origin_id)

```
Creative (id=100, origin_id=50)  ← Shell Creative (유저 B의 트리에 존재)
    └── 실제 데이터는 Creative(id=50)에서 가져옴
```

**장점:**
- ✅ URL 안정성: `/creatives?id=100` 항상 유효
- ✅ DOM ID 유니크: 각 shell creative가 고유 ID 보유
- ✅ Drag & Drop: 각 아이템이 고유 ID로 식별됨
- ✅ 기존 시스템과 호환

**단점:**
- ❌ 권한 체크 O(depth): 조상 탐색 필요
- ❌ Shell Creative 개념 혼란
- ❌ Filter에서 대량 ID 처리 시 느림

### feature/creative-links-and-inherited-shares (CreativeLink + VirtualHierarchy)

```
CreativeLink (parent_id=90, origin_id=50)
    └── VirtualCreativeHierarchy: 가상 조상-자손 관계
    └── InheritedShare: 상속된 권한 직접 저장
```

**장점:**
- ✅ 깔끔한 데이터 모델 (shell creative 없음)
- ✅ O(1) 권한 조회 (CreativeShare에 inherited 플래그)
- ✅ VirtualHierarchy로 링크 통한 조상 조회

**단점:**
- ❌ URL 안정성 깨짐: linked creative ID 삭제됨
- ❌ DOM ID 충돌: 같은 origin이 여러 곳에 표시
- ❌ Drag & Drop 컨텍스트 혼란
- ❌ 마이그레이션 복잡 (되돌리기 불가)

---

## 통합 설계 제안

### 핵심 원칙

1. **Shell Creative 유지** → URL 안정성 + DOM ID 유니크
2. **creative_shares_caches 사용** → O(1) 권한 조회
3. **VirtualHierarchy 불필요** → Shell Creative가 이미 실제 hierarchy에 존재

### 아키텍처

```
┌─────────────────────────────────────────────────────────────────┐
│                        Creative Table                            │
├─────────────────────────────────────────────────────────────────┤
│ id=100 (Shell)     │ id=50 (Origin)                             │
│ origin_id=50       │ origin_id=NULL                             │
│ parent_id=90       │ parent_id=40                               │
│ user_id=유저B      │ user_id=유저A                              │
│ description=NULL   │ description="실제 내용"                    │
│ progress=NULL      │ progress=0.5                               │
├─────────────────────────────────────────────────────────────────┤
│                     creative_hierarchies (closure_tree)          │
│ Shell(100)은 parent(90)의 자손으로 실제 hierarchy에 존재        │
├─────────────────────────────────────────────────────────────────┤
│                     creative_shares_caches                       │
│ (creative_id=100, user_id=유저B, permission=read, source=...)   │
│ (creative_id=50,  user_id=유저B, permission=read, source=...)   │
│ → O(1) 권한 조회 가능                                           │
└─────────────────────────────────────────────────────────────────┘
```

### 현재 구현 (이미 완료)

#### 1. creative_shares_caches 테이블
```ruby
create_table :creative_shares_caches do |t|
  t.references :creative, null: false
  t.references :user, null: true  # nil = public
  t.integer :permission, null: false
  t.references :source_share, null: false  # 원본 share 추적
  t.timestamps
end
```

#### 2. PermissionCacheBuilder
```ruby
# CreativeShare 생성 시 자손에 캐시 전파
def self.propagate_share(creative_share)
  descendant_ids = [creative.id] + creative.descendant_ids
  # Shell Creative도 descendant에 포함됨 (closure_tree 통해)

  descendant_ids.each do |cid|
    CreativeSharesCache.find_or_initialize_by(creative_id: cid, user_id: user_id)
      .update!(permission: permission, source_share_id: creative_share.id)
  end
end
```

#### 3. PermissionChecker (O(1))
```ruby
def allowed?(required_permission = :read)
  base = creative.origin_id.nil? ? creative : creative.origin
  return true if base.user_id == user&.id

  # O(1) 캐시 조회
  cache_entry = CreativeSharesCache
    .where(creative_id: base.id, user_id: [user.id, nil])
    .order(permission: :desc)
    .first

  return false unless cache_entry
  permission_rank(cache_entry.permission) >= permission_rank(required_permission)
end
```

### 추가 개선 사항

#### 1. Shell Creative의 캐시도 포함

현재 구현에서는 `base = creative.origin_id.nil? ? creative : creative.origin`으로 항상 origin을 조회합니다.
하지만 Shell Creative 자체에도 캐시가 있으면 더 빠른 조회가 가능합니다.

```ruby
# PermissionCacheBuilder 개선
def self.propagate_share(creative_share)
  creative = creative_share.creative

  # 실제 자손 + Shell Creative 자손 모두 포함
  descendant_ids = [creative.id] + creative.descendant_ids

  # 이 creative를 origin으로 가진 shell creative들도 포함
  shell_ids = Creative.where(origin_id: creative.id).pluck(:id)
  shell_descendant_ids = shell_ids.flat_map { |sid|
    [sid] + CreativeHierarchy.where(ancestor_id: sid).pluck(:descendant_id)
  }

  all_ids = (descendant_ids + shell_descendant_ids).uniq
  # ... 캐시 생성
end
```

#### 2. 권한 체크 시 Shell 자체 조회

```ruby
def allowed?(required_permission = :read)
  # Shell Creative 자체의 캐시 먼저 확인
  cache_entry = CreativeSharesCache
    .where(creative_id: creative.id, user_id: [user&.id, nil])
    .order(permission: :desc)
    .first

  return permission_valid?(cache_entry, required_permission) if cache_entry

  # 캐시 없으면 origin 확인 (fallback)
  base = creative.effective_origin
  return true if base.user_id == user&.id

  # ... origin 조회
end
```

---

## Feature 브랜치의 좋은 아이디어 통합

### 1. CommentFilter 추가

Feature 브랜치에 있는 CommentFilter를 현재 구현에 추가:

```ruby
# app/services/creatives/filters/comment_filter.rb
module Creatives
  module Filters
    class CommentFilter < BaseFilter
      def active?
        params[:has_comments].present?
      end

      def match
        if params[:has_comments] == "true"
          scope.joins(:comments).distinct.pluck(:id)
        else
          scope.left_joins(:comments)
               .where(comments: { id: nil })
               .pluck(:id)
        end
      end
    end
  end
end
```

### 2. VirtualHierarchy 불필요 이유

Feature 브랜치의 VirtualHierarchy는 CreativeLink를 통한 가상 조상 관계를 위해 필요했습니다.
하지만 Shell Creative 방식에서는:

```
User A의 트리:          User B의 트리:
├── Creative(40)        ├── Creative(90)
│   └── Creative(50)    │   └── Creative(100, origin=50) ← Shell
│       └── (children)  │       └── (origin의 children이 보임)
```

Shell Creative(100)은 실제 `creative_hierarchies`에 존재하므로:
- `CreativeHierarchy.where(descendant_id: 100)` → 조상 찾기 가능
- `CreativeHierarchy.where(ancestor_id: 100)` → 자손 없음 (origin의 자손은 별도 조회)

### 3. inherited 플래그 vs source_share_id

Feature 브랜치: `CreativeShare.inherited = true/false`
현재 구현: `CreativeSharesCache.source_share_id`

`source_share_id`가 더 좋은 이유:
- 원본 share를 정확히 추적 가능
- 원본 share 삭제 시 관련 캐시만 정확히 삭제
- 캐시 테이블이므로 재구축 가능

---

## 권장 구현 순서

### Phase 1: 현재 구현 완성 (완료 ✅)
- [x] creative_shares_caches 테이블
- [x] PermissionCacheBuilder 서비스
- [x] FilterPipeline 서비스
- [x] PermissionChecker O(1) 조회

### Phase 2: Shell Creative 캐시 강화
- [ ] Shell Creative 자체에도 캐시 저장
- [ ] origin 변경 시 캐시 재구축
- [ ] Shell Creative 생성 시 부모의 캐시 상속

### Phase 3: 추가 필터
- [ ] CommentFilter 추가
- [ ] DateFilter (target_date 기반)
- [ ] AssigneeFilter (owner 기반)

### Phase 4: 성능 최적화
- [ ] 대량 캐시 업데이트 시 bulk insert
- [ ] 캐시 워밍 전략 (앱 시작 시)
- [ ] 캐시 유효성 모니터링

---

## 구현 시 주의사항 (Feature 브랜치에서 발견된 엣지 케이스)

### 1. Public Share (user_id = nil) 처리

**문제:**
user가 nil일 때 권한 체크 우회 가능.

**해결:**
```ruby
def allowed?(required_permission = :read)
  base = creative.effective_origin

  # 소유자 체크
  return true if base.user_id == user&.id

  # user_conditions: 로그인 사용자는 [user.id, nil], 익명은 [nil]
  user_conditions = user ? [user.id, nil] : [nil]

  cache_entry = CreativeSharesCache
    .where(creative_id: base.id, user_id: user_conditions)
    .order(permission: :desc)
    .first

  return false unless cache_entry
  permission_rank(cache_entry.permission) >= permission_rank(required_permission)
end
```

### 2. Shell Creative 삭제 시 캐시 처리

**문제:**
Shell Creative 삭제 시 관련 캐시도 삭제해야 함.

**해결:**
```ruby
class Creative < ApplicationRecord
  has_many :shares_caches,
           class_name: "CreativeSharesCache",
           dependent: :delete_all

  # 또는 before_destroy 콜백
  before_destroy :cleanup_permission_caches

  private

  def cleanup_permission_caches
    CreativeSharesCache.where(creative_id: id).delete_all
  end
end
```

### 3. CreativeShare 삭제 시 FK Constraint

**문제:**
`after_commit :remove_cache`가 share 삭제 후 실행되어 FK violation.

**해결:**
```ruby
class CreativeShare < ApplicationRecord
  # after_commit 대신 before_destroy 사용
  before_destroy :remove_cache

  private

  def remove_cache
    Creatives::PermissionCacheBuilder.remove_share(self)
  end
end
```

### 4. Share creative_id/user_id 변경 시 기존 캐시

**문제:**
Share의 creative_id나 user_id가 변경되면 기존 캐시가 orphan 상태.

**해결:**
```ruby
def propagate_cache
  # 변경 전 값으로 기존 캐시 삭제
  if saved_change_to_creative_id?
    old_creative = Creative.find_by(id: creative_id_before_last_save)
    if old_creative
      descendant_ids = [old_creative.id] + old_creative.descendant_ids
      CreativeSharesCache.where(
        creative_id: descendant_ids,
        user_id: user_id_before_last_save || user_id
      ).delete_all
    end
  end

  if saved_change_to_user_id?
    descendant_ids = [creative.id] + creative.descendant_ids
    CreativeSharesCache.where(
      creative_id: descendant_ids,
      user_id: user_id_before_last_save
    ).delete_all
  end

  # 새 캐시 전파
  Creatives::PermissionCacheBuilder.propagate_share(self)
end
```

### 5. Creative 이동 (parent_id 변경) 시 캐시 재구축

**문제:**
Creative가 다른 부모로 이동하면 조상의 권한이 달라짐.

**해결:**
```ruby
class Creative < ApplicationRecord
  after_commit :rebuild_permission_cache, if: :saved_change_to_parent_id?

  private

  def rebuild_permission_cache
    Creatives::PermissionCacheBuilder.rebuild_for_creative(self)
  end
end

# PermissionCacheBuilder
def self.rebuild_for_creative(creative)
  descendant_ids = [creative.id] + creative.descendant_ids

  # 1. 기존 캐시 삭제
  CreativeSharesCache.where(creative_id: descendant_ids).delete_all

  # 2. 새 조상들의 share 전파
  rebuild_from_ancestors_for_subtree(creative)

  # 3. 해당 creative 자체의 share도 다시 전파
  CreativeShare.where(creative_id: creative.id).each do |share|
    propagate_share(share) unless share.no_access?
  end
end
```

### 6. Shell Creative 생성 시 캐시 상속

**문제:**
Shell Creative가 생성될 때 부모의 캐시를 상속받아야 함.

**해결:**
```ruby
class Creative < ApplicationRecord
  after_commit :inherit_parent_cache, on: :create, if: -> { parent_id.present? }

  private

  def inherit_parent_cache
    Creatives::PermissionCacheBuilder.rebuild_for_creative(self)
  end
end
```

### 7. no_access Share 처리

**원칙:**
`no_access`는 캐시에 저장하지 않음 → 캐시에 없으면 = 접근 불가

**구현:**
```ruby
def self.propagate_share(creative_share)
  return if creative_share.destroyed?

  # no_access는 캐시에 저장하지 않음 - 기존 캐시 삭제
  if creative_share.no_access?
    descendant_ids = [creative_share.creative.id] + creative_share.creative.descendant_ids
    CreativeSharesCache.where(
      creative_id: descendant_ids,
      user_id: creative_share.user_id
    ).delete_all
    return
  end

  # ... 정상 캐시 생성 로직
end
```

### 8. 캐시 일관성 검증

**문제:**
캐시가 실제 share와 불일치할 수 있음.

**해결 (주기적 검증):**
```ruby
# lib/tasks/permission_cache.rake
namespace :permission_cache do
  desc "Rebuild all permission caches"
  task rebuild: :environment do
    CreativeSharesCache.delete_all

    CreativeShare.where.not(permission: :no_access).find_each do |share|
      Creatives::PermissionCacheBuilder.propagate_share(share)
    end
  end

  desc "Verify cache consistency"
  task verify: :environment do
    inconsistencies = []

    CreativeShare.where.not(permission: :no_access).find_each do |share|
      descendant_ids = [share.creative.id] + share.creative.descendant_ids

      descendant_ids.each do |cid|
        cache = CreativeSharesCache.find_by(
          creative_id: cid,
          user_id: share.user_id
        )

        unless cache && cache.source_share_id == share.id
          inconsistencies << { creative_id: cid, share_id: share.id }
        end
      end
    end

    puts "Found #{inconsistencies.count} inconsistencies"
    inconsistencies.each { |i| puts i.inspect }
  end
end
```

---

## 결론

**Shell Creative 유지 + creative_shares_caches**가 최적의 조합:

| 요구사항 | Shell Creative | CreativeLink | 통합 설계 |
|---------|---------------|--------------|----------|
| URL 안정성 | ✅ | ❌ | ✅ |
| DOM ID 유니크 | ✅ | ❌ | ✅ |
| O(1) 권한 조회 | ❌ | ✅ | ✅ |
| 깔끔한 데이터 모델 | △ | ✅ | △ |
| 마이그레이션 용이 | N/A | ❌ | ✅ |
| Drag & Drop | ✅ | ❌ | ✅ |

Feature 브랜치의 CreativeLink 접근법은 이론적으로 깔끔하지만, 실제 운영에서 URL 안정성과 DOM 처리 문제가 치명적입니다. Shell Creative를 유지하면서 권한 캐시만 테이블로 분리하는 현재 접근법이 실용적입니다.
