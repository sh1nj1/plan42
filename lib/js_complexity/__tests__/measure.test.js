import { Linter } from "eslint";
import { jest } from "@jest/globals";

import { eslintConfig, foldMessages, parseBudget, RULES } from "../measure.js";

// Measure a source string the way lib/js_complexity/measure.js measures a file,
// and return the ratchet keys it produces. Going through Linter rather than
// hand-building an AST keeps the tests honest about the thing that actually
// varies between ESLint versions: where a rule reports its offense.
function measure(source, rules, filename = "engines/collavre/app/javascript/x.js") {
  const budget = { include: [], exclude: [], rules };
  const linter = new Linter();
  const messages = linter.verify(source, eslintConfig(budget), filename);
  return foldMessages(filename, source, linter.getSourceCode()?.ast, messages);
}

// Keys are `path | rule | entity`; the tests below care about the entity.
function entities(measured, rule) {
  return Object.keys(measured)
    .filter((key) => key.split(" | ")[1] === rule)
    .map((key) => key.split(" | ")[2]);
}

// What ComplexityRatchet::Check does with the two measurements: an entity the
// merge base does not have is new debt, and one that got bigger is growth.
// Both block. Written here so the identity tests can assert the property that
// actually matters — that an edit is REPORTED — rather than a key spelling.
function reported(before, after) {
  return Object.entries(after)
    .filter(([key, value]) => !(key in before) || value > before[key])
    .map(([key]) => key.split(" | ")[2]);
}

// Content anchors are FNV digests; the tests care that two entities got
// DIFFERENT anchors, not what the digest of any one of them is. Rewrite each
// distinct digest to `#a`, `#b`, ... in first-seen order so an assertion reads
// as the property it is making and does not have to be rewritten when an
// unrelated character moves inside a fixture.
function labelled(keys) {
  const seen = new Map();
  return keys.map((key) => key.replace(/#(?:[0-9a-f]{8})+/g, (digest) => {
    if (!seen.has(digest)) seen.set(digest, `#${String.fromCharCode(97 + seen.size)}`);
    return seen.get(digest);
  }));
}

// A function body of `count` distinct statements, so max-lines-per-function
// measures a value this test chose rather than one it has to look up.
function body(count) {
  return Array.from({ length: count }, (_, index) => `        const v${index} = ${index}`).join("\n");
}

