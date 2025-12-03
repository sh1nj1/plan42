# Autonomous AI Agent Architecture

This document outlines how to finalize a production-ready autonomous AI agent inside Plan42 using the existing Liquid prompts, RubyLLM-powered tools, and MCP server support.

## Objectives
- Operate as a proactive teammate that can self-drive tasks (summaries, triage, planning) while responding to mentions.
- Reuse the current AI user model fields (`llm_vendor`, `llm_model`, `system_prompt`, `llm_api_key`, `tools`) and Liquid rendering pipeline so each agent stays configurable per creative.
- Integrate tool calls through the MCP tool registry and RubyLLM tool adapters.
- Keep conversations auditable by persisting every agent action as comments or inbox items.

## System Components
- **Conversation entry**: `Comments::AiResponder` detects `@agent` mentions, builds message history (including creative tree markdown), renders the agent’s Liquid system prompt, and streams responses via `AiClient`. The same scaffolding can be reused for autonomous cycles by swapping the payload and role metadata.
- **Prompt templating**: `AiSystemPromptRenderer` renders Liquid templates with `ai_user`, `creative`, `comment`, and `payload` contexts. Autonomy loops should populate `payload` with the agent’s current intent (e.g., "plan next steps" or "run health check").
- **LLM transport**: `AiClient` wraps `RubyLLM` and exposes streaming completion plus tool execution through `Tools::MetaToolService.ruby_llm_tools`.
- **Tool surface**: MCP tools are registered from creative content via `McpService` and exposed as chat commands through `Comments::McpCommand`. Autonomous agents should call the same tools list defined on the AI user record, including MCP-registered ones.
- **State + memory**: use the existing `Comment` thread as long-term memory; cache short-term loop state (goal, scratchpad, pending tool calls) in Redis or Postgres JSONB on a new `agent_runs` table to keep loops resumable.

## Control Loop Design
1. **Triggering**
   - Manual: mention `@agent` as today.
   - Scheduled: ActiveJob cron (e.g., `AutonomousAgentJob`) runs on cadence per creative or agent setting.
   - Evented: webhook or callbacks on creative changes enqueue a new run.
2. **Plan step**
   - Build a `messages` array identical to `Comments::AiResponder#build_messages`, plus a synthetic `system` note describing the run goal (e.g., "Perform daily status review").
   - Render the Liquid system prompt with a `payload` describing the mission and recent deltas.
3. **Act step**
   - Call `AiClient#chat` with the agent’s `tools` list. When a tool call is emitted, persist it to `agent_runs.actions` and execute via RubyLLM’s tool callback.
   - Stream deltas into a draft comment so teammates see progress.
4. **Observe step**
   - Capture tool results, append them as `assistant` messages, and re-enter `Plan → Act` until the model stops or a max iteration limit is hit.
5. **Commit + notify**
   - Final content becomes a comment; optionally raise an Inbox item when actions changed state (e.g., tasks added). Store the run transcript + tool IO for audits.

## Data Model Extensions
- `agent_runs` (creative_id, ai_user_id, goal, state, context, transcript, iteration_count, next_run_at, status).
- `agent_actions` child records to detail each tool call (name, arguments, result, status, timestamps).
- Optional `agent_configs` per creative to store schedules, max iterations, and safety toggles.

## Safety + Governance
- Enforce allowlists: only expose MCP tools approved on the creative and listed on the AI user record.
- Add guardrail prompts instructing the model to request approval before destructive actions.
- Rate-limit autonomous jobs per creative to avoid loops; include circuit breakers when repeated tool failures occur.
- Log every prompt, tool call, and result for observability (ship to Rails logs + an audit table).

## Implementation Steps
- **Bootstrap job runner**: create `AutonomousAgentJob` to fetch eligible agents and drive the loop using the control steps above.
- **Shared orchestrator**: extract the conversation assembly from `Comments::AiResponder` into a reusable service (`AiConversationBuilder`) so both mention-driven and scheduled runs share context building.
- **Tool execution bridge**: ensure MCP tools register via `McpService.load_active_tools` on boot and mirror the list into the AI user’s `tools` array for RubyLLM to bind.
- **Prompt kits**: ship versioned Liquid prompt templates (e.g., `config/ai_prompts/*.liquid`) for common missions like daily summary, bug triage, or roadmap planning.
- **UI hooks**: surface agent run status in the creative sidebar; allow owners to pause/resume runs and view transcripts.

## Deployment Checklist
- Verify `GEMINI_API_KEY` (or vendor-specific keys) in production and staging.
- Run `McpService.load_active_tools` during deploy or after creative edits to keep tool registry fresh.
- Add cron entry for `AutonomousAgentJob` (e.g., via sidekiq-cron or Heroku scheduler) with per-agent cadence.
- Backfill existing AI users with default tools and Liquid prompts so autonomy can start immediately.
