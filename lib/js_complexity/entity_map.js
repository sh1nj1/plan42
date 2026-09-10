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
//   TopicsController#connect                    class method
//   TopicsController.observed                   static class member
//   CommentForm#submit>[this.el.addEventListener]  anonymous callback, named by
//                                                  the call it is passed to
//   parseDraft>normalise                        function nested in a function
//   CommentForm#submit~if (a) {                 statement fallback (see below)
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
//
// TWINS. Two entities in one scope can still end up with the same name: two
// `items.map(...)` callbacks in one method, or two identical `if` lines. A
// plain ordinal — first one bare, second one `(2)` — is NOT enough, because the
// bare name is inherited: delete the first twin and the survivor is renamed
// onto the deleted twin's key, so its growth is compared against a measurement
// that was never its own. Instead every member of a group of twins carries its
// position AND the group's size, `(2/3)`. Adding or removing a twin changes the
// size, which changes every key in the group at once, and the ratchet reports
// the survivors as new debt rather than silently comparing them against
// somebody else's baseline. Reordering twins likewise moves a larger value into
// a smaller slot, which reports as growth. The gate stays loud in both cases;
// what it must never do is stay quiet. See docs/complexity_budget.md.

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

// The statements max-depth reports on — ESLint counts a block as nested when it
// hangs off one of these, and reports the offense at the statement's own start
// position. Recording them while walking is what lets a `~source line` fallback
// know how many twins it is one of, the same way the Ruby side records every
// statement in a scope rather than only the offending ones.
const NESTING_STATEMENT_TYPES = new Set([
  "DoWhileStatement",
  "ForInStatement",
  "ForOfStatement",
  "ForStatement",
  "IfStatement",
  "SwitchStatement",
  "TryStatement",
  "WhileStatement",
  "WithStatement",
]);

// `parent` is a back-reference ESLint adds while traversing; following it would
// loop forever. `loc` and `range` hold no nodes, and skipping them keeps the
// walk off every position object in the file.
const SKIPPED_KEYS = new Set(["parent", "loc", "range"]);

const MAX_FALLBACK_TEXT = 100;

class Scope {
  constructor(segment, loc) {
    this.segment = segment;
    this.start = loc.start;
    this.end = loc.end;
    this.children = [];
    this.statements = [];
    // Filled in by the naming pass, which runs after the whole tree is known:
    // a scope's key depends on how many twins it has, and the last twin is only
    // known once the walk is finished.
    this.name = null;
    this.groups = null;
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
    nameChildren(this.root);
  }

  // Fully-qualified name of the innermost class or function containing the
  // offense, or null when the offense sits at file scope.
  nameAt(line, column) {
    return this.enclosing(line, column - 1).name;
  }

  // Name for an offense that does not sit on a definition. Twins inside one
  // scope carry their position and their group's size, for the reason the
  // header gives: two identical `if` lines in one method must not collapse into
  // one key, and neither may inherit the other's.
  fallbackAt(line, column) {
    const scope = this.enclosing(line, column - 1);
    const text = normaliseLine(this.lines[line - 1] ?? "");
    const base = `${scope.name ?? ""}~${text}`;

    const twins = statementGroup(scope, text);
    if (twins.length < 2) return base;

    // Columns are 0-based on nodes and 1-based in messages. An offense that
    // matches no recorded statement — a rule reporting somewhere this walk does
    // not model — keeps the unqualified name rather than guessing a position.
    const index = twins.findIndex((statement) => statement.line === line && statement.column === column - 1);
    const position = index === -1 ? twins.findIndex((statement) => statement.line === line) : index;
    return position === -1 ? base : `${base}(${position + 1}/${twins.length})`;
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
      scope = new Scope(segment, rangeOwner(node, parent).loc);
      enclosing.children.push(scope);
      this.scopes.push(scope);
    } else if (NESTING_STATEMENT_TYPES.has(node.type)) {
      enclosing.statements.push({
        line: node.loc.start.line,
        column: node.loc.start.column,
        text: normaliseLine(this.lines[node.loc.start.line - 1] ?? ""),
      });
    }

    for (const child of childNodes(node)) this.walk(child, node, scope);
  }
}

// Names a scope's children, then theirs. Source order is imposed here rather
// than taken from the walk: `childNodes` follows object keys, and a class's
// `superClass` is visited before its `body` whatever the source says. An
// ordinal read off a non-source order would move when nothing moved.
function nameChildren(scope) {
  const groups = new Map();
  for (const child of [ ...scope.children ].sort(byPosition)) {
    const group = groups.get(child.segment);
    if (group) group.push(child);
    else groups.set(child.segment, [ child ]);
  }

  for (const [ segment, twins ] of groups) {
    twins.forEach((child, index) => {
      child.name = join(scope.name, qualify(segment, index, twins.length));
      nameChildren(child);
    });
  }
}

// A lone entity keeps a clean key. Twins carry `(position/size)` — see the
// header: the size is what stops a survivor from inheriting a deleted twin's
// key, and the position is what stops twins from collapsing into one.
function qualify(segment, index, size) {
  return size === 1 ? segment : `${segment}(${index + 1}/${size})`;
}

function statementGroup(scope, text) {
  if (scope.groups === null) {
    scope.groups = new Map();
    for (const statement of [ ...scope.statements ].sort(byPosition)) {
      const group = scope.groups.get(statement.text);
      if (group) group.push(statement);
      else scope.groups.set(statement.text, [ statement ]);
    }
  }

  return scope.groups.get(text) ?? [];
}

function byPosition(left, right) {
  const leftStart = left.start ?? left;
  const rightStart = right.start ?? right;
  return leftStart.line - rightStart.line || leftStart.column - rightStart.column;
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
    // into a twin pair that reads as two unrelated members.
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
// position that separated them would depend on which was written first.
function memberPath(node) {
  if (node.type === "Identifier") return node.name;
  if (node.type === "ThisExpression") return "this";
  if (node.type !== "MemberExpression") return null;

  const object = memberPath(node.object);
  const property = memberName(node);
  return object ? `${object}.${property}` : property;
}

// An anonymous callback is identified by the call it is passed to. The WHOLE
// callee is kept — `[this.element.addEventListener]`, `[rows.map]` — not just
// its last segment: `[map]` alone makes twins out of every `.map` in a method,
// and twins are the one case where identity has to fall back on position.
function anonymousName(parent) {
  if (parent?.type !== "CallExpression" && parent?.type !== "NewExpression") return "[anonymous]";

  const callee = parent.callee ? memberPath(parent.callee) : null;
  return callee ? `[${callee}]` : "[anonymous]";
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
