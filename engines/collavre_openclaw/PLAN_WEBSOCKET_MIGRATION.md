# Plan: Chat Completion API → WebSocket Migration

## Decisions

- **WebSocket gem**: `faye-websocket` (stable, proven)
- **Existing callback code**: Keep (do not delete, clean up later)
- **Connection strategy**: On-Demand + Keep-Alive

## Current Architecture (AS-IS)

```
[Chat Request]
AiAgentService → AiClient → AiClientExtension
  ↓ (vendor == "openclaw")
OpenclawAdapter
  ↓
POST /v1/chat/completions (HTTP SSE streaming)
  ↓
OpenClaw Gateway response (SSE stream → parse → yield)

[Proactive Messages]
OpenClaw cron runs → callback_url POST → CallbacksController
  → PendingCallback nonce verification → CallbackProcessorJob → Comment creation
  (Currently non-functional: no callback invocation mechanism)
```

## Target Architecture (TO-BE)

```
[Chat Request]
AiAgentService → AiClient → AiClientExtension
  ↓ (vendor == "openclaw")
OpenclawAdapter
  ↓
WebsocketClient (faye-websocket)
  ↓
chat.send → chat event (delta/final) → yield

[Proactive Messages]
OpenClaw cron/heartbeat runs
  → Gateway broadcasts chat event
  → WebsocketClient receives
  → CallbackProcessorJob → Comment creation

[Existing Callback Code]
CallbacksController, PendingCallback → Kept (not deleted)
```

---

## Phase 1: WebSocket Infrastructure

### 1.1 Add faye-websocket gem

`collavre_openclaw.gemspec`:
```ruby
spec.add_dependency "faye-websocket", "~> 0.11"
spec.add_dependency "eventmachine", "~> 1.2"
```

### 1.2 WebsocketClient

**File**: `app/services/collavre_openclaw/websocket_client.rb`

Manages a single user's WebSocket connection to the OpenClaw Gateway.

