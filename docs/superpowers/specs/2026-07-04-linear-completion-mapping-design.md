# Linear ↔ Collavre 완료 상태 매핑 (Completion Mapping)

PR #1342 follow-up. Adds bidirectional completion sync between a Linear issue's
"done" workflow state and a Collavre leaf creative's 100% progress.

## Requirements (정순오)

1. 연결 시 완료 상태를 콤보박스로 선택. 기본값 = "Completed".
2. Linear 에서 이슈가 완료 상태가 되면 대응 Collavre 크리에이티브를 100% 처리.
3. **Leaf creative 만 동기화됨** (부모 progress 는 자식 평균 롤업이므로 직접 설정 불가).
4. 반대로 Collavre 크리에이티브가 100% 되면 Linear 이슈를 완료 상태로 설정.

## Key facts (existing engine)

- Collavre `progress` 는 float 0.0–1.0 컬럼. 부모 progress 는 `ProgressService`
  가 활성 자식 평균으로 자동 롤업(after_save). 따라서 **leaf 만** 독립적으로
  progress 를 가진다 — 요구사항 #3 과 정확히 일치.
- Linear workflow state 는 `{id, name, type}`; `type` ∈ {triage, backlog,
  unstarted, started, completed, canceled}. state 는 team 단위.
- 필드 매핑: state/labels/assignee → `creative.data["linear"]`, title →
  description, priority → sequence. `FieldMapper` 는 순수(진행률 미참조).
- 아웃바운드 트리거: `CreativeSyncObserver.LINEAR_RELEVANT_COLUMNS` 변경 시
  `OutboundSyncJob` enqueue. 현재 `%w[description sequence data parent_id]`.
- 인바운드: `InboundApplier#create_issue!/#update_issue!` 가 state 를 data 에 기록.

## Design

### Data model
- 엔진 마이그레이션: `linear_project_links.done_state_id` (string, nullable).
  Linear workflow state UUID. Nullable = 이 기능 이전 링크/완료상태 없는 팀은
  완료 매핑 비활성(안전한 no-op).

### 연결 UI (요구사항 #1)
- `Client#list_workflow_states` → `workflowStates(first:250){nodes{id name type
  position team{id}}}`. `options` 액션이 `states:` 도 반환.
- 모달 link 폼에 `done_state_id` `<select>` 추가. team 선택 시 JS 가 그 team 의
  state 로 채우고 **기본값 자동선택**: name=="Completed"(대소문자무시) 우선,
  없으면 첫 `type=="completed"`(position 오름차순). 완료 state 없으면 빈 값
  허용(선택). `create` 가 `done_state_id` 저장.

### 아웃바운드: leaf 100% → Linear done (요구사항 #4)
- `CreativeExporter.apply_completion!(attrs, creative, project_link)`:
  `done_state_id` 있고 creative 가 **leaf**(`children.active.empty?`)이고
  `progress >= 1.0` 이면 `attrs[:state_id] = done_state_id`.
- `content_hash_for`(class) 도 동일 로직 적용(인바운드/아웃바운드 해시 일치 필수).
- observer `LINEAR_RELEVANT_COLUMNS` 에 `progress` 추가 → leaf progress 변경이
  outbound sync 를 enqueue. 비-leaf progress 롤업은 leaf 아니라 apply_completion!
  이 no-op → content_hash 불변 → API 호출 없음(churn 만, 무해).
- **미완료(progress<1.0) 아웃바운드는 상태를 done 밖으로 되돌리지 않음** — 스펙은
  100%→done 방향만 명시. done 밖 목표 상태가 모호(어느 unstarted?)하므로 범위 외.
  data["linear"]["state"] 의 마지막 알려진 상태를 echo.

### 인바운드: Linear done → leaf 100% (요구사항 #2)
- `InboundApplier#reconcile_leaf_progress!(creative, project_link)`:
  - `done_state_id` blank → no-op. creative 가 leaf 아님 → no-op.
    origin-linked(`origin_id` present) → no-op(progress 직접설정 금지 validation).
  - inbound `state.id == done_state_id` → `progress = 1.0` (미달일 때만).
  - `state.id != done_state_id` 이고 현재 `progress == 1.0` → `progress = 0.0`
    (done 에서 벗어남 = 완료 취소). **부분 progress(예 0.5)는 보존** — done↔100%
    이진 매핑이므로 비-done 상태가 부분 진행을 덮지 않음.
- create 시: 항상 reconcile. update 시: state 필드가 적용될 때만(`changed.nil? ||
  changed.include?("state")`) reconcile → 제목-only 편집이 progress 를 안 건드림.
- `creative.skip_linear_sync = true`(기존) 하에서 progress 를 set → 에코 없음.

### 에코 안전성
- 아웃바운드 100%→done 푸시 → Linear 가 state 변경 웹훅 에코 → 인바운드
  is_done → progress 1.0(무변화) + content_hash 일치 → 루프 없음.
- 인바운드 done→progress 1.0 은 skip_linear_sync 로 아웃바운드 안 됨.

## Non-goals
- 아웃바운드 미완료(un-done) → Linear 상태 되돌리기(목표 상태 모호).
- 완료 상태 사후 변경 UI(연결 시점만; 변경은 unlink→relink).
- 다중 completed-type 상태 구분(설정된 단일 done_state_id 로 판정).

## Tests
- Client: `list_workflow_states` 파싱.
- Exporter: leaf+100%+done_id → state_id 푸시; 비-leaf 무시; progress<1.0 무시;
  done_id nil 무시; content_hash_for 일치.
- InboundApplier: done→1.0; done 벗어남(1.0→0.0); 부분 진행 보존; 비-leaf 무시;
  origin-linked 스킵; 제목-only 편집 progress 불변.
- Controller: create 가 done_state_id 저장; options 가 states 반환.
- Modal view: done-state select 렌더.
