# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# Not autoloaded: config/application.rb keeps this CI-only tool out of the app's
# object graph, so the test has to require it by path.
require Rails.root.join("lib/complexity_ratchet").to_s

# The ratchet is a CI gate, so a silent failure here does not break a feature —
# it quietly stops blocking anything, which is worse. These tests pin the two
# properties the gate depends on: entity keys survive editing, and the baseline
# can only ever tighten.
class ComplexityRatchetEntityMapTest < ActiveSupport::TestCase
  def path_for(source, line)
    ComplexityRatchet::EntityMap.for(source)[line]
  end

  test "names a method inside a nested namespace" do
    source = <<~RUBY
      module Collavre
        class Orchestrator
          def run
          end
        end
      end
    RUBY

    assert_equal "Collavre", path_for(source, 1)
    assert_equal "Collavre::Orchestrator", path_for(source, 2)
    assert_equal "Collavre::Orchestrator#run", path_for(source, 3)
  end

  test "distinguishes singleton methods from instance methods" do
    source = <<~RUBY
      class Widget
        def self.build
        end

        class << self
          def forge
          end
        end
      end
    RUBY

    assert_equal "Widget.build", path_for(source, 2)
    assert_equal "Widget::<<self#forge", path_for(source, 6)
  end

  test "names a block by its call and maps both the call and the do line" do
    source = <<~RUBY
      class Registry
        def register
          items
            .each do |item|
              item
            end
        end
      end
    RUBY

    # RuboCop reports Metrics/BlockLength against the whole send+block range, so
    # the offense line is the receiver's line, not the `do`.
    assert_equal "Registry#register[block:each]", path_for(source, 3)
    assert_equal "Registry#register[block:each]", path_for(source, 4)
  end

  test "a block-pass argument is not a scope" do
    # `&handler` parses as a BlockArgumentNode, which has no body. Treating it
    # like a literal block used to raise and silently degrade the whole file to
    # source-line fallback keys.
    source = <<~RUBY
      class Runner
        def run(&handler)
          items.each(&handler)
        end
      end
    RUBY

    assert_equal "Runner#run", path_for(source, 2)
    assert_nil path_for(source, 3)
  end

  test "sibling scopes sharing a name get distinct keys" do
    # Without the ordinal both blocks key to Sample#run[block:each], and
    # Measurement#record keeps only the larger of the two — so a second block
    # over the budget hides behind a bigger sibling already in the baseline.
    source = <<~RUBY
      class Sample
        def run
          items.each do |i|
            i
          end
          others.each do |o|
            o
          end
        end
      end
    RUBY

    assert_equal "Sample#run[block:each]", path_for(source, 3)
    assert_equal "Sample#run[block:each](2)", path_for(source, 6)
  end

  test "sibling scopes are counted per parent, not per file" do
    source = <<~RUBY
      class Sample
        def first
          items.each { |i| i }
        end

        def second
          items.each { |i| i }
        end
      end
    RUBY

    assert_equal "Sample#first[block:each]", path_for(source, 3)
    assert_equal "Sample#second[block:each]", path_for(source, 7)
  end

  test "a class reopened in the same file does not collapse into one key" do
    source = "class A\n  def b\n  end\nend\nclass A\n  def c\n  end\nend\n"

    assert_equal "A#b", path_for(source, 2)
    assert_equal "A(2)#c", path_for(source, 6)
  end

  test "the key is unchanged when code is inserted above the entity" do
    before = "class A\n  def b\n  end\nend\n"
    after  = "class A\n  CONST = 1\n\n  def b\n  end\nend\n"

    assert_equal path_for(before, 2), path_for(after, 4)
  end
end

