# Authoring Tools (Meta-Skills) as Creatives

Collavre tools follow the [rails_mcp_engine](https://github.com/sh1nj1/rails_mcp_engine)
pattern: a Ruby service class declares its metadata with the `ToolMeta` DSL and
its types with a Sorbet `sig`, and the engine generates both the RubyLLM tool and
the MCP tool from that single definition.

A tool does not need a deploy. Put its source in a Ruby code block inside a
Creative's description and Collavre picks it up:

1. Saving the Creative scans its code blocks for `extend ToolMeta`.
2. Each block becomes a pending tool, and the Creative owner receives an
   approval comment.
3. When the owner approves, the source is evaluated and registered. The tool
   then appears in `collavre tool list` and runs with `collavre tool run`.
4. Editing the source resets approval. Removing the block deletes the tool.

Only users with write permission on the tool's Creative can see and run it.

## Workflow

```bash
# 1. Start from a template
collavre tool scaffold --name weekly_digest --desc "Summarize a Creative's week" > weekly_digest.rb

# 2. Edit weekly_digest.rb, then preview the Creative Markdown (no network)
collavre tool create --parent 123 --file weekly_digest.rb --dry-run

# 3. Create the tool Creative, then ask the owner to approve it
collavre tool create --parent 123 --file weekly_digest.rb

# 4. After approval
collavre tool info weekly_digest
collavre tool run weekly_digest --json '{"creative_id": 123}'

# Change the source later (approval is required again)
collavre tool update 456 --file weekly_digest.rb
```

`create` refuses a `tool_name` that is already registered. Tool names are
global, so pick a specific name.

## Tool source shape

```ruby
module Tools
  class WeeklyDigestService
    extend T::Sig
    extend ToolMeta

    tool_name "weekly_digest"
    tool_description "Summarize a Creative's week."
    tool_param :creative_id, description: "Creative to summarize", required: true
    tool_param :days, description: "Window in days (default 7)", required: false

    sig { params(creative_id: Integer, days: T.nilable(Integer)).returns(T::Hash[Symbol, T.untyped]) }
    def call(creative_id:, days: nil)
      user = Collavre::Current.user
      raise "Current.user is required" unless user

      creative = Collavre::Creative.find_by(id: creative_id)
      return { error: "Creative not found", id: creative_id } unless creative
      return { error: "No read permission", id: creative_id } unless creative.has_permission?(user, :read)

      since = (days || 7).days.ago
      { success: true, id: creative.id, updated_children: creative.children.where("updated_at >= ?", since).count }
    end
  end
end
```

Rules the CLI checks before creating the Creative:

- The class lives in the `Tools` namespace and has `extend T::Sig` and `extend ToolMeta`.
- `tool_name` is a snake_case string literal and `tool_description` is a string literal.
- The entrypoint is `def call(...)` with a Sorbet `sig` above it.

Rules the CLI cannot check, so follow them yourself:

- Every `tool_param` matches a keyword argument in `sig` and `def call`.
  Optional params use `T.nilable(...)` and a default of `nil`.
- `sig` types drive the JSON schema. Use `String`, `Integer`, `Float`,
  `T::Boolean`, `T::Array[...]`, `T::Hash[...]`, and `T.nilable(...)`.
- Return a Hash. Return `{ error: "..." }` for expected failures instead of raising.
- Reference Collavre models by their full name (`Collavre::Creative`,
  `Collavre::Current`). The source is evaluated at the top level.

## Safety

The approved source runs inside the Collavre server with full application
privileges. Write tools the way the built-in tools are written:

- Act as `Collavre::Current.user` and check `has_permission?` on every Creative
  the tool reads (`:read`) or changes (`:write`).
- Do not shell out, read server files, read credentials or environment variables,
  or make network calls the owner has not asked for.
- Keep one tool to one clear job. Split unrelated actions into separate tools.

Approvers should read the source before approving it.
