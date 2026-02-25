# CollavreCompletionApi

OpenAI-compatible chat completions API for Collavre.

## Endpoints

- `POST /api/v1/chat/completions` — Chat completion (streaming + non-streaming)
- `GET /api/v1/models` — List accessible AI agents as models

## Authentication

Uses Doorkeeper OAuth Bearer tokens. Pass your OAuth access token as:

```
Authorization: Bearer <oauth_token>
```

Compatible with OpenAI SDK:

```python
from openai import OpenAI
client = OpenAI(
    base_url="https://your-collavre.com/api/v1",
    api_key="<oauth_access_token>"
)
```

## Context Injection

Pass optional headers to inject Collavre context into AI prompts:

- `X-Collavre-Creative: <creative_id>` — Include creative context
- `X-Collavre-Topic: <topic_id>` — Filter context to specific topic

## Installation

Add to your host app's `Gemfile`:

```ruby
gem "collavre_completion_api", path: "engines/collavre_completion_api"
```
