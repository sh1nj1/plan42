## v0.6.4 (2026-06-23)

### Changes
- 36c3f897 feat: typo correction (Phase 0 backend + Phase 1 chat composer) (#1317)
- a688ff6b build(deps): bump rack-session in /engines/collavre_openclaw (#1269)
- da1f34db build(deps): bump erb in /engines/collavre_openclaw (#1268)

## v0.6.3 (2026-06-10)

### Changes
- 71b3adee fix: dedup OpenClaw agent responses across processes via run_id (#1279)

## v0.6.2 (2026-06-04)

### Changes
- 83d558a0 feat(collavre): Phase 3 batch — DB-backed firebase/fcm/llm/openclaw/mail/misc settings (#1267)

## v0.6.1 (2026-04-17)

### Changes
- cfd0e0fb fix: resolve openclaw test bootsnap error, replace puts with logger, fix bare rescue, batch N+1 query (#1191)
- adc3e698 feat(collavre): extract SessionContextResolver for common session management (#1186)
- a06cdbcb fix: replace SQL interpolation with parameterized query and standardize rescue clauses (#1173)
- d1c0bd62 feat: add LLM request timeout to system settings (#1163)

## v0.6.0 (2026-04-08)

### Changes
- 030b0ba5 feat: optimize OpenClaw token usage with conditional context sending (#1133)

## v0.5.0 (2026-04-02)

### Changes
- 75520d21 fix: infer topic_id from comment in OpenClaw session key (#1101)
- 914f3085 fix: send image attachments in openclaw websocket mode (#1075)
- 3a889a69 fix: preserve openclaw callback topic context (#1076)
- ab6ab132 fix(openclaw): send full context in WebSocket mode, matching HTTP behavior
- 3d225af8 feat(openclaw): WebSocket production hardening and bug fixes (#1072)
- a62e4dbc feat: transform inbox into creative-based chat system (#1008)

## v0.4.0 (2026-02-20)

### Changes
- 0d579a9c feat: pass image attachments from comments to AI via RubyLLM (#808)

## v0.3.1 (2026-02-09)

### Changes
- 98e001cf fix: OPENCLAW_TRANSPORT=http as default
- 6e239654 fix: prevent duplication in openclaw proactive msg
- 879c1c31 fix: openclaw duplicated message
- 107bc987 fix: duplicated response in openclaw websocket (#762)
- 9f7c1894 fix(openclaw): use valid protocol schema constants for client id/mode

## v0.3.0 (2026-02-06)

### Changes
- 9b93730c feat: Share WebSocket connection among agents with same gateway URL (#740)
- dc11a660 feat: Proactive message handling for OpenClaw WebSocket (Phase 3) (#736)
- 4f477959 feat: WebSocket client for OpenClaw Gateway (Phase 1 & 2) (#735)