describe("entity naming", () => {
  test("separates field initializers from each other and from field functions", () => {
    const source = `class C {
      first = a || b || c;
      static first = a || b;
      #hidden = a || b;
      fn = () => a || b;
    }`;
    const measured = measure(source, { complexity: 0 });
    expect(entities(measured, "complexity")).toEqual([
      "C#first(initializer)", "C.first(initializer)",
      "C##hidden(initializer)", "C#fn(initializer)>(function)",
      "C#fn(initializer)",
    ]);
    expect(Object.values(measured)).toEqual([3, 2, 2, 2, 1]);
  });

  test("reports a new field below a larger initializer's baseline", () => {
    const before = measure("class C { first = a || b || c || d; }", { complexity: 1 });
    const after = measure("class C { first = a || b || c || d; second = a || b; }", { complexity: 1 });
    expect(reported(before, after)).toEqual(["C#second(initializer)"]);
  });

  test("reports field growth below a larger initializer's baseline", () => {
    const before = measure("class C { first = a || b || c || d; second = a || b; }", { complexity: 1 });
    const after = measure("class C { first = a || b || c || d; second = a || b || c; }", { complexity: 1 });
    expect(reported(before, after)).toEqual(["C#second(initializer)"]);
  });

  test("reports static block growth masked by a larger shrinking block", () => {
    const before = measure("class C { static { a || b || c || d; } static { a || b; } }", { complexity: 1 });
    const after = measure("class C { static { a || b || c; } static { a || b || c; } }", { complexity: 1 });
    expect(reported(before, after)).toHaveLength(2);
  });

  test("keeps static block identities across pure reorder", () => {
    const before = measure("class C { static { a || b || c; } static { x || y; } }", { complexity: 1 });
    const after = measure("class C { static { x || y; } static { a || b || c; } }", { complexity: 1 });
    expect(entities(before, "complexity")).toHaveLength(2);
    expect(reported(before, after)).toEqual([]);
  });

  test("keeps computed-key functions outside the field initializer scope", () => {
    const source = "class C { [(() => a || b)()] = c || d; }";
    expect(entities(measure(source, { complexity: 1 }), "complexity")).toEqual([
      "C>[anonymous]", "C#(computed)(initializer)",
    ]);
  });

  test("keeps computed-key functions outside a field value function", () => {
    const source = "class C { [(() => a || b)()] = () => c || d; }";
    expect(entities(measure(source, { complexity: 1 }), "complexity")).toEqual([
      "C#(computed)(initializer)>(function)", "C>[anonymous]",
    ]);
  });

  test("reports computed-key growth below a larger value function baseline", () => {
    const before = measure("class C { [(() => a || b)()] = () => p || q || r || s; }", { complexity: 1 });
    const after = measure("class C { [(() => a || b || c)()] = () => p || q || r || s; }", { complexity: 1 });
    expect(reported(before, after)).toEqual(["C>[anonymous]"]);
  });

  test("reports computed-key depth below a field value function baseline", () => {
    const value = [
      "  })()] = () => {",
      "    if (a) {",
      "      if (b) {",
      "        if (c) { run() }",
      "      }",
      "    }",
      "  }",
      "}",
    ];
    const before = measure([
      "class C {",
      "  [(function () {",
      "    if (a) {",
      "      if (c) { run() }",
      "    }",
      ...value,
    ].join("\n"), { "max-depth": 2 });
    const after = measure([
      "class C {",
      "  [(function () {",
      "    if (a) {",
      "      if (b) {",
      "        if (c) { run() }",
      "      }",
      "    }",
      ...value,
    ].join("\n"), { "max-depth": 2 });
    expect(reported(before, after)).toEqual(["C>[anonymous]~if (c) { run() }"]);
  });

  test("attributes depth inside a field function to that function", () => {
    const source = `class C {
      fn = () => {
        if (a) {
          if (b) { run() }
        }
      }
    }`;
    expect(entities(measure(source, { "max-depth": 1 }), "max-depth")).toEqual([
      "C#fn(initializer)>(function)~if (b) { run() }",
    ]);
  });

  test("names class methods, statics and accessors by their member", () => {
    const source = `
      class Editor {
        save(a, b, c) {}
        static create(a, b, c) {}
        get draft() { return this._d(1, 2, 3) }
        set draft(v) {}
      }
      Editor.prototype.x = function (a, b, c) {}
    `;
    expect(entities(measure(source, { "max-params": 2 }), "max-params")).toEqual([
      "Editor#save",
      "Editor.create",
      "Editor.prototype.x",
    ]);
  });

  test("names an anonymous default-exported class `default`", () => {
    // Every Stimulus controller in the engine is written this way.
    const source = `export default class extends Controller { connect(a, b, c) {} }`;
    expect(entities(measure(source, { "max-params": 2 }), "max-params")).toEqual(["default#connect"]);
  });

  test("names a nested function by its path through the enclosing scopes", () => {
    const source = `
      function outer() {
        function inner(a, b, c) {}
        return inner
      }
    `;
    expect(entities(measure(source, { "max-params": 2 }), "max-params")).toEqual(["outer>inner"]);
  });

  test("names an anonymous callback after the whole call it is passed to", () => {
    // The receiver is part of the name: `[addEventListener]` alone would make
    // twins out of two listeners on different elements, and twins are the one
    // case where identity has to fall back on source position.
    const source = `
      class Row {
        connect() {
          this.el.addEventListener("click", (a, b, c) => {})
          document.addEventListener("keydown", (a, b, c) => {})
        }
      }
    `;
    expect(entities(measure(source, { "max-params": 2 }), "max-params")).toEqual([
      "Row#connect>[this.el.addEventListener]",
      "Row#connect>[document.addEventListener]",
    ]);
  });

  test("anchors same-named siblings to a digest of their own source", () => {
    const source = `
      class Row {
        connect() {
          items.map((a, b, c) => { return a })
          items.map((a, b, c) => { return b })
        }
      }
    `;
    expect(labelled(entities(measure(source, { "max-params": 2 }), "max-params"))).toEqual([
      "Row#connect>[items.map]#a",
      "Row#connect>[items.map]#b",
    ]);
  });

  // Siblings that are byte-identical measure identically, so any permutation of
  // them is a no-op and a plain ordinal is enough to keep them apart.
  test("falls back to an ordinal only for byte-identical siblings", () => {
    const source = `
      class Row {
        connect() {
          items.map((a, b, c) => {})
          items.map((a, b, c) => {})
        }
      }
    `;
    expect(labelled(entities(measure(source, { "max-params": 2 }), "max-params"))).toEqual([
      "Row#connect>[items.map]#a(1/2)",
      "Row#connect>[items.map]#a(2/2)",
    ]);
  });

  // The name a reader would use is one level out from the call: every callback
  // in a React component is `useCallback`, and a component with eleven of them
  // had eleven entities whose keys all moved when a twelfth was added.
  test("names a callback by the binding its call sits in", () => {
    const source = `
      function Toolbar() {
        const handleFiles = useCallback((a, b, c) => {}, [])
        const openPicker = useCallback((a, b, c) => {}, [])
      }
    `;
    expect(entities(measure(source, { "max-params": 2 }), "max-params")).toEqual([
      "Toolbar>handleFiles[useCallback]",
      "Toolbar>openPicker[useCallback]",
    ]);
  });

  // A `.then` chain has no binding to borrow, so the callee carries the chain
  // instead. Appending a fourth link leaves the first three keys alone.
  test("names a chained callback by its position in the chain", () => {
    const source = `
      function save() {
        load().then((a, b, c) => {}).then((a, b, c) => {}).catch((a, b, c) => {})
      }
    `;
    expect(entities(measure(source, { "max-params": 2 }), "max-params")).toEqual([
      "save>[load().then]",
      "save>[load().then().then]",
      "save>[load().then().then().catch]",
    ]);
  });

  test("names a function by the binding it is assigned to", () => {
    const source = `
      const submit = (a, b, c) => {}
      const handlers = { retry: function (a, b, c) {} }
    `;
    expect(entities(measure(source, { "max-params": 2 }), "max-params")).toEqual(["submit", "retry"]);
  });
});

