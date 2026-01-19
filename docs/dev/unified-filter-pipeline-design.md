# 통합 Filter Pipeline 설계

## 현재 문제점

### IndexQuery의 분산된 필터 로직

```ruby
# 현재 main 브랜치
def resolve_creatives
  if params[:comment] == "true"
    # 코멘트 필터 - 자체 로직
    creatives = Creative.joins(:comments)...
    # 권한: select { |c| readable?(c) }
    # 조상: 없음
    # Progress: 없음

  elsif params[:search].present?
    # 검색 필터 - 또 다른 로직
    search_creatives  # 복잡한 UNION 쿼리
    # 권한: select { |c| readable?(c) }
    # 조상: 부분적
    # Progress: 없음

  elsif params[:tags].present?
    # 태그 필터 - filter_by_tags 메서드
    # 권한: has_permission?(user, :read)
    # 조상: CreativeHierarchy 사용
    # Progress: calculate_progress_map

  elsif params[:id]
    # ID 조회 - children_with_permission

  else
    # 루트 조회
  end
end
```

### 문제점 요약

| 문제 | 설명 |
|------|------|
| 필터 조합 불가 | 태그 + 검색 + 완료 상태 동시 적용 안됨 |
| 권한 체크 불일치 | `readable?`, `has_permission?`, `select` 혼재 |
| 조상 해석 불일치 | 필터별로 조상 포함 로직 다름 |
| Progress 계산 불일치 | 태그 필터만 progress_map 계산 |
| O(n) 권한 체크 | 결과마다 개별 권한 체크 |

---

## 통합 설계

### 아키텍처

```
┌─────────────────────────────────────────────────────────────────┐
│                         IndexQuery                               │
│  - 진입점, 결과 포맷팅                                           │
│  - FilterPipeline 호출                                           │
└────────────────────────────┬────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│                       FilterPipeline                             │
│  1. apply_filters() → 모든 필터 교집합                           │
│  2. resolve_ancestors() → 조상 포함                              │
│  3. filter_by_permission() → O(1) 권한 체크                      │
│  4. calculate_progress() → progress map                          │
└────────────────────────────┬────────────────────────────────────┘
                             │
        ┌────────────────────┼────────────────────┐
        ▼                    ▼                    ▼
┌──────────────┐    ┌──────────────┐    ┌──────────────┐
│ ProgressFilter│    │  TagFilter   │    │ SearchFilter │
│ (완료/미완료) │    │   (태그)     │    │    (검색)    │
└──────────────┘    └──────────────┘    └──────────────┘
        │                    │                    │
        ▼                    ▼                    ▼
┌──────────────┐    ┌──────────────┐    ┌──────────────┐
│CommentFilter │    │  DateFilter  │    │AssigneeFilter│
│  (코멘트)    │    │   (일정)     │    │   (담당자)   │
└──────────────┘    └──────────────┘    └──────────────┘
```

### 핵심 원칙

1. **모든 필터가 FilterPipeline 통과**
2. **필터는 조합 가능** (교집합)
3. **권한은 creative_shares_caches로 O(1) 체크**
4. **조상 해석은 항상 동일한 로직**

---

## 구현 상세

### 1. FilterPipeline (개선)

