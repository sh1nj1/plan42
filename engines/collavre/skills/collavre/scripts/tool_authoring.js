// Helpers for authoring Collavre tools (meta-skills) as Creatives.
//
// A Creative whose description holds a Ruby code block that `extend ToolMeta`
// becomes a pending MCP tool (rails_mcp_engine). The Creative owner approves it
// from the approval comment, then it is registered and runnable via meta_tool.

const TOOL_NAME_PATTERN = /^[a-z][a-z0-9_]*$/;
// Same matching McpService uses: a code block is a tool only if it contains
// this literal text, and its registered name is the first tool_name match.
const TOOL_MARKER = "extend ToolMeta";
const SERVER_TOOL_NAME = /tool_name\s+["'](.+?)["']/;

export function toolClassName(toolName) {
  const camel = toolName
    .split("_")
    .filter(Boolean)
    .map((part) => part[0].toUpperCase() + part.slice(1))
    .join("");
  return `${camel}Service`;
}

function rubyString(text) {
  return JSON.stringify(text).replace(/#\{/g, "\\#{");
}

export function scaffoldTool({ name, description }) {
  if (!name || !TOOL_NAME_PATTERN.test(name)) {
    throw new Error("--name must be snake_case (e.g. weekly_digest)");
  }
  const summary = description && description !== true ? description : `TODO: describe what ${name} does`;
  return `module Tools
  class ${toolClassName(name)}
    extend T::Sig
    extend ToolMeta

    tool_name ${rubyString(name)}
    tool_description ${rubyString(summary)}
    tool_param :creative_id, description: "Creative to operate on", required: true

    sig { params(creative_id: Integer).returns(T::Hash[Symbol, T.untyped]) }
    def call(creative_id:)
      user = Collavre::Current.user
      raise "Current.user is required" unless user

      creative = Collavre::Creative.find_by(id: creative_id)
      return { error: "Creative not found", id: creative_id } unless creative
      return { error: "No read permission", id: creative_id } unless creative.has_permission?(user, :read)

      { success: true, id: creative.id, progress: creative.progress }
    end
  end
end
`;
}

function extractString(source, keyword) {
  const match = source.match(new RegExp(`^\\s*${keyword}\\s+(?:"((?:[^"\\\\\\n]|\\\\.)+)"|'((?:[^'\\\\\\n]|\\\\.)+)')`, "m"));
  if (!match) return null;
  return (match[1] ?? match[2]).replace(/\\(.)/g, (_, ch) => (ch === "n" ? " " : ch));
}

// Mirrors what the server needs to turn the code block into a working tool:
// McpService only picks up blocks containing `extend ToolMeta`, reads
// `tool_name`/`tool_description` by regex, and ToolMeta refuses to build a
// schema without a Sorbet signature on the entrypoint.
function toolNameError(name, declared, count) {
  if (!name) return 'Missing `tool_name "snake_case_name"`';
  if (!declared) return `tool_name "${name}" must be a single string literal with matching quotes`;
  if (declared !== name) {
    return `tool_name is read as "${name}" by the server, not "${declared}"; keep the first tool_name a plain string`;
  }
  // The server records the first tool_name, but evaluating the class keeps the
  // last one; approval rejects a mismatch, so allow exactly one (comments too).
  if (count > 1) return `tool_name appears ${count} times; declare it exactly once`;
  if (!TOOL_NAME_PATTERN.test(name)) return `tool_name "${name}" must be snake_case`;
  return null;
}

export function validateToolSource(source) {
  const errors = [];
  if (!source || !source.trim()) {
    return { errors: ["Tool source is empty"] };
  }
  if (!source.includes(TOOL_MARKER)) errors.push("Missing `extend ToolMeta` (exactly one space)");
  if (!/\bextend\s+T::Sig\b/.test(source)) errors.push("Missing `extend T::Sig`");

  const name = source.match(SERVER_TOOL_NAME)?.[1];
  const count = source.match(new RegExp(SERVER_TOOL_NAME.source, "g"))?.length ?? 0;
  const nameError = toolNameError(name, extractString(source, "tool_name"), count);
  if (nameError) errors.push(nameError);

  const description = extractString(source, "tool_description");
  if (!description) errors.push('Missing `tool_description "..."`');

  if (!/^\s*(module\s+Tools\b|class\s+Tools::)/m.test(source)) {
    errors.push("Tool class must live in the Tools namespace (`module Tools` or `class Tools::...`)");
  }
  if (!/^\s*sig\s*(\{|do\b)/m.test(source)) errors.push("Missing Sorbet `sig` for the entrypoint");
  if (!/^\s*def\s+call\b/m.test(source)) errors.push("Missing `def call(...)` entrypoint");

  return { errors, name, description };
}

// Pick a fence longer than any backtick run inside the source so the code
// block cannot be closed early by the tool's own content.
function fenceFor(source) {
  const longest = (source.match(/`+/g) || []).reduce((max, run) => Math.max(max, run.length), 0);
  return "`".repeat(Math.max(3, longest + 1));
}

// Backslash-escape fence characters in the prose above the source, so a
// summary starting with ``` or ~~~ cannot open a code block that swallows
// the tool's own fence.
function escapeProse(text) {
  return String(text).replace(/[\\`~]/g, "\\$&");
}

export function toolCreativeMarkdown({ source, name, description, title }) {
  const heading = escapeProse(title && title !== true ? title : name);
  const fence = fenceFor(source);
  return `# ${heading}\n\n${escapeProse(description)}\n\n${fence}ruby\n${source.replace(/\s+$/, "")}\n${fence}\n`;
}