class ComplexityRatchetMeasurementTest < ActiveSupport::TestCase
  setup do
    @dir = Dir.mktmpdir
    @source = <<~RUBY
      class Sample
        def wide
          1
        end
      end
    RUBY
    File.write(File.join(@dir, "sample.rb"), @source)
  end

  teardown { FileUtils.remove_entry(@dir) }

  def fold(offenses)
    payload = { "files" => [ { "path" => File.join(@dir, "sample.rb"), "offenses" => offenses } ] }
    ComplexityRatchet::Measurement.new(root: @dir).fold(payload)
  end

  def offense(cop, message, line)
    { "cop_name" => cop, "message" => message, "location" => { "start_line" => line } }
  end

  test "extracts the measured value and keys it by path, cop and entity" do
    result = fold([ offense("Metrics/MethodLength", "Method has too many lines. [38/25]", 2) ])

    assert_equal({ "sample.rb | Metrics/MethodLength | Sample#wide" => 38 }, result)
  end

  test "extracts the AbcSize value from behind its component vector" do
    result = fold([ offense("Metrics/AbcSize", "ABC size is too high. [<7, 42, 8> 43.55/35]", 2) ])

    assert_equal 43.55, result.values.sole
  end

  test "keeps the worst value when one entity offends twice for the same cop" do
    result = fold([
      offense("Metrics/MethodLength", "Method has too many lines. [30/25]", 2),
      offense("Metrics/MethodLength", "Method has too many lines. [44/25]", 2)
    ])

    assert_equal 44, result.values.sole
  end

  test "counts offenses that carry no measured value" do
    # Metrics/BlockNesting says "Avoid more than 3 levels" with no number.
    result = fold([
      offense("Metrics/BlockNesting", "Avoid more than 3 levels of block nesting.", 3),
      offense("Metrics/BlockNesting", "Avoid more than 3 levels of block nesting.", 3)
    ])

    assert_equal 2, result.values.sole
  end

  test "falls back to the source line for offenses that are not on a definition" do
    result = fold([ offense("Metrics/BlockNesting", "Avoid more than 3 levels of block nesting.", 3) ])

    assert_equal "sample.rb | Metrics/BlockNesting | ~1", result.keys.sole
  end

  test "skips files with no offenses" do
    payload = { "files" => [ { "path" => "sample.rb", "offenses" => [] }, { "path" => "other.rb" } ] }

    assert_empty ComplexityRatchet::Measurement.new(root: @dir).fold(payload)
  end

  test "a new block does not hide behind a bigger sibling with the same call" do
    # The whole failure mode in one test: two `each` blocks in one method used
    # to fold to a single key, and #record keeps the maximum. A block added at
    # 80 against a sibling already baselined at 90 left the folded value at 90
    # — unchanged, so the ratchet passed a fresh over-budget block.
    File.write(File.join(@dir, "sample.rb"), <<~RUBY)
      class Sample
        def run
          items.each do |i|
            i
          end
          others.each do |o|
            o
          end
        end
      end
    RUBY

    result = fold([
      offense("Metrics/BlockLength", "Block has too many lines. [90/70]", 3),
      offense("Metrics/BlockLength", "Block has too many lines. [80/70]", 6)
    ])

    assert_equal({
      "sample.rb | Metrics/BlockLength | Sample#run[block:each]" => 90,
      "sample.rb | Metrics/BlockLength | Sample#run[block:each](2)" => 80
    }, result)

    baselined_sibling_only = result.reject { |key, _| key.end_with?("(2)") }.transform_values { 90 }
    check = ComplexityRatchet::Check.new(actual: result, baseline: baselined_sibling_only)

    refute_predicate check, :pass?
    assert_equal :new_offense, check.blocking_problems.sole.kind
  end
end