```ruby
# app/services/creatives/filter_pipeline.rb
module Creatives
  class FilterPipeline
    Result = Struct.new(
      :matched_ids,      # 필터에 직접 매칭된 ID
      :allowed_ids,      # 조상 포함 + 권한 필터링된 ID
      :progress_map,     # ID → progress 맵
      :overall_progress, # 전체 평균 progress
      keyword_init: true
    )

    FILTERS = [
      Filters::ProgressFilter,  # 완료/미완료
      Filters::TagFilter,       # 태그
      Filters::SearchFilter,    # 검색 (description, comments)
      Filters::CommentFilter,   # 코멘트 유무
      Filters::DateFilter,      # target_date 기반
      Filters::AssigneeFilter,  # owner 기반
    ].freeze

    def initialize(user:, params:, scope:)
      @user = user
      @params = params.respond_to?(:to_h) ? params.to_h.with_indifferent_access : params
      @scope = scope
    end

    def call
      matched_ids = apply_filters
      return empty_result if matched_ids.empty?

      allowed_ids = resolve_ancestors(matched_ids)
      allowed_ids = filter_by_permission(allowed_ids)

      progress_map, overall = calculate_progress(allowed_ids, matched_ids)

      Result.new(
        matched_ids: matched_ids.to_set,
        allowed_ids: allowed_ids.map(&:to_s).to_set,
        progress_map: progress_map,
        overall_progress: overall
      )
    end

    def any_filter_active?
      FILTERS.any? { |klass| klass.new(params: params, scope: scope).active? }
    end

    private

    attr_reader :user, :params, :scope

    def apply_filters
      active_filters = FILTERS
        .map { |klass| klass.new(params: params, scope: scope) }
        .select(&:active?)

      return scope.pluck(:id) if active_filters.empty?

      # 모든 필터의 교집합
      matched_sets = active_filters.map { |f| f.match.to_set }
      matched_sets.reduce(:&).to_a
    end

    def resolve_ancestors(matched_ids)
      ancestor_ids = CreativeHierarchy
        .where(descendant_id: matched_ids)
        .pluck(:ancestor_id)

      (matched_ids + ancestor_ids).uniq
    end

    def filter_by_permission(ids)
      user_conditions = user ? [user.id, nil] : [nil]

      # O(1) 캐시 테이블 조회
      accessible_ids = CreativeSharesCache
        .where(creative_id: ids, user_id: user_conditions)
        .pluck(:creative_id)

      # 소유한 Creative 포함
      owned_ids = user ? Creative.where(id: ids, user_id: user.id).pluck(:id) : []

      (accessible_ids + owned_ids).uniq
    end

    def calculate_progress(allowed_ids, matched_ids)
      creatives = Creative.where(id: allowed_ids).pluck(:id, :progress)
      progress_map = creatives.to_h { |id, p| [id.to_s, p || 0.0] }

      matched = creatives.select { |id, _| matched_ids.include?(id) }
      overall = matched.any? ? matched.sum { |_, p| p || 0.0 } / matched.size : 0.0

      [progress_map, overall]
    end

    def empty_result
      Result.new(
        matched_ids: Set.new,
        allowed_ids: Set.new,
        progress_map: {},
        overall_progress: 0.0
      )
    end
  end
end
```

### 2. 개선된 필터들

