# Slack Integration Plan (Collavre Plugin Engine)

콜라브 레일즈 엔진(`engines/collavre`)에 의존하는 **플러그인 레일즈 엔진** 형태로 Slack 연동을 설계합니다. Notion 연동과 유사하게 **특정 크리에이티브를 Slack 채널에 연결**하고 **채팅 메시지를 전송**할 수 있도록 구성합니다.

## 목표

- 크리에이티브 ↔ Slack 채널 **1:1 연결**
- 연결된 채널로 메시지 전송(수동/자동)
- Slack OAuth 설치 및 토큰 관리
- 안정적인 전송(백그라운드 잡, 재시도, 레이트리밋 대응)

## 엔진 구조(안)

```
engines/
  collavre_slack/
    app/
      controllers/
      jobs/
      models/
      services/
    config/
    db/
    lib/
```

- **Collavre 의존성**: `collavre` 엔진의 크리에이티브/권한 모델을 참조.
- **Isolation**: 엔진 네임스페이스 `CollavreSlack` 사용.
- **마이그레이션 위치**: `engines/collavre_slack/db/migrate` 내부에 포함.

## 핵심 도메인 모델

### 1) SlackAccount
- 사용자별 Slack 설치 정보 저장
- 필드 예시
  - `user_id` (Collavre 사용자)
  - `team_id`, `team_name`
  - `access_token` (bot token)
  - `authed_user_id`
  - `scopes`, `token_expires_at` (옵션)

### 2) SlackChannelLink
- 크리에이티브 ↔ 채널 **1:1 연결**
- 필드 예시
  - `creative_id`
  - `slack_account_id`
  - `channel_id`, `channel_name`
  - `created_by_id` (연결 생성자)
  - `is_active`
  - `unique_index` (creative_id, channel_id)

### 3) SlackMessageLog (선택)
- 메시지 전송 이력 저장
- 필드 예시
  - `slack_channel_link_id`
  - `sender_id`
  - `message_ts`, `status`, `error_message`

### 4) SlackUserMapping
- Slack 사용자 ↔ Collavre 사용자 매핑
- 필드 예시
  - `slack_user_id`
  - `collavre_user_id`
  - `slack_account_id`
  - `display_name`, `email`

### 5) MentionMapping (규칙/헬퍼로 구현 가능)
- Slack 멘션 ↔ Collavre 멘션 매핑
- 규칙
  - Slack의 `<@U123>` 멘션을 Collavre 사용자 ID로 치환
  - 매핑이 없을 경우 텍스트로 유지하고 알림만 기록

## 주요 서비스/컴포넌트

### SlackClient
- Slack Web API 래퍼
- 책임: OAuth 교환, 채널 조회, 메시지 전송

### SlackIntegrationService
- 비즈니스 로직 집합
- 책임: 계정 연결, 채널 링크 생성/해제, 전송 요청

### SlackMessageDispatcher
- 메시지 전송용 서비스
- 책임: 포맷팅, 큐잉, 재시도, 레이트리밋 대응

### SlackEventHandler
- Slack 이벤트 수신 처리
- 책임: 이벤트 검증, Collavre 채팅으로 전달할 페이로드 정규화

## 컨트롤러 설계(예시)

### OAuth
- `SlackAuthController`
  - `GET /auth/slack` → Slack OAuth 시작
  - `GET /auth/slack/callback` → 토큰 교환 및 SlackAccount 생성

### Integration CRUD
- `Creatives::SlackIntegrationsController`
  - `GET /creatives/:creative_id/slack_integrations`
  - `POST /creatives/:creative_id/slack_integrations` (채널 연결)
  - `DELETE /creatives/:creative_id/slack_integrations/:id`

### Message API
- `SlackMessagesController`
  - `POST /creatives/:creative_id/slack_messages`

### Events API
- `SlackEventsController`
  - `POST /slack/events` (이벤트 구독 엔드포인트)

## 백그라운드 잡

