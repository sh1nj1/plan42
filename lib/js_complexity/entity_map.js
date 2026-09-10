// Resolves an ESLint offense position to the fully-qualified name of the entity
// it sits on.
//
// The complexity ratchet compares two measurements of the same tree taken at
// different commits, so an entity has to keep its identity across ordinary
// editing. A line number does not survive an insertion above it, and a bare
// function name is not unique inside a file, so neither works as a key on its
// own. The Ruby half of the ratchet solves this with a Prism walk
// (ComplexityRatchet::EntityMap); this is the same idea over an ESTree AST.
//
// Names read as a path from the outermost scope inward:
//
//   TopicsController#connect                 class method
//   TopicsController.observed                static class member
//   CommentForm#submit>[addEventListener]    anonymous callback, named by its call
//   parseDraft>normalise                     function nested in a function
//   CommentForm#submit~if (a) {              statement fallback (see below)
//
// Lookup is by CONTAINMENT, not by start position, because ESLint does not
// report an offense at the node it is about: `getFunctionHeadLoc` puts a method
// offense on the method name, an arrow offense on the `=>` token, and a
// max-depth offense on a statement somewhere in the middle. All three are
// inside the entity, so the innermost scope containing the offense is the
// answer in every case — as long as a class member's scope carries the
// MethodDefinition's range rather than the inner FunctionExpression's, which
// starts after the name.
//
// Rules that report on a statement rather than a definition — max-depth is the
// one in the budget — get the enclosing scope plus the normalised source line,
// written with a leading `~`. That is the fallback shape the Ruby side uses for
// Metrics/BlockNesting.

const FUNCTION_TYPES = new Set([
  "FunctionDeclaration",
  "FunctionExpression",
  "ArrowFunctionExpression",
]);

const CLASS_TYPES = new Set(["ClassDeclaration", "ClassExpression"]);

// A function written as a class member or an object value is reported at its
// key, which lies outside the function node. Take the range from the member so
// containment still finds it.
const MEMBER_TYPES = new Set(["MethodDefinition", "PropertyDefinition", "Property"]);

// `parent` is a back-reference ESLint adds while traversing; following it would
// loop forever. `loc` and `range` hold no nodes, and skipping them keeps the
// walk off every position object in the file.
const SKIPPED_KEYS = new Set(["parent", "loc", "range"]);

const MAX_FALLBACK_TEXT = 100;

class Scope {
  constructor(name, loc) {
    this.name = name;
    this.start = loc.start;
    this.end = loc.end;
    // Sibling entities that share a name are numbered from the second on, so a
    // second over-budget `[map]` callback in one method cannot hide behind the
    // first. Counting happens per parent scope, so an edit elsewhere in the
    // file leaves the ordinal alone.
    this.children = new Map();
    this.fallbacks = new Map();
  }

  contains(line, column) {
    if (line < this.start.line || line > this.end.line) return false;
    if (line === this.start.line && column < this.start.column) return false;
    if (line === this.end.line && column > this.end.column) return false;
    return true;
  }

  // Later start wins, and on a tie the earlier end: both mean "more deeply
  // nested". Comparing widths instead would need the source to convert a
  // line/column span into a length.
  innerThan(other) {
    if (this.start.line !== other.start.line) return this.start.line > other.start.line;
    if (this.start.column !== other.start.column) return this.start.column > other.start.column;
    if (this.end.line !== other.end.line) return this.end.line < other.end.line;
    return this.end.column < other.end.column;
  }
}

export class EntityMap {
  static for(ast, source) {
    return new EntityMap(ast, source);
  }

  constructor(ast, source) {
    this.lines = source.split("\n");
    this.root = new Scope(null, ast.loc);
    this.scopes = [];
    this.walk(ast, null, this.root);
  }

  // Fully-qualified name of the innermost class or function containing the
  // offense, or null when the offense sits at file scope.
  nameAt(line, column) {
    return this.enclosing(line, column - 1).name;
  }

  // Name for an offense that does not sit on a definition. Twins inside one
  // scope get an ordinal, so two identical `if` lines in the same method do not
  // collapse into one key where only the larger would be recorded.
  fallbackAt(line, column) {
    const scope = this.enclosing(line, column - 1);
    const base = `${scope.name ?? ""}~${normaliseLine(this.lines[line - 1] ?? "")}`;
    const seen = (scope.fallbacks.get(base) ?? 0) + 1;
    scope.fallbacks.set(base, seen);
    return seen > 1 ? `${base}[fallback:${seen}]` : base;
  }

  // ESLint message columns are 1-based; node columns are 0-based. Callers pass
  // the message column, so this takes the converted one.
  enclosing(line, column) {
    let best = this.root;
    for (const scope of this.scopes) {
      if (!scope.contains(line, column)) continue;
      if (best === this.root || scope.innerThan(best)) best = scope;
    }
    return best;
  }

