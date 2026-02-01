# Collavre OpenClaw Integration

This engine enables AI agents in Collavre to use [OpenClaw](https://github.com/openclaw/openclaw) as their LLM backend, with support for bidirectional communication.

## Features

- **OpenAI-compatible API**: Uses OpenClaw's `/v1/chat/completions` endpoint
- **Streaming responses**: Real-time streaming of AI responses
- **Proactive messaging**: OpenClaw can send messages to Collavre without user prompt
- **Secure callbacks**: Nonce-based authentication for callback requests (no tokens exposed)
- **Topic-based sessions**: Each Topic gets its own OpenClaw session (isolated context)
- **Multi-user support**: Multiple users can share the same Topic context with sender attribution

## Installation

The engine is automatically loaded when placed in the `engines/` directory of a Collavre installation.

### Run Migrations

```bash
bin/rails db:migrate
```

## Configuration

### Environment Variables

- `OPENCLAW_WEBHOOK_SECRET` - Default webhook secret for verifying inbound requests
- `OPENCLAW_REQUEST_TIMEOUT` - Timeout for outbound requests (default: 180 seconds)

### Setting up an AI Agent with OpenClaw

1. Create an AI agent user in Collavre
2. Set the `llm_vendor` to `"openclaw"`
3. Configure the OpenClaw account with:
   - **Gateway URL**: The URL of your OpenClaw gateway
   - **API Token**: (Optional) For authentication to OpenClaw
   - **Channel ID**: (Optional) Specific channel to use

## Session Mapping

Collavre's structure maps to OpenClaw sessions as follows:

```
Collavre                          OpenClaw
─────────────────────────────────────────────────────
Creative (Chat Room)
  └── Topic A ──────────────────→ Session A
  │     ├── [User1]: "Hello"      (shared context)
  │     ├── [User2]: "Hi there"
  │     └── AI: "Hello everyone!"
  │
  └── Topic B ──────────────────→ Session B
        └── [User1]: "New topic"   (isolated context)
```

**Key concepts:**
- **Topic = Session**: Each Topic gets its own OpenClaw session
- **Shared context**: All users in the same Topic share the conversation history
- **User attribution**: Messages include sender name: `[Username]: message`
- **Session key**: Stable key based on `account:creative:topic` (not nonce)

### Session Key Format

```
collavre:<account_id>:creative:<creative_id>:topic:<topic_id>
```

This key is sent via `x-openclaw-session-key` header to ensure stable session routing.

## How it Works

### Request Flow (Collavre → OpenClaw)

```
User mentions AI agent in Collavre
    ↓
OpenclawAdapter builds request with context
    ↓
Creates PendingCallback with secure nonce
    ↓
Sends request to OpenClaw /v1/chat/completions
    ↓
Streams response back to Collavre
```

### Callback Flow (OpenClaw → Collavre)

```
OpenClaw wants to send proactive message
    ↓
Extracts nonce from user context
    ↓
POST /openclaw/callback/:account_id
    { "nonce": "...", "type": "proactive", "content": "..." }
    ↓
Collavre verifies nonce (one-time use)
    ↓
Creates comment on the creative
```

## API Endpoints

### `POST /openclaw/callback/:account_id`

Webhook endpoint for receiving messages from OpenClaw.

**Authentication Methods** (in priority order):

1. **Nonce** (recommended, most secure):
   ```json
   {
     "nonce": "abc123...",
     "type": "proactive",
     "content": "Hello from OpenClaw!"
   }
   ```
   - Nonce is provided in the `user` field when Collavre sends requests
   - One-time use, expires after 10 minutes
   - No token exposure

2. **HMAC Signature**:
   ```
   X-OpenClaw-Signature: <hmac-sha256-hex>
   ```
   - Signature = HMAC-SHA256(api_token, request_body)

3. **Bearer Token**:
   ```
   Authorization: Bearer <api_token>
   ```

### Payload Types

**Proactive Message** (OpenClaw initiates):
```json
{
  "type": "proactive",
  "nonce": "callback_nonce_from_user_context",
  "content": "This is a proactive message from AI!",
  "creative_id": 123,  // Optional if using nonce
  "thread_id": 456     // Optional
}
```

**Response** (async response to request):
```json
{
  "type": "response",
  "nonce": "...",
  "content": "AI response content",
  "context": {
    "comment_id": 789  // Updates existing comment
  }
}
```

**Error**:
```json
{
  "type": "error",
  "nonce": "...",
  "error": "Rate limit exceeded"
}
```

### `GET /openclaw/health`

Health check endpoint.

## Security

### Nonce-based Authentication

When Collavre sends a request to OpenClaw, it includes callback information in the `user` field:

```json
{
  "model": "openclaw",
  "messages": [...],
  "user": "collavre:{\"callback_url\":\"https://collavre.com/openclaw/callback/1\",\"callback_nonce\":\"abc123...\",\"creative_id\":456}"
}
```

The nonce:
- Is unique per request
- Expires after 10 minutes
- Can only be used once (consumed on verification)
- Is tied to a specific account

This means:
- **No tokens are transmitted** in the callback request
- **Replay attacks are prevented** (nonce is consumed)
- **Expired requests are rejected**
- **Cross-account attacks are blocked** (nonce is bound to account)

### Cleanup

Expired pending callbacks are automatically cleaned up. You can also run:

```ruby
CollavreOpenclaw::PendingCallback.cleanup_expired!
```

## OpenAI API Compatibility

OpenClaw Gateway provides an **OpenAI-compatible Chat Completions endpoint** at `/v1/chat/completions`.

### Enabling the Endpoint

In your OpenClaw Gateway config (`openclaw.config.json5`):

```json5
{
  gateway: {
    http: {
      endpoints: {
        chatCompletions: { enabled: true }
      }
    }
  }
}
```

### Authentication

Send a bearer token:
```
Authorization: Bearer <token>
```

### Example: Non-streaming Request

```bash
curl -sS http://127.0.0.1:18789/v1/chat/completions \
  -H "Authorization: Bearer $OPENCLAW_GATEWAY_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "openclaw:main",
    "messages": [{"role":"user","content":"Hello!"}]
  }'
```

### Example: Streaming Request (SSE)

```bash
curl -N http://127.0.0.1:18789/v1/chat/completions \
  -H "Authorization: Bearer $OPENCLAW_GATEWAY_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "openclaw:main",
    "stream": true,
    "messages": [{"role":"user","content":"Hello!"}]
  }'
```

## OpenClaw Callback (For OpenClaw Users)

When OpenClaw receives a request from Collavre, the `user` field contains callback information:

```
collavre:{"callback_url":"https://...","callback_nonce":"...","creative_id":123}
```

To send a proactive message back:

```bash
# Parse the user field to extract callback info
CALLBACK_URL="https://collavre.com/openclaw/callback/1"
NONCE="abc123..."

# Send proactive message (no auth header needed - nonce is the auth)
curl -X POST "$CALLBACK_URL" \
  -H "Content-Type: application/json" \
  -d '{
    "type": "proactive",
    "nonce": "'"$NONCE"'",
    "content": "Hello from OpenClaw!"
  }'
```

## License

AGPL-3.0, same as Collavre.