- `SlackMessageJob`
  - Slack API 호출 전담
  - 실패 시 재시도, 레이트리밋 처리

- `SlackInboundMessageJob`
  - Slack 이벤트 메시지를 Collavre 채팅으로 비동기 전송
  - Collavre 채팅 전송 흐름에 영향 없도록 분리

- `SlackChannelSyncJob` (선택)
  - 주기적으로 채널 목록 동기화

## Slack 앱 설정

### OAuth Scopes
- Bot Token Scopes (예시)
  - `chat:write`
  - `channels:history` (이벤트 수신용)
  - `channels:read`
  - `groups:read`
  - `im:read`
  - `mpim:read`

### Redirect URL
- `https://yourdomain.com/auth/slack/callback`

## 메시지 전송 시나리오

1. 사용자가 크리에이티브에서 Slack 연결 생성
2. 연결된 채널 선택
3. 메시지 입력 또는 자동 이벤트(예: 상태 변경)
4. `SlackMessageJob`이 비동기로 전송 (콜라브 채팅 전송 흐름에 영향 없음)
5. `SlackMessageLog` 기록 및 UI에 상태 표시

## 역방향 동기화 (Slack → Collavre 채팅)

- Slack 이벤트(Webhook)로 수신된 메시지를 Collavre 채팅으로 전달
- Slack 이벤트 수신 컨트롤러에서 최소 검증 후 비동기 잡으로 위임
- Slack 메시지 텍스트/첨부를 Collavre 채팅 포맷으로 변환
- 사용자/멘션 매핑을 적용해 Collavre 사용자로 정확히 연결

## 권한/보안 고려사항

- **크리에이티브 권한 검사**: Collavre 권한 모델과 통합
- **토큰 암호화**: Rails credentials 또는 ActiveRecord Encryption
- **리미트 처리**: 429 응답 시 재시도

## 운영 설정

- 필수 환경 변수: `SLACK_CLIENT_ID`, `SLACK_CLIENT_SECRET`, `SLACK_SIGNING_SECRET`, `SLACK_REDIRECT_URI`
- 선택 환경 변수: `SLACK_SCOPES` (기본값 제공)
- 누락 이벤트 대응: `SlackChannelSyncJob`으로 채널 히스토리를 재동기화하고, 마지막 동기화 시각을 기록

## UI/UX 플로우(간단)

- 크리에이티브 설정 → "Slack 연결" 탭 추가
- Slack OAuth 연결
- 채널 목록 선택 후 연결 생성
- 메시지 입력창 또는 자동화 설정

## 단계별 구현 로드맵

### Phase 1: 최소 기능(MVP)
- Slack OAuth 연결
- 채널 리스트 조회
- 크리에이티브 ↔ 채널 1:1 연결
- 메시지 전송
- Slack → Collavre 채팅 역방향 전달(기본 메시지/멘션)

### Phase 2: 안정성/운영
- 레이트리밋 대응, 재시도
- 전송 로그 및 상태 표시
- 테스트 강화

### Phase 3: 고급 기능
- 자동 이벤트 기반 전송
- 멀티 채널/멀티 워크스페이스
- 메시지 템플릿/서식 지원(Block Kit)

## 상세 계획 및 태스크 세분화

> 목표: Collavre 채팅 전송 흐름에 영향 없이 Slack 연동을 제공하고, Slack ↔ Collavre 양방향 메시징과 사용자/멘션 매핑을 안정적으로 운영한다.

### Milestone 0: 사전 준비/정의
- [x] Slack 앱 생성 및 기본 설정 정의(리다이렉트 URL, Event Subscriptions URL 확정)
- [x] 권한/스코프 확정(`chat:write`, `channels:history` 등)
- [x] 엔진 네임스페이스/경로 확정(`engines/collavre_slack`)
- [x] 마이그레이션 위치 확정(`engines/collavre_slack/db/migrate`)

### Milestone 1: 데이터 모델/마이그레이션
- [x] `SlackAccount` 모델/마이그레이션 생성
  - [x] OAuth 토큰/팀 정보 저장 필드
  - [x] 토큰 암호화(ActiveRecord Encryption or credentials)