describe("twin identity across commits", () => {
  // Two callbacks the naming cannot tell apart by name, sized independently.
  // The measurements below stand in for the two sides of the merge-base
  // comparison; only the callbacks are kept, because the method wrapping them
  // changes size whenever the fixture does and that is not what these tests are
  // about.
  function twins(...sizes) {
    const calls = sizes.map((size) => `        items.map((row) => {\n${body(size)}\n        })`).join("\n");
    const measured = measure(`
      class Row {
        connect() {
${calls}
        }
      }
    `, { "max-lines-per-function": 2 });

    return Object.fromEntries(Object.entries(measured).filter(([key]) => key.includes("[items.map]")));
  }

  // The hole this shape exists to close, in the form Codex found it: a plain
  // ordinal compares SLOTS, so a twin that moved into a smaller slot is checked
  // against the twin that used to be there. Baselines 12 and 6 against a
  // reordered 9 and 5 passed — slot 1 read `9 <= 12` and slot 2 read `5 <= 6` —
  // while the 6-line callback had in fact grown to 9.
  test("does not hide growth behind a reorder and a compensating shrink", () => {
    expect(labelled(reported(twins(12, 6), twins(9, 5)))).toEqual([
      "Row#connect>[items.map]#a",
      "Row#connect>[items.map]#b",
    ]);
  });

  // A deleted twin cannot hand its measurement to a survivor either: the
  // survivor is anchored to its own body, so growth is measured against its own
  // baseline rather than the deleted twin's 12.
  test("does not hand a deleted twin's key to the survivor", () => {
    const before = twins(12, 6);
    const after = twins(9);

    expect(Object.keys(after).some((key) => key in before)).toBe(false);
    expect(reported(before, after)).toEqual(["Row#connect>[items.map]"]);
  });

  // The anchor is only spelled out when it has to be, so an entity's key does
  // not carry a digest it does not need. Crossing between "one" and "two" is
  // therefore a rename, and a rename reads as new debt. That direction is safe
  // — it is loud about an improvement, never quiet about growth — and it is the
  // one place a twin's identity still depends on its siblings.
  test("reports the survivor when deleting a twin leaves it alone in its scope", () => {
    expect(reported(twins(12, 6), twins(6))).toEqual(["Row#connect>[items.map]"]);
  });

  // What the old ordinal got wrong in the other direction: moving twins around
  // is not a change, and the gate should not say it is.
  test("says nothing when twins are reordered and neither one changed", () => {
    expect(reported(twins(12, 6), twins(6, 12))).toEqual([]);
  });

  // The cost of anchoring: an over-budget twin that shrinks but stays over
  // budget has a new body, so it has a new key and reads as new debt. Recover
  // by naming the callback, by getting it under budget, or with a waiver.
  test("reports a twin that shrinks without getting under budget", () => {
    expect(labelled(reported(twins(12, 6), twins(10, 6)))).toEqual(["Row#connect>[items.map]#a"]);
  });

  test("says nothing when a twin is deleted and the rest are untouched", () => {
    expect(reported(twins(12, 8, 6), twins(12, 8))).toEqual([]);
  });

  // A 32-bit FNV word is small enough to collide on plausible input: these two
  // markers were found by brute force in a few seconds, and under a single word
  // both callbacks below digest to 299effeb. Grouping twins by that digest put
  // two DIFFERENT callbacks back on one ordinal — the slot identity the whole
  // scheme exists to remove — and a pure reorder of them reported growth that
  // had not happened. Twins are grouped by source text instead, and the digest
  // widens until it separates them.
  const COLLIDING = { big: [ 12, 3893 ], small: [ 6, 250530 ] };

  function collidingTwins(...pairs) {
    const calls = pairs
      .map(([ size, marker ]) => `        items.map((row) => {\n${body(size)}\n        const pad = ${marker}\n        })`)
      .join("\n");
    const measured = measure(`
      class Row {
        connect() {
${calls}
        }
      }
    `, { "max-lines-per-function": 2 });

    return Object.fromEntries(Object.entries(measured).filter(([key]) => key.includes("[items.map]")));
  }

  test("separates twins whose bodies collide on a single digest word", () => {
    const keys = Object.keys(collidingTwins(COLLIDING.big, COLLIDING.small)).map((key) => key.split(" | ")[2]);

    expect(keys).toHaveLength(2);
    expect(new Set(keys).size).toBe(2);
    // No survivor fell back on a slot.
    for (const key of keys) expect(key).not.toMatch(/\(\d+\/\d+\)$/);
  });

  test("says nothing when colliding twins are reordered and neither one changed", () => {
    const before = collidingTwins(COLLIDING.big, COLLIDING.small);
    const after = collidingTwins(COLLIDING.small, COLLIDING.big);

    expect(reported(before, after)).toEqual([]);
  });

  test("refuses to measure distinct twins when every digest width collides", () => {
    // Force every FNV word to zero, exercising exhaustion without relying on
    // finding a 96-bit collision. The real measurement must fail closed.
    const multiply = jest.spyOn(Math, "imul").mockReturnValue(0);
    try {
      expect(() => collidingTwins(COLLIDING.big, COLLIDING.small))
        .toThrow("Cannot distinguish complexity entities: [items.map]");
    } finally {
      multiply.mockRestore();
    }
  });

  test("still measures identical twins when every digest width collides", () => {
    const multiply = jest.spyOn(Math, "imul").mockReturnValue(0);
    try {
      expect(Object.keys(collidingTwins(COLLIDING.big, COLLIDING.big))).toHaveLength(2);
    } finally {
      multiply.mockRestore();
    }
  });

  // The digest normalises whitespace so that reindenting does not move a key.
  // Collapsing NEWLINES along with the rest was a hole: `max-lines-per-function`
  // counts lines, so two callbacks differing only in where a template literal's
  // text wraps measure 5 and 4 while normalising to the same string. They shared
  // an anchor, fell back on a slot, and a reorder compared each against the
  // other's baseline.
  function wrapping(...bodies) {
    const calls = bodies.map((cb) => `        items.map((row) => {\n${cb}\n          use(t)\n        })`).join("\n");
    const measured = measure(`
      class Row {
        connect() {
${calls}
        }
      }
    `, { "max-lines-per-function": 2 });

    return Object.fromEntries(Object.entries(measured).filter(([key]) => key.includes("[items.map]")));
  }

  const WRAPPED = "          const t = `aaa\nbbb`";
  const ONE_LINE = "          const t = `aaa bbb`";

  test("separates twins that differ only in how a template literal wraps", () => {
    const keys = Object.keys(wrapping(WRAPPED, ONE_LINE)).map((key) => key.split(" | ")[2]);

    expect(new Set(keys).size).toBe(2);
    for (const key of keys) expect(key).not.toMatch(/\(\d+\/\d+\)$/);
  });

  test("says nothing when twins that wrap differently are reordered", () => {
    expect(reported(wrapping(WRAPPED, ONE_LINE), wrapping(ONE_LINE, WRAPPED))).toEqual([]);
  });

  // The other half of the same trade: whitespace the rules cannot measure must
  // NOT move a key, or every reformat reads as new debt.
  test("keeps a twin's key when it is reindented", () => {
    const indented = (text) => text.replace(/^ +/gm, (run) => `${run}    `);

    expect(reported(
      wrapping(WRAPPED, ONE_LINE),
      wrapping(indented(WRAPPED), indented(ONE_LINE)),
    )).toEqual([]);
  });

  // `skipBlankLines` is on, so a blank line cannot change a measurement and
  // must not change a key either.
  test("keeps a twin's key when a blank line is added inside it", () => {
    expect(reported(wrapping(WRAPPED, ONE_LINE), wrapping(`${WRAPPED}\n`, ONE_LINE))).toEqual([]);
  });

  // "Line break" has to mean what ESLint means by it. It splits lines on
  // `\r\n`, `\r`, U+2028 and U+2029 as well as `\n`, so all of them are lines
  // that `max-lines-per-function` counts. Treating U+2028 as ordinary
  // whitespace collapsed two callbacks measuring 5 and 4 onto one anchor.
  const SEPARATED = "          const t = `aaa\u2028bbb`";

  test("separates twins that differ by a Unicode line separator", () => {
    const keys = Object.keys(wrapping(SEPARATED, ONE_LINE)).map((key) => key.split(" | ")[2]);

    expect(new Set(keys).size).toBe(2);
    for (const key of keys) expect(key).not.toMatch(/\(\d+\/\d+\)$/);
  });

  test("says nothing when twins differing by a Unicode line separator are reordered", () => {
    expect(reported(wrapping(SEPARATED, ONE_LINE), wrapping(ONE_LINE, SEPARATED))).toEqual([]);
  });

  // The stability side of the same rule: a line ending is not something a rule
  // can measure, so rewriting the file CRLF must leave every key alone.
  test("keeps a twin's key when line endings change to CRLF", () => {
    const crlf = (text) => text.replace(/\n/g, "\r\n");

    expect(reported(
      wrapping(WRAPPED, ONE_LINE),
      wrapping(crlf(WRAPPED), crlf(ONE_LINE)),
    )).toEqual([]);
  });

  // Statements that share a source line are the same problem in the max-depth
  // fallback, and go through the same `discriminate` the definitions above do:
  // two `if (x) {` lines with different bodies are two keys, so neither can be
  // measured against the other's baseline.
  function guards(...bodies) {
    return measure(`
      class Row {
        render() {
${bodies.map((tag) => `          if (x) {\n            if (x) {\n              if (y) { return ${tag} }\n            }\n          }`).join("\n")}
        }
      }
    `, { "max-depth": 1 });
  }

  test("gives statements that share a source line but not a body distinct keys", () => {
    // The two reported `if (x) {` lines are byte-different only in the `return`
    // buried inside them, and that is enough: they are separate keys, not two
    // slots in one.
    expect(labelled(entities(guards(1, 2), "max-depth"))).toEqual([
      "Row#render~if (x) {#a",
      "Row#render~if (y) { return 1 }",
      "Row#render~if (x) {#b",
      "Row#render~if (y) { return 2 }",
    ]);
  });

  test("says nothing when statement twins are reordered and neither one changed", () => {
    expect(reported(guards(1, 2), guards(2, 1))).toEqual([]);
  });

  // Unlike every other measurement here, `max-depth`'s is NOT a property of the
  // entity's own text: two byte-identical `if (a) { y() }` statements sit at
  // different depths when one of them is inside another guard, and measure
  // differently. They shared an anchor and fell back on the ordinal, so the
  // "byte-identical twins measure identically" that justifies the ordinal did
  // not hold for statements. A statement's identity carries its depth now.
  function nested(...guards) {
    const bodies = guards.map(([ guard, deep ]) => deep
      ? `        if (${guard}) {\n          if (${guard}) {\n            if (a) { y() }\n          }\n        }`
      : `        if (${guard}) {\n          if (a) { y() }\n        }`);

    return measure(`
      function handle(p, q, a) {
${bodies.join("\n")}
      }
    `, { "max-depth": 1 });
  }

  const DEEP_P = [ "p", true ], SHALLOW_Q = [ "q", false ];

  test("gives byte-identical statements at different depths distinct keys", () => {
    const keys = entities(nested(DEEP_P, SHALLOW_Q), "max-depth").filter((key) => key.includes("if (a)"));

    expect(new Set(keys).size).toBe(2);
    for (const key of keys) expect(key).not.toMatch(/\(\d+\/\d+\)$/);
  });

  test("says nothing when statements at different depths swap source order", () => {
    expect(reported(nested(DEEP_P, SHALLOW_Q), nested(SHALLOW_Q, DEEP_P))).toEqual([]);
  });

  // The over-correction to guard against: depth is in the key, so a statement
  // that genuinely deepens has to still be reported.
  test("reports a statement that gets deeper", () => {
    const deeper = reported(nested(SHALLOW_Q), nested([ "q", true ]));

    expect(deeper).toContain("handle~if (a) { y() }");
  });

  // An earlier version counted enclosing nesting statements instead of taking
  // ESLint's number, arguing that the key only had to CHANGE when the
  // measurement changed. It does not: a key has to DETERMINE its measurement.
  // Both `if (a) { y() }` below sit under three enclosing statements, but the
  // second hangs off an `else if`, which ESLint does not count — so they
  // measured 3 and 2 while sharing an anchor and falling back on the ordinal,
  // and each was compared against the other's baseline.
  const PLAIN_REGION = `        if (p) {
          if (p) {
            if (a) { y() }
          }
        }`;
  const ELSE_IF_REGION = `        if (q) {
          x()
        } else if (q) {
          if (a) { y() }
        }`;

  function regions(...bodies) {
    return measure(`
      function handle(p, q, a) {
${bodies.join("\n")}
      }
    `, { "max-depth": 1 });
  }

  test("separates byte-identical statements an else-if exempts from a depth level", () => {
    const measured = regions(PLAIN_REGION, ELSE_IF_REGION);
    const keys = entities(measured, "max-depth").filter((key) => key.includes("if (a)"));

    expect(new Set(keys).size).toBe(2);
    // No ordinal: an ordinal here would mean two different measurements
    // sharing one anchor, which is the defect.
    for (const key of keys) expect(key).not.toMatch(/\(\d+\/\d+\)$/);
    expect(new Set(keys.map((key) => measured[`engines/collavre/app/javascript/x.js | max-depth | ${key}`]))).toEqual(new Set([ 3, 2 ]));
  });

  test("does not compare an else-if-exempt statement against an ordinarily nested one", () => {
    // Same two statements, swapped. Under the ordinal each inherited the
    // other's baseline and the swap was silent.
    expect(reported(regions(PLAIN_REGION, ELSE_IF_REGION), regions(ELSE_IF_REGION, PLAIN_REGION)))
      .not.toEqual([]);
  });

  // The sixth variant, and the rule I had argued could not have it: twins sit
  // in one scope by construction, so surely they nest identically. They do not.
  // max-nested-callbacks pops on EVERY function exit but pushes only for
  // functions whose parent is a call, so a function expression that is not a
  // callback pops a level it never added and everything after it counts lower.
  function separated(middle) {
    return measure(`
a(function () {
  items.map((row) => { total += row.n })
${middle}
  items.map((row) => { total += row.n })
})
`, { "max-nested-callbacks": 0 });
  }

  const NON_CALLBACK = "  const helper = function () { return 1 }";

  test("separates twins a non-callback function expression deflates the count for", () => {
    const measured = separated(NON_CALLBACK);
    const keys = entities(measured, "max-nested-callbacks").filter((key) => key.includes("items.map"));

    expect(new Set(keys).size).toBe(2);
    for (const key of keys) expect(key).not.toMatch(/\(\d+\/\d+\)$/);
    expect(new Set(keys.map((key) => measured[`engines/collavre/app/javascript/x.js | max-nested-callbacks | ${key}`])))
      .toEqual(new Set([ 2, 1 ]));
  });

  test("reports the twin whose callback nesting deepens", () => {
    // Moving the non-callback above both twins takes the second from 1 to 2.
    const before = separated(NON_CALLBACK);
    const after = measure(`
a(function () {
${NON_CALLBACK}
  items.map((row) => { total += row.n })
  items.map((row) => { total += row.n })
})
`, { "max-nested-callbacks": 0 });

    expect(reported(before, after)).not.toEqual([]);
  });

  // A FunctionDeclaration is not handled by the rule at all, so it neither
  // pushes nor pops and must NOT separate the twins — the over-correction to
  // guard against is anchoring on something the measurement does not see.
  test("keeps twins together across a function declaration, which the rule ignores", () => {
    const measured = separated("  function helper() { return 1 }");
    const keys = entities(measured, "max-nested-callbacks").filter((key) => key.includes("items.map"));

    // Nothing separates them: one anchor, and the ordinal that byte-identical
    // twins are entitled to precisely because they measure identically.
    expect(new Set(keys.map((key) => key.replace(/\(\d+\/\d+\)$/, ""))).size).toBe(1);
    for (const key of keys) expect(key).toMatch(/\(\d+\/\d+\)$/);
    expect(new Set(keys.map((key) => measured[`engines/collavre/app/javascript/x.js | max-nested-callbacks | ${key}`])))
      .toEqual(new Set([ 2 ]));
  });

  // ESLint decrements on every one of these statements but only increments on
  // some, so an if/else-if chain leaves its counter BELOW where it started and
  // what follows measures too shallow. Mirroring the rule means reproducing
  // that, not correcting it — the key has to match the number ESLint printed.
  test("reproduces the depth ESLint reports after an else-if chain", () => {
    const measured = measure(`
      function f(a, b, c) {
        if (a) { g() } else if (b) { g() } else if (c) { g() }
        while (a) {
          while (b) { g() }
        }
      }
    `, { "max-depth": 0 });

    // Only the chain's head counts; the two `while`s land at -1 and 0.
    expect(entities(measured, "max-depth")).toEqual([ "f~if (a) { g() } else if (b) { g() } else if (c) { g() }" ]);
  });
});

