# Plan: Chat Completion API → WebSocket Migration

## 결정 사항

- **WebSocket gem**: `faye-websocket` (안정적, 검증됨)
- **기존 callback 코드**: 유지 (삭제하지 않음, 나중에 정리)
- **연결 전략**: On-Demand + Keep-Alive

## 현재 구조 (AS-IS)

```
[채팅 요청]
AiAgentService → AiClient → AiClientExtension
  ↓ (vendor == "openclaw")
OpenclawAdapter
  ↓
POST /v1/chat/completions (HTTP SSE streaming)
  ↓
OpenClaw Gateway 응답 (SSE stream → 파싱 → yield)

[프로액티브 메시지]
OpenClaw 크론 실행 → callback_url POST → CallbacksController
  → PendingCallback nonce 검증 → CallbackProcessorJob → Comment 생성
  (현재 미작동: callback 호출 메커니즘 부재)
```

## 목표 구조 (TO-BE)

```
[채팅 요청]
AiAgentService → AiClient → AiClientExtension
  ↓ (vendor == "openclaw")
OpenclawAdapter
  ↓
WebsocketClient (faye-websocket)
  ↓
chat.send → chat event (delta/final) → yield

[프로액티브 메시지]
OpenClaw 크론/하트비트 실행
  → Gateway가 chat event broadcast
  → WebsocketClient가 수신
  → CallbackProcessorJob → Comment 생성

[기존 callback 코드]
CallbacksController, PendingCallback → 유지 (삭제하지 않음)
```

---

## Phase 1: WebSocket 인프라

### 1.1 faye-websocket gem 추가

`collavre_openclaw.gemspec`:
```ruby
spec.add_dependency "faye-websocket", "~> 0.11"
spec.add_dependency "eventmachine", "~> 1.2"
```

### 1.2 WebsocketClient

**파일**: `app/services/collavre_openclaw/websocket_client.rb`

OpenClaw Gateway에 대한 단일 유저 WebSocket 연결을 관리하는 클래스.