- [x] `SlackChannelLink` 모델/마이그레이션 생성
  - [x] `creative_id`, `channel_id`, `slack_account_id`, `is_active` 필드
  - [x] `creative_id + channel_id` 유니크 인덱스
- [x] `SlackUserMapping` 모델/마이그레이션 생성
  - [x] `slack_user_id`, `collavre_user_id`, `slack_account_id`
- [x] `SlackMessageLog` 모델/마이그레이션 생성(옵션)

### Milestone 2: Slack OAuth/설치 플로우
- [x] `SlackAuthController` 구현
  - [x] OAuth 시작, 콜백 처리, `SlackAccount` 생성/갱신
- [x] `SlackClient` 구현
  - [x] OAuth token exchange
  - [x] 채널 리스트 조회

### Milestone 3: 크리에이티브 ↔ 채널 연결
- [x] `Creatives::SlackIntegrationsController` 구현
  - [x] 채널 조회/연결/해제
- [x] 권한 체크 (Collavre 정책)
- [x] 중복 연결 방지 로직(유니크 인덱스 + 검증)

### Milestone 4: Slack → Collavre 메시지 역방향 전달
- [x] `SlackEventsController` 구현
  - [x] Slack 서명 검증
  - [x] 이벤트 필터링(봇 메시지 제외 등)
- [x] `SlackEventHandler` 구현
  - [x] Slack 이벤트를 Collavre 채팅 페이로드로 정규화
  - [x] 첨부/스레드 변환 규칙 정의
- [x] `SlackInboundMessageJob` 구현
  - [x] 비동기 전송으로 Collavre 채팅 흐름에 영향 없음 보장
- [x] 사용자/멘션 매핑 적용
  - [x] `SlackUserMapping` 기반 사용자 매핑
  - [x] 멘션 치환 규칙(MentionMapping)

### Milestone 5: Collavre → Slack 메시지 전송
- [x] `SlackMessageDispatcher` 구현
  - [x] 포맷팅/큐잉/레이트리밋 대응
- [x] `SlackMessageJob` 구현
  - [x] Slack API 전송, 재시도 정책 적용
- [x] `SlackMessageLog` 기록(옵션)

### Milestone 6: 운영/안정화
- [x] 레이트리밋/재시도 정책 튜닝
- [x] 전송 실패/재시도 알림 UX
- [x] 채널 목록 동기화 잡(`SlackChannelSyncJob`) 검토
- [x] Slack 이벤트 누락 대비 재동기화 플로우 정의

### Milestone 7: 테스트/문서화
- [x] 모델 테스트(`SlackAccount`, `SlackChannelLink`, `SlackUserMapping`)
- [x] 서비스 테스트(`SlackClient`, `SlackEventHandler`, `SlackMessageDispatcher`)
- [x] 컨트롤러 테스트(OAuth, 메시지 전송, 이벤트 수신)
- [x] 시스템 테스트(크리에이티브 설정 화면)
- [x] 운영 문서/트러블슈팅 정리

## 테스트 전략

- 모델 테스트: SlackAccount, SlackChannelLink, SlackUserMapping
- 서비스 테스트: SlackClient, SlackMessageDispatcher, SlackEventHandler
- 컨트롤러 테스트: OAuth, 메시지 전송, 이벤트 수신
- 시스템 테스트: 크리에이티브 UI에서 채널 연결 플로우

## 리스크 및 완화

- **토큰 만료/회수**: 재인증 플로우 제공
- **채널 접근 불가**: 사용자에게 권한 요청 안내
- **Slack API 제한**: 비동기 처리 + 백오프

## 구현 체크리스트

- [x] 엔진 구조 생성
- [x] OAuth 설정 및 credentials 추가
- [x] 모델 및 마이그레이션
- [x] API/서비스 구현
- [x] UI 연결
- [x] 테스트 작성 및 문서화