**Responsibilities:**
- WebSocket connection creation (ws:// or wss://)
- OpenClaw protocol handshake (`connect` request + auth token)
- RPC request/response mapping (`type: "req"` → `type: "res"`, id-based)
- Event reception (`type: "event"`, event: "chat")
- Tick response (keepalive)
- Auto-reconnect (exponential backoff)

**Protocol Flow:**
```
1. Establish WS connection
2. Gateway → connect.challenge (nonce)
3. Client → connect request (auth token, role: "operator")
4. Gateway → hello-ok (protocol version, tick interval)
5. Bidirectional communication:
   - Client → req (chat.send, chat.history, chat.abort)
   - Gateway → res (response)
   - Gateway → event (chat delta/final, tick)
```

**Interface:**
```ruby
class WebsocketClient
  def initialize(user:)
  def connected?
  def connect!
  def disconnect!

  # RPC methods
  def chat_send(session_key:, message:, attachments: nil, idempotency_key:, &on_event)
  def chat_history(session_key:, limit: nil)
  def chat_abort(session_key:, run_id: nil)

  # Register proactive message callback
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

**File**: `app/services/collavre_openclaw/connection_manager.rb`

Per-user WebSocket connection pool management. Singleton.

**Responsibilities:**
- Per-user WebsocketClient creation/caching
- Lazy connect (connects on first request)
- Idle timeout (disconnects after 30 minutes of inactivity)
- Graceful shutdown on app exit
- Thread-safe access (Mutex)

**Interface:**
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

### 1.4 Threading Model

faye-websocket is EventMachine-based:
- WebSocket connections managed in a separate EM thread
- Rails request threads block on `chat_send` calls (via Queue or ConditionVariable)
- EM reactor auto-starts if not running

```ruby
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

### 1.5 Configuration Extension

```ruby
# configuration.rb
attr_accessor :ws_idle_timeout        # Default: 30 min (1800s)
attr_accessor :ws_reconnect_max       # Max reconnect attempts: 10
attr_accessor :ws_reconnect_base_delay # Reconnect base delay: 1s
attr_accessor :ws_connect_timeout     # Connect timeout: 10s
```

---

## Phase 2: Chat Transport Switch

### 2.1 OpenclawAdapter Modification

Change `chat()` method to WebSocket-based:

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
      # final contains full text — skip if already yielded via deltas
    when "error"
      yield "Error: #{event[:errorMessage]}" if block_given?
    when "aborted"
      # User aborted
    end
  end
end
```

### 2.2 Message Format Conversion

**HTTP (current):**
- `messages` array (full conversation history)
- `model` field for agent routing
- `user` field with callback info

**WebSocket (new):**
- `message` single string (latest message only)
- `sessionKey` for session routing
- Gateway manages session history

```ruby
def format_message_for_ws(messages)
  # Extract only the last user message
  last_user = Array(messages).reverse.find { |m|
    role = m[:role] || m["role"]
    role.to_s == "user"
  }

  return "" unless last_user

  parts = last_user[:parts] || last_user["parts"]
  if parts
    Array(parts).map { |p| p[:text] || p["text"] }.compact.join("\n")
  else
    last_user[:text] || last_user["text"] || last_user[:content] || last_user["content"]
  end.to_s
end
```

### 2.3 Session Key Strategy

No change. Use existing `build_session_key` logic:
```
agent:<agent_id>:collavre:<user_id>:creative:<creative_id>:topic:<topic_id>
```

HTTP header (`x-openclaw-session-key`) → `chat.send` params (`sessionKey`).

### 2.4 HTTP Fallback

Fall back to existing HTTP method on WebSocket connection failure:

```ruby
def chat(messages, tools: [], &block)
  if websocket_available?
    chat_via_websocket(messages, tools: tools, &block)
  else
    chat_via_http(messages, tools: tools, &block)  # existing code
  end
end
```

---

## Phase 3: Proactive Message Reception

### 3.1 Event Handler Registration

Register proactive message handler on WebSocket connection:

```ruby
# In ConnectionManager on connection creation
client = WebsocketClient.new(user: user)
client.on_proactive_message do |event|
  handle_proactive_message(user, event)
end
```

### 3.2 Distinguishing Request Response vs Proactive

```ruby
# Inside WebsocketClient
def handle_chat_event(payload)
  run_id = payload[:runId]

  if @pending_runs.key?(run_id)
    # Response to a request → forward to request callback
    @pending_runs[run_id].call(payload)
  else
    # Proactive message → forward to handler
    @proactive_handler&.call(payload)
  end
end
```

### 3.3 CallbackProcessorJob Integration

Reuse existing CallbackProcessorJob:

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

### 3.4 Session Key Parsing

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

## Phase 4: Keep Existing Callback Code

> **Decision: Keep current implementation as-is. Do not delete.**

Code that remains:
- `CallbacksController` — HTTP callback endpoint
- `PendingCallback` model — nonce management
- `callback_url` / `callback_nonce` logic — in OpenclawAdapter
- `config/routes.rb` — callback route
- DB table `openclaw_pending_callbacks`

Rationale:
- HTTP callback can run in parallel until WebSocket is proven stable
- Clean up in a separate PR once WebSocket is fully validated

---

## Phase 5: Tests

### 5.1 Unit Tests

```ruby
# test/services/websocket_client_test.rb
- connect/disconnect
- chat.send → chat event reception → text extraction
- Proactive message detection (unregistered runId)
- Reconnect logic (exponential backoff)
- Tick response

# test/services/connection_manager_test.rb
- Per-user connection creation/reuse
- Idle timeout → disconnect
- Thread-safe access
- disconnect_all

# test/services/openclaw_adapter_test.rb
- WebSocket path tests
- HTTP fallback tests
- Message format conversion
```

### 5.2 Mock WebSocket Server

```ruby
# test/support/mock_openclaw_gateway.rb
class MockOpenclawGateway
  # EventMachine-based mock WS server
  # - connect handshake response
  # - chat.send → chat event response
  # - Proactive message simulation
end
```

---

## Implementation Order

```
Phase 1: WebSocket Infrastructure              [PR #1]
  ├─ 1.1 Add faye-websocket gem
  ├─ 1.2 Implement WebsocketClient
  ├─ 1.3 Implement ConnectionManager
  ├─ 1.4 EM reactor management
  └─ 1.5 Configuration extension + tests

Phase 2: Chat Transport Switch                 [PR #2]
  ├─ 2.1 OpenclawAdapter.chat() → WS switch
  ├─ 2.2 Message format conversion
  ├─ 2.3 HTTP fallback retained
  └─ 2.4 Tests

Phase 3: Proactive Messages                    [PR #3]
  ├─ 3.1 Event handler registration
  ├─ 3.2 Request/proactive distinction
  ├─ 3.3 CallbackProcessorJob integration
  └─ 3.4 Tests
```

---

## Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| WS connection drops | Proactive message loss | Auto-reconnect + chat.history recovery |
| EventMachine compatibility | Possible conflict with Puma | Run EM in separate thread |
| Server restart | All WS connections dropped | Auto-reconnect after restart |
| Gateway down | Chat unavailable | HTTP fallback (Phase 2.4) |
| Concurrency bugs | Message loss/duplication | idempotencyKey + Mutex |
| Memory increase | Users × connections | Idle timeout (30 min) |

## Open Questions

### chat.send message is a single string

- Current HTTP: sends full conversation history (`messages` array) + system prompt
- WS `chat.send`: single `message` string only

**Resolution:**
1. Gateway manages session history, so send only the latest message → history maintained by Gateway
2. System prompt → managed in OpenClaw agent config (SOUL.md etc.)
3. Creative context → included as message prefix

**→ Detailed decision made during Phase 2 implementation**
