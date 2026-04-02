## v0.4.0 (2026-04-02)

### Changes
- 0365a14b refactor: move comment dispatch from controller to model callback (#1086)
- cacedf7c feat(github): complete OAuth flow in popup with repository selection (#977)

## v0.3.3 (2026-03-12)

### Changes
- f782b351 fix: move host-app migrations to their respective engines (#963)

## v0.3.2 (2026-03-12)

### Changes
- dc0d02ae feat: upgrade AI model from gemini-2.5-flash to gemini-3-flash-preview

## v0.3.0 (2026-02-20)

### Changes
- 23a5ec0a refactor: remove unused github_gemini_prompt column and UI (#837)
- 2a6911d9 fix: restrict creative progress updates to 100% on leaf nodes only (#830)
- 997eb7c9 fix: pass creative_id to GitHub PR Analyzer tools (#815)
- 2cf79938 feat: add creative_batch_service tool with approval requirement (#814)
- 8f9a96bc fix: github integration modal duplicate message and missing links (#806)
- f577f736 fix: store GitHub integration links on origin creative (#807)
- fcda7659 docs: consolidate GitHub integration docs into collavre_github engine (#794)
- 1f03143d feat: add agent_conf YAML field for AI agent context settings (#790)

## v0.2.1 (2026-02-12)

### Changes
- 1d36f7da fix: correct GitHub PR Analyzer routing expression (#769)

## v0.2.0 (2026-02-09)

### Changes
- 885e3c31 feat: add AgentOrchestrator with Matcher component (#751)
- f6c42d22 docs: update collavre_github README with MCP tools and architecture
- 4f1589c4 feat: add GitHub PR Analyzer seed AI agent (#750)
- 470596b3 refactor: convert GitHub webhooks to system comments (#748)

