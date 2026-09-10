import { Linter } from "eslint";

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
  return keys.map((key) => key.replace(/#[0-9a-f]{8}/g, (digest) => {
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
