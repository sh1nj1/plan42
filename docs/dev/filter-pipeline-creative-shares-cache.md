# Filter Pipeline 개선 계획: creative_shares_cache

## 목표

1. **핵심**: Filter Pipeline에서 사용자 권한 범위 내 필터링 성능 개선 (O(1) 권한 조회)
2. **URL 안정성**: 기존 Linked Creative (origin_id) `/creatives?id=` URL 접근 유지
3. **단순한 접근**: `creative_shares_caches` 테이블로 상속된 권한 미리 계산

**기반**: main 브랜치

**핵심 원칙**:
- `no_access`는 캐시에 저장하지 않음 → 캐시에 없으면 = 접근 불가
- sequence는 향후 추가 (현재 scope 외)

---

## 이전 상태

### PermissionChecker 동작 방식
```ruby
# 조상을 따라 올라가며 share 찾기 - O(depth) 복잡도
def allowed_on_tree?(node, required_permission)
  return true if node.user_id == user&.id

  current = node
  while current
    share = share_for(current)
    if share
      return false if share.permission.to_s == "no_access"
      if permission_rank(share.permission) >= permission_rank(required_permission)
        return true
      end
    end
    current = current.parent
  end
  false
end
```

### 문제점
- 권한 체크마다 조상 탐색 필요 (O(depth))
- Filter에서 대량 ID 필터링 시 느림
- 캐시가 요청 범위 내 메모리 캐시만 존재

---

## 새로운 설계

### 1. creative_shares_caches 테이블

```ruby
# Migration
create_table :creative_shares_caches do |t|
  t.references :creative, null: false, foreign_key: true
  t.references :user, null: true, foreign_key: true  # nil = public
  t.integer :permission, null: false
  t.references :source_share, null: false, foreign_key: { to_table: :creative_shares }
  t.timestamps
end

add_index :creative_shares_caches, [:creative_id, :user_id], unique: true
add_index :creative_shares_caches, [:user_id, :permission]
```

**스키마 설명:**
- `creative_id`: 권한이 적용되는 Creative
- `user_id`: 권한을 가진 사용자 (nil = public share)
- `permission`: 계산된 최종 권한 (no_access, read, feedback, write, admin)
- `source_share_id`: 이 권한의 원천이 되는 CreativeShare (추적용)

### 2. CreativeSharesCache 모델

```ruby
# app/models/creative_shares_cache.rb
class CreativeSharesCache < ApplicationRecord
  belongs_to :creative
  belongs_to :user, optional: true
  belongs_to :source_share, class_name: "CreativeShare"

  enum :permission, {
    no_access: 0,
    read: 1,
    feedback: 2,
    write: 3,
    admin: 4
  }
end
```

### 3. PermissionCacheBuilder 서비스

```ruby
# app/services/creatives/permission_cache_builder.rb
module Creatives
  class PermissionCacheBuilder
    # CreativeShare 생성/업데이트 시 호출
    def self.propagate_share(creative_share)
      # no_access는 캐시에 저장하지 않음 - 대신 기존 캐시 삭제
      if creative_share.no_access?
        descendant_ids = [creative.id] + creative.descendant_ids
        CreativeSharesCache.where(creative_id: descendant_ids, user_id: user_id).delete_all
        return
      end

      # 해당 creative + 모든 자손에 캐시 생성
      descendant_ids = [creative.id] + creative.descendant_ids
      descendant_ids.each do |cid|
        CreativeSharesCache.find_or_initialize_by(creative_id: cid, user_id: user_id)
          .update!(permission: permission, source_share_id: creative_share.id)
      end
    end

    # CreativeShare 삭제 시 호출
    def self.remove_share(creative_share)
      CreativeSharesCache.where(source_share_id: creative_share.id).delete_all
      rebuild_from_ancestors(creative_share.creative, creative_share.user_id)
    end

    # Creative parent_id 변경 시 호출
    def self.rebuild_for_creative(creative)
      descendant_ids = [creative.id] + creative.descendant_ids
      CreativeSharesCache.where(creative_id: descendant_ids).delete_all
      rebuild_from_ancestors_for_subtree(creative)
    end
  end
end
```

