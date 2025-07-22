# Features

## List Creatives

### Creative View

#### A Creative should be ordered by sequence


#### 크리에이티브 경계 표시

* 개별 크리에이티브 경계 표시
  * 마우스 오버시 크리에이티브 배경색을 변화시켜 영역을 표시
  * 모바일에서 마우스 오버 없이 구분하기 위해 앞에 경계 블록 표시 긴 세로바를 넣음
* 하위 영역까지 표시
  * 하위를 가지고 expansion \(펼치기\) 액션이 있는 크리에이티브는 하위가 어디까지인지 구분 표시를 한다.

#### View count


#### Progress

* Value range 0.0 \~ 1.0
* 필터링 된 페이지에 대해 상위 Progress 는 재계산되어야 한다. 예를 들면, Plan 에 태그된 것만 볼 경우, 그 태그된 크리에이티브들만으로 진행률이 재계산되어야 한다.
* 계산 방식 유연화
  * 하위의 평균이 현재 크리에이티브의 Progress 가된다.
  * 가중치 계산? 작업의 크기에 따른 구분이 필요할 수도 있고, 난이도등 여러 요소가 있을 수 있다.
* Parent Creative progress should be auto\-calculated by it's children progress
* Only leaf Creative progress can be edited by a user

#### Creative Level Style

* Top 3 parent level Creative will be represented as h1, h2, h3
* Leaf Creative should not be applied auto\-level style

#### Printable Page

* 앱의 웹페이지를 브라우저에서 출력하면, 메뉴와 팝업등의 요소가 제외되고 컨텐츠 내용만 출력된다

#### Conversion

* Idea, R&amp;D 수준의 작업은 우선 메인 문서로 기록되기 전에 탐색및 조사, 토론 등이 필요하다. 이때 이런 것은 관련 크리에이티브에 코멘트로 기록되어 토론이 될 수 있을 것이다. 이후 확정이 되면 정식 문서 내의 크리에이티브로 "전환" 된다면 좋을 것이다.
* 코멘트는 해당 크레이이티브의 하위 크리에이티브로 전환될 수 있다.
* 크리에이티브는 상위 크리에이티브의 코멘트로 전환될 수 있다.
* 코멘트로 전환은 문서에서 더이상 불필요하거나 과거의 내용등을 코멘트로 전환함으로써 더이상 문서에 불필요한 내용을 남가지 않게 한다.
* 백로그 개념은 어떻게 처리할 것인가?

#### Creatives should contain its tree structure even if some of the Creatives hidden by filters or permissions


#### List all tags for the creative and toggle button to filter with that tag


#### 모두 펼침 토글


#### Text Styles

* 문단 가운데 정렬
* 문단 우측 정렬


### Actions

#### Drag and Drop Creative to change parent or order

* Drop to up or down and show indicationChange parent if not same parent.
* Drop to be appended as child Creative if a user drop to the right side of the creative rowShow child drop indication \- do not show up/down line indication and "↳" arrow like indication

#### Row Action Buttons

* Only show action buttons when user over the creative row to look UI clean
* New Creative
  * Form
    * 다른 크리에이티브를 링크할 수 있다
    * 취소를 누르면 이전 상태로 가야 한다.
  * 태그 검색 상태에서 추가를 하면, 생성시 해당 태그도 모두 추가한다.
* Always show row action buttons when it is mobile device

#### Creative menu

* Add&nbsp; Creative
  * New sub\-creative
  * 아래에 추가 \- 현재 크리에이티브 아래에 같은 레벨로 추가
  * New upper\-creative
* Import
  * Import from Markdown file.
    * Convert markdown table
    * Covert link
  * When importing set parent_id as current creative and import everything under the current Creative.
* Deletion
  * Delete one Creative onlyWhen deleting a Creative, all its children should be re\-linked to its parent \(i.e., their parent_id set to the deleted Creative’s parent\).After deletion, redirect to the parent Creative \(or to the root if there is no parent\).
  * Delete with children
* Export
  * Markdown
  * Export to Notion page

#### Expansion toggle

* Expansion toggle for each Creative on the left side
* Keep expansion state at given Creative for each User

#### Add child creative button on left side


#### Link to Creative show it's children and Creative actions


#### Multi\-Selection

* selection 모드 일경우 기존의 Drag and Drop 에 의해 이동 기능은 중지되고, creative\-row 가 선택되어야 한다.shift key 를 누르고 드래그 하는 경우, 추가로 선택되어야 한다.alt key 를 누르고 드래그 하는 경우, 선택에서 제외되어야 한다.

#### Attach files

* Use Trix editor's attachement


### Inline edit a Creative

#### Change text


#### 수정 모드에서 위아래 크리에이티브로 이동하여 수정할 수 있다


