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
  def path_for(source, line, last_line = nil)
    ComplexityRatchet::EntityMap.for(source)[line, last_line]
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

  test "singleton methods on explicit receivers get distinct keys" do
    # `def self.run` keeps the plain `.run` key it has always had, but
    # `def Foo.run` and `def Bar.run` are separate entities. Collapsed onto one
    # key, swapping a baselined 90-line `Foo.run` for an 80-line `Bar.run`
    # reads as a tightening when it is in fact new debt on a new method.
    source = <<~RUBY
      module Sample
        def self.run
        end

        def Foo.run
        end

        def Bar.run
        end
      end
    RUBY

    assert_equal "Sample.run", path_for(source, 2)
    assert_equal "Sample::Foo.run", path_for(source, 5)
    assert_equal "Sample::Bar.run", path_for(source, 8)
  end

  test "keeps the population of siblings that are below the budget" do
    source = <<~RUBY
      class Sample
        def run
          items.each { |item| item }
          others.each { |item| item }
        end
      end
    RUBY

    assert_equal({ "Sample#run[block:each]" => 2 }, ComplexityRatchet::EntityMap.for(source).sibling_populations)
  end

  test "keeps the population of fallback statement twins below the budget" do
    source = <<~RUBY
      class Sample
        def run
          if ready
          end
          if ready
          end
        end
      end
    RUBY

    assert_equal({ "Sample#run~if ready" => 2 }, ComplexityRatchet::EntityMap.for(source).sibling_populations)
  end

  test "keeps block call prefixes as sibling anchors" do
    source = <<~RUBY
      class Sample
        def run
          first.each { |item| item }
          second.each { |item| item }
        end
      end
    RUBY

    assert_equal(
      { "Sample#run[block:each]" => [ "first.each", "second.each" ] },
      ComplexityRatchet::EntityMap.for(source).sibling_anchors
    )
  end

  test "keeps lambda anchors for sibling verification" do
    source = <<~RUBY
      class Sample
        HANDLERS = [
          -> do
            first
          end,
          -> do
            second
          end
        ]
      end
    RUBY

    assert_equal(
      { "Sample[lambda]" => [ "[lambda]", "[lambda]" ] },
      ComplexityRatchet::EntityMap.for(source).sibling_anchors
    )
  end

  test "keeps the assignment anchor of a unique lambda" do
    source = <<~RUBY
      class Sample
        HANDLER = -> do
          first
        end
      end
    RUBY

    assert_equal(
      { "Sample[lambda]" => [ "HANDLER =" ] },
      ComplexityRatchet::EntityMap.for(source).sibling_anchors
    )
  end

  test "keeps the preceding assignment anchor of a multiline unique lambda" do
    source = <<~RUBY
      class Sample
        HANDLER =
          -> do
            first
          end
      end
    RUBY

    assert_equal(
      { "Sample[lambda]" => [ "HANDLER =" ] },
      ComplexityRatchet::EntityMap.for(source).sibling_anchors
    )
  end

  test "keeps the enclosing call anchor of a multiline unique lambda" do
    source = <<~RUBY
      class Sample
        register(
          -> do
            first
          end
        )
      end
    RUBY

    assert_equal(
      { "Sample[lambda]" => [ "register(" ] },
      ComplexityRatchet::EntityMap.for(source).sibling_anchors
    )
  end

  test "keeps enclosing call anchor after an earlier multiline lambda argument" do
    source = <<~RUBY
      class Sample
        register(
          :handler,
          -> do
            first
          end
        )
      end
    RUBY

    assert_equal(
      { "Sample[lambda]" => [ "register( :handler," ] },
      ComplexityRatchet::EntityMap.for(source).sibling_anchors
    )
  end

  test "keeps the anchor of a uniquely named block" do
    source = <<~RUBY
      class Sample
        def run
          users.each { |user| user }
        end
      end
    RUBY

    assert_equal(
      { "Sample#run[block:each]" => [ "users.each" ] },
      ComplexityRatchet::EntityMap.for(source).sibling_anchors
    )
  end

  test "keeps assignment context in callable block anchors" do
    source = <<~RUBY
      class Sample
        HANDLER = proc do
          first
        end
        DISPATCHER = lambda do
          second
        end
      end
    RUBY

    assert_equal(
      {
        "Sample[block:proc]" => [ "HANDLER =" ],
        "Sample[block:lambda]" => [ "DISPATCHER =" ]
      },
      ComplexityRatchet::EntityMap.for(source).sibling_anchors
    )
  end

  test "keeps assignment context in other anonymous block anchors" do
    source = <<~RUBY
      class Sample
        HANDLER = Enumerator.new do
          first
        end
      end
    RUBY

    assert_equal(
      { "Sample[block:new]" => [ "HANDLER =" ] },
      ComplexityRatchet::EntityMap.for(source).sibling_anchors
    )
  end

  test "keeps enclosing call context after earlier callable arguments" do
    source = <<~RUBY
      class Sample
        register(:handler, Enumerator.new do
          first
        end)
      end
    RUBY

    assert_equal(
      { "Sample[block:new]" => [ "register(:handler," ] },
      ComplexityRatchet::EntityMap.for(source).sibling_anchors
    )
  end

  # Both views come from one parse now. They have to stay keyed identically, or
  # verify_monotonic would look up an anchor under a key the population never
  # produced and silently compare nothing.
  test "sibling profile answers both views from one pass over the sources" do
    source = <<~RUBY
      class Sample
        def run
          first.each { |item| item }
          second.each { |item| item }
        end
      end
    RUBY
    sources = { "a.rb" => source, "gone.rb" => nil }

    profile = ComplexityRatchet.sibling_profile(sources)

    assert_equal({ "a.rb | Sample#run[block:each]" => 2 }, profile.fetch(:populations))
    assert_equal({ "a.rb | Sample#run[block:each]" => [ "first.each", "second.each" ] }, profile.fetch(:anchors))
    assert_equal profile.fetch(:populations), ComplexityRatchet.sibling_populations(sources)
    assert_equal profile.fetch(:anchors), ComplexityRatchet.sibling_anchors(sources)
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

  # Sibling ordinals fixed twins that start on different lines. Chained blocks
  # start on the SAME line: RuboCop reports both `each` and `map` below at the
  # receiver's line and column, because a block offense covers the whole
  # `send + block` range and the outer send begins at `items`. Only the end line
  # separates them, and Prism's node ranges match RuboCop's offense ranges
  # exactly for classes, defs and blocks.
  test "chained blocks opening on one line resolve to different entities" do
    source = <<~RUBY
      class Sample
        def run
          items.each do |i|
            i
          end.map do |o|
            o
          end
        end
      end
    RUBY

    assert_equal "Sample#run[block:each]", path_for(source, 3, 5)
    assert_equal "Sample#run[block:map]", path_for(source, 3, 7)

    # Without an end line there is still an answer, so an offense whose range is
    # not a scope's range keeps resolving to something rather than to nil.
    assert_equal "Sample#run[block:each]", path_for(source, 3)
  end

  # `-> do ... end` is a LambdaNode, not a CallNode carrying a block, so the
  # visitor never reached it and every arrow lambda fell back to its source
  # line — which reads `-> do` for all of them.
  test "arrow lambdas are entities, and siblings do not share a key" do
    source = <<~RUBY
      class Sample
        HANDLERS = [
          -> do
            1
          end,
          -> do
            2
          end
        ].freeze
      end
    RUBY

    assert_equal "Sample[lambda]", path_for(source, 3, 5)
    assert_equal "Sample[lambda](2)", path_for(source, 6, 8)
  end

  # A `do ... end` hangs off three node types, and only CallNode was handled.
  # `super do` is a SuperNode or a ForwardingSuperNode depending on nothing more
  # than whether the parentheses are written, so both fell back to their source
  # line — and `~super do` is the same text for every one of them.
  test "blocks attached to super are entities, with or without parentheses" do
    source = <<~RUBY
      class Sample < Base
        def run
          super do
            1
          end
          super() do
            2
          end
          super do
            3
          end
        end
      end
    RUBY

    assert_equal "Sample#run[block:super]", path_for(source, 3, 5)
    assert_equal "Sample#run[block:super](2)", path_for(source, 6, 8)
    assert_equal "Sample#run[block:super](3)", path_for(source, 9, 11)
  end

  # A lambda is a scope like any other: things nested inside it must carry it in
  # their path, or a method-shaped body inside a lambda keys as if it were a
  # sibling of the lambda.
  test "scopes nested inside a lambda carry it in their key" do
    source = <<~RUBY
      class Sample
        def run
          -> do
            items.each do |i|
              i
            end
          end
        end
      end
    RUBY

    assert_equal "Sample#run[lambda][block:each]", path_for(source, 4, 6)
  end

  # `lambda { }` and `proc { }` are ordinary calls with blocks and were already
  # covered; pinning them keeps the new node type from being mistaken for the
  # only way to write one.
  test "lambda and proc written as method calls keep their call-shaped keys" do
    source = <<~RUBY
      class Sample
        A = lambda do
          1
        end
        B = proc do
          2
        end
      end
    RUBY

    assert_equal "Sample[block:lambda]", path_for(source, 2, 4)
    assert_equal "Sample[block:proc]", path_for(source, 5, 7)
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

  def offense(cop, message, line, last_line = nil)
    { "cop_name" => cop, "message" => message, "location" => { "start_line" => line, "last_line" => last_line } }
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

    assert_equal "sample.rb | Metrics/BlockNesting | Sample#wide~1", result.keys.sole
  end

  test "fallback keys retain the enclosing scope" do
    File.write(File.join(@dir, "sample.rb"), <<~RUBY)
      class Sample
        def first
          if ready
          end
        end

        def second
          if ready
          end
        end
      end
    RUBY

    result = fold([
      offense("Metrics/BlockNesting", "Avoid more than 3 levels of block nesting.", 3),
      offense("Metrics/BlockNesting", "Avoid more than 3 levels of block nesting.", 8)
    ])

    assert_equal({
      "sample.rb | Metrics/BlockNesting | Sample#first~if ready" => 1,
      "sample.rb | Metrics/BlockNesting | Sample#second~if ready" => 1
    }, result)
  end

  test "fallback keys distinguish repeated statements within the same scope" do
    File.write(File.join(@dir, "sample.rb"), <<~RUBY)
      class Sample
        def wide
          if ready
          end
          if ready
          end
        end
      end
    RUBY

    result = fold([
      offense("Metrics/BlockNesting", "Avoid more than 3 levels of block nesting.", 3),
      offense("Metrics/BlockNesting", "Avoid more than 3 levels of block nesting.", 5)
    ])

    assert_equal({
      "sample.rb | Metrics/BlockNesting | Sample#wide~if ready" => 1,
      "sample.rb | Metrics/BlockNesting | Sample#wide~if ready[fallback:2]" => 1
    }, result)
  end

  test "fallback ordinals include matching statements below the budget" do
    File.write(File.join(@dir, "sample.rb"), <<~RUBY)
      class Sample
        def wide
          if ready
          end
          if ready
          end
        end
      end
    RUBY

    result = fold([ offense("Metrics/BlockNesting", "Avoid more than 3 levels of block nesting.", 5) ])

    assert_equal({ "sample.rb | Metrics/BlockNesting | Sample#wide~if ready[fallback:2]" => 1 }, result)
  end

  test "fallback ordinals use the same abbreviation as their measurement keys" do
    condition = Array.new(20, "ready").join(" && ")
    statement = "if #{condition}"
    File.write(File.join(@dir, "sample.rb"), <<~RUBY)
      class Sample
        def wide
          #{statement}
          end
          #{statement}
          end
        end
      end
    RUBY

    result = fold([ offense("Metrics/BlockNesting", "Avoid more than 3 levels of block nesting.", 5) ])

    abbreviated = "#{statement[0, 97]}..."
    assert_equal({ "sample.rb | Metrics/BlockNesting | Sample#wide~#{abbreviated}[fallback:2]" => 1 }, result)
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

  # The same hiding place one level down. Sibling blocks at least start on
  # different lines; chained blocks share a start line AND a start column, so
  # the ordinal cannot help — both offenses below are reported at line 3. Only
  # the end line tells them apart, which is why the map is keyed by range.
  test "a chained block does not hide behind the block it is chained onto" do
    File.write(File.join(@dir, "sample.rb"), <<~RUBY)
      class Sample
        def run
          items.each do |i|
            i
          end.map do |o|
            o
          end
        end
      end
    RUBY

    result = fold([
      offense("Metrics/BlockLength", "Block has too many lines. [90/70]", 3, 5),
      offense("Metrics/BlockLength", "Block has too many lines. [80/70]", 3, 7)
    ])

    assert_equal({
      "sample.rb | Metrics/BlockLength | Sample#run[block:each]" => 90,
      "sample.rb | Metrics/BlockLength | Sample#run[block:map]" => 80
    }, result)

    inner_only = result.slice("sample.rb | Metrics/BlockLength | Sample#run[block:each]")
    check = ComplexityRatchet::Check.new(actual: result, baseline: inner_only)

    refute_predicate check, :pass?
    assert_equal :new_offense, check.blocking_problems.sole.kind
  end

  # The third shape of the same hiding place, and the worst of them: the
  # fallback key for an arrow lambda is the text of its opening line, which is
  # `-> do` for every lambda ever written. A whole table of them folded to one
  # key regardless of nesting, file position or what they contain. Verified
  # against real RuboCop output before the fix — two 80-line lambdas in one
  # array produced `{"… | Metrics/BlockLength | ~-> do" => 80}`.
  test "an arrow lambda does not hide behind another arrow lambda" do
    File.write(File.join(@dir, "sample.rb"), <<~RUBY)
      class Sample
        HANDLERS = [
          -> do
            1
          end,
          -> do
            2
          end
        ].freeze
      end
    RUBY

    result = fold([
      offense("Metrics/BlockLength", "Block has too many lines. [90/70]", 3, 5),
      offense("Metrics/BlockLength", "Block has too many lines. [80/70]", 6, 8)
    ])

    assert_equal({
      "sample.rb | Metrics/BlockLength | Sample[lambda]" => 90,
      "sample.rb | Metrics/BlockLength | Sample[lambda](2)" => 80
    }, result)

    first_only = result.slice("sample.rb | Metrics/BlockLength | Sample[lambda]")
    check = ComplexityRatchet::Check.new(actual: result, baseline: first_only)

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

  test "rejects nonfinite baseline limits" do
    File.write(path, <<~YAML)
      a.rb:
        Metrics/MethodLength:
          A#run: .nan
    YAML

    error = assert_raises(ComplexityRatchet::Error) { ComplexityRatchet.load_baseline(path) }

    assert_includes error.message, "finite nonnegative"
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

  SIB  = "a.rb | Metrics/BlockLength | A#run[block:each]"
  SIB2 = "a.rb | Metrics/BlockLength | A#run[block:each](2)"
  SIBLING_POPULATION = "a.rb | A#run[block:each]"
  FALLBACK = "a.rb | Metrics/BlockNesting | A#run~if ready"

  # Deleting the first of two same-named siblings renames the second onto the
  # first's key. Both keys are separately monotonic — 88 -> 83 is a tightening
  # and the (2) entry is a deletion — so per-key comparison waves through an
  # entity that grew from 78 to 83.
  test "rejects a survivor that inherited a removed sibling's allowance" do
    problem = ComplexityRatchet.verify_monotonic(
      { SIB => 88, SIB2 => 78 }, { SIB => 83 }
    ).sole

    assert_equal :baseline_sibling_shift, problem.kind
    assert_equal SIB, problem.key
    assert_includes problem.message, "78"
  end

  test "accepts a survivor that stayed within the family's smallest limit" do
    assert_empty ComplexityRatchet.verify_monotonic({ SIB => 88, SIB2 => 78 }, { SIB => 78 })
  end

  test "keeps numeric parentheses in fallback source identities out of sibling families" do
    plain = "a.rb | Metrics/BlockNesting | A#run~process"
    numeric = "a.rb | Metrics/BlockNesting | A#run~process(2)"

    # `process(2)` is source text, not the `(2)` ordinal that #disambiguate
    # appends to a sibling. Removing the numeric sibling must not hold the
    # independent `process` entry to its lower allowance.
    assert_empty ComplexityRatchet.verify_monotonic(
      { plain => 90, numeric => 80 }, { plain => 85 }
    )
  end

  test "groups descendants of ordinalized scopes into the same sibling family" do
    first = "a.rb | Metrics/MethodLength | A#run"
    second = "a.rb | Metrics/MethodLength | A(2)#run"

    # Reopening A twice gives the second `run` an ordinal on its enclosing
    # scope. Deleting the first reopening transfers its allowance onto the
    # survivor, just as deleting same-named leaf scopes does.
    problem = ComplexityRatchet.verify_monotonic(
      { first => 90, second => 80 }, { first => 85 }
    ).sole

    assert_equal :baseline_sibling_shift, problem.kind
    assert_includes problem.message, "80"
  end

  test "rejects a shifted survivor when only its deleted sibling was baselined" do
    # The second sibling was below budget at 60, so it has no baseline key.
    # Its presence still has to survive long enough to stop it inheriting the
    # deleted 90-line sibling's unsuffixed key after growing to 80.
    before_source = <<~RUBY
      class A
        def run
          high.each { |item| item }
          low.each { |item| item }
        end
      end
    RUBY
    after_source = <<~RUBY
      class A
        def run
          low.each { |item| item }
        end
      end
    RUBY
    problem = ComplexityRatchet.verify_monotonic(
      { SIB => 90 }, { SIB => 80 },
      before_siblings: ComplexityRatchet.sibling_populations("a.rb" => before_source),
      after_siblings: ComplexityRatchet.sibling_populations("a.rb" => after_source)
    ).sole

    assert_equal :baseline_sibling_shift, problem.kind
    assert_equal SIB, problem.key
  end

  test "rejects a newcomer that took over a baselined sibling's key" do
    # The mirror image of a deletion. Inserting a new sibling *ahead* of the
    # baselined one hands the unsuffixed key to the newcomer while the original
    # retreats behind `(2)` and drops below budget. Per-key comparison then sees
    # 90 -> 80 and calls it an improvement, so the population has to be watched
    # for any change, not only for shrinkage.
    before_source = <<~RUBY
      class A
        def run
          high.each { |item| item }
        end
      end
    RUBY
    after_source = <<~RUBY
      class A
        def run
          low.each { |item| item }
          high.each { |item| item }
        end
      end
    RUBY
    problem = ComplexityRatchet.verify_monotonic(
      { SIB => 90 }, { SIB => 80 },
      before_siblings: ComplexityRatchet.sibling_populations("a.rb" => before_source),
      after_siblings: ComplexityRatchet.sibling_populations("a.rb" => after_source)
    ).sole

    assert_equal :baseline_sibling_shift, problem.kind
    assert_equal SIB, problem.key
  end

  test "accepts an unchanged population when only one sibling is baselined" do
    assert_empty ComplexityRatchet.verify_monotonic(
      { SIB => 90 }, { SIB => 80 },
      before_siblings: { SIBLING_POPULATION => 2 },
      after_siblings: { SIBLING_POPULATION => 2 }
    )
  end

  test "rejects an allowance change for ambiguous siblings with an incomplete baseline" do
    before_source = <<~RUBY
      class A
        def run
          items.each { |item| high(item) }
          items.each { |item| low(item) }
        end
      end
    RUBY
    after_source = <<~RUBY
      class A
        def run
          items.each { |item| low(item) }
          items.each { |item| high(item) }
        end
      end
    RUBY

    problem = ComplexityRatchet.verify_monotonic(
      { SIB => 90 }, { SIB => 80 },
      before_siblings: ComplexityRatchet.sibling_populations("a.rb" => before_source),
      after_siblings: ComplexityRatchet.sibling_populations("a.rb" => after_source),
      before_sibling_anchors: ComplexityRatchet.sibling_anchors("a.rb" => before_source),
      after_sibling_anchors: ComplexityRatchet.sibling_anchors("a.rb" => after_source)
    ).sole

    assert_equal :baseline_sibling_shift, problem.kind
    assert_includes problem.message, "not baselined"
  end

  test "rejects a fallback twin that inherits its deleted sibling's baseline key" do
    before_source = <<~RUBY
      class A
        def run
          if ready
          end
          if ready
          end
        end
      end
    RUBY
    after_source = <<~RUBY
      class A
        def run
          if ready
            if nested
            end
          end
        end
      end
    RUBY

    problem = ComplexityRatchet.verify_monotonic(
      { FALLBACK => 1 }, { FALLBACK => 1 },
      before_siblings: ComplexityRatchet.sibling_populations("a.rb" => before_source),
      after_siblings: ComplexityRatchet.sibling_populations("a.rb" => after_source)
    ).sole

    assert_equal :baseline_sibling_shift, problem.kind
    assert_equal FALLBACK, problem.key
  end

  test "rejects reordered families with an unbaselined sibling even below the recorded floor" do
    before_source = <<~RUBY
      class A
        def run
          high.each { |item| item }
          low.each { |item| item }
        end
      end
    RUBY
    after_source = <<~RUBY
      class A
        def run
          low.each { |item| item }
          high.each { |item| item }
        end
      end
    RUBY

    problem = ComplexityRatchet.verify_monotonic(
      { SIB => 90 }, { SIB => 80 },
      before_siblings: ComplexityRatchet.sibling_populations("a.rb" => before_source),
      after_siblings: ComplexityRatchet.sibling_populations("a.rb" => after_source),
      before_sibling_anchors: ComplexityRatchet.sibling_anchors("a.rb" => before_source),
      after_sibling_anchors: ComplexityRatchet.sibling_anchors("a.rb" => after_source)
    ).sole

    assert_equal :baseline_sibling_shift, problem.kind
    assert_includes problem.message, "not baselined"
  end

  test "rejects same-count siblings that exchange allowances by changing order" do
    before_source = <<~RUBY
      class A
        def run
          first.each { |item| item }
          second.each { |item| item }
        end
      end
    RUBY
    after_source = <<~RUBY
      class A
        def run
          second.each { |item| item }
          first.each { |item| item }
        end
      end
    RUBY

    problem = ComplexityRatchet.verify_monotonic(
      { SIB => 90, SIB2 => 80 }, { SIB => 85, SIB2 => 80 },
      before_sibling_anchors: ComplexityRatchet.sibling_anchors("a.rb" => before_source),
      after_sibling_anchors: ComplexityRatchet.sibling_anchors("a.rb" => after_source)
    ).sole

    assert_equal :baseline_sibling_shift, problem.kind
    assert_equal SIB, problem.key
    assert_includes problem.message, "changed order"
  end

  test "rejects a unique block replaced with a different anchor" do
    before_source = <<~RUBY
      class A
        def run
          users.each { |user| user }
        end
      end
    RUBY
    after_source = <<~RUBY
      class A
        def run
          orders.each { |order| order }
        end
      end
    RUBY

    problem = ComplexityRatchet.verify_monotonic(
      { SIB => 90 }, { SIB => 80 },
      before_sibling_anchors: ComplexityRatchet.sibling_anchors("a.rb" => before_source),
      after_sibling_anchors: ComplexityRatchet.sibling_anchors("a.rb" => after_source)
    ).sole

    assert_equal :baseline_sibling_shift, problem.kind
    assert_includes problem.message, "source anchor"
  end

  test "rejects a unique lambda replaced with a different assignment" do
    before_source = <<~RUBY
      class Sample
        HANDLER = -> do
          first
        end
      end
    RUBY
    after_source = <<~RUBY
      class Sample
        DISPATCHER = -> do
          second
        end
      end
    RUBY
    key = "a.rb | Metrics/BlockLength | Sample[lambda]"

    problem = ComplexityRatchet.verify_monotonic(
      { key => 90 }, { key => 80 },
      before_sibling_anchors: ComplexityRatchet.sibling_anchors("a.rb" => before_source),
      after_sibling_anchors: ComplexityRatchet.sibling_anchors("a.rb" => after_source)
    ).sole

    assert_equal :baseline_sibling_shift, problem.kind
    assert_includes problem.message, "source anchor"
  end

  test "rejects a callable block replaced with a different assignment" do
    before_source = <<~RUBY
      class Sample
        HANDLER = proc do
          first
        end
      end
    RUBY
    after_source = <<~RUBY
      class Sample
        DISPATCHER = proc do
          second
        end
      end
    RUBY
    key = "a.rb | Metrics/BlockLength | Sample[block:proc]"

    problem = ComplexityRatchet.verify_monotonic(
      { key => 90 }, { key => 80 },
      before_sibling_anchors: ComplexityRatchet.sibling_anchors("a.rb" => before_source),
      after_sibling_anchors: ComplexityRatchet.sibling_anchors("a.rb" => after_source)
    ).sole

    assert_equal :baseline_sibling_shift, problem.kind
    assert_includes problem.message, "source anchor"
  end

  test "rejects another anonymous block replaced with a different assignment" do
    before_source = <<~RUBY
      class Sample
        HANDLER = Enumerator.new do
          first
        end
      end
    RUBY
    after_source = <<~RUBY
      class Sample
        OTHER = Enumerator.new do
          second
        end
      end
    RUBY
    key = "a.rb | Metrics/BlockLength | Sample[block:new]"

    problem = ComplexityRatchet.verify_monotonic(
      { key => 90 }, { key => 80 },
      before_sibling_anchors: ComplexityRatchet.sibling_anchors("a.rb" => before_source),
      after_sibling_anchors: ComplexityRatchet.sibling_anchors("a.rb" => after_source)
    ).sole

    assert_equal :baseline_sibling_shift, problem.kind
    assert_includes problem.message, "source anchor"
  end

  test "rejects a callable block replaced after an earlier call argument" do
    before_source = <<~RUBY
      class Sample
        register(:handler, Enumerator.new do
          first
        end)
      end
    RUBY
    after_source = <<~RUBY
      class Sample
        subscribe(:handler, Enumerator.new do
          second
        end)
      end
    RUBY
    key = "a.rb | Metrics/BlockLength | Sample[block:new]"

    problem = ComplexityRatchet.verify_monotonic(
      { key => 90 }, { key => 80 },
      before_sibling_anchors: ComplexityRatchet.sibling_anchors("a.rb" => before_source),
      after_sibling_anchors: ComplexityRatchet.sibling_anchors("a.rb" => after_source)
    ).sole

    assert_equal :baseline_sibling_shift, problem.kind
    assert_includes problem.message, "source anchor"
  end

  test "rejects a multiline lambda replaced with a different enclosing call" do
    before_source = <<~RUBY
      class Sample
        register(
          -> do
            first
          end
        )
      end
    RUBY
    after_source = <<~RUBY
      class Sample
        subscribe(
          -> do
            second
          end
        )
      end
    RUBY
    key = "a.rb | Metrics/BlockLength | Sample[lambda]"

    problem = ComplexityRatchet.verify_monotonic(
      { key => 90 }, { key => 80 },
      before_sibling_anchors: ComplexityRatchet.sibling_anchors("a.rb" => before_source),
      after_sibling_anchors: ComplexityRatchet.sibling_anchors("a.rb" => after_source)
    ).sole

    assert_equal :baseline_sibling_shift, problem.kind
    assert_includes problem.message, "source anchor"
  end

  test "accepts same-count siblings when their anchors keep the same order" do
    anchors = { SIBLING_POPULATION => [ "first.each", "second.each" ] }

    assert_empty ComplexityRatchet.verify_monotonic(
      { SIB => 90, SIB2 => 80 }, { SIB => 85, SIB2 => 80 },
      before_sibling_anchors: anchors,
      after_sibling_anchors: anchors
    )
  end

  test "rejects changed allowances for same-count siblings with identical anchors" do
    anchors = { SIBLING_POPULATION => [ "items.each", "items.each" ] }

    problem = ComplexityRatchet.verify_monotonic(
      { SIB => 90, SIB2 => 80 }, { SIB => 85, SIB2 => 80 },
      before_sibling_anchors: anchors,
      after_sibling_anchors: anchors
    ).sole

    assert_equal :baseline_sibling_shift, problem.kind
    assert_equal SIB, problem.key
    assert_includes problem.message, "indistinguishable anchors"
  end

  test "rejects changed allowances for same-count lambda siblings" do
    before_source = <<~RUBY
      class Sample
        HANDLERS = [
          -> do
            first
          end,
          -> do
            second
          end
        ]
      end
    RUBY
    after_source = <<~RUBY
      class Sample
        HANDLERS = [
          -> do
            second
          end,
          -> do
            first
          end
        ]
      end
    RUBY
    first = "a.rb | Metrics/BlockLength | Sample[lambda]"
    second = "a.rb | Metrics/BlockLength | Sample[lambda](2)"

    problem = ComplexityRatchet.verify_monotonic(
      { first => 90, second => 80 }, { first => 85, second => 75 },
      before_sibling_anchors: ComplexityRatchet.sibling_anchors("a.rb" => before_source),
      after_sibling_anchors: ComplexityRatchet.sibling_anchors("a.rb" => after_source)
    ).sole

    assert_equal :baseline_sibling_shift, problem.kind
    assert_includes problem.message, "indistinguishable anchors"
  end

  # Nothing was removed, so neither sibling can have inherited anything.
  test "accepts an intact sibling family where each entry tightened" do
    assert_empty ComplexityRatchet.verify_monotonic(
      { SIB => 88, SIB2 => 78 }, { SIB => 80, SIB2 => 70 }
    )
  end

  # A shrinking family is normal; only a survivor above the family floor is not.
  test "accepts a sibling family that shrank with no survivor over the floor" do
    assert_empty ComplexityRatchet.verify_monotonic({ SIB => 88, SIB2 => 78 }, {})
  end

  # Ordinals are per parent scope, so an unrelated entity that merely shares a
  # cop and a file is not a sibling.
  test "does not treat unrelated entries as siblings" do
    other = "a.rb | Metrics/BlockLength | A#other[block:each]"

    assert_empty ComplexityRatchet.verify_monotonic({ SIB => 88, other => 78 }, { SIB => 88 })
  end

  test "a base ref that predates the baseline file has nothing to verify" do
    # The bootstrap commit adds hundreds of entries at once; there is no prior
    # baseline for them to be a regression against.
    assert_empty ComplexityRatchet.verify_monotonic(nil, { KEY => 30 })
  end
