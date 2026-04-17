## v0.2.6 (2026-04-17)

### Changes
- 7e50303f refactor: extract shared error handling in GitHub PR services and Slack jobs (#1203)
- 7718c7d1 fix: add permission checks for IDOR and HTML-escape for XSS vulnerabilities (#1190)
- e2a11327 refactor: extract shared IntegrationWizard JS module from modal wizards (#1177)
- 3902cdae refactor: extract IntegrationSetup concern from integration controllers (#1176)

## v0.2.5 (2026-04-09)

### Changes
- ddd75680 fix: add ownership checks for user profile, AI user, and Slack account (#1147)
- 390cb1f9 fix: patch XSS vulnerabilities and update action_text-trix (#1145)
- 31823b43 chore: daily code cleanup — fix N+1, extract concerns, remove dead code (#1140)

## v0.2.4 (2026-04-02)

### Changes
- 0365a14b refactor: move comment dispatch from controller to model callback (#1086)
- a62e4dbc feat: transform inbox into creative-based chat system (#1008)

## v0.2.3 (2026-03-16)

### Changes
- 0eaee5d8 fix: compact Slack badge with click-to-reveal channel name (#972)

## v0.2.2 (2026-03-13)

### Changes
- 6b16f533 fix(slack): prevent WebMock from blocking HTTP in other engines' tests
- 7db1fee3 feat(slack): paginate channel list and add channel search (#970)

## v0.2.1 (2026-02-11)

### Changes
- 86957f10 fix: skip AI agent dispatch for slash command messages

## v0.2.0 (2026-02-09)

### Changes
- 885e3c31 feat: add AgentOrchestrator with Matcher component (#751)

