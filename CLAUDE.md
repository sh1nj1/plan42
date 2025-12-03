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

## MCP Tools
- `Tools::GitRepositorySearchService` (tool name: `git_repository_search`) lets agents:
  - clone GitHub repositories with `action: "clone"` by passing `repo: { url, pat }` and a destination `root_path` (relative
    paths are resolved from `Rails.root`).
  - search this or a cloned repo with `action: "search"`, providing `query` for ripgrep, `file_path` with `start_line`/
    `line_count` for file reads, and `max_results` to bound match counts. You can target different repositories with
    `root_path`.

## System Prompt Templates
- AI user system prompts are rendered as [Liquid templates](https://github.com/Shopify/liquid) so you can inject runtime context.
- Available variables:
  - `ai_user`: `id`, `name`, `llm_vendor`, `llm_model`.
  - `creative`: `id`, `description` (plain text), `progress`, `owner_name`.
  - `comment`: `id`, `content`, `user_name`.
  - `payload`: user message text after stripping the mention prefix.
- Templates fall back to the raw prompt if rendering fails; check Rails logs for `AI system prompt rendering failed` warnings when debugging.
