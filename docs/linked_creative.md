# Linked Creative 시스템 설계 및 동작

## 개념 및 구조
- `Creative` 모델에 `origin_id`(self-referencing) 컬럼을 추가하여, `origin_id`가 존재하면 해당 Creative를 "Linked Creative"로 간주합니다.
- Linked Creative는 원본 Creative(origin)의 대부분의 정보를 참조하며, owner(사용자)와 parent만 자신 고유로 가집니다.

## 생성 및 공유 로직
- CreativeShare를 통해 Creative가 공유될 때, 공유 대상 사용자를 owner로 하는 Linked Creative가 자동 생성됩니다.
- 이미 동일 origin_id와 user_id를 가진 Linked Creative가 있으면 중복 생성하지 않습니다.
- Linked Creative 생성 시 `origin_id`, `user_id`, `parent_id`만 저장하며, validation은 origin Creative에만 적용됩니다 (`unless: -> { origin_id.present? }`).

## 모델 동작 및 권한
- Linked Creative는 getter/메서드에서 origin Creative의 정보를 참조하도록 오버라이드되어 있습니다.
    - 예: `progress`, `description`, `user`, `children` 등
    - `effective_attribute`, `effective_description`, `effective_origin` 등 메서드로 구현
- 권한 체크는 `has_permission?` 메서드를 통해 owner이거나 공유받은 경우 권한을 부여합니다.
- 트리/부모 구조는 `owning_parent` 메서드로, 현재 유저가 소유한 Linked Creative의 parent를 반환(없으면 원본 parent).
- `children_with_permission`은 origin Creative의 children 중 권한 있는 것만 반환합니다.

## Progress/트리 연쇄 갱신
- Linked Creative의 progress가 수정되면,
    - 원본 Creative의 parent, 그리고 자신을 origin으로 참조하는 모든 Linked Creative의 progress도 함께 갱신합니다.
- `update_parent_progress`에서 linked_creatives의 progress를 동기화하고, parent의 progress도 갱신합니다.

## 컨트롤러/뷰 동작
- **creatives_controller.rb**
    - index 액션에서 parent_id로 Creative를 쿼리한 뒤, owner이거나 권한 있는 것만 Ruby에서 필터(`children_with_permission`)하여 목록에 노출.
    - parent_creative도 owner/공유 모두에서 접근 가능.
- **creative_shares_controller.rb**
    - 공유 시 실제 origin Creative를 기준으로 Linked Creative를 생성.
- **creatives_helper.rb**
    - 트리 렌더링 등에서 Linked Creative의 description 등 정보를 효과적으로 참조.
- **index.html.erb**
    - 상위로 이동 시 `owning_parent` 사용.
    - Creative 목록은 권한 필터링된 children만 트리로 렌더링.

## 기타
- Linked Creative는 삭제/수정 시 연쇄적으로 관련 parent/child의 progress가 올바르게 갱신됩니다.
- 모든 주요 동작은 코드에서 실제로 검증된 로직에 기반하여 구현되었습니다.

---

이 문서는 2025-05-28 기준 최신 소스 코드와 실제 동작을 바탕으로 작성되었습니다.
