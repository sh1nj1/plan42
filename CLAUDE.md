# CLAUDE Agent Guide

## Purpose
This document captures best practices for integrating Anthropic's Claude models into the project.

## Setup Checklist
- Verify API access and keys are stored using the team's standard secrets management approach.
- Note any environment variables required to initialize Claude clients.
- Link to reusable prompts or templates that Claude-based workflows should follow.
- Gemini-based parent recommendations and streaming responses (PR analysis, `@gemini` replies) now use the
  [`ruby_llm`](https://github.com/crmne/ruby_llm) client. Ensure `GEMINI_API_KEY` is present so `RubyLLM` can configure the
  shared Gemini chat session via `config/initializers/ruby_llm.rb`.

## Collaboration Tips
- Keep dialogue transcripts or prompt iterations in version control when they inform product behavior.
- Record evaluation results and regression checks so other agents can reuse them.
- Cross-reference related guidance in `AGENTS.md` to maintain a cohesive developer experience.

## Autonomous Agent Architecture
- Use the Liquid-rendered system prompts (`AiSystemPromptRenderer`) and RubyLLM transport (`AiClient`) as the foundation for any autonomous loop.
- A full design for running scheduled or evented agents (control loop, data model, safety guardrails, and deployment checklist) lives in [`docs/ai-autonomous-agent.md`](docs/ai-autonomous-agent.md).
- When implementing autonomous behavior, reuse the existing comment-based memory and MCP tool registrations so every agent action remains auditable in the creative thread.

## System Prompt Templates
- AI user system prompts are rendered as [Liquid templates](https://github.com/Shopify/liquid) so you can inject runtime context.
- Available variables:
  - `ai_user`: `id`, `name`, `llm_vendor`, `llm_model`.
  - `creative`: `id`, `description` (plain text), `progress`, `owner_name`.
  - `comment`: `id`, `content`, `user_name`.
  - `payload`: user message text after stripping the mention prefix.
- Templates fall back to the raw prompt if rendering fails; check Rails logs for `AI system prompt rendering failed` warnings when debugging.
