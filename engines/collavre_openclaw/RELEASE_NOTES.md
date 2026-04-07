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