end

# verify_monotonic reads the baseline; these read the budget the baseline is
# measured against. Both are needed, because raising a Max makes the offenses
# vanish, `--regenerate` deletes their entries, and a deletion is indistinguish-
# able from a refactor to a check that only looks at the baseline.
class ComplexityRatchetBudgetTest < ActiveSupport::TestCase
  BEFORE = {
    "inherit_gem" => { "rubocop-rails-omakase" => "rubocop.yml" },
    "AllCops" => { "Exclude" => [ "db/**/*", "tmp/**/*" ] },
    "Metrics/MethodLength" => { "Enabled" => true, "Max" => 25 },
    "Metrics/AbcSize" => { "Enabled" => true, "Max" => 35 }
  }.freeze

  def with(overrides)
    BEFORE.merge(overrides)
  end

  test "accepts an unchanged budget" do
    assert_empty ComplexityRatchet.verify_budget(BEFORE, BEFORE.dup)
  end

  test "accepts a tightened limit and a newly added cop" do
    after = with(
      "Metrics/MethodLength" => { "Enabled" => true, "Max" => 20 },
      "Metrics/BlockNesting" => { "Enabled" => true, "Max" => 3 }
    )

    assert_empty ComplexityRatchet.verify_budget(BEFORE, after)
  end

  # The measured bypass: MethodLength 25 -> 200 drops 160 of this repo's 438
  # baseline entries, reports zero new debt, and passes every other check.
  test "rejects a raised limit" do
    after = with("Metrics/MethodLength" => { "Enabled" => true, "Max" => 200 })
    problem = ComplexityRatchet.verify_budget(BEFORE, after).sole

    assert_equal :budget_loosened, problem.kind
    assert_equal "Metrics/MethodLength", problem.key
    assert problem.blocking?
  end

  test "rejects a nonfinite limit" do
    after = with("Metrics/AbcSize" => { "Enabled" => true, "Max" => Float::NAN })
    problem = ComplexityRatchet.verify_budget(BEFORE, after).sole

    assert_equal :budget_invalid_max, problem.kind
    assert_includes problem.message, "finite"
  end

  test "rejects a cop switched off or deleted outright" do
    off = with("Metrics/AbcSize" => { "Enabled" => false, "Max" => 35 })
    assert_equal :budget_disabled, ComplexityRatchet.verify_budget(BEFORE, off).sole.kind

    deleted = BEFORE.except("Metrics/AbcSize")
    assert_equal :budget_disabled, ComplexityRatchet.verify_budget(BEFORE, deleted).sole.kind
  end

  # Dropping Max leaves the cop enabled at whatever RuboCop's default happens to
  # be, which moves on a gem upgrade. A budget that is not written down cannot
  # be compared on the next PR.
  test "rejects a limit that stops being explicit" do
    after = with("Metrics/AbcSize" => { "Enabled" => true })

    assert_equal :budget_implicit, ComplexityRatchet.verify_budget(BEFORE, after).sole.kind
  end

  test "rejects a widened Exclude but accepts a narrowed one" do
    widened = with("AllCops" => { "Exclude" => [ "db/**/*", "tmp/**/*", "engines/collavre/app/services/**/*" ] })
    problem = ComplexityRatchet.verify_budget(BEFORE, widened).sole

    assert_equal :budget_scope_narrowed, problem.kind
    assert_equal "engines/collavre/app/services/**/*", problem.key

    narrowed = with("AllCops" => { "Exclude" => [ "db/**/*" ] })
    assert_empty ComplexityRatchet.verify_budget(BEFORE, narrowed)
  end

  test "rejects a moved inherit, which can widen Exclude from outside the file" do
    after = with("inherit_gem" => { "rubocop-rails-omakase" => "loose.yml" })

    assert_equal :budget_inherit_changed, ComplexityRatchet.verify_budget(BEFORE, after).sole.kind
  end

  # Max is the loudest way to loosen a cop, not the only one. A per-cop
  # `Exclude: ['**/*']` turns MethodLength off repository-wide while the line
  # above it still reads `Max: 25`; --regenerate then deletes every entry that
  # cop held and both gates go green. Same for the keys that exempt code by name
  # rather than by path.
  test "rejects a per-cop Exclude that silences the cop while Max stays put" do
    after = with("Metrics/MethodLength" => { "Enabled" => true, "Max" => 25, "Exclude" => [ "**/*" ] })
    problem = ComplexityRatchet.verify_budget(BEFORE, after).sole

    assert_equal :budget_setting_changed, problem.kind
    assert_equal "Metrics/MethodLength", problem.key
    assert_includes problem.message, "Exclude"
  end

  test "rejects the other per-cop keys that silence offenses without moving Max" do
    {
      "Include" => [ "nothing/**/*" ],
      "AllowedMethods" => [ "call" ],
      "AllowedPatterns" => [ "." ],
      "CountAsOne" => %w[array hash heredoc],
      "CountComments" => false
    }.each do |key, value|
      after = with("Metrics/MethodLength" => { "Enabled" => true, "Max" => 25, key => value })
      problem = ComplexityRatchet.verify_budget(BEFORE, after).sole

      assert_equal :budget_setting_changed, problem.kind, "#{key} was accepted"
      assert_includes problem.message, key
    end
  end

  # Enumerating loosening keys is a losing game — this is an allowlist, so a
  # tightening trips it too. That is deliberate: it is not blocked, it goes
  # through the reset label, and a reviewer sees the budget move.
  test "reports a per-cop setting even when it tightens" do
    after = with("Metrics/AbcSize" => { "Enabled" => true, "Max" => 35, "CountRepeatedAttributes" => true })

    assert_equal :budget_setting_changed, ComplexityRatchet.verify_budget(BEFORE, after).sole.kind
  end

  # AllCops/Exclude may shrink, so it is compared separately. Everything else
  # under AllCops narrows what RuboCop reads at all.
  test "rejects an AllCops change other than Exclude" do
    after = with("AllCops" => BEFORE["AllCops"].merge("Include" => [ "app/**/*.rb" ]))
    problem = ComplexityRatchet.verify_budget(BEFORE, after).sole

    assert_equal :budget_scope_narrowed, problem.kind
    assert_equal "AllCops", problem.key
    assert_includes problem.message, "Include"
  end

  test "rejects a new top-level key that can change how the config resolves" do
    after = with("inherit_mode" => { "merge" => [ "Exclude" ] })

    assert_equal :budget_inherit_changed, ComplexityRatchet.verify_budget(BEFORE, after).sole.kind
  end

  test "a base ref that predates the config file has nothing to verify" do
    assert_empty ComplexityRatchet.verify_budget(nil, BEFORE.dup)
  end