### 4. CreativeShare 콜백

```ruby
# app/models/creative_share.rb
after_commit :propagate_cache, on: [:create, :update]
before_destroy :remove_cache
```

### 5. Creative 콜백

```ruby
# app/models/creative.rb
after_commit :rebuild_permission_cache, if: :saved_change_to_parent_id?
```

### 6. PermissionChecker (O(1) 조회)

```ruby
# app/services/creatives/permission_checker.rb
def allowed?(required_permission = :read)
  base = creative.origin_id.nil? ? creative : creative.origin

  # 소유자 체크
  return true if base.user_id == user&.id

  # 캐시 테이블에서 O(1) 조회
  user_conditions = user ? [user.id, nil] : [nil]
  cache_entry = CreativeSharesCache
    .where(creative_id: base.id, user_id: user_conditions)
    .order(permission: :desc)
    .first

  return false unless cache_entry

  permission_rank(cache_entry.permission) >= permission_rank(required_permission)
end
```

### 7. FilterPipeline 서비스

```ruby
# app/services/creatives/filter_pipeline.rb
module Creatives
  class FilterPipeline
    Result = Struct.new(:matched_ids, :allowed_ids, :progress_map, :overall_progress, keyword_init: true)

    FILTERS = [
      Filters::ProgressFilter,
      Filters::TagFilter,
      Filters::SearchFilter
    ].freeze

    def call
      matched_ids = apply_filters
      allowed_ids = resolve_ancestors(matched_ids)
      allowed_ids = filter_by_permission(allowed_ids)  # O(1) 캐시 조회
      progress_map, overall = calculate_progress(allowed_ids, matched_ids)

      Result.new(matched_ids:, allowed_ids:, progress_map:, overall_progress: overall)
    end
  end
end
```

---

## 파일 구조

### 새 파일
| 파일 | 설명 |
|------|------|
| `db/migrate/xxx_create_creative_shares_cache.rb` | 테이블 생성 |
| `db/migrate/xxx_populate_creative_shares_cache.rb` | 기존 데이터 캐싱 |
| `app/models/creative_shares_cache.rb` | 모델 |
| `app/services/creatives/permission_cache_builder.rb` | 캐시 업데이트 로직 |
| `app/services/creatives/filter_pipeline.rb` | 필터 파이프라인 |
| `app/services/creatives/filters/base_filter.rb` | 필터 베이스 클래스 |
| `app/services/creatives/filters/progress_filter.rb` | 완료/미완료 필터 |
| `app/services/creatives/filters/tag_filter.rb` | 태그 필터 |
| `app/services/creatives/filters/search_filter.rb` | 검색 필터 |

### 수정 파일
| 파일 | 변경 내용 |
|------|----------|
| `app/models/creative_share.rb` | after_commit, before_destroy 콜백 추가 |
| `app/models/creative.rb` | parent_id 변경 시 콜백 추가 |
| `app/services/creatives/permission_checker.rb` | 캐시 테이블 사용 |

---

## 테스트

### 단위 테스트
- `test/services/creatives/permission_cache_builder_test.rb`
- `test/services/creatives/filter_pipeline_test.rb`
- `test/services/creatives/filters/progress_filter_test.rb`
- `test/services/creatives/filters/tag_filter_test.rb`
- `test/services/creatives/filters/search_filter_test.rb`

### 기존 테스트 업데이트
- `test/models/creative_permission_cache_test.rb` - 테이블 기반 캐시 테스트로 변경

---

## 검증 방법

1. `rails db:migrate` 실행
2. `rails test` 통과 확인
3. UI에서 share 생성/삭제 후:
   ```sql
   SELECT * FROM creative_shares_caches WHERE user_id = ?;
   ```
4. Filter 결과가 권한에 맞게 나오는지 확인
