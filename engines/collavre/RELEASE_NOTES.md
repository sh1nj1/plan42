## v0.11.1 (2026-03-24)

### Changes
- eead2373 fix: update inbox panel CSS test to reference engine gnb.css (#1035)
- cb53e988 refactor: extract GNB styles from host app to collavre engine (#1033)

## v0.11.0 (2026-03-24)

### Changes
- 646a3e44 style: add right padding to breadcrumb for action button spacing (#1032)
- c46142fa feat: redesign creative-actions-row with breadcrumb and overflow menu (#1031)
- e8ca266b feat: persist topic selection server-side via UserCreativePreference (#1025)
- 151002ce fix: close fullscreen chat properly on swipe down (#1027)
- d9cc5463 fix: ensure only one GNB popup is visible at a time on mobile (#1026)
- eadbb422 feat: add inline progress toggle on hover (#1021)
- 3f7a567a fix: update system test for Enter key shortcut change (#1024)
- c3ab40e9 fix: swap Enter/Shift+Enter behavior in creative inline editor (#1019)
- c34070fe fix: markdown import drop not working due to missing dragover class (#1020)
- 8697d203 feat: multi-word AND search for creatives and comments (#1016)
- 6d58c308 fix: constrain mobile chat popup max-height when keyboard opens (#1017)
- 836a1bb1 fix: use calc-based dynamic vertical centering for creative row icons (#1018)

## v0.10.0 (2026-03-20)

### Changes
- 284b1024 feat: drag & drop creative into chat form to insert markdown link (#1014)
- 390a62f9 fix: prevent Rails callback deduplication from silencing badge broadcasts (#1013)
- cba46cf4 feat: create new topic from selected messages via drag-drop and search popup (#1012)

## v0.9.0 (2026-03-19)

### Changes
- 6c555730 feat: add select-all toggle checkbox to comment selection action bar (#1007)
- b48750de refactor: use generic scrollable ancestor detection in chat popup (#1002)
- e395638e feat: add merge selected chat messages action (#1004)
- 9ccb9e5b feat: drag & drop AI agent to topic tabs to set primary agent (#1005)
- 9f4bfb7e fix: prevent CompressJob from deleting comments when AI call fails (#1003)
- efd7c517 fix: broadcast topic creation from /topic command to update UI instantly (#999)
- 2f4f22bd feat: use orchestration rules for agent selection in CompressJob (#1001)
- aab343d7 fix: allow scroll inside chat popup textarea and review quotes (#1000)
- 20517e16 fix: close chat popup when creative is deleted (#996)
- 454c5dfc fix: improve visibility of comment version buttons and activity log marker (#994)
- 6fa2203a fix: allow creative admins to edit action payload in update_action (#995)
- 737a8885 fix: allow scrolling inside action details and edit textarea in chat popup (#993)
- 5be05ef8 feat: add drag-and-drop creative onto context area (#992)
- 8199360e fix: render markdown when navigating comment versions (#991)
- 0a58da8c feat: align chat popup to right of button when space available (#990)
- b2bbcb9b fix: prevent wheel event handler from blocking share modal scroll (#989)
- 35b3c419 fix: remove underline decoration from creative hover (#988)
- 239632a0 fix: limit hover underline to first line of creative content (#987)

## v0.8.3 (2026-03-16)

### Changes
- 83d30f02 feat: add glowing border effect to chat popup and active creative row (#983)
- 4944e5cb fix: hide chevron toggle for leaf nodes without children container (#984)
- 0321af0d fix: remove global scroll-behavior smooth to prevent scroll animation on back navigation (#980)

## v0.8.2 (2026-03-16)

### Changes
- da02ef96 fix(ui): unify design tokens, improve dark mode contrast, and add accessibility polish
- 7bd5367e fix: unify chat header section spacing (#979)
- f2c05986 feat: show inherited permissions in share modal with inline editing (#978)
- 536fb0d5 feat: replace emoji icons with SVG icons in chat contexts (#976)
- a1e3b7fb feat: add AI-generated summary to tool approval messages (#973)
- fb5b243e fix: use Numeric instead of Float in tool service Sorbet sigs (#975)
- ff9697b2 fix: remove global smooth scroll to fix back navigation scroll restoration (#974)
- 2aa5075a Feat/chevron icon (#971)

## v0.8.1 (2026-03-13)

### Changes
- afa9be45 fix: use TreeFormatter.plain_description in new_ai view (#968)

## v0.8.0 (2026-03-13)

### Changes
- 8178cd47 feat: add archive/unarchive for creatives and chat topics (#960)
- 4db8c251 fix: prevent race condition in deep-link comment highlighting (#967)
- 7129bb1d refactor: extract collavre engine stylesheets into helper (#966)
- a2d3b691 fix: prevent stale comments when switching creative chat windows (#965)

## v0.7.2 (2026-03-12)

### Changes
- f782b351 fix: move host-app migrations to their respective engines (#963)

## v0.7.1 (2026-03-12)

### Changes
- 99ae4fa3 fix: reset stale topic_id when switching creatives in chat (#961)

## v0.7.0 (2026-03-12)

### Changes
- 586723a6 fix: cascade delete quoting comments when quoted comment is destroyed (#959)
- 3c05b9b2 fix: allow write-permission users to create topics in UI (#958)
- dc0d02ae feat: upgrade AI model from gemini-2.5-flash to gemini-3-flash-preview
- 1633a387 refactor: remove self-reflection feature, keep confidence output (#955)
- f09b1497 fix: prevent background creative list from scrolling through chat popup (#956)
- 42580b44 fix: share modal XSS, debounce refresh, and i18n error message (#954)
- 3a1b694a merge: resolve conflict with main (add navigate_label + share-modal container)
- c29a978e fix: optimistic UI for share modal and fix delete confirm dialog
- 9d035f68 feat: convert share modal forms to fetch-based submission
- 2a6a0be8 feat: unify share modal into reusable Stimulus controller
- 48be412f feat: add navigate button (→) to context chips (#952)
- da37b427 fix: load child creatives instead of root list when entering chat fullscreen directly (#950)
- cff7b489 fix: refresh CSRF token after OS window switch to prevent 422 (#951)
- 037ffbec feat: add metadata editor to creative inline editor (#947)
- 4f0b2071 feat: allow background creative scrolling while chat popup is open (#948)
- 47f2a9b7 fix: decode HTML entities in creative_snippet (#944)
- e1eff6c4 fix: prevent context chips from being clipped and reduce title padding (#941)
- 0b36850d feat: creative context injection with inheritance (#939)
- d146bf0d feat: drag and drop topics to move between creatives (#936)
- 7bacc169 fix: destroy user with hierarchical creatives (closure_tree leaf-first) (#937)
- 0e0c386c feat: add list/org-chart view switcher for contacts tab (#934)
- 995af318 fix: use origin ownership and shares for linked creatives in org chart (#933)
- b5da08f5 fix: use effective_description for linked creatives in org chart (#932)
- 280d898c fix: support deep tree indentation, linked creative shares, and expand/collapse all (#931)
- 486c1ffd fix: only show creatives with actual shares in org chart (#930)
- ff1bf372 feat: replace contacts tab with org chart view (#924)
- 0651f478 fix: restore creative-row hover background on level-1/2/3 rows (#923)
- 5b31ec3d refactor: apply SRP to AI agent orchestration services (#921)
- acc2f90d fix: convert SQL string interpolation to parameterized queries (#920)
- c2fcda10 fix: replace html_safe with safe_join and content_tag (#919)
- 42b52433 refactor: extract users_controller concerns for better organization (#918)
- 2a838694 refactor: split comments_controller into concerns (#917)
- c5d24694 refactor: extract creatives controller concerns (#916)
- 422fafa9 refactor: extract common logic from workflow_executor and work_command (#915)
- 450f4f9f chore: remove unused helper method toggle_button_symbol (#914)
- 701839a0 chore: remove 4 unused JavaScript modules (#913)
- c4d1b291 chore: remove 3 unused view partials (#922)
- 902ada30 refactor: simplify authentication flow in creative_imports_controller (#911)
- fc5dd51d fix: add authorization checks to prevent IDOR in creative controllers (#910)
- c26ef291 fix: add reset_session before session creation to prevent session fixation (#909)
- 0e6df808 fix: replace html_safe with sanitize in slide_view to prevent XSS (#908)
- 77adc8f6 feat: add /creative command for linking creatives in chat (#907)

## v0.6.0 (2026-03-05)

### Changes
- db908d3c fix: strip whitespace in normalize_description for creative create/update (#903)
- f6137dc8 fix: retry workflow subtask on empty AI response and fix supervisor mention format (#899)
- 839ff7a5 fix: improve collavre CLI output quality (#891)
- e386119b feat: add /compress command to summarize and clean topic messages (#888)
- 6ec26002 feat: add creative_import_service MCP tool for markdown import (#886)
- aaaa7777 fix: resolve FK constraint error when deleting comments (#885)
- 4a0f3643 feat: OpenAI-compatible chat completions API (#883)
- 1790e90f fix: cancel queued tasks when waiting notice is deleted (#884)
- 7001c05c feat(collavre): add review comment versioning (#882)
- f8ced8a4 feat(comments): replace selection hint with action bar for batch operations (#879)
- a6f5cab8 fix: update review quote tests for store-based API and fix ID collision
- 506e90ef feat: add optional supervisor agent to /work command (#877)
- 86cac589 fix: cache rendered workflow context to prevent re-render failures in job context
- 36866ec0 feat: review quote chips UI for multi-review workflow (#876)
- 3e10a00f fix: auto-resize textarea in comment form (#875)
- 98d24978 fix: populate creative_id on Task creation for topic concurrency checks (#872)
- 62153745 fix: add visual feedback when review button appends quote (#870)
- ec215f80 fix: scope topic concurrency checks by creative_id (#871)
- 699afbe8 fix: prevent duplicate agent task execution for same comment (#869)
- 7ca09011 fix: resolve user lookup error in WorkflowExecutor
- 4fa83985 chore: add debug logging to WorkflowExecutor for progress tracking
- b91e84e0 fix: add sub-task completion notice to parent creative chat (#868)
- 508c8407 fix: remove agent fallback from workflow trigger comment author (#867)
- 1b5f06ca fix: use /work command issuer as trigger comment author, not agent (#866)
- e384b49f fix: resolve workflow_context creative ID to markdown content (#865)
- 2cce47e5 fix: restore progress >= 1.0 skip for completed creatives (#864)
- e213bce2 fix: only skip creatives with active tasks, allow re-work after done/failed/cancelled (#863)
- 7e40d8e6 feat: enrich workflow trigger with creative markdown and sender context (#862)
- 573c4d12 feat: add /work stop and /work resume subcommands (#861)
- 2fc03891 fix: route subtask agent responses to child creative's chat (#860)
- 0941e1e7 feat: add /work command for DFS workflow execution (#859)
- 9c271dcd feat: unify review and replace buttons with multi-quote support (#856)
- 4fb54457 feat: refactor creative_retrieval_service for agent-friendly output (#855)

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

