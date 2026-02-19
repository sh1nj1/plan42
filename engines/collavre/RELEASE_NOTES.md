## v0.5.0 (2026-02-20)

### Changes
- d3906a77 fix: add agent_status heartbeat during streaming and safety timeout (#780)
- 8f9fd644 fix: exclude failed jobs from CronSchedulerJob duplicate guard (#853)
- d4d6f24d fix: remove process guard from CronSchedulerJob boot initializer (#852)
- b881ad2a feat: add topic name to AI agent context (#851)
- d34e2a8f feat: add CronSchedulerJob for dynamic recurring tasks (#850)
- bc2d3670 fix: make loop breaker per-topic and skip user-initiated messages (#849)
- ad72d79d fix: display system comments as 'System' instead of 'Gemini' (#846)
- 415b917b feat: add scheduling decision logs and waiting notices for deferred/delayed jobs (#845)
- 9e6c522a fix: clear debounce timer on disconnect and guard stale async results (#844)
- 05fec734 fix: debounce creative search with 300ms delay and min 3 chars (#843)
- 664c4c0b fix: handle nil topic_id (main topic) in CronActionJob (#841)
- 194f28e7 feat: use topic_name instead of topic_id in cron_create tool (#840)
- 23a5ec0a refactor: remove unused github_gemini_prompt column and UI (#837)
- 1a0a83ad fix: update creative_batch_service_test to respect leaf-only progress constraint (#836)
- 66d81f8d fix: allow mentions after punctuation characters in MentionParser (#834)
- 63abc9d7 feat: include sender name in A2A completion instruction for reliable report-back chain (#832)
- 07e9cce1 fix: stabilize flaky CreativeBatchServiceTest by ensuring permission cache (#833)
- 2a6911d9 fix: restrict creative progress updates to 100% on leaf nodes only (#830)
- ff58c4bd fix: improve date input calendar icon visibility in dark mode (#829)
- cee8d091 fix: add confidence format instruction when self-reflection is enabled (#826)
- 997eb7c9 fix: pass creative_id to GitHub PR Analyzer tools (#815)
- 99094b58 fix: align radio/checkbox with text in GitHub integration modal (#823)
- f813d73f fix: support mid-text @mentions for A2A agent routing (#822)
- 41036594 fix: apply i18n to mcp_command error message (#821)
- 36fadb6c refactor: extract CreateService and DestroyService from CreativesController (#820)
- ed22c2c9 refactor: extract Linkable, Permissible, Describable concerns from Creative model (#819)
- 28d0c1c4 refactor: extract MessageBuilder, ReviewHandler, ApprovalHandler from AiAgentService (#818)
- 6a2549df refactor: extract CommandMenuService and CommentMoveService from CommentsController (#817)
- a2577431 refactor: extract MarkdownConverter service from CreativesHelper (#816)
- 2cf79938 feat: add creative_batch_service tool with approval requirement (#814)
- e47b19a7 fix: replace inline styles with CSS class for share modal inputs (#813)
- 04e52b9c fix: add box-sizing border-box to share popup input and select (#812)
- d602eec3 fix: prevent double-wrapping HTML inside existing markdown code blocks (#811)
- f2541421 refactor: unify close button style with popup-close-btn class (#810)
- f45fb2a4 fix: add rescue logging around SystemEvents dispatch in comments controller (#809)
- 0d579a9c feat: pass image attachments from comments to AI via RubyLLM (#808)
- 5cc349f8 fix: remove tree-line-color and bullet-color from :root defaults (#805)
- cd036bd7 docs: add creative_children_level to agent_conf help text (#804)
- cce3ce17 fix: add inline fallbacks to all creative tree CSS variable usages (#803)
- a81bf004 fix: use inherit/currentColor defaults for creative tree CSS variables (#802)
- c218b9ec fix: make share popup close and delete buttons transparent (#801)
- 67034292 feat: add context.creative_children_level to agent_conf (#800)
- 63902162 feat: add creative tree CSS variables for theme customization (#799)
- d17f8859 refactor: move admin settings controller, views, routes, and i18n to collavre engine (#797)
- 361a176c feat: add admin UI/UX settings tab with default theme (#796)
- c2f75c99 feat: add admin unlock user action (#795)
- b5782553 feat: sort simple search results by description length (relevance) (#792)
- 0d37c3a4 fix: remove duplicate GitHub integration button from creative actions (#793)
- e01151dd feat: add copy action for AI agents on contacts page (#791)
- 1f03143d feat: add agent_conf YAML field for AI agent context settings (#790)
- 85d77a65 fix: custom themes now ignore OS dark mode setting (#789)
- b39cc9d4 docs: add design tokens guide (#788)
- 33140cd6 refactor: update theme generator to use semantic design tokens (#787)
- fab221a1 refactor: enforce color-no-hex as error, add missing semantic tokens (#786)
- 2c437ec0 refactor: tokenize remaining CSS files with design tokens (#785)
- 031dfbce refactor: tokenize creatives.css — replace hardcoded values with design tokens (#784)
- 8fcc72a5 refactor: tokenize comments_popup.css — replace hardcoded values with design tokens (#783)
- e8773e45 feat: semantic design tokens and legacy aliases (#782)
- 8d665ff8 feat: add design tokens (Open Props) and Stylelint enforcement (#781)
- 54895214 feat: auto-wrap pasted HTML content in code blocks (#778)
- dc3a16ac fix: voice button active state not visible due to CSS specificity (#779)
- ed63471c Feat/collaboration policy and a2a instructions (#775)
- bfedee8e fix: strengthen review prompt to prevent abbreviated responses (#771)
- 01ade975 fix: remove bullet prefix from popup list items (#777)
- b5ebc613 feat: add review button to AI agent comments for mobile support (#773)
- cb0114e3 fix: save immediately on progress checkbox change instead of debouncing (#776)

## v0.4.0 (2026-02-12)

### Changes
- cea0b37b fix: remove duplicate GitHub integration modal render (#770)
- 709153ae feat: add completion emoji reaction on review message update (#768)
- 7e8df962 fix: disable stuck detection by default
- b16a97db fix: strip HTML from creative title in stuck detector notifications (#767)
- cfed92c9 feat: add review message (quote + reply) feature (#765)
- f09c59c5 fix: share user search showing results briefly then disappearing (#766)

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

