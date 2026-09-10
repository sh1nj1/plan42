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
//   Toolbar>handleFiles[useCallback]            callback named by its binding
//   save>[load().then().then]                   callback named by its chain
//   parseDraft>normalise                        function nested in a function
//   CommentForm#submit~if (a) {                 statement fallback (see below)
//   Row#connect>[items.map]#2842ca41            twin, anchored to its own source
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
// `items.map(...)` callbacks in one method, or two identical `if` lines. Any
// scheme that separates them BY POSITION — `(2)`, or `(2/3)` — makes a slot the
// identity, and a slot is not an identity: the entity in slot 2 after an edit
// need not be the entity that was in slot 2 before it, so its measurement is
// compared against somebody else's baseline. Deleting a twin and reordering
// twins are both ways to reach that, and the second can conceal real growth —
// baselines 12 and 6 against a reordered 9 and 5 read `9 <= 12` and `5 <= 6`
// and say nothing, while the 6-line callback has in fact grown to 9.
//
// So the first move is to have fewer twins: a callback takes the WHOLE callee
// including any chain (`[load().then().then]`) and the binding its call sits in
// (`handleFiles[useCallback]`), which is enough to name all but a handful.
// What is left is anchored to a digest of its own source — `[items.map]#2842ca41`
// — so a twin's key depends on the twin and on nothing around it. Siblings can
// be added, deleted or reordered without touching it, and an edit that changes
// its measurement changes its key, so growth surfaces as new debt instead of
// slipping into a neighbour's baseline. Only byte-identical twins still need an
// ordinal, and those measure identically, so any permutation of them is a
// no-op — which holds only because the digested text covers everything that
// feeds the measurement. A statement's therefore includes its DEPTH, and that
// depth has to be the number ESLint reports rather than an approximation of
// it; see `depthsOf`. "Byte-identical" is meant literally: twins are grouped by their source
// text and not by the digest of it, because one 32-bit FNV word collides often
// enough to find a pair by brute force in seconds, and a collision would put
// two different entities back on one ordinal. The digest widens a word at a
// time until it separates them.
//
// The digest is spelled out only when a name is shared, so keys stay readable
// and an ordinary entity does not carry a hash it has no use for. That leaves
// one seam: going from one such entity to two, or back, renames it. That
// direction is safe — the gate is loud about a change it cannot attribute,
// never quiet about growth. See docs/complexity_budget.md.

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

// max-depth resets its counter inside a function, and inside a static block.
const DEPTH_ROOTS = new Set([
  "ArrowFunctionExpression",
  "FunctionDeclaration",
  "FunctionExpression",
  "Program",
  "StaticBlock",
]);

// The depth ESLint would report for every statement it counts, mirrored from
// the rule rather than approximated.
//
// An earlier version counted enclosing nesting statements and argued that it
// only had to CHANGE when ESLint's depth changed, so the exceptions did not
// need modelling. That was wrong, and it is the same defect as the twin
// ordinal one level down: a key has to DETERMINE its measurement, and a count
// that is merely correlated with ESLint's does not. Two byte-identical
// `if (a) { y() }` statements can both sit under three enclosing statements
// while measuring 3 and 2, because one of them hangs off an `else if` — so
// they shared an anchor, fell back on the ordinal, and each was compared
// against the other's baseline.
//
// Mirroring means mirroring the rule's arithmetic, not a tidied-up version of
// it, because the number that has to match is the one ESLint prints:
//
//   * an IfStatement whose PARENT is an IfStatement does not count. That is
//     broader than `else if` — an unbraced `if (a) if (b) {}` is exempt too.
//   * every one of these types decrements on exit, including the ones that
//     never incremented, so an `if`/`else if`/`else if` chain leaves the
//     counter two BELOW where it started and the statements after it measure
//     too shallow. That is an upstream quirk; reproducing it is the point,
//     since the ratchet's job is to key what ESLint actually reported.
//
// Statements that do not count get no entry: max-depth cannot report one, so
// nothing ever needs its key.
function depthsOf(ast) {
  const depths = new Map();
  const counters = [];

  const visit = (node, parent) => {
    const root = DEPTH_ROOTS.has(node.type);
    if (root) counters.push(0);

    const nesting = NESTING_STATEMENT_TYPES.has(node.type);
    if (nesting && !(node.type === "IfStatement" && parent?.type === "IfStatement")) {
      depths.set(node, ++counters[counters.length - 1]);
    }

    // Source order, because the counter is sequential rather than lexical: the
    // drift an if-chain leaves behind applies to whatever is visited next, and
    // `childNodes` follows object keys.
    for (const child of [ ...childNodes(node) ].sort(byRange)) visit(child, node);

    if (nesting) counters[counters.length - 1]--;
    if (root) counters.pop();
  };

  visit(ast, null);
  return depths;
}

