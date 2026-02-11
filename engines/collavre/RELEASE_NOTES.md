## v0.3.2 (2026-02-12)

### Changes
- 4097fbbd fix: move ai orchestration i18n text to engine

## v0.3.1 (2026-02-11)

### Changes
- d9ff72c6 fix: move ai orchestration settings test to engine
- 86957f10 fix: skip AI agent dispatch for slash command messages
- 53b76d10 fix: standardize mention format to @name: and handle existing topics in /topic command
- e34a64da fix: set topic's primary agent
- 5f7b20d4 fix: show /topic command
- f23cc936 fix: prevent AI agent self-response loop in deferred task dequeue
- 23892190 fix: enable stuck_detection by default in PolicyResolver
- 861be479 fix: add auto-recovery to StuckDetector for stuck running tasks
- 3157027f fix: include queued status in cancel_pending_tasks on comment deletion

## v0.3.0 (2026-02-09)

### Changes
- 4ab307e3 fix: formatting
- a0c83f65 fix: enforce topic_max_concurrent_jobs on Main topic (nil topic_id)
- 3f8327c8 feat: add cron CRUD tools for AI agent scheduled tasks
- 6a5d6d43 fix: pass response_content explicitly to self-reflection evaluator
- 3f98980c feat: add stuck detection and auto-escalation
- b8992267 fix: require creative permission for all agents regardless of searchable
- e5aadaa4 refactor: use i18n for A2A collaboration prompts
- 8e90a8ec feat: add A2A sender context for agent-to-agent communication (#759)
- 6d236492 style: fix array literal bracket spacing in loop_breaker
- cba8b192 feat: add loop breaker for infinite loop prevention (#758)
- 4d7dec2f feat: add agent context builder for A2A collaboration (#757)
- f5b53165 feat: add self-reflection evaluator for AI agents (#756)
- 15b7191b refactor: move orchestration controller and view to collavre engine (#755)
- 7b0e517b feat: add /topic command to create topic with primary agent (#754)
- 470aec55 fix: show AI errors in chat message with exception class name (#753)
- 885e3c31 feat: add AgentOrchestrator with Matcher component (#751)
- e76baf5c refactor: extract GitHub integration into collavre_github engine (#746)
- 2ce8b567 fix: show AI typing indicator only on the correct creative (#745)

## v0.2.5 (2026-02-06)

### Changes
- 6664da75 feat: restrict sharing non-searchable AI agents to owners only (#739)
- 9f78717f fix: exit fullscreen returns to mobile position on mobile devices (#738)

