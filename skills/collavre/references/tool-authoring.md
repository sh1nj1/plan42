# Ruby tools stored in Creatives

Use this workflow when asked to create or edit a Collavre MCP tool. The Ruby
source lives in a Creative, written with `creative_create_service` or
`creative_update_service`. There is no separate authoring CLI or registration
endpoint. Use the existing owner approval action to enable execution.

## Discover and choose the destination

Call `meta_tool(action: "get", tool_name: "creative_create_service")` and the
corresponding `get` for `creative_update_service` to inspect current parameters.
Retrieve the intended parent with `creative_retrieval_service`; use a Creative
the requester has authorized you to write. If the purpose or destination is
missing, ask for it before creating executable content.

Search existing registered names with `meta_tool(action: "search", query: ... )`.
Choose a unique snake_case tool name and `Tools::<UniqueName>Service` class.
Discovery only includes approved tools the current user can access; absence is
not proof that a name is globally free. A duplicate pending name cannot become
a second tool; use a distinct name rather than modifying somebody else's tool.
One tool per Creative makes later edits and approvals easier to inspect.

## Write the service in a Ruby fence

Follow the [rails_mcp_engine DSL](https://github.com/vrerv/rails_mcp_engine#defining-a-tool-service).
Include `extend T::Sig`, `extend ToolMeta`, literal `tool_name` and
`tool_description`, `tool_param` metadata, and a Sorbet-signed keyword `call`.
Keep the class name's `Service` suffix: the library generates wrapper constants
from the remaining name. Do not declare extra services or register tools yourself.

This harmless example has no resource access or side effects:

```ruby
class Tools::CreativeGreetingService
  extend T::Sig
  extend ToolMeta

  tool_name "creative_greeting"
  tool_description "Return the supplied name in a structured greeting payload."
  tool_param :name, description: "Name to return", required: true

  sig { params(name: String).returns(T::Hash[Symbol, String]) }
  def call(name:)
    { name: name }
  end
end
```

For resource operations, use `Collavre::Current.user` as the caller and check
`creative.has_permission?(Collavre::Current.user, :read)` (or `:write` for
mutations) on every resource accessed. Permission to run the tool's Creative
does not authorize access to other Creatives. Ruby executes in the application
process; owner approval is a trust decision, not a sandbox. User-facing messages
must use the application's English and Korean i18n translations.

## Save with the existing Creative tool

Send the entire Markdown body, including the opening and closing Ruby fences.
Use actual newlines in the description value (JSON encodes them as `\n`). For
example, call the existing tool through `meta_tool` with this JSON; replace the
parent ID with the authorized destination:

```json
{
  "action": "run",
  "tool_name": "creative_create_service",
  "arguments": {
    "parent_id": 123,
    "description": "# Greeting tool\n\n```ruby\nclass Tools::CreativeGreetingService\n  extend T::Sig\n  extend ToolMeta\n  tool_name \"creative_greeting\"\n  tool_description \"Return the supplied name in a structured greeting payload.\"\n  tool_param :name, description: \"Name to return\", required: true\n  sig { params(name: String).returns(T::Hash[Symbol, String]) }\n  def call(name:)\n    { name: name }\n  end\nend\n```"
  }
}
```

The meta response wraps the Creative service response in `result`. Check its
`success`/`error` or `pending_review`, and retain the returned Creative ID or
`change_set_id`. Do not retry a successful create merely because the tool is
not yet discoverable: extraction happens in a queued job after the save.

## Approval and verification

Under `ai_write_policy=review`, the owner first applies the Creative draft in
History. Applying the draft is separate from approving the executable tool.
Once the code is stored, Collavre creates an owner approval comment for the
tool. Report the Creative ID and pending state; wait for that approval instead
of marking the tool approved yourself. If approval fails, inspect its error,
correct the source, and request approval of the corrected version.

After approval, verify the real schema and result:

```json
{"action":"get","tool_name":"creative_greeting"}
```

```json
{"action":"run","tool_name":"creative_greeting","arguments":{"name":"Soonoh"}}
```

The second response's `result` must be `{"name":"Soonoh"}`. For a different
tool, choose a harmless representative call consistent with the user's request.
Report the Creative ID, actual tool name, approval status, and verification
result. An unavailable result can mean extraction is pending, approval is
missing, registration failed, or the caller lacks write access to the Creative.
Do not claim success solely because the Creative was saved.

## Edit or remove

Read the existing Creative before editing. `creative_update_service` replaces
the entire body; preserve unrelated prose and code. Its retrieval view is a
plain-text rendering, so do not assume it is a lossless Markdown round-trip.
Use the original full Markdown when available; obtain the original source
before replacing a body whose formatting you cannot reconstruct safely.

Call `meta_tool(action: "run", tool_name: "creative_update_service",
arguments: {id: <existing Creative ID>, description: <full Markdown>})`.
Keep the same tool and service names for an ordinary edit. Source changes revoke
the old registration when the extraction job runs and require approval again.
Removing the code block removes the tool; renaming is removal plus creation and
needs approval. Verify the old name is unavailable and the approved replacement
has the expected schema and behavior. Other processes reconcile approved
versions on their next `meta_tool` call; a call already in progress is not
cancelled by an edit.