#### 수정 모드에서 아래에 새 크리에이티브를 추가할 수 있다


#### 수정모드에서 하위에 새 크리에이티브를 추가할 수 있다


#### 취소 버튼을 눌러 취소할 수 있다


#### 엔터키를 누르면 수정 모드로 변경


#### Change progress



### Filters

#### Show only completed Creatives


#### Show only incomplete Creatives


#### 기간안에 추가된 것만 필터


#### 지정된 tag 들만 필터


#### 코멘트가 있는 것만 필터


#### 태깅되지 않은 것만 필터


#### Show Creatives only given level depth




## Commenting

### 크리에이티브에 코멘트를 추가/삭제/리스트 할 수 있다.


### 댓글은 소유자만 편집및 삭제 할 수 있다


### Linked Creative 이면 원본에 코멘트가 등록되고 원본 코멘트를 표시해야함


### Topic

#### 코멘트는 2단계 상하 관계가 있다.


#### 토픽 아래에 코멘트 리스트가 달린다.


#### 크레이이티브 &gt; 토픽 &gt; 코멘트 관계가 있다.


#### 토픽은 하나의 히든 크리에이티브라고 보면된다.



### 댓글 리스트

#### 댓글 필터시 지정된 Creative 하위로만 필터되어야 된다


#### 댓글만 있는 크리에이트브만 필터할 수 있다.



### Chat

#### 개별 코멘트는 채팅처럼 작동할 수 있도록, 실시간으로 메세지가 전송되어야 한다.


#### 권한이 없는 사용자를 멘션하면 "피드백" 권한으로 공유할지 물어보고 공유한다


#### 현재 보고 있는 화면에서 새로운 댓글이 추가되면 이동할 수 있는 링크를 포함하여 "새로운 댓글이 추가되었습니다. 댓글로 이동" 을 노티스에 표시하고, 링크를 삽입한다. 링크를 누르면 해당 댓글창이 열리면서 해당 댓글이 플래쉬 된다. 해당 링크를 누르면 해당 노티스는 사라진다.


#### 사용자 온라인 상태 표시


#### 채팅의 참여 사용자는 Creative.user \(owner\) 가 방장 개념이고, 그외 feedback 권한을 가진 모든 사용자가 해당 채널 참여자다


#### AI 에이전트

* AI 에이전트를 사용자가 설정하면 동료 처럼 채팅


### Chat \(Comment\) Commands

#### 현재 쓰레드에서 논의한 내용으로 크리에이티브 생성 기능 \- [Conversion](https://plan42.vrerv.com/creatives/430) 과 유사


#### 오프라인 회의\(Meeting\)

* "/meeting " 을 입력하면, 미팅 추가 팝업이 표시되고, 현재 참여자가 모두 미팅 대상이 된다. \- 구글 캘린더 연동


### 댓글을 수정할 수 있다.


### 코멘트에서 사용자를 멘션할 수 있다.



## UI/UX

### Navigation


### Customise 404


### Favicon


### Tips

#### page title 위에 "드래그해서 선택을 토글할 수 있습니다." 문구를 선택 모드일때 표시 하고 닫기 버튼을 추가하여 drag\-to\-selection 기능에 대해 닫은 지 여부를 사용자에 UserLearned 에 저장?



### Theme

#### 기본 테마를 제공한다.


#### 테마는 다음을 정한다크리에이티브 레벨별 스타일완료/미완료 스타일


#### Dark Mode UI




## Multi\-User

### Sign up

#### Email verification


#### Reset Password


#### Tutorial

* 사용자가 최초 로그인하면, 튜토리얼을 표시한다.
* 튜토리얼 작성
  * 6 단계의 깊이로 간단한&nbsp; 콜라브 제품을 소개하는 문서를 만들어서 튜토리얼 자체도 하나의 크리에이티브들로 구성되도록 한다.
* 콜라브 튜토리얼
  * 콜라브는 문서 \- 태스크 \- 채팅 통합 협업 플랫폼입니다
  * 트리 구조와 문서크리에이티브페이지 구분 없음완료 상태 퍼센티지상위 전파 \- 평균값태그 \- 계획공유토론 \- 채팅댓글이 해당 크리에이티브에 대한 주제로 채팅처럼 실시간 확인 진행 가능참여자태스크의 할당은 롤별로 가능하며 멀티 가능기획, 디자인, 개발


### On\-Premises


### Organisation

#### Creative 는 Organisation 소유일 수 있다.Organisation 소유의 Creative 하위는 모두 조직 소유이다.



### Inbox

#### Inbox Item List

