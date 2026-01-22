# CLAUDE Agent Guide

## Purpose
This document provides constitutional context for AI agents working in the Collavre codebase.

## Project Overview

**Collavre** is an experimental platform for small development teams providing:
- Knowledge management (tree-like todo lists and documentation)
- Task management with hierarchical structures
- Real-time chat and AI-powered collaboration
- Third-party integrations (GitHub, Notion, Google Calendar, MCP servers)

The core metaphor is the **"Creative"** — a hierarchical tree-structured item that serves as documentation, task, or chat thread.

## Core Domain Models

| Model | Purpose |
|-------|---------|
| **Creative** | Tree container for work items, docs, discussion. Hierarchical via closure_tree, progress tracking (0.0-1.0), rich HTML descriptions |
| **User** | System user with optional AI agent capabilities (llm_vendor, llm_model, system_prompt) |
| **Comment** | Real-time chat messages within creatives. Threaded by topic, mentions, reactions, images |
| **Topic** | Conversation namespace within a creative |
| **CreativeShare** | Permission grants (no_access, read, feedback, write, admin) |
| **Task** | AI agent execution trigger, tracks task_actions |

## Key Architecture Patterns

### Linked Creative System (origin_id)
- Creative with `origin_id` is a "linked" copy owned by a shared user
- Linked creatives delegate `description`, `progress`, `user` to origin
- Use `effective_origin()` for permission/content lookups
- Critical for multi-owner tree sharing without duplication

### Permission Model
- Hierarchical: permissions cascade from parent to children
- Four levels: `read`, `feedback`, `write`, `admin`
- Cache invalidated on parent moves or user changes
- `PermissionChecker` service enforces access control
- Always call `creative.has_permission?(current_user, :read)` before returning data

### Progress Calculation
- Parent progress = average of children's progress
- Linked creatives inherit origin's progress
- `Creatives::ProgressService` handles cascading updates

### Real-time (ActionCable/Turbo Streams)
- `Comment` broadcasts to `[creative, :comments]` channel
- Singleton consumer in `app/javascript/services/cable.js`
- `CommentPresenceStore` tracks active readers
- Prefer `createSubscription` for new subscriptions

## AI and LLM Integration

### RubyLLM Configuration
- Configured via `config/initializers/ruby_llm.rb`
- Supports Google Gemini models (primary)
- Logs to `log/ruby_llm.log` and `ruby_llm_logs` table
- API key from `GEMINI_API_KEY` env var

### System Prompt Templates
- Uses [Liquid templates](https://github.com/Shopify/liquid) for dynamic prompts
- Available variables:
  - `ai_user`: `id`, `name`, `llm_vendor`, `llm_model`
  - `creative`: `id`, `description` (plain text), `progress`, `owner_name`
  - `comment`: `id`, `content`, `user_name`
  - `payload`: user message text after stripping mention prefix
- Fallback to raw prompt if rendering fails

### Agent Execution Flow
1. Event occurs → `SystemEvents::Dispatcher` routes to matching agents
2. `AiAgentJob` created with context
3. Job calls `AiAgentService#call` which builds message history, renders prompt, streams response
4. Response streamed into new comment via Turbo

## Core Services

| Service | Purpose |
|---------|---------|
| `Creatives::ProgressService` | Calculate/update progress cascades |
| `Creatives::PermissionChecker` | Enforce hierarchical access control |
| `Creatives::TreeFormatter` | Markdown export with hierarchy |
| `Comments::CommandProcessor` | Parse `/command` syntax |
| `Comments::McpCommand` | Execute MCP tool calls |
| `AiAgentService` | Agent execution orchestration |
| `AiClient` | Generic LLM adapter |
| `AiSystemPromptRenderer` | Liquid template rendering |
| `Github::PullRequestAnalyzer` | Gemini-powered PR analysis |

## Integrations

- **GitHub**: Webhook-based PR analysis, auto-posts summary to creative
- **Notion**: OAuth export of creatives as Notion pages
- **Google Calendar**: Event creation from comments
- **MCP Servers**: Remote tool execution via SSE, tools require admin approval

## Tech Stack

| Aspect | Technology |
|--------|------------|
| Framework | Rails 8.x |
| Frontend | Hotwire (Turbo + Stimulus), ViewComponent, React 19 |
| Asset Pipeline | jsbundling-rails with esbuild |
| Package Manager | npm with workspaces |
| Rich Text Editor | Lexical 0.38.x |
| Realtime | ActionCable + SolidCable |
| Background Jobs | SolidQueue |
| Cache | SolidCache |
| Auth | Bcrypt + WebAuthn + OAuth (Google, GitHub, Notion) |
| LLM | RubyLLM → Google Gemini |
| MCP | FastMcp (local) + SSE (remote) |

## JavaScript Build System

- **Build command**: `npm run build` (production) or `npm run build -- --watch` (development)
- **Entry points**: Auto-discovered from `app/javascript/*.{js,jsx}` and `engines/*/app/javascript/*`
- **Output**: `app/assets/builds/` (bundled JS with source maps)
- **Config**: `script/build.cjs` using esbuild with ESM format and automatic JSX transformation
- **Tests**: `npm run test` (Jest with jsdom)

## Lexical Editor (Creative Descriptions)

Creatives use Lexical, a React-based rich text editor, for inline description editing.

### Architecture
- **Factory**: `createInlineEditor()` in `app/javascript/lexical_inline_editor.jsx`
- **React component**: `app/javascript/components/InlineLexicalEditor.jsx`
- **Stimulus integration**: `app/javascript/creative_row_editor.js`
- **Form template**: `app/views/creatives/_inline_edit_form.html.erb`

### Data Flow
Creative HTML → Lexical editor → `$generateHtmlFromNodes()` → auto-save to `creative[description]`

### Features
- Rich text: headings, lists, quotes, code blocks, text formatting
- File uploads: images and attachments via Rails Direct Upload
- Link management: auto-link detection, link popup UI
- Custom nodes: `ImageNode`, `AttachmentNode`

### Keyboard Shortcuts
- `Enter + Shift` - Add sibling creative
- `Enter + Alt` - Add child creative
- `Cmd/Ctrl + Shift + .` - Level down (make child)
- `Cmd/Ctrl + Shift + ,` - Level up (make sibling)
- Arrow keys at edges - Navigate between creatives
- `Escape` - Close editor

## Guidelines for AI Agents

1. **Linked Creatives**: Always check `origin_id`. Use `effective_origin()` for lookups
2. **Permission-First**: Call `has_permission?` before returning data
3. **Async Operations**: Long-running AI operations go through `AiAgentJob`
4. **Tool Registration**: Dynamic tools require ownership + admin approval
5. **Broadcast Awareness**: Comment creation triggers broadcasts; respect `private` flag
6. **Streaming**: Use `AiClient#chat` with block yield for real-time updates
7. **Logging**: Tool executions go to `ActivityLog`, LLM interactions to `ruby_llm_logs`

## Key Configuration Files

| File | Purpose |
|------|---------|
| `config/initializers/ruby_llm.rb` | RubyLLM + Gemini config |
| `config/initializers/auth_provider_registry.rb` | Auth provider registration |
| `config/initializers/mcp_tools.rb` | Auto-load MCP tools on boot |
| `AGENTS.md` | Related agent guidance |
