# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# Not autoloaded: config/application.rb keeps this CI-only tool out of the app's
# object graph, so the test has to require it by path.
require Rails.root.join("lib/complexity_ratchet").to_s
require Rails.root.join("lib/complexity_ratchet/javascript").to_s

# The JavaScript budget is the same ratchet as the Ruby one and needs the same
# two properties pinned: a measurement that produces stable entity keys, and a
# budget that can only tighten. The entity naming itself is tested where it
# lives, in lib/js_complexity/__tests__/measure.test.js.
class ComplexityRatchetJavascriptBudgetTest < ActiveSupport::TestCase
  BEFORE = {
    "include" => [ "engines/collavre/**/*.js" ],
    "exclude" => [ "**/__tests__/**" ],
    "rules" => { "complexity" => 13, "max-lines" => 300 }
  }.freeze

  def verify(after)
    ComplexityRatchet::Javascript.verify_budget(BEFORE, BEFORE.merge(after))
  end

  test "accepts an unchanged budget" do
    assert_empty verify({})
  end

  test "accepts a tightened threshold and a newly added rule" do
    assert_empty verify("rules" => { "complexity" => 10, "max-lines" => 300, "max-params" => 4 })
  end

  # The bypass this exists to catch: both trees are measured with this branch's
  # budget, so raising a threshold stops the offenses on both sides at once and
  # the entity-by-entity comparison sees nothing at all.
  test "rejects a raised threshold" do
    problem = verify("rules" => { "complexity" => 40, "max-lines" => 300 }).sole

    assert_equal :js_budget_loosened, problem.kind
    assert_equal "complexity", problem.key
    assert problem.blocking?
  end

  test "rejects a rule that is deleted outright" do
    problem = verify("rules" => { "complexity" => 13 }).sole

    assert_equal :js_budget_disabled, problem.kind
    assert_equal "max-lines", problem.key
  end

  test "rejects a threshold that is not a non-negative integer" do
    assert_equal :js_budget_invalid_max, verify("rules" => BEFORE["rules"].merge("complexity" => -1)).sole.kind
    assert_equal :js_budget_invalid_max, verify("rules" => BEFORE["rules"].merge("complexity" => 13.5)).sole.kind
    assert_equal :js_budget_invalid_max, verify("rules" => BEFORE["rules"].merge("complexity" => "13")).sole.kind
  end

  test "rejects narrowing the measured scope from either side" do
    dropped = verify("include" => []).sole
    assert_equal :js_budget_scope_narrowed, dropped.kind
    assert_includes dropped.message, "include"

    excluded = verify("exclude" => [ "**/__tests__/**", "engines/collavre/app/javascript/controllers/**" ]).sole
    assert_equal :js_budget_scope_narrowed, excluded.kind
    assert_includes excluded.message, "exclude"
  end

  test "accepts widening the measured scope from either side" do
    assert_empty verify("include" => BEFORE["include"] + [ "engines/collavre/**/*.jsx" ])
    assert_empty verify("exclude" => [])
  end

  # An allowlist, not a list of known tricks: a key the comparison cannot judge
  # is a bypass waiting to be written into it.
  test "rejects a key the ratchet does not know how to compare" do
    problem = verify("overrides" => [ { "files" => "**/*", "rules" => {} } ]).sole

    assert_equal :js_budget_unknown_key, problem.kind
    assert_equal "overrides", problem.key
  end

  test "has nothing to say when the budget file is new" do
    assert_empty ComplexityRatchet::Javascript.verify_budget(nil, BEFORE)
  end
end

