# 단계별 마이그레이션 플랜

- <u>0. 안전한 진입(빌드/로드 정리)</u>
  - <u>단기: 현 상태 유지. 장기: 레이아웃의 개별 [<%= javascript_include_tag %>](cci:1://file:///Users/soonoh/project/soonoh/plan42/app/javascript/creatives_api.js:2:4-4:5)를 제거하고 [application.js](cci:7://file:///Users/soonoh/project/soonoh/plan42/app/javascript/application.js:0:0-0:0) 하나만 남기도록 전환.</u>
  - <u>[application.js](cci:7://file:///Users/soonoh/project/soonoh/plan42/app/javascript/application.js:0:0-0:0)에서 필요한 스크립트를 모두 import 하도록 통일.</u>
- <u>1. 공통 유틸/서비스 정리</u>
  - <u>`lib/api/csrf_fetch.js` 생성(모든 fetch에 CSRF 헤더/credentials 통일).</u>
  - <u>`window.creativesApi` → `lib/api/creatives.js` ESM로 이전하고 import 방식으로 교체.</u>
  - <u>`@rails/actioncable`를 dependency로 추가하고 `services/cable.js`에서 `createConsumer()` export. 레이아웃의 `javascript_include_tag 'actioncable'` 제거 예정.</u>
- <u>2. 작은 모듈부터 Stimulus 전환(Quick wins)</u>
  - <u>[popup_menu.js](cci:7://file:///Users/soonoh/project/soonoh/plan42/app/javascript/popup_menu.js:0:0-0:0) → `controllers/popup_menu_controller.js`</u>
  - <u>[progress_filter_toggle.js](cci:7://file:///Users/soonoh/project/soonoh/plan42/app/javascript/progress_filter_toggle.js:0:0-0:0) → `controllers/progress_filter_controller.js`</u>
  - <u>[creatives_import.js](cci:7://file:///Users/soonoh/project/soonoh/plan42/app/javascript/creatives_import.js:0:0-0:0) → `controllers/creatives/import_controller.js`</u>
  - <u>[select_mode.js](cci:7://file:///Users/soonoh/project/soonoh/plan42/app/javascript/select_mode.js:0:0-0:0) → `controllers/creatives/select_mode_controller.js`</u>
  - <u>[action_text_attachment_link.js](cci:7://file:///Users/soonoh/project/soonoh/plan42/app/javascript/action_text_attachment_link.js:0:0-0:0) → `controllers/action_text_attachment_link_controller.js`</u>
  - <u>각 뷰/파트셜에 `data-controller="..."`와 `data-*-target` 추가</u>
- <u>3. 크리에이티브 관련 컴포넌트 전환</u>
  - <u>[creatives_drag_drop.js](cci:7://file:///Users/soonoh/project/soonoh/plan42/app/javascript/creatives_drag_drop.js:0:0-0:0) → `controllers/creatives/drag_drop_controller.js`</u>
  - <u>[creatives_expansion.js](cci:7://file:///Users/soonoh/project/soonoh/plan42/app/javascript/creatives_expansion.js:0:0-0:0) → `controllers/creatives/expansion_controller.js`</u>
  - <u>[creative_row_editor.js](cci:7://file:///Users/soonoh/project/soonoh/plan42/app/javascript/creative_row_editor.js:0:0-0:0) → `controllers/creatives/row_editor_controller.js` (가능하면 모달/저장/링크/자동저장 기능을 작은 private 모듈로 분리)</u>
- <u>4. 댓글 시스템 분해</u>
  - <u>[comments.js](cci:7://file:///Users/soonoh/project/soonoh/plan42/app/javascript/comments.js:0:0-0:0)를 아래 컨트롤러로 나눔:</u>
    - <u>`comments/popup_controller.js`(열기/닫기/위치/리사이즈/크기 저장)</u>
    - <u>`comments/list_controller.js`(초기 로드/페이지네이션/하이라이트/읽음 처리)</u>
    - <u>`comments/form_controller.js`(전송/편집/검증)</u>
    - <u>`comments/presence_controller.js`(참여자/타이핑 인디케이터/ActionCable)</u>
    - <u>`comments/mention_menu_controller.js`(멘션 UI)</u>
  - <u>공통 유틸: `lib/utils/markdown.js`로 `marked` import하여 SSR-safe 렌더링. CDN 의존성 제거.</u>
- <u>5. 의존성 정리</u>
  - <u>`marked`를 npm dependency로 추가하고, 컨트롤러에서 import 사용. 레이아웃의 CDN 스크립트 제거.</u>
  - <u>[register_service_worker.js](cci:7://file:///Users/soonoh/project/soonoh/plan42/app/javascript/register_service_worker.js:0:0-0:0)는 유지하되, 필요시 `services/notifications.js`로 로직 일부 이전.</u>
- <u>6. 레이아웃 간소화</u>
  - <u>[application.html.erb](cci:7://file:///Users/soonoh/project/soonoh/plan42/app/views/layouts/application.html.erb:0:0-0:0)에서 [creatives/popup_menu/progress_filter/...](cci:1://file:///Users/soonoh/project/soonoh/plan42/app/javascript/creatives_api.js:2:4-4:5) 개별 `javascript_include_tag` 제거.</u>
  - <u>[application.js](cci:7://file:///Users/soonoh/project/soonoh/plan42/app/javascript/application.js:0:0-0:0) 한 개만 모듈 타입으로 로드.</u>
- <u>7. 전역 제거</u>
  - <u>`window.*Initialized` 플래그, `window.attach*` 등 제거. Stimulus의 connect/disconnect 라이프사이클로 대체.</u>
- 8. 회귀 테스트 포인트
  - 크리에이티브 트리(확장/드래그/인라인편집/삭제)
  - 댓글 팝업(참여자, 타이핑, 페이지네이션, 멘션, 모바일 키보드, 리사이즈, 읽음처리)
  - 플랜 타임라인(무한 스크롤, 새로고침, 삭제)
  - 알림/FCM 등록 플로우
  - 다크/라이트 모드, 필터 토글

# 이 구조로 얻는 이점

- __중복/글로벌 상태 제거__: `window.*`를 없애고 import로 의존성이 명시적.
- __초기화 중복 방지__: Stimulus 라이프사이클로 중복 바인딩 방지. `turbo:load` 보일러플레이트 제거.
- __유지보수성 향상__: 큰 파일을 컨트롤러 단위로 분해. 테스트/디버깅 쉬워짐.
- __로딩 단순화__: 레이아웃은 [application.js](cci:7://file:///Users/soonoh/project/soonoh/plan42/app/javascript/application.js:0:0-0:0) 한 개만 로드.

# 빠른 적용 후보(Quick wins)

- __creatives_import 전환__: 지금 열려 있는 [app/javascript/creatives_import.js](cci:7://file:///Users/soonoh/project/soonoh/plan42/app/javascript/creatives_import.js:0:0-0:0)는 Stimulus로 전환하기 가장 좋습니다.
  - `controllers/creatives/import_controller.js`로 이관(드롭존/인풋/프로그레스는 targets, 안내문구는 values로 관리).
  - 관련 뷰에 `data-controller="creatives--import"` 추가.

- __popup_menu / progress_filter / select_mode__도 비교적 독립적이라 컨버전이 용이.

# 레이아웃 정리 방향

- [app/views/layouts/application.html.erb](cci:7://file:///Users/soonoh/project/soonoh/plan42/app/views/layouts/application.html.erb:0:0-0:0)에서 다음을 제거 대상으로 두고
  - `javascript_include_tag 'creatives'`, `'popup_menu'`, `'progress_filter_toggle'`, `'plans_timeline'`, `'actioncable'`
- [app/javascript/application.js](cci:7://file:///Users/soonoh/project/soonoh/plan42/app/javascript/application.js:0:0-0:0)에서 필요한 모든 컨트롤러/모듈을 import.
- `marked` CDN 제거 후 npm import.