```ruby
# app/services/creatives/filters/base_filter.rb
module Creatives
  module Filters
    class BaseFilter
      def initialize(params:, scope:)
        @params = params
        @scope = scope
      end

      def active?
        raise NotImplementedError
      end

      def match
        raise NotImplementedError
      end

      private

      attr_reader :params, :scope
    end
  end
end

# app/services/creatives/filters/progress_filter.rb
class ProgressFilter < BaseFilter
  def active?
    params[:progress_filter].present? ||
    params[:min_progress].present? ||
    params[:max_progress].present?
  end

  def match
    result = scope

    case params[:progress_filter]
    when "completed"
      result = result.where("progress >= ?", 1.0)
    when "incomplete"
      result = result.where("progress < ?", 1.0)
    end

    if params[:min_progress].present?
      result = result.where("progress >= ?", params[:min_progress].to_f)
    end

    if params[:max_progress].present?
      result = result.where("progress <= ?", params[:max_progress].to_f)
    end

    result.pluck(:id)
  end
end

# app/services/creatives/filters/search_filter.rb
class SearchFilter < BaseFilter
  def active?
    params[:search].present?
  end

  def match
    query = "%#{sanitize_like(params[:search])}%"

    # description 또는 comments.content 검색
    scope
      .left_joins(:comments)
      .where("creatives.description LIKE :q OR comments.content LIKE :q", q: query)
      .distinct
      .pluck(:id)
  end

  private

  def sanitize_like(str)
    str.gsub(/[%_]/) { |m| "\\#{m}" }
  end
end

# app/services/creatives/filters/comment_filter.rb
class CommentFilter < BaseFilter
  def active?
    params[:has_comments].present? || params[:comment].present?
  end

  def match
    has_comments = params[:has_comments] == "true" || params[:comment] == "true"

    if has_comments
      scope.joins(:comments).distinct.pluck(:id)
    else
      scope.left_joins(:comments).where(comments: { id: nil }).pluck(:id)
    end
  end
end

# app/services/creatives/filters/date_filter.rb
class DateFilter < BaseFilter
  def active?
    params[:due_before].present? || params[:due_after].present? || params[:has_due_date].present?
  end

  def match
    # Label의 target_date 기반 필터링
    result = scope.joins(:tags).joins("INNER JOIN labels ON tags.label_id = labels.id")

    if params[:has_due_date] == "true"
      result = result.where.not(labels: { target_date: nil })
    elsif params[:has_due_date] == "false"
      # target_date가 없는 creative
      return scope.left_joins(tags: :label)
                  .where(labels: { target_date: nil })
                  .or(scope.left_joins(:tags).where(tags: { id: nil }))
                  .pluck(:id)
    end

    if params[:due_before].present?
      result = result.where("labels.target_date <= ?", Date.parse(params[:due_before]))
    end

    if params[:due_after].present?
      result = result.where("labels.target_date >= ?", Date.parse(params[:due_after]))
    end

    result.distinct.pluck(:id)
  end
end

# app/services/creatives/filters/assignee_filter.rb
class AssigneeFilter < BaseFilter
  def active?
    params[:assignee_id].present? || params[:unassigned].present?
  end

  def match
    if params[:unassigned] == "true"
      # owner가 없는 Label을 가진 creative
      scope.left_joins(tags: :label)
           .where(labels: { owner_id: nil })
           .or(scope.left_joins(:tags).where(tags: { id: nil }))
           .pluck(:id)
    else
      assignee_ids = Array(params[:assignee_id])
      scope.joins(tags: :label)
           .where(labels: { owner_id: assignee_ids })
           .distinct
           .pluck(:id)
    end
  end
end
```

### 3. IndexQuery 단순화

```ruby
# app/services/creatives/index_query.rb
module Creatives
  class IndexQuery
    Result = Struct.new(
      :creatives,
      :parent_creative,
      :shared_creative,
      :shared_list,
      :overall_progress,
      :allowed_creative_ids,
      :progress_map,
      keyword_init: true
    )

    def initialize(user:, params: {})
      @user = user
      @params = params.with_indifferent_access
    end

    def call
      result = resolve_creatives
      shared_creative = result[:parent] || result[:creatives]&.first
      shared_list = shared_creative ? shared_creative.all_shared_users : []

      Result.new(
        creatives: result[:creatives],
        parent_creative: result[:parent],
        shared_creative: shared_creative,
        shared_list: shared_list,
        overall_progress: result[:overall_progress] || 0,
        allowed_creative_ids: result[:allowed_ids],
        progress_map: result[:progress_map]
      )
    end

    private

    attr_reader :user, :params

    def resolve_creatives
      scope = determine_scope
      pipeline = FilterPipeline.new(user: user, params: params, scope: scope)

      if pipeline.any_filter_active?
        handle_filtered_query(pipeline)
      elsif params[:id]
        handle_id_query
      else
        handle_root_query
      end
    end

    def determine_scope
      if params[:id]
        base = Creative.find_by(id: params[:id])&.effective_origin
        base ? base.descendants : Creative.none
      else
        Creative.where(origin_id: nil)  # 실제 creative만 (shell 제외)
      end
    end

    def handle_filtered_query(pipeline)
      result = pipeline.call

      return empty_result if result.matched_ids.empty?

      start_nodes = determine_start_nodes(result.allowed_ids)
      parent = params[:id] ? Creative.find_by(id: params[:id]) : nil

      {
        creatives: start_nodes,
        parent: parent,
        allowed_ids: result.allowed_ids,
        overall_progress: result.overall_progress,
        progress_map: result.progress_map
      }
    end

    def handle_id_query
      creative = Creative.find_by(id: params[:id])
      return empty_result unless creative && accessible?(creative)

      {
        creatives: creative.children_with_permission(user, :read),
        parent: creative,
        allowed_ids: nil,
        overall_progress: nil,
        progress_map: nil
      }
    end

    def handle_root_query
      {
        creatives: Creative.where(user: user).roots,
        parent: nil,
        allowed_ids: nil,
        overall_progress: nil,
        progress_map: nil
      }
    end

    def determine_start_nodes(allowed_ids)
      allowed_set = allowed_ids.to_set

      if params[:id]
        parent = Creative.find_by(id: params[:id])
        parent&.children&.select { |c| allowed_set.include?(c.id.to_s) } || []
      else
        Creative.where(id: allowed_ids.map(&:to_i))
                .reject { |c| c.ancestor_ids.any? { |aid| allowed_set.include?(aid.to_s) } }
      end
    end

    def accessible?(creative)
      creative.user == user || creative.has_permission?(user, :read)
    end

    def empty_result
      { creatives: [], parent: nil, allowed_ids: Set.new, overall_progress: 0, progress_map: {} }
    end
  end
end
```

