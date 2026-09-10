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

  test("gives twins their position and their group's size", () => {
    const source = `
      class Row {
        connect() {
          items.map((a, b, c) => {})
          items.map((a, b, c) => {})
        }
      }
    `;
    expect(entities(measure(source, { "max-params": 2 }), "max-params")).toEqual([
      "Row#connect>[items.map](1/2)",
      "Row#connect>[items.map](2/2)",
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
  // Two callbacks the naming cannot tell apart, sized independently. The
  // measurements below stand in for the two sides of the merge-base comparison;
  // only the callbacks are kept, because the method wrapping them changes size
  // whenever the fixture does and that is not what these tests are about.
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

  // The hole this shape exists to close. Under a plain ordinal the survivor is
  // renamed onto the deleted twin's key — `>[items.map](2)` becomes
  // `>[items.map]` — so 6 growing to 9 is compared against the 12 that was
  // deleted, and the ratchet says nothing.
  test("does not hand a deleted twin's key to the survivor", () => {
    const before = twins(12, 6);
    const after = twins(9);

    expect(Object.keys(after).some((key) => key in before)).toBe(false);
    expect(reported(before, after)).toEqual(["Row#connect>[items.map]"]);
  });

  // The same edit without the growth still reports. That is the deliberate
  // cost: the group's size is part of every key in it, so removing a twin
  // invalidates the survivors' baselines and they read as new debt. A gate that
  // is loud about an improvement is recoverable — a waiver, a name, or getting
  // the survivor under budget. A gate that is quiet about growth is not.
  test("reports the survivor as new debt even when nothing grew", () => {
    expect(reported(twins(12, 6), twins(6))).toEqual(["Row#connect>[items.map]"]);
  });

  test("does not hide growth when twins are reordered", () => {
    // 12/6 becomes 6-grown-to-9 first, 12 second. Slot 2 held 6 and now holds
    // 12, which reports — the growth cannot cross into the larger baseline.
    expect(reported(twins(12, 6), twins(9, 12))).toEqual(["Row#connect>[items.map](2/2)"]);
  });

  test("says nothing when a twin shrinks and nothing else moves", () => {
    expect(reported(twins(12, 6), twins(10, 6))).toEqual([]);
  });

  // Identical `if` lines in one method are the same problem in the statement
  // fallback, and get the same treatment: the group's size is part of the key,
  // so the survivor of a deleted twin cannot inherit its measurement.
  test("does not hand a deleted statement twin's key to the survivor", () => {
    const guards = (count) => measure(`
      class Row {
        render() {
${Array.from({ length: count }, () => "          if (a) { if (b) { return 1 } }").join("\n")}
        }
      }
    `, { "max-depth": 1 });

    const before = guards(2);
    const after = guards(1);

    expect(entities(before, "max-depth")).toEqual([
      "Row#render~if (a) { if (b) { return 1 } }(2/4)",
      "Row#render~if (a) { if (b) { return 1 } }(4/4)",
    ]);
    expect(entities(after, "max-depth")).toEqual(["Row#render~if (a) { if (b) { return 1 } }(2/2)"]);
    expect(Object.keys(after).some((key) => key in before)).toBe(false);
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
    // Three `if`s share the line, so the two offending ones are twins 2 and 3
    // of a group of three — the outermost `if` is inside the budget and still
    // counts towards the group, exactly as the Ruby side counts below-budget
    // statements.
    expect(entities(measure(source, { "max-depth": 1 }), "max-depth")).toEqual([
      "Row#render~if (a) { if (b) { if (c) { return 1 } } }(2/3)",
      "Row#render~if (a) { if (b) { if (c) { return 1 } } }(3/3)",
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