class ComplexityRatchetJavascriptMeasurementTest < ActiveSupport::TestCase
  BUDGET = <<~YAML
    include:
      - "**/*.js"
    exclude:
      - "**/__tests__/**"
    rules:
      complexity: 2
      max-params: 2
  YAML

  TWIN_BUDGET = <<~YAML
    include:
      - "**/*.js"
    exclude: []
    rules:
      max-lines-per-function: 2
  YAML

  # Runs the real Node script against a throwaway tree, which is the part that
  # cannot be unit-tested from either side: the Ruby half has to survive the
  # script's actual output, and the script has to measure a tree that has no
  # node_modules and no config of its own.
  test "measures a tree with this checkout's tooling and budget" do
    Dir.mktmpdir do |tree|
      File.write(File.join(tree, "widget.js"), <<~JS)
        export class Widget {
          render(a, b, c) {
            return a && b || c ? 1 : 2
          }
        }
      JS
      FileUtils.mkdir_p(File.join(tree, "__tests__"))
      File.write(File.join(tree, "__tests__", "widget.test.js"), "const f = (a, b, c) => a\n")

      measured = with_budget do |config|
        ComplexityRatchet::Javascript::Measurement.call(root: tree, tool_root: Rails.root.to_s, config: config)
      end

      assert_equal(
        {
          "widget.js | complexity | Widget#render" => 4,
          "widget.js | max-params | Widget#render" => 3
        },
        measured
      )
    end
  end

  # The Codex reviews on PR #1651 named both halves of this. With an order-only
  # ordinal a same-named callback is identified by its SLOT, so deleting the
  # first of two renames the survivor onto the deleted one's key, and reordering
  # two of them measures each against the other's baseline. The JavaScript unit
  # tests pin the naming; these pin the thing that actually matters, which is
  # what the gate does with it.
  test "reports a surviving twin's growth after its sibling is deleted" do
    before = measure_twins(12, 6)
    after  = measure_twins(9)

    assert_empty before.keys & after.keys, "a survivor must not inherit a deleted twin's key"
    assert_equal [ :new_offense ], check(actual: after, base: before).map(&:kind)
  end

  # Codex's second case: under a slot ordinal this passed, because slot 1 read
  # `9 <= 12` and slot 2 read `5 <= 6` while the 6-line callback had grown to 9.
  test "reports growth hidden behind a reorder and a compensating shrink" do
    problems = check(actual: measure_twins(9, 5), base: measure_twins(12, 6))

    assert_equal [ :new_offense, :new_offense ], problems.map(&:kind)
  end

  test "reports growth that moves between reordered twins" do
    problems = check(actual: measure_twins(9, 12), base: measure_twins(12, 6))

    assert_equal [ :new_offense ], problems.map(&:kind)
  end

  # A twin is anchored to its own body, so its siblings can come and go around
  # it without touching its baseline. Under the ordinal this reported.
  test "says nothing when a twin is deleted and the rest are untouched" do
    assert_empty check(actual: measure_twins(12, 8), base: measure_twins(12, 8, 6))
  end

  test "says nothing when twins are reordered and neither one changed" do
    assert_empty check(actual: measure_twins(6, 12), base: measure_twins(12, 6))
  end

  # The cost of anchoring, stated as a test so it cannot drift into folklore: an
  # over-budget twin that shrinks without getting under budget has a new body,
  # so it has a new key and reads as new debt. Loud about an improvement is
  # recoverable — name the callback, finish the job, or waive it. Quiet about
  # growth is not.
  test "reports a twin that shrinks without getting under budget" do
    problems = check(actual: measure_twins(10, 6), base: measure_twins(12, 6))

    assert_equal [ :new_offense ], problems.map(&:kind)
  end

  test "raises with the file and the reason when a tree cannot be measured" do
    Dir.mktmpdir do |tree|
      File.write(File.join(tree, "broken.js"), "class {\n")

      error = assert_raises(ComplexityRatchet::Error) do
        with_budget do |config|
          ComplexityRatchet::Javascript::Measurement.call(root: tree, tool_root: Rails.root.to_s, config: config)
        end
      end

      assert_includes error.message, "broken.js"
      assert_includes error.message, "could not be parsed"
    end
  end

  private

  # A method holding `sizes.length` callbacks that the entity naming cannot tell
  # apart, each `sizes[i]` statements long. Only the callbacks are returned: the
  # enclosing method changes size whenever the fixture does, and that is not what
  # these tests are about.
  def measure_twins(*sizes)
    calls = sizes.map { |size| "  items.map((row) => {\n#{Array.new(size) { |i| "    const v#{i} = #{i}" }.join("\n")}\n  })" }

    Dir.mktmpdir do |tree|
      File.write(File.join(tree, "row.js"), "class Row {\n connect() {\n#{calls.join("\n")}\n }\n}\n")

      measured = with_budget(TWIN_BUDGET) do |config|
        ComplexityRatchet::Javascript::Measurement.call(root: tree, tool_root: Rails.root.to_s, config: config)
      end

      measured.select { |key, _value| key.include?("[items.map]") }
    end
  end

  def check(actual:, base:)
    ComplexityRatchet::Check.new(actual: actual, base: base).problems
  end

  def with_budget(budget = BUDGET)
    Dir.mktmpdir do |dir|
      config = File.join(dir, "budget.yml")
      File.write(config, budget)
      yield config
    end
  end
end

# The include globs are the whole scope of the gate. A typo in one of them
# measures nothing at all and reports success, which is the failure mode this
# design is otherwise built to avoid.
class ComplexityRatchetJavascriptScopeTest < ActiveSupport::TestCase
  setup do
    @budget = YAML.safe_load_file(Rails.root.join(ComplexityRatchet::Javascript::CONFIG_PATH))
  end

  test "the shipped include globs match the core engine's JavaScript" do
    matched = Dir.glob(@budget["include"], base: Rails.root.to_s)

    assert_operator matched.size, :>, 100
    assert_includes matched, "engines/collavre/app/javascript/controllers/index.js"
  end

  test "every shipped threshold is a rule the measurement can map to an entity" do
    known = File.read(Rails.root.join("lib/js_complexity/measure.js")).scan(/^  "?([a-z-]+)"?: \{$/).flatten

    assert_includes known, "complexity"
    assert_empty @budget["rules"].keys - known
  end
end