function byRange(left, right) {
  return left.range[0] - right.range[0] || left.range[1] - right.range[1];
}

// The functions max-nested-callbacks counts. It pushes a function whose PARENT
// is a call — that is its whole definition of "callback" — and reports the
// stack's height.
const CALLBACK_TYPES = new Set(["ArrowFunctionExpression", "FunctionExpression"]);

// The callback-nesting height ESLint would report for every function, mirrored
// from that rule for the same reason `depthsOf` mirrors max-depth: it is the
// second measurement here that is not a property of the entity's own text, so a
// twin's anchor has to carry it or two twins can share an anchor while
// measuring differently.
//
// It was tempting to argue this one away — twins sit in one scope by
// construction, so surely they nest identically. They do not, because the rule
// pops on EVERY function exit while pushing only for callbacks. A function
// expression that is not a callback therefore pops a level it never added, and
// everything after it in the scope counts one lower:
//
//   a(function () {
//     items.map((row) => { ... })            // 2
//     const helper = function () { ... }      // pops without having pushed
//     items.map((row) => { ... })            // 1  — same name, same source
//   })
//
// Byte-identical and same-named, those two shared an anchor and took an
// ordinal, each compared against the other's baseline. As with `depthsOf` the
// quirk is reproduced rather than corrected: the key has to match the number
// ESLint printed. FunctionDeclaration is deliberately absent — the rule does
// not handle it, so it neither pushes nor pops.
function callbackDepthsOf(ast) {
  const depths = new Map();
  let height = 0;

  const visit = (node, parent) => {
    const callback = CALLBACK_TYPES.has(node.type);
    if (callback) {
      if (parent?.type === "CallExpression") height++;
      depths.set(node, height);
    }

    for (const child of [ ...childNodes(node) ].sort(byRange)) visit(child, node);

    // `Array#pop` on an empty stack is a no-op, so the height floors at zero.
    if (callback) height = Math.max(0, height - 1);
  };

  visit(ast, null);
  return depths;
}

// `parent` is a back-reference ESLint adds while traversing; following it would
// loop forever. `loc` and `range` hold no nodes, and skipping them keeps the
// walk off every position object in the file.
const SKIPPED_KEYS = new Set(["parent", "loc", "range"]);

const MAX_FALLBACK_TEXT = 100;

