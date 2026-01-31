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

## License

AGPL-3.0, same as Collavre.
