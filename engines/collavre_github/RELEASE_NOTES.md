## v0.6.0 (2026-06-04)

### Changes
- 6e3d2728 feat(collavre): Phase 2 GitHub — DB-backed webhook secret, API endpoint, mock toggle (#1266)
- 3d73c334 feat(collavre): Phase 2 OmniAuth — DB-backed Google/GitHub/Notion OAuth keys (#1265)
- 73876b13 feat(channels): topic-badge abstraction + preview MCP tools (#1259)
- 199a0ebf fix(pr_monitor): default chip label/link fallback from channel config (#1255)
- d43ea449 fix(pr_monitor): de-dup closed event, status badge chips, dismiss-on-X (#1242)
- 7cd616ac fix(pr_monitor): auto-provision PR-channel webhook events and re-seed on reactivate (#1240)
- a8cafca7 fix(pr_monitor): seed chip label/link and announce attach in topic (#1239)
- bf9b1d57 feat(channels): GitHub PR comment listener via Channel abstraction (#1238)

## v0.5.1 (2026-04-17)

### Changes
- 813a8a8a refactor: move github integration JS into collavre_github engine (#1218)

## v0.5.0 (2026-04-17)

### Changes
- 64a9d540 fix: prevent NoMethodError when markdown_root_creative is nil during initial sync (#1207)
- 0345f1f0 feat: GitHub markdown datasource with read-only sync (#1201)
- 7e50303f refactor: extract shared error handling in GitHub PR services and Slack jobs (#1203)
- cfd0e0fb fix: resolve openclaw test bootsnap error, replace puts with logger, fix bare rescue, batch N+1 query (#1191)
- 3902cdae refactor: extract IntegrationSetup concern from integration controllers (#1176)

## v0.4.1 (2026-04-09)

### Changes
- 31823b43 chore: daily code cleanup — fix N+1, extract concerns, remove dead code (#1140)

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