class ComplexityRatchetCheckTest < ActiveSupport::TestCase
  TODAY = Date.new(2026, 8, 11)
  KEY = "a.rb | Metrics/MethodLength | A#b"

  def check(actual:, baseline: {}, waivers: [])
    ComplexityRatchet::Check.new(actual: actual, baseline: baseline, waivers: waivers, today: TODAY)
  end

  def waiver(expires:, key: KEY, owner: "@sh1nj1", reason: "because")
    ComplexityRatchet::Waiver.new(key: key, owner: owner, reason: reason, expires: expires)
  end

  test "passes when every entity matches its baseline" do
    result = check(actual: { KEY => 30 }, baseline: { KEY => 30 })

    assert_predicate result, :pass?
    assert_empty result.problems
  end

  test "blocks an entity that grew" do
    problem = check(actual: { KEY => 31 }, baseline: { KEY => 30 }).problems.sole

    assert_equal :regression, problem.kind
    assert_predicate problem, :blocking?
  end

  test "blocks a new over-budget entity that has no baseline entry" do
    # This is the case a .rubocop_todo.yml would wave through: auto-gen raises
    # MethodLength's Max to the file's worst value, so brand-new bloat inherits
    # the amnesty. Here it has to be fixed or waived.
    problem = check(actual: { KEY => 31 }).problems.sole

    assert_equal :new_offense, problem.kind
    assert_predicate problem, :blocking?
  end

  test "blocks a stale baseline when the entity improved" do
    problem = check(actual: { KEY => 28 }, baseline: { KEY => 30 }).problems.sole

    assert_equal :stale, problem.kind
    assert_match(/--regenerate/, problem.message)
  end

  test "blocks a stale baseline when the entity dropped under budget entirely" do
    problem = check(actual: {}, baseline: { KEY => 30 }).problems.sole

    assert_equal :stale, problem.kind
  end

  test "a live waiver suppresses a new over-budget entity" do
    result = check(actual: { KEY => 31 }, waivers: [ waiver(expires: TODAY + 30) ])

    assert_predicate result, :pass?
  end

  test "an expired waiver blocks instead of quietly lapsing" do
    problem = check(actual: { KEY => 31 }, waivers: [ waiver(expires: TODAY - 1) ]).problems.sole

    assert_equal :expired_waiver, problem.kind
    assert_predicate problem, :blocking?
  end

  test "a waiver expiring beyond the cap is rejected" do
    problem = check(
      actual: { KEY => 31 },
      waivers: [ waiver(expires: TODAY + ComplexityRatchet::MAX_WAIVER_DAYS + 1) ]
    ).problems.sole

    assert_equal :invalid_waiver, problem.kind
  end

  test "a waiver missing an owner or a reason is rejected" do
    problem = check(actual: { KEY => 31 }, waivers: [ waiver(expires: TODAY + 30, owner: nil) ]).problems.sole

    assert_equal :invalid_waiver, problem.kind
  end

  test "a blank owner or reason is rejected rather than counted as present" do
    # `owner: ""` satisfies a nil check while providing exactly none of the
    # accountability the waiver exists to create — and a waiver that validates
    # skips the entity entirely.
    [ { owner: "" }, { reason: "   " }, { owner: "\n" } ].each do |blank|
      result = check(actual: { KEY => 31 }, waivers: [ waiver(expires: TODAY + 30, **blank) ])

      refute_predicate result, :pass?, "expected #{blank.inspect} to be rejected"
      assert_equal :invalid_waiver, result.problems.sole.kind
    end
  end

  test "an unused waiver is reported but does not block" do
    result = check(actual: {}, waivers: [ waiver(expires: TODAY + 30) ])

    assert_predicate result, :pass?
    assert_equal :unused_waiver, result.problems.sole.kind
  end
end

class ComplexityRatchetBaselineTest < ActiveSupport::TestCase
  KEY = "engines/collavre/app/services/collavre/agent_orchestrator.rb | Metrics/ClassLength | Collavre::AgentOrchestrator"

  setup { @dir = Dir.mktmpdir }
  teardown { FileUtils.remove_entry(@dir) }

  def path
    File.join(@dir, ComplexityRatchet::BASELINE_PATH)
  end

  test "round-trips through the nested on-disk format" do
    entries = { KEY => 391, "a.rb | Metrics/AbcSize | A#b" => 43.55 }
    ComplexityRatchet.dump_baseline(path, entries)

    assert_equal entries, ComplexityRatchet.load_baseline(path)
  end

  test "writes one line per entity even for keys past YAML's implicit-key limit" do
    ComplexityRatchet.dump_baseline(path, { KEY => 391 })

    # A flat key this long makes Psych emit the `? key` / `: value` explicit
    # form, which turns a one-line diff into three.
    refute_includes File.read(path), "? "
  end

  test "an absent baseline reads as empty rather than raising" do
    assert_empty ComplexityRatchet.load_baseline(path)
  end

  test "a fallback entity name containing the separator survives the round trip" do
    entries = { "a.rb | Metrics/BlockNesting | ~x = a | b" => 1 }
    ComplexityRatchet.dump_baseline(path, entries)

    assert_equal entries, ComplexityRatchet.load_baseline(path)
  end

  test "normalize keeps whole numbers integral" do
    assert_equal 38, ComplexityRatchet.normalize(38.0)
    assert_equal 43.55, ComplexityRatchet.normalize(43.5512)
  end
