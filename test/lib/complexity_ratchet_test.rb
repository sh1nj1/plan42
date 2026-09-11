# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# Not autoloaded: config/application.rb keeps this CI-only tool out of the app's
# object graph, so the test has to require it by path.
require Rails.root.join("lib/complexity_ratchet").to_s
require Rails.root.join("lib/complexity_ratchet/base_tree").to_s

# The ratchet is a CI gate, so a silent failure here does not break a feature —
# it quietly stops blocking anything, which is worse. These tests pin the two
# properties the gate depends on: an entity key means the same thing in both
# measurements, and the budget can only ever tighten.
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

  test "ignores inline RuboCop suppression directives when measuring metrics" do
    captured_command = nil
    payload = { "files" => [] }.to_json

    Open3.stub(:capture3, ->(*command, chdir:) {
      captured_command = command
      [ payload, "", nil ]
    }) do
      ComplexityRatchet::Measurement.new(root: @dir).call
    end

    assert_includes captured_command, "--ignore-disable-comments"
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
    check = ComplexityRatchet::Check.new(actual: result, base: baselined_sibling_only)

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
    check = ComplexityRatchet::Check.new(actual: result, base: inner_only)

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
    check = ComplexityRatchet::Check.new(actual: result, base: first_only)

    refute_predicate check, :pass?
    assert_equal :new_offense, check.blocking_problems.sole.kind
  end
end

class ComplexityRatchetCheckTest < ActiveSupport::TestCase
  TODAY = Date.new(2026, 8, 11)
  KEY = "a.rb | Metrics/MethodLength | A#b"

  def check(actual:, base: {}, waivers: [])
    ComplexityRatchet::Check.new(actual: actual, base: base, waivers: waivers, today: TODAY)
  end

  def waiver(expires:, key: KEY, owner: "@sh1nj1", reason: "because")
    ComplexityRatchet::Waiver.new(key: key, owner: owner, reason: reason, expires: expires)
  end

  test "passes when every entity matches the merge base" do
    result = check(actual: { KEY => 30 }, base: { KEY => 30 })

    assert_predicate result, :pass?
    assert_empty result.problems
  end

  test "blocks an entity that grew" do
    problem = check(actual: { KEY => 31 }, base: { KEY => 30 }).problems.sole

    assert_equal :regression, problem.kind
    assert_predicate problem, :blocking?
  end

  test "blocks a new over-budget entity that is within budget at the merge base" do
    # This is the case a .rubocop_todo.yml would wave through: auto-gen raises
    # MethodLength's Max to the file's worst value, so brand-new bloat inherits
    # the amnesty. Here it has to be fixed or waived.
    problem = check(actual: { KEY => 31 }).problems.sole

    assert_equal :new_offense, problem.kind
    assert_predicate problem, :blocking?
  end

  # The committed-baseline design blocked here, demanding the snapshot be
  # re-recorded in the same PR. With nothing recorded there is nothing to keep
  # in sync, so shrinking an entity is silently allowed — which is the whole
  # reason PR #1538 could not go green against a moving main.
  test "an entity that improved reports nothing" do
    assert_empty check(actual: { KEY => 28 }, base: { KEY => 30 }).problems
  end

  test "an entity that dropped under budget entirely reports nothing" do
    assert_empty check(actual: {}, base: { KEY => 30 }).problems
  end

  # Growth on an entity that is already over budget on both sides is the case
  # the gate exists for; growth that stays under the budget is not measured at
  # all, on either side, so it never reaches Check.
  test "an entity over budget on both sides may shrink but not grow" do
    assert_empty check(actual: { KEY => 30 }, base: { KEY => 31 }).problems
    assert_equal :regression, check(actual: { KEY => 32 }, base: { KEY => 31 }).problems.sole.kind
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

# Both sides of the comparison are measured with THIS branch's budget, so
# raising a Max silences the same entities twice and cancels out. That is what
# makes the budget the one input the comparison cannot police for itself.
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

  # The measured bypass: MethodLength 25 -> 200 silences 160 of this repo's 430
  # over-budget entities on both sides at once, and reports nothing.
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
  # above it still reads `Max: 25` — and it silences both sides of the
  # comparison equally, so nothing else notices. Same for the keys that exempt
  # code by name rather than by path.
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

# The merge base is what the whole gate compares against, so getting this wrong
# fails open — a base tree that silently came out as HEAD would report every
# entity as unchanged and block nothing.
class ComplexityRatchetBaseTreeTest < ActiveSupport::TestCase
  setup do
    @dir = Dir.mktmpdir
    git "init", "--quiet", "--initial-branch=main"
    git "config", "user.email", "ratchet@example.com"
    git "config", "user.name", "Ratchet"
    write(ComplexityRatchet::CONFIG_PATH, "Metrics/MethodLength:\n  Max: 25\n")
    write("app.rb", "BASE\n")
    commit "base"
    @base = rev_parse("HEAD")
  end

  teardown { FileUtils.remove_entry(@dir) }

  test "yields a checkout of the merge base, not of HEAD" do
    git "checkout", "--quiet", "-b", "feature"
    write("app.rb", "HEAD\n")
    commit "feature work"

    yielded = nil
    sha = ComplexityRatchet::BaseTree.at_merge_base(root: @dir, ref: "main") do |tree, base_sha|
      yielded = File.read(File.join(tree, "app.rb"))
      base_sha
    end

    assert_equal "BASE\n", yielded
    assert_equal @base, sha
  end

  # Both sides have to be measured with the same budget, or a PR that tightens a
  # Max reports every entity the tightening newly caught as brand-new debt.
  test "the base tree carries this branch's budget, not its own" do
    git "checkout", "--quiet", "-b", "feature"
    write(ComplexityRatchet::CONFIG_PATH, "Metrics/MethodLength:\n  Max: 10\n")
    commit "tighten the budget"

    budget = ComplexityRatchet::BaseTree.at_merge_base(root: @dir, ref: "main") do |tree, _sha|
      File.read(File.join(tree, ComplexityRatchet::CONFIG_PATH))
    end

    assert_equal "Metrics/MethodLength:\n  Max: 10\n", budget
  end

  test "returns nil without yielding when HEAD is already the merge base" do
    refute ComplexityRatchet::BaseTree.at_merge_base(root: @dir, ref: "main") { flunk "should not yield" }
  end

  test "removes the scratch worktree even when the block raises" do
    git "checkout", "--quiet", "-b", "feature"
    write("app.rb", "HEAD\n")
    commit "feature work"

    assert_raises(RuntimeError) do
      ComplexityRatchet::BaseTree.at_merge_base(root: @dir, ref: "main") { raise "boom" }
    end

    assert_equal "", git("worktree", "list", "--porcelain").scan(/^worktree (.+)$/).flatten
      .reject { |path| File.identical?(path, @dir) }.join
  end

  test "an unknown ref has no merge base" do
    assert_nil ComplexityRatchet::BaseTree.merge_base(@dir, "no/such/ref")
  end

  private

  def git(*args)
    out, err, status = Open3.capture3("git", *args, chdir: @dir)
    raise "git #{args.join(' ')}: #{err}" unless status.success?

    out
  end

  def write(path, contents)
    File.write(File.join(@dir, path), contents)
  end

  def commit(message)
    git "add", "--all"
    git "commit", "--quiet", "--no-verify", "-m", message
  end

  def rev_parse(ref) = git("rev-parse", ref).strip
end
