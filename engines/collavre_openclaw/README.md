# Collavre OpenClaw Integration

This engine enables AI agents in Collavre to use [OpenClaw](https://github.com/openclaw/openclaw) as their LLM backend.

## Installation

The engine is automatically loaded when placed in the `engines/` directory of a Collavre installation.

## Configuration

### Environment Variables

- `OPENCLAW_WEBHOOK_SECRET` - Default webhook secret for verifying inbound requests
- `OPENCLAW_REQUEST_TIMEOUT` - Timeout for outbound requests (default: 30 seconds)

### Setting up an AI Agent with OpenClaw

1. Create an AI agent user in Collavre
2. Set the `llm_vendor` to `"openclaw"`
3. Configure the OpenClaw account with:
   - **Gateway URL**: The URL of your OpenClaw gateway
   - **API Token**: (Optional) For authentication
   - **Channel ID**: (Optional) Specific channel to use

## How it Works

1. When a comment mentions an AI agent with `llm_vendor: "openclaw"`, the system triggers the agent
2. The `OpenclawAdapter` sends the conversation context to the OpenClaw gateway
3. Responses are streamed back and displayed in real-time
4. The adapter supports both synchronous streaming and async callbacks

## API Endpoints

- `POST /openclaw/callback/:account_id` - Webhook for async responses from OpenClaw
- `GET /openclaw/health` - Health check endpoint

## OpenAI API Compatibility

OpenClaw Gateway provides an **OpenAI-compatible Chat Completions endpoint** at `/v1/chat/completions`. This allows tools that support the OpenAI API format to connect to OpenClaw.

### Key Points

| Item | Description |
|------|-------------|
| **Compatibility** | Compatible with OpenAI Chat Completions format (minimal implementation) |
| **Default State** | Disabled by default (must enable in config) |
| **Endpoint** | `POST /v1/chat/completions` |
| **Supported Fields** | `messages`, `stream`, `model`, `user` |

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

Uses Gateway auth configuration. Send a bearer token:

```
Authorization: Bearer <token>
```

- When `gateway.auth.mode="token"`, use `gateway.auth.token` (or `OPENCLAW_GATEWAY_TOKEN`)
- When `gateway.auth.mode="password"`, use `gateway.auth.password` (or `OPENCLAW_GATEWAY_PASSWORD`)

### Agent Routing

Specify which OpenClaw agent to use via the `model` field:

- `model: "openclaw:main"` - Routes to the `main` agent
- `model: "openclaw:<agentId>"` - Routes to a specific agent
- `model: "agent:<agentId>"` - Alias format

Or use a header:

```
x-openclaw-agent-id: <agentId>
```

### Session Behavior

- **Stateless by default**: A new session key is generated for each request
- **Stateful option**: Include an OpenAI `user` string to derive a stable session key across calls

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

### Limitations

This is a minimal OpenAI-compatible implementation. Some advanced OpenAI features may not be fully supported:

- Function calling format may differ
- Vision/multimodal requests have limited support
- Not all OpenAI-specific parameters are implemented

For full details, see the [OpenClaw Gateway HTTP API documentation](https://docs.openclaw.ai/gateway/openai-http-api).

## License

AGPL-3.0, same as Collavre.
