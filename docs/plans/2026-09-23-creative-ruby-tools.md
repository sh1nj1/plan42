# Creative-native Ruby tool implementation plan

## Objective

An agent writes a Ruby tool into a Collavre Creative using the existing
`creative_create_service` and `creative_update_service` MCP tools. After the
Creative owner's approval, agents discover and invoke the resulting tool through
`meta_tool`. The source of truth is the Creative's code block.

## Revert scope

Partially revert merge commit `3111f8f86408a1bf927c8c3dce744f8eaa886c73`
(PR #1721). Remove CLI scaffold/create/update commands, authoring helpers and
CLI documentation from both skill copies, plus CLI-specific tests. Revert the
retrieval metadata addition and its tests. Preserve later changes. Keep the shared
CLI JSON output conversion for Ruby inspect results, including string-key hash
rockets, Ruby string escapes, and literal source text inside descriptions. Cover
this output path in both skill copies with standalone regression tests.

Keep the server registration protections: `McpToolRegistrar`, expected-name
validation, class/constant collision checks, failed-registration cleanup,
serialized approvals, transaction rollback cleanup, and per-tool rescue during
active-tool loading. Keep model/service approval tests and move the registrar
regression tests out of the deleted CLI test into a standalone service test with
inline Ruby source. These protections remain active throughout this change.

## Existing path to reuse

1. `creative_create_service(description:, parent_id:)` stores Markdown; Ruby
   fenced code becomes an HTML code block.
2. Creative callbacks enqueue `UpdateMcpToolsJob`; `McpService` extracts source
   containing `extend ToolMeta` and records an unapproved `McpTool`.
3. A system comment requests approval from the Creative owner. Under
   `ai_write_policy=review`, the Creative draft must be applied first; draft
   approval and executable-tool approval are separate steps.
4. Owner approval invokes the installed `rails_mcp_engine` 0.4.2
   `Tools::MetaToolWriteService` to build the tool wrappers.
5. `meta_tool` supports list/search/get/run; source updates reset approval.

## Implementation steps for the follow-up

1. Read the target Creative and existing tool names through `meta_tool`. Define
   the requested tool's purpose, input schema, output, parent Creative and unique
   service/tool names before creating executable content.
2. Write the actual tool as `class Tools::<UniqueName>Service`, with
   `extend T::Sig`, `extend ToolMeta`, `tool_name`, `tool_description`,
   `tool_param`, a Sorbet `sig`, and a keyword-argument `call` method. Follow the
   library's DSL rather than creating another registration framework. Resource
   operations must use `Collavre::Current.user` and enforce Creative permissions.
3. Pass the complete Markdown containing that Ruby source to
   `meta_tool(action: "run", tool_name: "creative_create_service", arguments: ...)`.
   Subsequent edits use `creative_update_service` with the existing Creative ID.
   Keep unrelated Creative content intact. No CLI scaffold/create/update commands
   or new native authoring endpoint are required.
4. Report the actual Creative/draft result and wait for the existing owner
   approval mechanism. Do not claim a tool is available merely because its
   Creative was saved. Use `meta_tool` search/get to verify registration, then
   run a harmless representative call and compare the output.
5. Document this exact MCP workflow and copyable Ruby example in both Collavre
   skill copies. Make the workflow discoverable in relevant tool descriptions
   if needed; keep the change focused on Creative-native authoring.
6. Preserve the existing registration protections and regression tests. Address
   only verified additional lifecycle gaps with separate tests. Review
   duplicate names/classes, failed registration cleanup, approval rollback,
   concurrent approvals and worker/restart visibility before enabling the flow.
   Keep library-level registration fixes in rails_mcp_engine where appropriate.

7. Completed: separate Creative attributes and recent-comment serialization
   from tree traversal, preserving the JSON response. Both revert-only
   complexity waivers are removed. Registration waivers are unnecessary
   because the hardened implementation is retained.

## Acceptance tests

- Create through the real Creative service, execute queued jobs, verify the
  unapproved tool and owner approval comment; verify it cannot run yet.
- Approve through the actual approval path, verify `meta_tool get` schema and
  `run` output using real library registration, not a registration mock.
- Update source through CreativeUpdateService, verify the prior tool is removed,
  approval resets, and re-approval exposes the new behavior.
- Cover review-policy drafts, missing permissions, malformed Ruby/signatures,
  duplicate names/classes, removal of code and Creative deletion.
- Verify approved tool loading after restart and execution from another worker.
- Verify both skill copies remain identical and examples run end to end.

## Implementation status

The Creative-native follow-up adds the authoring guide and executable example to
both skill copies, and links the workflow from create/update tool descriptions.
The example is tested through real `meta_tool` calls, queued extraction, the
owner's approval action, and the installed rails_mcp_engine registration.

Integration and review checks exposed lifecycle gaps addressed in this implementation:

- Meta-tool calls bypassed FastMcp's tool-list permission filter. The Collavre
  integration now checks approval and Creative write access for get/run/call and
  filters list/search results. The library still owns schema building and dispatch.
- Registries are process-local. Before meta discovery/execution, reconcile
  registered source with persisted approved versions, discard deleted/revoked
  definitions, and load missing approved definitions independently of the caller.
  Caller permissions control visibility and execution, not process-wide registry
  population, so read-only/anonymous requests preserve authorized RubyLLM access. One failed
  definition must not prevent loading the others. A running call is not cancelled.
  Refresh reads registered names once from DSL metadata instead of rebuilding
  every schema for every active tool.
- System tool names are reserved during Creative extraction, with an EN/KO
  explanation posted once per message to the Creative, including repeated autosaves.
  Existing conflicting rows cannot hide,
  replace, or unregister application tools; registry ownership takes precedence.
- Approval resumption uses `action: "call"`, which the installed gem does not
  dispatch. Normalize this alias to `run` before the same approval/write-access
  gate, and test both successful calls and a revoked writer's approval resume.

An empty stored description now removes extracted tools just like removing a
code block. The guide documents asynchronous extraction, separate draft and tool
approvals, duplicate names, rename, and whole-body updates. It does not create
production tool Creatives automatically or bypass the owner's approval.

The serialization refactor and waiver removal shipped in PR #1741. This
follow-up is based on that merged change and does not modify serialization or
reintroduce retrieval metadata.

## Delivery boundary

The original PR #1739 delivered the partial revert and this plan. The follow-up
implements the Creative-native workflow described above. CLI scaffold/create/
update commands and a separate native authoring endpoint remain out of scope.

Reference: https://github.com/vrerv/rails_mcp_engine#defining-a-tool-service