class Scope {
  constructor(segment, loc, range) {
    this.segment = segment;
    this.range = range;
    this.start = loc.start;
    this.end = loc.end;
    this.children = [];
    this.statements = [];
    // Filled in by the naming pass, which runs after the whole tree is known:
    // a scope's key depends on how many twins it has, and the last twin is only
    // known once the walk is finished.
    this.name = null;
    this.anchor = null;
    // Set for function scopes by the walk; classes and the root never carry a
    // callback height because no rule reports one on them.
    this.callbackDepth = 0;
    this.keyed = false;
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
    this.root = new Scope(null, ast.loc, ast.range);
    this.source = source;
    this.scopes = [];
    this.depths = depthsOf(ast);
    this.callbackDepths = callbackDepthsOf(ast);
    this.walk(ast, null, null, this.root);
    nameChildren(this.root, source);
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
    keyStatements(scope, this.source);

    // Columns are 0-based on nodes and 1-based in messages.
    const statement = scope.statements.find((candidate) => candidate.line === line && candidate.column === column - 1)
      ?? scope.statements.find((candidate) => candidate.line === line);

    // An offense that matches no recorded statement — a rule reporting
    // somewhere this walk does not model — keeps the unqualified name rather
    // than guessing which statement it belongs to.
    const text = statement?.key ?? normaliseLine(this.lines[line - 1] ?? "");
    return `${scope.name ?? ""}~${text}`;
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
  // also built in tests straight from a parse. The grandparent comes along
  // because an anonymous callback's best name is usually one level further
  // out than its call — see `anonymousName`.
  walk(node, parent, grandparent, enclosing) {
    const segment = segmentFor(node, parent, grandparent);
    let scope = enclosing;

    if (segment !== null) {
      const owner = rangeOwner(node, parent);
      scope = new Scope(segment, owner.loc, owner.range);
      scope.callbackDepth = this.callbackDepths.get(node) ?? 0;
      enclosing.children.push(scope);
      this.scopes.push(scope);
    } else if (this.depths.has(node)) {
      enclosing.statements.push({
        line: node.loc.start.line,
        column: node.loc.start.column,
        range: node.range,
        depth: this.depths.get(node),
        text: normaliseLine(this.lines[node.loc.start.line - 1] ?? ""),
      });
    }

    for (const child of childNodes(node)) this.walk(child, node, parent, scope);
  }
}

// Names a scope's children, then theirs. Source order is imposed here rather
// than taken from the walk: `childNodes` follows object keys, and a class's
// `superClass` is visited before its `body` whatever the source says. An
// ordinal read off a non-source order would move when nothing moved.
function nameChildren(scope, source) {
  for (const [ segment, group ] of groupBy(scope.children, (child) => child.segment)) {
    for (const [ , twins ] of discriminate(group, segment, (child) => definitionBody(source, child))) {
      twins.forEach((child, index) => {
        child.name = join(scope.name, ordinal(child.anchor, index, twins.length));
        nameChildren(child, source);
      });
    }
  }
}

// Splits a group that shares a name into subgroups that do not, by anchoring
// each member to a digest of its own source. A lone member keeps the clean
// name. See the TWINS note in the header for why anchoring beats counting.
//
// The subgroups are the distinct BODIES, not the distinct digests. One 32-bit
// FNV word is small enough that two different bodies really do collide — a
// brute-force search finds a pair of plausible callbacks in seconds — and two
// members that share an anchor go on to be told apart by `ordinal`, which is
// the slot identity the anchor exists to replace. So the digest is widened a
// word at a time until distinct bodies have distinct anchors. The first width
// is a plain FNV-1a, so a group that does not actually collide keeps exactly
// the key it would have had.
function discriminate(group, name, bodyOf) {
  if (group.length < 2) {
    if (group.length === 1) group[0].anchor = name;
    return groupBy(group, () => name);
  }

  for (const member of group) member.body = bodyOf(member);

  for (const width of DIGEST_WIDTHS) {
    for (const member of group) member.anchor = `${name}#${digest(member.body, width)}`;
    const groups = groupBy(group, (member) => member.anchor);
    if (separated(groups)) return groups;
  }
  throw new Error(`Cannot distinguish complexity entities: ${name} (digest collision at every supported width)`);
}

// Whether every anchor group holds one body — the property that makes the
// ordinal below safe. If distinct bodies collide at all three widths, abort
// measurement rather than compare different entities through positional keys.
function separated(groups) {
  return [ ...groups.values() ].every((group) => group.every((member) => member.body === group[0].body));
}

// Members that are still indistinguishable after anchoring are byte-identical,
// so they measure identically and any permutation of them is a no-op. A plain
// ordinal separates them; nothing can hide behind it.
function ordinal(anchor, index, size) {
  return size === 1 ? anchor : `${anchor}(${index + 1}/${size})`;
}

const DIGEST_WIDTHS = [ 1, 2, 3 ];

// `width` FNV-1a runs over the entity's normalised source, each under its own
// offset basis, concatenated. Written out rather than taken from node:crypto
// because this has to produce the same digest on both sides of the ratchet and
// on every Node version that runs it — and because the widths have to nest, so
// that widening a colliding group cannot disturb one that does not collide.
function digest(text, width) {
  let out = "";
  for (let word = 0; word < width; word += 1) {
    let hash = (0x811c9dc5 ^ Math.imul(word, 0x9e3779b9)) >>> 0;
    for (let index = 0; index < text.length; index += 1) {
      hash ^= text.charCodeAt(index);
      hash = Math.imul(hash, 0x01000193) >>> 0;
    }
    out += hash.toString(16).padStart(8, "0");
  }
  return out;
}

// Reindenting must not move a key, but anything the budget's rules can MEASURE
// has to move it, or two entities that measure differently end up sharing an
// anchor and fall back on a slot. So this collapses the whitespace the rules
// cannot see and keeps the whitespace they can:
//
//   - horizontal whitespace never reaches a measurement, so runs of it collapse
//     to one space and any of it around a newline goes away entirely. Reindent,
//     retab, trailing spaces and CRLF all leave the digest alone.
//   - a LINE BREAK does reach one: `max-lines-per-function` counts lines. It is
//     kept. Collapsing it was a real hole — two callbacks differing only in
//     where a template literal's text wraps normalised to the same string while
//     measuring 5 and 4, so they shared an anchor and a reorder compared each
//     against the other's baseline. A line break is everything ESLint splits
//     lines on, U+2028 and U+2029 included, not just `\n`.
//   - runs of newlines collapse to one, because the rules run with
//     `skipBlankLines`, so a blank line cannot change a measurement either.
//
// Comments are the one thing left that moves a digest without moving a
// measurement (`skipComments` is on), so editing a comment inside an
// over-budget twin re-keys it and reads as new debt. That is the loud
// direction, and separating comments from their look-alikes inside strings
// needs the token stream, which is a lot of machinery for a twin.
function normalise(text) {
  return text.replace(BREAK_RUN, "\n").replace(HORIZONTAL_RUN, " ");
}

function sourceOf(source, node) {
  return normalise(source.slice(node.range[0], node.range[1]));
}

// A definition carries its CALLBACK-NESTING HEIGHT as well as its source, for
// the same reason a statement carries its depth: `max-nested-callbacks` does
// not measure what the function says, and two byte-identical same-named
// callbacks in one scope can measure differently. See `callbackDepthsOf`.
function definitionBody(source, scope) {
  return `${scope.callbackDepth}\n${sourceOf(source, scope)}`;
}

// A statement carries its NESTING DEPTH as well as its source, because unlike
// every other measurement here, `max-depth`'s is not a property of the entity's
// own text: two byte-identical `if (a) { y() }` statements in one function sit
// at different depths if one of them is inside another guard, and measure
// differently. Sharing an anchor, they fell back on the ordinal, which is the
// slot identity the anchor exists to replace — a reorder then reported offenses
// that had not happened, and a restructure that genuinely deepened one of them
// left both their keys unchanged.
//
// The depth is ESLint's own, computed by `depthsOf`. Approximating it is not
// enough and was the fifth variant of this bug: a key has to DETERMINE its
// measurement, and a count that merely moves when ESLint's moves does not.
// Two byte-identical statements under three enclosing statements measure 3 and
// 2 when one hangs off an `else if`, which put them back on a shared anchor
// and an ordinal — the slot identity this whole scheme exists to remove.
function statementBody(source, statement) {
  return `${statement.depth}\n${sourceOf(source, statement)}`;
}

// "Newline" has to mean what ESLint means by it, not `\n`: it splits a file on
// `\r\n`, `\r`, `\u2028` and `\u2029` too, so all of them are countable lines to
// `max-lines-per-function`. Treating U+2028 as horizontal whitespace collapsed
// two callbacks that measured 5 and 4 onto one anchor. `\v` and `\f` are NOT in
// ESLint's set, so they stay horizontal.
const LINE_BREAK = String.raw`\r\n|[\n\r\u2028\u2029]`;
const HORIZONTAL = String.raw`[^\S\n\r\u2028\u2029]`;
const BREAK_RUN = new RegExp(`${HORIZONTAL}*(?:${LINE_BREAK})(?:${HORIZONTAL}*(?:${LINE_BREAK}))*${HORIZONTAL}*`, "gu");
const HORIZONTAL_RUN = new RegExp(`${HORIZONTAL}+`, "gu");

function groupBy(items, key) {
  const groups = new Map();
  for (const item of [ ...items ].sort(byPosition)) {
    const group = groups.get(key(item));
    if (group) group.push(item);
    else groups.set(key(item), [ item ]);
  }
  return groups;
}

// Gives every statement in a scope its final key, the same way nameChildren
// does for nested definitions: statements sharing a source line are anchored to
// a digest of their own body, and only byte-identical ones fall back on an
// ordinal. Done once per scope, on first use.
function keyStatements(scope, source) {
  if (scope.keyed) return;
  scope.keyed = true;

  for (const [ text, group ] of groupBy(scope.statements, (statement) => statement.text)) {
    for (const [ , twins ] of discriminate(group, text, (statement) => statementBody(source, statement))) {
      twins.forEach((statement, index) => {
        statement.key = ordinal(statement.anchor, index, twins.length);
      });
    }
  }
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

function segmentFor(node, parent, grandparent) {
  if (CLASS_TYPES.has(node.type)) return className(node, parent);
  if (!FUNCTION_TYPES.has(node.type)) return null;

  return functionName(node, parent, grandparent);
}

function className(node, parent) {
  return node.id?.name ?? inferredName(parent) ?? "(anonymous class)";
}

function functionName(node, parent, grandparent) {
  if (parent?.type === "MethodDefinition" || parent?.type === "PropertyDefinition") {
    // `get x()` and `set x()` share a name; without the kind they would collide
    // into a twin pair that reads as two unrelated members.
    const kind = parent.kind === "get" || parent.kind === "set" ? `${parent.kind} ` : "";
    return `${parent.static ? "." : "#"}${kind}${memberName(parent)}`;
  }
  if (node.type === "FunctionDeclaration" && node.id?.name) return node.id.name;

  return inferredName(parent) ?? anonymousName(parent, grandparent);
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
  // A call in the middle of a chain is rendered but not descended into for its
  // arguments: `load(a, b).then` is `load().then` whatever it was passed, so
  // editing an argument does not move the key of a callback further down the
  // chain.
  if (node.type === "CallExpression") {
    const callee = node.callee ? memberPath(node.callee) : null;
    return callee ? `${callee}()` : null;
  }
  if (node.type !== "MemberExpression") return null;

  const object = memberPath(node.object);
  const property = memberName(node);
  return object ? `${object}.${property}` : property;
}

// An anonymous callback is identified by the call it is passed to, plus the
// binding that call sits in when there is one. Both halves exist to keep the
// callback OUT of a twin group, because a twin's identity has to fall back on
// its position among its siblings and a position is not a stable identity —
// see the TWINS note in the header.
//
// The whole callee is kept, not just its last segment: `[map]` alone makes
// twins out of every `.map` in a method. A chained call renders its object as
// `foo()`, so the two callbacks in `load().then(a).then(b)` read
// `[load().then]` and `[load().then().then]` rather than one `[then]` pair —
// and appending a third `.then` leaves both of them alone.
//
// The binding is what makes React components tractable. Every callback in a
// component is `useCallback`, so a component with eleven of them had eleven
// twins whose keys all moved the moment a twelfth was added. `const handleFiles
// = useCallback(...)` is really named `handleFiles`, one level out from the
// call, and that name survives its siblings.
function anonymousName(parent, grandparent) {
  if (parent?.type !== "CallExpression" && parent?.type !== "NewExpression") return "[anonymous]";

  const callee = parent.callee ? memberPath(parent.callee) : null;
  const call = callee ? `[${callee}]` : "[anonymous]";
  // A CallExpression can only sit in the positions inferredName reads from as
  // the bound value, so no further check that the binding is really this call.
  const binding = inferredName(grandparent);
  return binding ? `${binding}${call}` : call;
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
  const collapsed = normalise(text.trim());
  return collapsed.length > MAX_FALLBACK_TEXT
    ? `${collapsed.slice(0, MAX_FALLBACK_TEXT - 3)}...`
    : collapsed;
}