end

class ComplexityRatchetMonotonicityTest < ActiveSupport::TestCase
  KEY = "a.rb | Metrics/MethodLength | A#b"

  test "accepts a baseline that only tightens" do
    assert_empty ComplexityRatchet.verify_monotonic({ KEY => 30 }, { KEY => 28 })
  end

  test "accepts a baseline entry that disappeared" do
    assert_empty ComplexityRatchet.verify_monotonic({ KEY => 30 }, {})
  end

  test "rejects a raised value" do
    # Without this the ratchet is decorative: anyone could regenerate the
    # baseline and land any regression.
    problem = ComplexityRatchet.verify_monotonic({ KEY => 30 }, { KEY => 240 }).sole

    assert_equal :baseline_loosened, problem.kind
  end

  test "rejects a newly added entry" do
    problem = ComplexityRatchet.verify_monotonic({}, { KEY => 30 }).sole

    assert_equal :baseline_addition, problem.kind
  end

  test "a base ref that predates the baseline file has nothing to verify" do
    # The bootstrap commit adds hundreds of entries at once; there is no prior
    # baseline for them to be a regression against.
    assert_empty ComplexityRatchet.verify_monotonic(nil, { KEY => 30 })
  end
end

class ComplexityRatchetRegenerateTest < ActiveSupport::TestCase
  KEY = "a.rb | Metrics/MethodLength | A#b"
  OTHER = "b.rb | Metrics/AbcSize | B#c"

  test "lowers entries that shrank and drops entries that were resolved" do
    updated, unrecorded = ComplexityRatchet.regenerate({ KEY => 30, OTHER => 40 }, { KEY => 26 })

    assert_equal({ KEY => 26 }, updated)
    assert_empty unrecorded
  end

  test "refuses to absorb new debt and names it instead" do
    updated, unrecorded = ComplexityRatchet.regenerate({}, { KEY => 30 })

    assert_empty updated
    assert_equal [ KEY ], unrecorded
  end
end

class ComplexityRatchetWaiverLoadingTest < ActiveSupport::TestCase
  setup { @dir = Dir.mktmpdir }
  teardown { FileUtils.remove_entry(@dir) }

  def write(body)
    File.join(@dir, "waivers.yml").tap { |path| File.write(path, body) }
  end

  test "parses waivers and coerces the expiry to a Date" do
    waiver = ComplexityRatchet.load_waivers(write(<<~YAML)).sole
      waivers:
        - key: "a.rb | Metrics/MethodLength | A#b"
          owner: "@sh1nj1"
          reason: "handshake is linear"
          expires: "2026-11-09"
    YAML

    assert_equal Date.new(2026, 11, 9), waiver.expires
    assert_equal "@sh1nj1", waiver.owner
  end

  test "accepts an unquoted date, which YAML loads as a Date" do
    waiver = ComplexityRatchet.load_waivers(write(<<~YAML)).sole
      waivers:
        - key: "k"
          owner: "@o"
          reason: "r"
          expires: 2026-11-09
    YAML

    assert_equal Date.new(2026, 11, 9), waiver.expires
  end

  test "an unparseable expiry becomes nil so the check rejects the waiver" do
    waiver = ComplexityRatchet.load_waivers(write(<<~YAML)).sole
      waivers:
        - key: "k"
          owner: "@o"
          reason: "r"
          expires: "someday"
    YAML

    assert_nil waiver.expires
  end

  test "the checked-in waiver template parses to an empty list" do
    assert_empty ComplexityRatchet.load_waivers(write(ComplexityRatchet::WAIVERS_TEMPLATE))
  end

  test "an absent waiver file reads as empty" do
    assert_empty ComplexityRatchet.load_waivers(File.join(@dir, "missing.yml"))
  end
end
