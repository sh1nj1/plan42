# How to configure MCP remote servers

## Create OAuth Application and PAT

Profile > OAuth Applications > New Application
Create Personal Access Token after creating oauth application

## Google Antigravity

```json
{
    "mcpServers": {
        "collavre-mcp-server": {
            "command": "npx",
            "args": [
                "mcp-remote",
                "http://localhost:3000/mcp/sse",
                "--header",
                "Authorization: Bearer ${AUTH_TOKEN}"
            ],
            "env": {
                "AUTH_TOKEN": "..."
            }
        }
    }
}
```