**책임:**
- WebSocket 연결 생성 (ws:// 또는 wss://)
- OpenClaw protocol handshake (`connect` request + auth token)
- RPC 요청/응답 매핑 (`type: "req"` → `type: "res"`, id 기반)
- Event 수신 (`type: "event"`, event: "chat")
- Tick 응답 (keepalive)
- 자동 재연결 (exponential backoff)

**프로토콜 흐름:**
```
1. WS 연결 수립
2. Gateway → connect.challenge (nonce)
3. Client → connect request (auth token, role: "operator")
4. Gateway → hello-ok (protocol version, tick interval)
5. 이후 양방향 통신:
   - Client → req (chat.send, chat.history, chat.abort)
   - Gateway → res (응답)
   - Gateway → event (chat delta/final, tick)
```

**인터페이스:**
```ruby
class WebsocketClient
  def initialize(user:)
  def connected?
  def connect!
  def disconnect!

  # RPC 메서드
  def chat_send(session_key:, message:, idempotency_key:, &on_event)
  def chat_history(session_key:, limit: nil)
  def chat_abort(session_key:, run_id: nil)

  # 프로액티브 메시지 콜백 등록
  def on_proactive_message(&handler)

  private
  def handle_message(data)
  def handle_event(event_name, payload)
  def handle_response(id, payload)
  def send_request(method, params)
  def reconnect!
end
```

### 1.3 ConnectionManager

**파일**: `app/services/collavre_openclaw/connection_manager.rb`

유저별 WebSocket 연결 풀 관리. Singleton.

**책임:**
- 유저별 WebsocketClient 생성/캐싱
- Lazy connect (첫 요청 시 연결)
- Idle timeout (30분 미사용 시 해제)
- 앱 종료 시 전체 연결 해제
- Thread-safe access (Mutex)

**인터페이스:**
```ruby
class ConnectionManager
  include Singleton

  def connection_for(user)  # → WebsocketClient (lazy connect)
  def disconnect(user)
  def disconnect_all
  def connected_count
  def status  # → { connected: 3, idle: 1, reconnecting: 0 }
end
```

### 1.4 스레딩 모델

faye-websocket은 EventMachine 기반이므로:
- 별도 EM 스레드에서 WebSocket 연결 관리
- Rails 요청 스레드에서는 `chat_send` 호출 시 블로킹 대기 (Queue 또는 ConditionVariable)
- EM reactor가 실행 중이 아니면 자동 시작

```ruby
# EventMachine reactor 관리
module CollavreOpenclaw
  class EmReactor
    def self.ensure_running!
      return if EM.reactor_running?
      @thread = Thread.new { EM.run }
      sleep 0.1 until EM.reactor_running?
    end
  end
end
```

### 1.5 Configuration 확장

```ruby
# configuration.rb
attr_accessor :websocket_idle_timeout      # 기본: 30분 (1800초)
attr_accessor :websocket_reconnect_max     # 최대 재연결 시도: 10
attr_accessor :websocket_reconnect_base    # 재연결 대기 기본값: 1초
attr_accessor :websocket_connect_timeout   # 연결 타임아웃: 10초
```

---

## Phase 2: Chat 전송 전환

### 2.1 OpenclawAdapter 수정

`chat()` 메서드를 WebSocket 기반으로 변경:

```ruby
def chat(messages, tools: [], &block)
  connection = ConnectionManager.instance.connection_for(@user)

  session_key = build_session_key
  run_id = SecureRandom.uuid
  message_text = format_message_for_ws(messages)

  connection.chat_send(
    session_key: session_key,
    message: message_text,
    idempotency_key: run_id
  ) do |event|
    case event[:state]
    when "delta"
      text = extract_delta_text(event)
      yield text if text.present? && block_given?
    when "final"
      # final은 전체 텍스트 포함 — delta로 이미 yield했으면 스킵
    when "error"
      yield "Error: #{event[:errorMessage]}" if block_given?
    when "aborted"
      # 사용자가 abort한 경우
    end
  end
end
```

### 2.2 메시지 포맷 변환

**HTTP (현재):**
- `messages` 배열 (전체 대화 이력)
- `model` 필드로 agent 지정
- `user` 필드에 callback 정보

**WebSocket (변경):**
- `message` 단일 문자열 (최신 메시지만)
- `sessionKey`로 세션 라우팅
- Gateway가 세션 이력 관리

```ruby
def format_message_for_ws(messages)
  # 마지막 user 메시지만 추출
  last_user = Array(messages).reverse.find { |m|
    role = m[:role] || m["role"]
    %w[user].include?(role.to_s)
  }

  if last_user
    parts = last_user[:parts] || last_user["parts"]
    if parts
      Array(parts).map { |p| p[:text] || p["text"] }.compact.join("\n")
    else
      last_user[:text] || last_user["text"] || last_user[:content] || last_user["content"]
    end
  else
    ""
  end.to_s
end
```

### 2.3 Session Key 전략

변경 없음. 기존 `build_session_key` 로직 그대로 사용:
```
agent:<agent_id>:collavre:<user_id>:creative:<creative_id>:topic:<topic_id>
```

HTTP 헤더 (`x-openclaw-session-key`) → `chat.send` params (`sessionKey`)로 이동만.

### 2.4 HTTP fallback

WebSocket 연결 실패 시 기존 HTTP 방식으로 폴백:

```ruby
def chat(messages, tools: [], &block)
  if websocket_available?
    chat_via_websocket(messages, tools: tools, &block)
  else
    chat_via_http(messages, tools: tools, &block)  # 기존 코드
  end
end
```

---

## Phase 3: 프로액티브 메시지 수신

### 3.1 Event Handler 등록

WebSocket 연결 시 프로액티브 메시지 핸들러 등록:

```ruby
# ConnectionManager에서 연결 생성 시
client = WebsocketClient.new(user: user)
client.on_proactive_message do |event|
  handle_proactive_message(user, event)
end
```

### 3.2 프로액티브 vs 요청 응답 구분

```ruby
# WebsocketClient 내부
def handle_chat_event(payload)
  run_id = payload[:runId]
  session_key = payload[:sessionKey]

  if @pending_runs.key?(run_id)
    # 요청에 대한 응답 → 해당 요청의 콜백으로 전달
    @pending_runs[run_id].call(payload)
  else
    # 프로액티브 메시지 → 핸들러로 전달
    @proactive_handler&.call(payload)
  end
end
```

### 3.3 CallbackProcessorJob 연동

기존 CallbackProcessorJob을 재사용:

```ruby
def handle_proactive_message(user, event)
  content = extract_message_text(event[:message])
  session_key = event[:sessionKey]
  context = parse_session_key(session_key)

  CallbackProcessorJob.perform_later(
    user.id,
    {
      "type" => "proactive",
      "content" => content,
      "context" => {
        "creative_id" => context[:creative_id],
        "thread_id" => context[:topic_id]
      }
    }
  )
end
```

### 3.4 Session Key 파싱

```ruby
def parse_session_key(session_key)
  parts = session_key.to_s.split(":")
  result = {}

  parts.each_with_index do |part, i|
    case part
    when "creative" then result[:creative_id] = parts[i + 1]
    when "topic" then result[:topic_id] = parts[i + 1]
    when "collavre" then result[:user_id] = parts[i + 1]
    end
  end

  result
end
```

---

## Phase 4: 기존 callback 코드 유지

> **결정: 현재 구현 그대로 유지. 삭제하지 않음.**

유지되는 코드:
- `CallbacksController` — HTTP callback 엔드포인트
- `PendingCallback` 모델 — nonce 관리
- `callback_url` / `callback_nonce` 로직 — OpenclawAdapter 내
- `config/routes.rb` — callback route
- DB 테이블 `openclaw_pending_callbacks`

이유:
- WebSocket이 안정화될 때까지 HTTP callback도 병행 가능
- 나중에 WebSocket이 충분히 검증되면 별도 PR로 정리

---

## Phase 5: 테스트

### 5.1 Unit Tests

```ruby
# test/services/websocket_client_test.rb
- connect/disconnect
- chat.send → chat event 수신 → 텍스트 추출
- 프로액티브 메시지 감지 (미등록 runId)
- 재연결 로직 (exponential backoff)
- tick 응답

# test/services/connection_manager_test.rb
- 유저별 연결 생성/재사용
- idle timeout → disconnect
- thread-safe access
- disconnect_all

# test/services/openclaw_adapter_test.rb
- WebSocket 경로 테스트
- HTTP fallback 테스트
- 메시지 포맷 변환
```

### 5.2 Mock WebSocket Server

```ruby
# test/support/mock_openclaw_gateway.rb
class MockOpenclawGateway
  # EventMachine 기반 mock WS 서버
  # - connect handshake 응답
  # - chat.send → chat event 응답
  # - 프로액티브 메시지 시뮬레이션
end
```

---

## 구현 순서

```
Phase 1: WebSocket 인프라                    [PR #1]
  ├─ 1.1 faye-websocket gem 추가
  ├─ 1.2 WebsocketClient 구현
  ├─ 1.3 ConnectionManager 구현
  ├─ 1.4 EM reactor 관리
  └─ 1.5 Configuration 확장 + 테스트

Phase 2: Chat 전환                           [PR #2]
  ├─ 2.1 OpenclawAdapter.chat() → WS 전환
  ├─ 2.2 메시지 포맷 변환
  ├─ 2.3 HTTP fallback 유지
  └─ 2.4 테스트

Phase 3: 프로액티브 메시지                    [PR #3]
  ├─ 3.1 Event handler 등록
  ├─ 3.2 요청/프로액티브 구분
  ├─ 3.3 CallbackProcessorJob 연동
  └─ 3.4 테스트
```

---

## 리스크 & 완화

| 리스크 | 영향 | 완화 |
|--------|------|------|
| WS 연결 끊김 | 프로액티브 메시지 유실 | auto-reconnect + chat.history 복구 |
| EventMachine 호환성 | Puma와 충돌 가능 | 별도 스레드에서 EM 실행 |
| 서버 재시작 | 모든 WS 연결 끊김 | 재시작 후 자동 재연결 |
| Gateway 다운 | 채팅 불가 | HTTP fallback (Phase 2.4) |
| 동시성 버그 | 메시지 유실/중복 | idempotencyKey + Mutex |
| 메모리 증가 | 유저 수 × 연결 | idle timeout (30분) |

## 미해결 사항

### chat.send의 message가 단일 문자열인 문제

- 현재 HTTP: 전체 대화 이력 (`messages` 배열) + 시스템 프롬프트 전송
- WS `chat.send`: `message` 단일 문자열만

**해결 방안:**
1. Gateway가 세션 이력을 관리하므로 최신 메시지만 전송 → 이력은 Gateway가 유지
2. 시스템 프롬프트 → OpenClaw agent config (SOUL.md 등)에서 관리
3. Creative 컨텍스트 → 메시지 앞에 prefix로 포함

**→ Phase 2 구현 시 상세 결정 필요**