* 인박스에 사용자에게 전달된 메세지나 이벤트 메세지를 표시한다
* 인박스 메세지는 "new" \(새로운\), "read" \(읽음\) 상태를 가진다
* 앱 메뉴에 "인박스" 메뉴를 추가하고 누르면 오른쪽 슬라이드 패널로 메세지 리스트를 표시한다
* 인박스 리스트는 안읽은 메세지를 기본으로 표시한다
* 닫기를누르면 슬라이드가 닫힌다.
* 인박스 리스트에 "않읽은 메시지 표시" 토글을 둔다

#### Notify Inbox Message

* 매일 오전 09:00 에 각 사용자의 읽지 않은 인박스 메세지 최대 10개까지를 읽어서 메일로 보낸다. 만약 메세지가 없으면 보내지 않는다.

#### Inbox Message

* 사용자가 코멘트를 달면, 해당 Creative 사용자의 InboxItem 을 추가한다. "{User.email} 가 "{comment}" 를 추가했습니다." 라는 메세지로 표시한다.
* /creatives/:creative_id/comments/:comment_id 로 comment 의 url 을 만들고, 호출되면, 해당 코멘트 팝업이 표시되고 해당 comment 의 배경색이 플래쉬 되는 애니메이션이 표시된다.
* 사용자가 크리에이티브를 공유하면, 공유받은 사용자의 인박스에 다음 메세지를 생성한다."{user} 가 \\"{short_title}\\" 을 공유했습니다." 또한 해당 메세지를 누르면 해당 /creatives/:id 로 이동한다.
* 사용자가 인박스에서 메세지 링크를 누르면 자동 읽음 처리


### User Avatar

#### 사용자 링크에 아바타를 표시한다.아바타 클릭시 바로 프로파일로 이동하지 않고, 팝업 메뉴를 띄운다.사용자 팝업메뉴에는 "프로파일", "로그아웃" 을 표시한다.프로파일에 아바타 변경 메뉴를 추가하고 구현한다.아바타가 없는 사용자는 빈 아바타를 사용한다.외부 아바타는 url 로 이미지를 링크한다.



### Change password


### Share

#### Share a Creative to a user with permission


#### Invitation

* Invitation for by sharing, if the user not exists
* 사용자는 초대 리스트를 보고 초대 결과를 확인할 수 있다

#### List shared users


#### Only given Creatives are shown for each User by their permission.


#### Update share user's permission


#### Delete shared user


#### Permissions

* No access permission
* Read permission
* Feedback permission \- can comment
* Write permission
* Full access permission
* 권한은 하위 모든 노드에 적용된다.
* 만약 특정 하위 노드에 적용하지 않고 싶으면 NONE 퍼미션을 추가해야 한다.



## Search

### 단순 단어 매칭


### 검색 결과가 없음을 표시해야 한다


### 검색시 코멘트에 정보가 있는 Creative 도 검색된다.


### 조건 검색및 정렬 \(ransack\)


### 빠른 검색, 대용량 데이터 검색

#### searchkick \(Elasticsearch&nbsp; 기반\)


#### meilisearch\-rails \(빠른 설치 \+ 간단한 설정\)



### 검색창이 앱 상단바에 있고, 검색어를 입력할 수 있다.



## Tagging

### Tag Creatives to list only given Creatives


### Tag Permission

#### List owner tags or owner is nil


#### Owner can delete



### Variation

#### same contents but different expression. e.g. translations



### Plan

#### User must set target date and set name optionally


#### Total progress for Plan


#### 사용자는 Plan 의 이름을 바꿀 수 있다


#### Plan Timeline

* 그 plan bar 는 완료 percentage 에 따라 progress bar 처름 채워주고, 이름 과 percentage 를 표시한다. 이때 이름과 percentage 는 항상 plan bar 가 있을 경우 표시되어야 한다.
* 플랜\(계획\)은 생성일과 타겟날짜 사이를 plan bar 로 표시한다. 날짜 범위 안에서 plan bar 를 표시하고, 날짜가 스크로되어 범위가 업데이트 되면 plan bar 도 업데이트 한다.
* 계획 리스트의 타임라인을 가로 달력을 일자별로 표시하고, 좌우로 무한 스크롤 되어서 추가 날짜가 나타날 수 있다.



## Integration

### Notion


### Slack


### Jira


### Github


### Gitlab


### OpenAI Codex CLI or Cloud



## BI

### 주간 보고 자동화



## Developer features

### List users \- [link](https://plan42.vrerv.com/users)


### List all emails \- sent by the system for verification



## Directory Tree

### Show directory tree on the left side panel



## Linked Creative

### origin_id 가 있는 Creative 는 Linked Creative 이다.


### Linked Creative 는 origin Creative 로의 연결이 표시되어 클릭하면 원본으로 바로 이동 된다.