---

## 필터 조합 예시

### Before (현재)
```
# 태그 + 검색 동시 적용 불가
params[:tags] = [1, 2]
params[:search] = "foo"
# → search가 무시되거나 tags가 무시됨
```

### After (통합)
```
# 모든 필터 조합 가능
params = {
  tags: [1, 2],
  search: "foo",
  progress_filter: "incomplete",
  has_comments: "true"
}
# → 태그 1 또는 2 AND "foo" 포함 AND 미완료 AND 코멘트 있음
```

---

## 마이그레이션 계획

### Phase 1: 현재 구현 유지하며 병행 (완료 ✅)
- [x] FilterPipeline 생성
- [x] 기본 필터 구현 (Progress, Tag, Search)
- [x] creative_shares_caches 테이블

### Phase 2: 추가 필터 구현
- [ ] CommentFilter
- [ ] DateFilter
- [ ] AssigneeFilter

### Phase 3: IndexQuery 리팩토링
- [ ] resolve_creatives 통합
- [ ] 개별 필터 분기 제거
- [ ] FilterPipeline 전면 사용

### Phase 4: 컨트롤러/뷰 업데이트
- [ ] CSR 최적화 (HTML/JSON 분리)
- [ ] `any_filter_active?` 헬퍼 추가
- [ ] 필터 결과에 `expires_now` 호출
- [ ] 뷰에서 필터 파라미터만 전달

### Phase 5: TreeBuilder 단순화
- [ ] `skip_creative?` 로직을 FilterPipeline에 위임
- [ ] 중복 필터 로직 제거

### Phase 6: JavaScript 개선
- [ ] expansion_controller.js ID 추출 로직 강화
- [ ] tree_renderer.js 정리

---

## Feature 브랜치에서 가져올 좋은 변경사항

`feature/creative-links-and-inherited-shares` 브랜치에는 CreativeLink (URL 안정성 문제)를 제외하고
가져올 만한 좋은 개선사항들이 있음.

### 1. 컨트롤러 CSR 최적화 (HTML/JSON 분리)

**변경 내용:**
HTML 요청 시 전체 트리 쿼리를 스킵하고 CSR(Client-Side Rendering)로 JSON 요청 시에만
데이터 로딩.

```ruby
# app/controllers/creatives_controller.rb
def index
  respond_to do |format|
    format.html do
      # HTML은 parent_creative만 필요 (nav/title 용)
      if params[:id].present?
        creative = Creative.find_by(id: params[:id])
        @parent_creative = creative if creative&.has_permission?(Current.user, :read)
      end
      @creatives = []  # CSR이 JSON으로 가져옴
      @shared_list = @parent_creative ? @parent_creative.all_shared_users : []
    end
    format.json do
      # 전체 쿼리는 JSON 요청 시에만
      # ... 기존 쿼리 로직 ...
    end
  end
end
```

**장점:**
- HTML 페이지 초기 로딩 속도 개선
- 불필요한 DB 쿼리 감소
- 필터 결과에 대해 `expires_now` 호출로 캐시 방지

### 2. TreeBuilder 단순화

**변경 내용:**
`skip_creative?` 로직을 FilterPipeline에 위임.

