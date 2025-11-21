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