end

# .rubocop_metrics.yml carries `Enabled` and `Max` and inherits the rest, so the
# budget only half lives in this repository. Verified on the real tree by
# widening one inherited default the way an upgrade would, with nothing in the
# repository changed: 438 entities measured down to 277, `--regenerate` deleted
# all 161 MethodLength entries, and both gates exited 0.
class ComplexityRatchetToolchainTest < ActiveSupport::TestCase
  LOCK = <<~LOCK
    GEM
      remote: https://rubygems.org/
      specs:
        rails (8.1.0)
        rubocop (1.86.0)
          rubocop-ast (>= 1.49.0, < 2.0)
        rubocop-ast (1.49.1)
        parser (3.3.10.2)
        prism (1.9.0)
        rubocop-rails-omakase (1.1.0)
          rubocop (>= 1.72)

    DEPENDENCIES
      rubocop-rails-omakase
  LOCK

  def with(replacements)
    replacements.reduce(LOCK) { |lock, (from, to)| lock.sub(from, to) }
  end

  test "rejects a RuboCop upgrade, which moves the inherited half of the budget" do
    problem = ComplexityRatchet.verify_toolchain(LOCK, with("rubocop (1.86.0)" => "rubocop (1.87.0)")).sole

    assert_equal :toolchain_changed, problem.kind
    assert_equal "rubocop", problem.key
    assert_includes problem.message, "1.86.0 -> 1.87.0"
  end

  # The config named in `inherit_gem` ships in this gem, so its version moves
  # AllCops/Exclude and the cop defaults just as directly as RuboCop's own.
  test "rejects an upgrade of any gem in the rubocop family" do
    %w[rubocop-ast rubocop-rails-omakase].each do |gem_name|
      after = with("#{gem_name} (1." => "#{gem_name} (9.")
      problem = ComplexityRatchet.verify_toolchain(LOCK, after).sole

      assert_equal gem_name, problem.key, "#{gem_name} was accepted"
    end
  end

  test "rejects parser changes that alter offenses or entity identities" do
    { "parser" => "3.3.10.2", "prism" => "1.9.0" }.each do |gem_name, version|
      problem = ComplexityRatchet.verify_toolchain(LOCK, with("#{gem_name} (#{version})" => "#{gem_name} (9.0.0)")).sole

      assert_equal gem_name, problem.key, "#{gem_name} was accepted"
    end
  end

  test "rejects a downgrade and a removal as readily as an upgrade" do
    downgraded = ComplexityRatchet.verify_toolchain(with("rubocop (1.86.0)" => "rubocop (1.70.0)"), LOCK).sole
    assert_equal "1.70.0 -> 1.86.0", downgraded.message[/[\d.]+ -> [\d.]+/]

    removed = ComplexityRatchet.verify_toolchain(LOCK, LOCK.sub(/^    rubocop-ast \(1\.49\.1\)\n/, "")).sole
    assert_equal "rubocop-ast", removed.key
    assert_includes removed.message, "(absent)"
  end

  # A dependency line repeats the gem with a constraint rather than a version.
  # Reading those would compare "rubocop (>= 1.72)" against itself forever and
  # miss the resolved version entirely.
  test "reads resolved versions and not the dependency constraints under them" do
    assert_empty ComplexityRatchet.verify_toolchain(LOCK, LOCK.sub("rubocop (>= 1.72)", "rubocop (>= 1.86)"))
  end

  test "ignores gems outside the rubocop family and an unchanged lock" do
    assert_empty ComplexityRatchet.verify_toolchain(LOCK, with("rails (8.1.0)" => "rails (8.2.0)"))
    assert_empty ComplexityRatchet.verify_toolchain(LOCK, LOCK.dup)
  end

  test "a base ref that predates the lockfile has nothing to verify" do
    assert_empty ComplexityRatchet.verify_toolchain(nil, LOCK)
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

  TODAY = Date.new(2026, 8, 11)

  def waiver(key: KEY, owner: "@sh1nj1", reason: "because", expires: TODAY + 30)
    ComplexityRatchet::Waiver.new(key: key, owner: owner, reason: reason, expires: expires)
  end

  # --check honours a live waiver, so --regenerate has to as well. It did not:
  # the command wrote the tightened baseline and then exited 1, telling you to
  # waive an entity that was already waived. That made the documented refactor
  # workflow unrunnable for as long as any waiver existed.
  test "a live waiver is not new debt, so an unrelated refactor can regenerate" do
    baseline = { OTHER => 40 }
    actual = { OTHER => 32, KEY => 30 }

    updated, unrecorded = ComplexityRatchet.regenerate(
      baseline, actual, waivers: [ waiver ], today: TODAY
    )

    assert_equal({ OTHER => 32 }, updated)
    assert_empty unrecorded

    # And the two commands agree about it.
    assert_predicate ComplexityRatchet::Check.new(
      actual: actual, baseline: updated, waivers: [ waiver ], today: TODAY
    ), :pass?
  end

  # Honouring a dead waiver would be the mirror-image bug: --regenerate exits 0
  # on debt that Check blocks, so CI fails with the workflow reporting success.
  test "an expired waiver does not suppress the debt it used to cover" do
    _updated, unrecorded = ComplexityRatchet.regenerate(
      {}, { KEY => 30 }, waivers: [ waiver(expires: TODAY - 1) ], today: TODAY
    )

    assert_equal [ KEY ], unrecorded
  end

  test "a blank-owner waiver does not suppress the debt it names" do
    _updated, unrecorded = ComplexityRatchet.regenerate(
      {}, { KEY => 30 }, waivers: [ waiver(owner: "  ") ], today: TODAY
    )

    assert_equal [ KEY ], unrecorded
  end

  test "a waiver past the expiry cap does not suppress the debt it names" do
    _updated, unrecorded = ComplexityRatchet.regenerate(
      {}, { KEY => 30 }, waivers: [ waiver(expires: TODAY + 365) ], today: TODAY
    )

    assert_equal [ KEY ], unrecorded
  end

  test "a waiver for some other entity leaves new debt visible" do
    _updated, unrecorded = ComplexityRatchet.regenerate(
      {}, { KEY => 30 }, waivers: [ waiver(key: OTHER) ], today: TODAY
    )

    assert_equal [ KEY ], unrecorded
  end

  # The other half of honouring a waiver here. Check skips waived keys, so
  # growth in an already-baselined entity raises no problem — and --regenerate
  # used to copy that growth into the baseline on the next unrelated refactor.
  # The temporary waiver became a permanent higher limit, and --verify-baseline
  # blocked the branch that did it.
  test "growth under a live waiver is not written into the baseline" do
    baseline = { KEY => 31, OTHER => 40 }
    actual = { KEY => 41, OTHER => 32 }

    updated, unrecorded = ComplexityRatchet.regenerate(
      baseline, actual, waivers: [ waiver ], today: TODAY
    )

    assert_equal({ KEY => 31, OTHER => 32 }, updated)
    assert_empty unrecorded
    assert_empty ComplexityRatchet.verify_monotonic(baseline, updated)
  end

  # What the waiver's expiry is for: the recorded limit is still 31, so once
  # the waiver lapses the entity owes the same 10 lines it always did.
  test "the recorded limit is what the entity owes once the waiver lapses" do
    updated, = ComplexityRatchet.regenerate(
      { KEY => 31 }, { KEY => 41 }, waivers: [ waiver ], today: TODAY
    )
    problem = ComplexityRatchet::Check.new(
      actual: { KEY => 41 }, baseline: updated, waivers: [], today: TODAY
    ).problems.sole

    assert_equal :regression, problem.kind
    assert_equal "grew from 31 to 41", problem.message
  end

  # Growth with no waiver at all is Check's business, not this command's. It
  # must not be laundered either — regenerate can lower a value or drop a key,
  # and that is all it can do.
  test "growth with no waiver is not written into the baseline either" do
    updated, = ComplexityRatchet.regenerate({ KEY => 31 }, { KEY => 41 })

    assert_equal({ KEY => 31 }, updated)
    assert_empty ComplexityRatchet.verify_monotonic({ KEY => 31 }, updated)
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