  // `parent` is threaded explicitly rather than read from `node.parent`:
  // ESLint only sets that back-reference while it traverses, and this map is
  // also built in tests straight from a parse.
  walk(node, parent, enclosing) {
    const segment = segmentFor(node, parent);
    let scope = enclosing;

    if (segment !== null) {
      const ordinal = (enclosing.children.get(segment) ?? 0) + 1;
      enclosing.children.set(segment, ordinal);
      const numbered = ordinal > 1 ? `${segment}(${ordinal})` : segment;

      scope = new Scope(join(enclosing.name, numbered), rangeOwner(node, parent).loc);
      this.scopes.push(scope);
    }

    for (const child of childNodes(node)) this.walk(child, node, scope);
  }
}

function* childNodes(node) {
  for (const [name, value] of Object.entries(node)) {
    if (SKIPPED_KEYS.has(name) || value === null || typeof value !== "object") continue;

    for (const candidate of Array.isArray(value) ? value : [ value ]) {
      if (isNode(candidate)) yield candidate;
    }
  }
}

function isNode(value) {
  return value !== null && typeof value === "object" && typeof value.type === "string";
}

function join(prefix, segment) {
  if (!prefix) return segment;

  return segment.startsWith("#") || segment.startsWith(".") ? `${prefix}${segment}` : `${prefix}>${segment}`;
}

function rangeOwner(node, parent) {
  return isMember(node, parent) ? parent : node;
}

function isMember(node, parent) {
  return FUNCTION_TYPES.has(node.type) && parent !== null && MEMBER_TYPES.has(parent.type) && parent.value === node;
}

function segmentFor(node, parent) {
  if (CLASS_TYPES.has(node.type)) return className(node, parent);
  if (!FUNCTION_TYPES.has(node.type)) return null;

  return functionName(node, parent);
}

function className(node, parent) {
  return node.id?.name ?? inferredName(parent) ?? "(anonymous class)";
}

function functionName(node, parent) {
  if (parent?.type === "MethodDefinition" || parent?.type === "PropertyDefinition") {
    // `get x()` and `set x()` share a name; without the kind they would collide
    // into an ordinal pair that reads as two unrelated members.
    const kind = parent.kind === "get" || parent.kind === "set" ? `${parent.kind} ` : "";
    return `${parent.static ? "." : "#"}${kind}${memberName(parent)}`;
  }
  if (node.type === "FunctionDeclaration" && node.id?.name) return node.id.name;

  return inferredName(parent) ?? anonymousName(parent);
}

// `const submit = () => {}` and `{ submit: function () {} }` are named by what
// they are bound to: that is the name a reader would use for them.
function inferredName(parent) {
  if (!parent) return null;
  // `export default class extends Controller {}` is the shape every Stimulus
  // controller in this engine uses. "(anonymous class)" would be accurate and
  // useless; `default` is what the importing side calls it.
  if (parent.type === "ExportDefaultDeclaration") return "default";
  if (parent.type === "VariableDeclarator" && parent.id?.type === "Identifier") return parent.id.name;
  if (parent.type === "Property") return memberName(parent);
  if (parent.type === "AssignmentExpression" && parent.left?.type === "MemberExpression") {
    return memberPath(parent.left);
  }
  return null;
}

// `Editor.prototype.render = function () {}` keeps the whole chain: two classes
// in one file both assigning `.render` would otherwise share a name, and the
// ordinal that separated them would depend on which was written first.
function memberPath(node) {
  if (node.type === "Identifier") return node.name;
  if (node.type === "ThisExpression") return "this";
  if (node.type !== "MemberExpression") return null;

  const object = memberPath(node.object);
  const property = memberName(node);
  return object ? `${object}.${property}` : property;
}

// An anonymous callback is identified by the call it is passed to —
// `[addEventListener]`, `[map]` — which is how the Ruby side anchors blocks.
function anonymousName(parent) {
  if (parent?.type !== "CallExpression" && parent?.type !== "NewExpression") return "[anonymous]";

  const callee = parent.callee;
  if (callee?.type === "Identifier") return `[${callee.name}]`;
  if (callee?.type === "MemberExpression") return `[${memberName(callee)}]`;
  return "[anonymous]";
}

function memberName(node) {
  const named = node.key ?? node.property;
  if (!named) return "(computed)";
  if (named.type === "Identifier") return named.name;
  if (named.type === "Literal") return String(named.value);
  if (named.type === "PrivateIdentifier") return `#${named.name}`;
  return "(computed)";
}

function normaliseLine(text) {
  const collapsed = text.trim().replace(/\s+/g, " ");
  return collapsed.length > MAX_FALLBACK_TEXT
    ? `${collapsed.slice(0, MAX_FALLBACK_TEXT - 3)}...`
    : collapsed;
}