describe("offense shapes", () => {
  test("max-lines belongs to the file, not to whatever sits on the overflowing line", () => {
    const source = `const a = 1\nconst b = 2\nfunction c() { return 3 }\n`;
    const measured = measure(source, { "max-lines": 1 });
    expect(entities(measured, "max-lines")).toEqual(["(file)"]);
    expect(Object.values(measured)).toEqual([3]);
  });

  test("max-depth falls back to the enclosing scope plus the source line", () => {
    const source = `
      class Row {
        render() {
          if (a) { if (b) { if (c) { return 1 } } }
        }
      }
    `;
    // Three `if`s share the line, so all three record the same text and each is
    // anchored to its own span. The outermost is inside the budget and reports
    // nothing; the two that do report are distinct keys rather than two slots
    // in one group, so neither can be measured against the other's baseline.
    expect(labelled(entities(measure(source, { "max-depth": 1 }), "max-depth"))).toEqual([
      "Row#render~if (a) { if (b) { if (c) { return 1 } } }#a",
      "Row#render~if (a) { if (b) { if (c) { return 1 } } }#b",
    ]);
  });

  test("records the largest value when one entity trips a rule twice", () => {
    const source = `
      function render() {
        if (a) { if (b) { if (c) { if (d) { return 1 } } } }
      }
    `;
    const measured = measure(source, { "max-depth": 1 });
    // Three nested offenses on one line, at depths 2, 3 and 4. They are twins
    // of one group rather than one collapsed key, so the deepest is recorded
    // rather than being the only one recorded.
    expect(Math.max(...Object.values(measured))).toBe(4);
  });

  test("reads the measured value out of every rule in the budget", () => {
    const source = `
      class Editor {
        save(a, b, c, d) {
          if (a) { if (b) { if (c) { return 1 } } }
          return a && b || c && d ? 1 : 2
        }
      }
      setTimeout(() => { setTimeout(() => { setTimeout(() => {}) }) })
    `;
    const measured = measure(source, {
      complexity: 1,
      "max-depth": 1,
      "max-lines": 1,
      "max-lines-per-function": 1,
      "max-nested-callbacks": 1,
      "max-params": 1,
    });
    const seen = new Set(Object.keys(measured).map((key) => key.split(" | ")[1]));
    expect([...seen].sort()).toEqual(Object.keys(RULES).sort());
    expect(Object.values(measured).every((value) => Number.isInteger(value) && value > 0)).toBe(true);
  });

  test("throws rather than guessing when a source file does not parse", () => {
    expect(() => measure("class {", { "max-params": 1 })).toThrow(/could not be parsed/);
  });

  test("ignores ESLint's notice that an inline disable comment was refused", () => {
    // noInlineConfig is on, so `eslint-disable` comments cannot switch the gate
    // off; ESLint reports that as a rule-less warning, which is not an entity.
    const source = `/* eslint-disable max-params */\nfunction f(a, b, c) {}\n`;
    expect(entities(measure(source, { "max-params": 2 }), "max-params")).toEqual(["f"]);
  });
});

describe("budget parsing", () => {
  test("rejects a rule the entity mapping does not cover", () => {
    expect(() => parseBudget("rules:\n  no-unused-vars: 3\n")).toThrow(/no entity mapping/);
  });

  test("rejects a threshold that is not a non-negative integer", () => {
    expect(() => parseBudget("rules:\n  complexity: 2.5\n")).toThrow(/non-negative integers/);
    expect(() => parseBudget("rules:\n  complexity: -1\n")).toThrow(/non-negative integers/);
  });

  test("reads include, exclude and rules", () => {
    const budget = parseBudget(`
include:
  - "engines/collavre/**/*.js"
exclude:
  - "**/__tests__/**"
rules:
  complexity: 13
`);
    expect(budget).toEqual({
      include: ["engines/collavre/**/*.js"],
      exclude: ["**/__tests__/**"],
      rules: { complexity: 13 },
    });
  });

  test("refuses to honour an inline directive that would silence the gate", () => {
    expect(eslintConfig({ rules: {} }).linterOptions.noInlineConfig).toBe(true);
  });
});
