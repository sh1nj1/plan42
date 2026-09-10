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

  test("names an anonymous callback after the call it is passed to", () => {
    const source = `
      class Row {
        connect() {
          this.el.addEventListener("click", (a, b, c) => {})
        }
      }
    `;
    expect(entities(measure(source, { "max-params": 2 }), "max-params")).toEqual([
      "Row#connect>[addEventListener]",
    ]);
  });

  test("numbers siblings that share a name from the second on", () => {
    const source = `
      class Row {
        connect() {
          items.map((a, b, c) => {})
          items.map((a, b, c) => {})
        }
      }
    `;
    expect(entities(measure(source, { "max-params": 2 }), "max-params")).toEqual([
      "Row#connect>[map]",
      "Row#connect>[map](2)",
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
    expect(entities(measure(source, { "max-depth": 1 }), "max-depth")).toEqual([
      "Row#render~if (a) { if (b) { if (c) { return 1 } } }",
      "Row#render~if (a) { if (b) { if (c) { return 1 } } }[fallback:2]",
    ]);
  });

  test("records the largest value when one entity trips a rule twice", () => {
    const source = `
      function render() {
        if (a) { if (b) { if (c) { if (d) { return 1 } } } }
      }
    `;
    const measured = measure(source, { "max-depth": 1 });
    // Three nested offenses on one line: depths 2, 3 and 4 all report at the
    // same normalised source line, so they share a key after the ordinal.
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