```ruby
# 변경 전 (main)
def skip_creative?(creative)
  if allowed_creative_ids
    return !allowed_creative_ids.include?(creative.id.to_s)
  end

  tags = Array(raw_params["tags"]).map(&:to_s)
  if tags.present?
    creative_label_ids = creative.tags.pluck(:label_id).map(&:to_s)
    return true if (creative_label_ids & tags).empty?
  end

  if raw_params["min_progress"].present?
    min_progress = raw_params["min_progress"].to_f
    return true if creative.progress.to_f < min_progress
  end

  if raw_params["max_progress"].present?
    max_progress = raw_params["max_progress"].to_f
    return true if creative.progress.to_f > max_progress
  end

  false
end

# 변경 후 (feature branch)
def skip_creative?(creative)
  # FilterPipeline이 allowed_creative_ids에 모든 필터링 결과를 담음
  # (매칭 아이템 + 조상). 여기서 중복 필터 로직 불필요.
  return !allowed_creative_ids.include?(creative.id.to_s) if allowed_creative_ids

  false
end
```

**장점:**
- 코드 중복 제거 (필터 로직이 한 곳에만)
- 유지보수성 향상
- 새 필터 추가 시 TreeBuilder 수정 불필요

### 3. 컨트롤러 any_filter_active? 헬퍼

**변경 내용:**
필터 활성 여부 확인 메서드 추가.

```ruby
# app/controllers/creatives_controller.rb
private

def any_filter_active?
  params[:tags].present? ||
    params[:min_progress].present? ||
    params[:max_progress].present? ||
    params[:search].present? ||
    params[:comment] == "true"
end
```

**용도:**
- 필터 결과에 대해 `expires_now` 호출 (캐시 방지)
- JSON 응답 시 필터 활성 상태 확인

### 4. 뷰 개선: 필터 파라미터만 전달

**변경 내용:**
JSON 요청 시 필요한 필터 파라미터만 전달.

```erb
<%# 변경 전 %>
tree_params = request.query_parameters.merge(format: :json)

<%# 변경 후 %>
tree_params = params.to_unsafe_h.slice(
  "id", "tags", "min_progress", "max_progress", "search", "comment"
).merge(format: :json)
```

**장점:**
- 불필요한 파라미터 전파 방지
- URL 깔끔함 유지

### 5. expansion_controller.js 개선

**변경 내용:**
현재 creative ID 추출 로직 강화.

```javascript
computeCurrentCreativeId() {
  // URL path: /creatives/:id
  const match = window.location.pathname.match(/\/creatives\/(\d+)/)
  let id = match ? match[1] : null

  // URL params: ?id=...
  if (!id) {
    const params = new URLSearchParams(window.location.search)
    id = params.get('id')
  }

  // Title row에서 가져오기 (fallback)
  if (!id) {
    const titleRow = this.element.querySelector('creative-tree-row[is-title]')
    id = titleRow?.getAttribute('creative-id')
  }

  return id
}
```

---

## 가져오지 않을 변경사항

### CreativeLink 관련 (URL 안정성 문제)

다음 변경사항들은 URL 안정성 문제로 가져오지 않음:

- `CreativeLink` 모델 및 마이그레이션
- `VirtualCreativeHierarchy` 모델
- `InheritedShareBuilder` 서비스
- `LinkCleaner` 서비스
- `show_link`, `unlink` 액션
- `/l/:id` 라우트

이유:
- Shell Creative(origin_id)가 이미 URL 안정성 제공
- creative_shares_caches로 O(1) 권한 조회 가능
- 기존 시스템과 호환성 유지

---

## 기대 효과

| 개선 항목 | Before | After |
|----------|--------|-------|
| 권한 체크 | O(depth) × n | O(1) |
| 필터 조합 | 불가 | 가능 |
| 코드 중복 | 4개 분기 | 1개 파이프라인 |
| 새 필터 추가 | 분기 추가 | 클래스 추가 |
| 테스트 용이성 | 분산 | 집중 |
| HTML 초기 로딩 | 전체 쿼리 | 최소 쿼리 (CSR) |
| TreeBuilder 복잡도 | 필터 로직 중복 | 위임으로 단순화 |
