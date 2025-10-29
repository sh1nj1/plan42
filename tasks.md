### 현황 요약
- 인라인 편집 폼은 `<trix-editor>`와 관련 데이터 속성을 직접 렌더링하며, 숨겨진 `creative[description]` 필드와 함께 Trix 에디터에 의존하고 있습니다.


- `creative_row_editor.js`는 `trix-editor` 요소를 직접 선택하고, `editor.editor.loadHTML`, `trix-change` 이벤트, `data-trix-*` 속성 변환 등 Trix 전용 API에 강하게 결합돼 있습니다.



- 전역 엔트리에서 `trix`, `@rails/actiontext`, `trix_color_picker`를 임포트하며 패키지 의존성에도 `trix`가 명시돼 있습니다.



- 툴바 색상 선택기 등 Trix 확장을 위해 별도 스크립트가 존재하고, 대량의 CSS가 `trix-editor`, `.trix-content` 구조를 전제로 정의돼 있습니다.



- 백엔드 헬퍼는 `.trix-content` 래퍼를 가정해 마크다운 변환을 수행하며, 시스템 테스트 역시 `trix-editor`를 직접 찾습니다.



- 사양 문서에는 “Trix editor's attachment” 사용이 명시돼 있어 교체 시 문서 업데이트가 필요합니다.


### Lexical 전환 목표
1. 인라인 편집과 폼 전반에서 Trix 의존성을 제거하고 Lexical 기반의 일관된 편집 경험을 제공한다.
2. 기존 ActionText/ActiveStorage 백엔드 및 저장된 콘텐츠와의 호환성을 유지한다.
3. 현재 제공 중인 기능(자동 링크, 색상/배경색 지정, 첨부, 단축키, 저장 동기화 등)을 Lexical에서도 동일하게 지원한다.

### 단계별 계획

1. **환경 정리 및 패키지 준비**
   - `package.json`에서 `trix`와 연동 스크립트 임포트를 제거하고, `lexical`, `@lexical/rich-text`, `@lexical/html`, `@lexical/link` 등 필요한 Lexical 패키지를 추가한다.


   - `app/javascript/application.js`에서 Trix 관련 임포트를 모두 제거하고, 새 Lexical 초기화 스크립트를 불러오도록 구성한다.


2. **공용 Lexical 에디터 래퍼 구축**
   - `app/javascript`에 Lexical 초기화 모듈을 추가해, `createEditor`와 컴포저 설정(리치 텍스트, 리스트, 링크, 히스토리 등)을 캡슐화한다.
   - `@lexical/html`을 이용해 HTML ↔ Lexical 상태 변환 헬퍼를 만들고, 기존 Trix 저장본에서 `.trix-content` 래퍼를 벗겨 입력하도록 전처리한다.


   - 에디터 상태 변경 시 숨겨진 `<input type="hidden" name="creative[description]">` 값이 갱신되도록 커스텀 리스너를 구현하고, 포커스 제어·undo/redo 키 바인딩을 포함한 기본 단축키를 설정한다.



3. **인라인 편집기 교체**
   - `_inline_edit_form.html.erb`에서 `<trix-editor>`와 `trix-toolbar`를 제거하고, Lexical 에디터 컨테이너와 자체 툴바(텍스트 스타일, 색상, 링크, 리스트 등)를 렌더링하도록 업데이트한다.


   - `creative_row_editor.js`를 Lexical API 기반으로 재작성하여 다음을 지원한다: 초기 콘텐츠 로드/저장, `autoLinkUrls` 기능을 Lexical command 혹은 transformer로 대체, `Shift+Enter`, `Alt+Enter`, `Escape`, 화살표 이동 로직을 Lexical selection으로 구현, 저장 시 HTML 직렬화 및 FormData 제출, `data-trix-*` 치환 로직 제거 등.


   - 기존 색상/배경색 선택 기능을 Lexical toolbar 버튼과 포맷 명령으로 구현하고, 현재 `trix_color_picker.js`는 제거한다.


4. **정규 폼 컴포넌트 교체**
   - `form.rich_text_area`를 대체할 Rails 파셜/뷰 헬퍼를 작성하여, 동일한 Lexical 래퍼를 생성하고 `creative[description]` hidden field를 재사용하도록 한다.


   - Turbo/Turbo Frame 복원 시 에디터가 재초기화되도록 Stimulus 컨트롤러(예: `creatives--row-editor`)나 전역 초기화 시점을 점검한다.


5. **ActiveStorage 첨부 & ActionText 호환**
   - 기존 Trix 저장 구조(`trix-data-attachment` 변환) 대신 Lexical image/file 노드가 `<action-text-attachment>` HTML을 생성하도록 커스텀 노드를 구현한다.


   - ActiveStorage DirectUpload를 JS에서 직접 호출하여 업로드 진행 상황을 표시하고, 업로드 완료 시 SGID를 사용해 `ActionText::Attachment` HTML을 삽입한다.
   - `ActionTextAttachmentLinkController`가 그대로 동작하도록 `<action-text-attachment>` 마크업을 유지하며, 필요 시 Lexical에서 생성한 앵커에 `target="_blank"/`rel="noopener"` 속성을 부여한다.


6. **스타일 및 레이아웃 정리**
   - `actiontext.css`에서 Trix 전용 규칙을 제거하고, Lexical 출력 구조(예: `.lexical-editor`, `.editor-content`)에 맞게 최소한의 스타일을 다시 정의한다. 과거 콘텐츠를 위해 `.trix-content` 스타일은 호환성 수준으로 축소 유지한다.


   - 슬라이드 뷰 등 `.trix-content`를 참조하던 다른 스타일(`slide_view.css`)도 Lexical 출력 클래스를 지원하도록 수정한다.


7. **백엔드/헬퍼 조정**
  - `html_links_to_markdown` 등 헬퍼가 Lexical에서 생성한 HTML 구조(예: `<p>`, `<ul>`, `<figure>` 등)를 올바르게 처리하도록 분기나 정규식을 보완하고, 기존 `.trix-content` 경로는 레거시용으로 유지한다.


  - 필요한 경우 새 Lexical 래퍼 클래스(예: `.creative-rich-text`)를 감지하여 마크다운 변환을 수행하도록 테스트를 추가한다.

8. **문서 및 시스템 테스트 갱신**
   - 시스템 테스트에서 `trix-editor` 셀렉터를 Lexical 편집기 컨테이너로 교체하고, 주요 단축키와 저장 동작이 계속 통과하는지 확인한다.


   - 사양 문서의 “Use Trix editor's attachment” 같은 기술을 Lexical 기반 워크플로로 업데이트한다.


9. **정리 및 회귀 점검**
   - `trix_color_picker.js` 및 관련 import 제거, 사용되지 않는 CSS/JS/테스트 코드 삭제.
   - 기존 저장된 콘텐츠(특히 첨부/색상 하이라이트)를 Lexical에서 불러와 편집·저장해도 문제 없는지 수동 검증하고, 필요한 경우 마이그레이션 스크립트나 백필터를 추가한다.

### Testing
- ⚠️ 미실행 (계획 수립 작업만 수행)
