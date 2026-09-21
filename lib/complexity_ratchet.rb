# frozen_string_literal: true

require "date"
require "prism"
require "yaml"

# Entity-level complexity ratchet, measured against the merge base.
#
# The problem it solves: the core engine's app code has been compounding at
# roughly +65% per quarter with an added:deleted line ratio around 13:1, and not
# one CI gate constrains it. RuboCop runs omakase, which disables every Metrics
# cop; Codecov is informational.
#
# The obvious fix — `rubocop --auto-gen-config` — is a trap. Auto-gen raises each
# cop's Max to the worst value it observes, which in this repo means
# MethodLength 240, ClassLength 1731, AbcSize 267. That does not enable the cop,
# it disables it with extra steps: a brand-new 200-line method would pass. The
# other auto-gen mode, per-file Exclude, is worse — an excluded file becomes
# permanently invisible to that cop and can grow without limit, which is exactly
# the amnesty a god object wants.
#
# So the comparison here is per ENTITY (a specific class, module, method, or
# block) rather than per cop or per file:
#
#   * an entity already over budget at the merge base may not grow
#   * an entity NOT over budget at the merge base must fit the budget in
#     .rubocop_metrics.yml — new code gets no amnesty from old debt
#   * the budget itself may only tighten (see #verify_budget)
#   * the single escape hatch is a waiver with an owner, a reason, and an expiry
#     date; an expired waiver fails CI
#
# WHY THE MERGE BASE, AND NOT A COMMITTED BASELINE FILE
#
# The first cut of this gate committed a `.complexity_baseline.yml` snapshot and
# compared the working tree against it. That design fails on contact with a
# moving `main`, and it failed on its own PR: eleven entities the branch never
# touched were reported, four of them because `main` had legitimately improved
# them. `Collavre::User` shrinking from 323 to 295 lines on main turned every
# open PR red.
#
# Worse, the only way out was `--regenerate`, which rewrote the snapshot from the
# working tree — and in a drifted state that silently absorbs main's regressions
# into the baseline. The documented rule "never regenerate to make CI green" was
# therefore a rule the tool made unavoidable.
#
# Measuring the merge base directly removes the class of bug rather than guarding
# it. Both sides are measured in the same run, with the same RuboCop and the same
# budget, so:
#
#   * main's drift is invisible — the merge base moves with main
#   * an improvement is just an improvement; there is nothing to re-record
#   * a RuboCop upgrade shifts both sides identically, so it cannot silently
#     delete debt (the old design needed a whole Gemfile.lock check for this)
#   * there is no snapshot to loosen, so `--verify-baseline`, `--regenerate` and
#     their tamper-detection machinery have nothing left to defend
#
# The cost is that the ratchet is relative, not absolute: a branch cut before an
# improvement lands could regrow that entity back to its older value without
# tripping. Requiring branches to be current with main before merge closes it,
# and the squash-merge workflow already rebases. That is a smaller hole than a
# gate the team turns off in week two because it reddens unrelated PRs.
#
# Entities are keyed by their fully-qualified name, not by line number, so
# inserting code above a method does not move it between the two measurements.
module ComplexityRatchet
  Error = Class.new(StandardError)

  CONFIG_PATH   = ".rubocop_metrics.yml"
  WAIVERS_PATH  = ".complexity_waivers.yml"
  # The measured value inside a RuboCop Metrics message:
  #   "Method has too many lines. [38/25]"                    -> 38
  #   "Assignment Branch Condition size ... [<7, 42, 8> 43.55/35]" -> 43.55
  # Metrics/BlockNesting carries no number; those offenses are counted instead.
  VALUE_PATTERN = /\[(?:<[^>]*>\s*)?([\d.]+)\/[\d.]+\]/
  SEPARATOR = " | "

  WAIVERS_TEMPLATE = <<~YAML
    # Time-boxed exceptions to the complexity budget.
    #
    # A waiver is the ONLY way to land a new entity that exceeds
    # .rubocop_metrics.yml. It is deliberately more expensive than fixing the
    # code: it needs a named owner, a reason a reviewer can argue with, and an
    # expiry date. Once `expires` passes, CI fails until the entity is fixed or
    # the waiver is consciously renewed — so a waiver decays into work instead
    # of into permanent amnesty.
    #
    # Cap the expiry at 90 days out. Copy the key verbatim from the
    # bin/complexity_check output.
    #
    # - key: "engines/collavre/app/services/collavre/example.rb | Metrics/MethodLength | Collavre::Example#call"
    #   owner: "@github-handle"
    #   reason: "Vendor protocol handshake is a single linear sequence; splitting it hides the order."
    #   expires: "2026-11-09"

    waivers: []
  YAML

  MAX_WAIVER_DAYS = 90

  # Resolves a source line to the fully-qualified name of the entity that starts
  # on it. Baseline keys have to survive ordinary editing: a line number shifts
  # every time something is inserted above it, and a bare method name is not
  # unique within a file, so neither works as an identity on its own.
  class EntityMap < Prism::Visitor
    # Deliberately not rescued. A visitor that blows up on some node shape would
    # otherwise degrade every entity in that file to its `~source line` fallback
    # — a baseline that looks complete but silently loses its identity keys. A
    # loud crash is the cheaper failure. (Prism reports syntax errors in the
    # result rather than raising, so a malformed file still parses to a tree.)
    def self.for(source)
      map = new(source)
      Prism.parse(source).value.accept(map)
      map
    end

    def initialize(source)
      @source = source
      @paths = {}
      @ranges = {}
      @enclosures = []
      @stack = []
      @fallback_statements = Hash.new { |hash, key| hash[key] = [] }
      @occurrences = Hash.new(0)
      @call_stack = []
      @collection_stack = []
      super()
    end

    # `last_line` is optional so a caller with only a line still gets an answer,
    # but passing it is what separates two scopes that open on the same line.
    def [](line, last_line = nil)
      @ranges[[ line, last_line ]] || @paths[line]
    end

    # Metrics/BlockNesting points at a statement inside its owning method or
    # block rather than at a Prism scope. Keep that owner so source-line
    # fallbacks in different methods cannot share one baseline key.
    def enclosing_path(line, last_line = line)
      last_line ||= line
      @enclosures
        .select { |start_line, end_line, _path| start_line <= line && end_line >= last_line }
        .min_by { |start_line, end_line, _path| end_line - start_line }
        &.last
    end

    # Ordinalise every same-text statement in a scope, including below-budget
    # siblings; duplicate offenses at one source range still share an ordinal.
    def fallback_ordinal(line, last_line, text)
      statements = @fallback_statements[[ enclosing_path(line, last_line).to_s, text ]]
      index = statements.find_index { |start_line, end_line| start_line == line && (last_line.nil? || end_line == last_line) }
      (index || statements.find_index { |start_line, _end_line| start_line == line })&.+(1)
    end

    def visit_class_node(node)
      nest(node.constant_path.slice, node.location) { super }
    end

    def visit_module_node(node)
      nest(node.constant_path.slice, node.location) { super }
    end

    def visit_singleton_class_node(node)
      nest("<<#{node.expression.slice}", node.location) { super }
    end

    def visit_def_node(node)
      nest("#{receiver_prefix(node.receiver)}#{node.name}", node.location) { super }
    end

    # `def self.run` is the enclosing class's own method and keeps the plain
    # `.run` key. Any other receiver names a different object, so it has to
    # reach the key: collapsed onto one `.run`, replacing a baselined 90-line
    # `Foo.run` with an 80-line `Bar.run` reads as a tightening when it is a
    # different method carrying new debt.
    def receiver_prefix(receiver) = receiver ? receiver.is_a?(Prism::SelfNode) ? "." : "#{receiver.slice}." : "#"

    # Record direct statements while their enclosing scope is on the stack.
    def visit_statements_node(node)
      node.body.each do |statement|
        text = statement.location.slice.lines.first.strip.gsub(/\s+/, " ")
        @fallback_statements[[ path, abbreviate(text) ]] << [ statement.location.start_line, statement.location.end_line ]
      end
      super
    end

    # A `do ... end` can hang off three node types, not one: an ordinary call,
    # `super do`, and `super() do`. Only the first was handled, so a super block
    # fell through to the `~source line` fallback and every `super do` in a file
    # shared the key `~super do`.
    #
    # These three are the complete set — they are the only Prism nodes that
    # carry a `block` field capable of holding a literal BlockNode (the
    # Index*Node and ParametersNode forms take a block *argument* or *parameter*,
    # which is not a scope). Enumerating a closed grammar is fine; the trouble on
    # this gate has always come from enumerating open-ended things instead.
    def visit_call_node(node)
      @call_stack << node
      nest_block(node, "[block:#{node.name}]") { super }
    ensure
      @call_stack.pop
    end

    # `super do` and `super() do` — SuperNode and ForwardingSuperNode. Both key
    # as `[block:super]`; they are the same call, and which one Prism produces
    # depends only on whether the author wrote the parentheses.
    def visit_super_node(node)
      nest_block(node, "[block:super]") { super }
    end

    def visit_forwarding_super_node(node)
      nest_block(node, "[block:super]") { super }
    end

    # `-> do ... end` is a LambdaNode, not a CallNode with a block, so it is not
    # reached by #visit_call_node — but RuboCop still reports Metrics/BlockLength
    # against it. Without this every arrow lambda fell through to the `~source
    # line` fallback, and that line is literally `-> do` for all of them: a table
    # of lambdas collapsed to one key and Measurement#record kept only the
    # largest, so a new over-budget lambda hid behind a baselined sibling.
    #
    # Measured before the fix, on two 80-line lambdas in one array:
    #   {"… | Metrics/BlockLength | ~-> do" => 80}   # one key, two entities
    #
    # `[lambda]` rather than a name because a lambda literal has none; siblings
    # separate through the usual ordinal.
    def visit_lambda_node(node)
      nest("[lambda]", node.location, anchor: lambda_anchor(node)) { super }
    end

    def visit_array_node(node)
      with_collection(node) { super }
    end

    def visit_hash_node(node)
      with_collection(node) { super }
    end

    private

    def abbreviate(text) = text.length > 100 ? "#{text[0, 97]}..." : text

    # RuboCop reports Metrics/BlockLength against the whole `send + block`
    # range, so the offense line is the call's line rather than the `do`. The
    # `do` line is recorded too, as a fallback for anything that points there.
    #
    # `node.block` is a BlockArgumentNode for `foo(&blk)`, which has no body and
    # is not a scope — only a literal BlockNode introduces one. Without a block
    # the node is not a scope at all, so it is visited normally.
    #
    # Everything except the block is visited outside the new scope: a receiver
    # or an argument is evaluated at the call site, so a lambda passed as an
    # argument belongs beside the call rather than inside its block.
    def nest_block(node, segment)
      return yield unless node.block.is_a?(Prism::BlockNode)

      node.compact_child_nodes.each { |child| child.accept(self) unless child.equal?(node.block) }
      nest(segment, node.location, node.block.location.start_line, anchor: block_anchor(node)) do
        node.block.body&.accept(self)
      end
    end

    def block_anchor(node)
      anchor = node.location.slice[0...(node.block.location.start_offset - node.location.start_offset)]
        .gsub(/\s+/, " ").strip
      return anchor unless node.is_a?(Prism::CallNode)

      combined_context_anchor(callable_context_anchor(node), enclosing_collection_anchor) || anchor
    end

    # A call-shaped anonymous block begins after an enclosing assignment or
    # argument list. Preserve that context when it identifies the block, just
    # as #lambda_anchor does for arrow literals; otherwise HANDLER and OTHER
    # can share an anchor such as `Enumerator.new`. A collection containing the
    # call supplies the same ownership context when neither local form applies.
    def callable_context_anchor(node)
      before_call = @source.byteslice(0, node.location.start_offset)
      current_line = before_call.split("\n").last.to_s.strip
      return current_line if current_line.end_with?("=", "(")

      preceding_line = before_call.rstrip.split("\n").last.to_s.strip
      return preceding_line if current_line.empty? && preceding_line.end_with?("=", "(")

      enclosing_call_anchor(node)
    end

    # A block-producing call may itself be an argument after an earlier value:
    # `register(:name, Enumerator.new do ...)`. Its local prefix ends in a
    # comma, so looking only at line suffixes loses the enclosing call's
    # identity. The visitor stack supplies that parent relationship directly.
    def enclosing_call_anchor(node)
      parent = @call_stack.reverse_each.find do |candidate|
        candidate != node && candidate.arguments&.arguments&.any? { argument_contains?(node, _1) }
      end
      return unless parent

      prefix_length = node.location.start_offset - parent.location.start_offset
      parent.location.slice[0...prefix_length].gsub(/\s+/, " ").strip
    end

    def argument_contains?(node, argument)
      argument.equal?(node) || argument.compact_child_nodes.any? { argument_contains?(node, _1) }
    end

    # The literal is anonymous, but its statement prefix is stable when it is
    # assigned or passed to a call. This distinguishes a replacement from a
    # smaller version of the same unique lambda without making its body part of
    # the identity.
    def lambda_anchor(node)
      context_anchor = combined_context_anchor(enclosing_call_anchor(node), enclosing_collection_anchor)
      return context_anchor if context_anchor

      before_lambda = @source.byteslice(0, node.location.start_offset)
      prefix = before_lambda.split("\n").last.to_s.strip
      return prefix unless prefix.empty?

      preceding_line = before_lambda.rstrip.split("\n").last.to_s.strip
      preceding_line.end_with?("=", "(") ? preceding_line : "[lambda]"
    end

    # A callable can have both an enclosing call and an owning collection. The
    # call distinguishes its immediate construction, while the collection
    # distinguishes the constant or variable that owns it.
    def combined_context_anchor(*anchors)
      anchor = anchors.compact.join(" ")
      anchor unless anchor.empty?
    end

    # A lambda in an assigned collection begins after `[` or `{`, so its own
    # line has no assignment context. Keep the collection's opening prefix to
    # distinguish a replacement of HANDLERS from a replacement of OTHER.
    def with_collection(node)
      @collection_stack << node
      yield
    ensure
      @collection_stack.pop
    end

    def enclosing_collection_anchor
      anchor = @collection_stack.filter_map do |collection|
        before_collection = @source.byteslice(0, collection.location.start_offset)
        prefix = before_collection.split("\n").last.to_s.strip
        prefix = before_collection.rstrip.split("\n").last.to_s.strip if prefix.empty?
        "#{prefix} #{collection.location.slice[0]}" unless prefix.empty?
      end.join(" ")
      anchor unless anchor.empty?
    end

    # Two indexes, because a start line alone is not an identity. In a chained
    # block — `items.each do ... end.map do ... end` — both blocks are reported
    # by RuboCop at the receiver's line and column, so a line-keyed map resolves
    # both to the inner block and Measurement#record keeps only the larger: a
    # new outer block hides behind a baselined inner one. Prism's node ranges
    # match RuboCop's offense ranges exactly for classes, defs and blocks, so
    # the end line separates them.
    #
    # The line-only map stays as the fallback for offenses whose range is not a
    # scope's range (Metrics/BlockNesting points at a bare statement).
    def nest(segment, location, *extra_lines, anchor: segment)
      @stack.push(disambiguate(segment, anchor))
      @ranges[[ location.start_line, location.end_line ]] ||= path
      @enclosures << [ location.start_line, location.end_line, path ]
      [ location.start_line, *extra_lines ].each { |line| @paths[line] ||= path }
      yield
    ensure
      @stack.pop
    end

    # Sibling scopes can share a name: `items.each do` twice in one method, or a
    # class reopened later in the same file. Left alone they collapse to one key,
    # and Measurement#record keeps only the larger value — so a second block
    # landing at 80 against a sibling pinned at 90 would be invisible to the
    # ratchet even though it blows the budget. The ordinal is counted over the
    # fully-qualified parent path, so it is stable against edits anywhere else in
    # the file, and only the second and later twins carry a suffix — the common
    # case of a uniquely-named scope keeps a clean key.
    def disambiguate(segment, anchor)
      sibling_path = join(path, segment)
      occurrence = (@occurrences[sibling_path] += 1)
      occurrence == 1 ? segment : "#{segment}(#{occurrence})"
    end

    # "Collavre::AgentOrchestrator#run[block:each]" — `::` between namespaces,
    # `#`/`.`/`[` already carry their own separator.
    def path = @stack.each_with_object(+"") { |segment, acc| join(acc, segment) }

    def join(prefix, segment)
      prefix << "::" unless prefix.empty? || segment.start_with?("#", ".", "[")
      prefix << segment
    end
  end

  # A single reason the ratchet is unhappy. `blocking` separates hard failures
  # from advisory notes so an unused waiver cannot fail a build on its own.
  Problem = Struct.new(:kind, :key, :message, :blocking, keyword_init: true) do
    def blocking?
      blocking
    end
  end

  Waiver = Struct.new(:key, :owner, :reason, :expires, keyword_init: true) do
    # `owner: ""` is not an owner and `reason: ""` is not a reason: a blank
    # waiver silently skips the entity in Check#measurement_problems, which is
    # the strongest thing this tool can do for you, handed out for free.
    def invalid_reason(today)
      return "waiver is missing owner/reason/expires" if incomplete?
      return nil unless expires > today + MAX_WAIVER_DAYS

      "waiver expiry #{expires} is more than #{MAX_WAIVER_DAYS} days out"
    end

    # Valid, in date, and therefore actually suppressing something today.
    def live?(today)
      invalid_reason(today).nil? && expires >= today
    end

    # `owner: ""` is not an owner and `reason: ""` is not a reason. Accepting
    # them would leave the field technically present and the accountability the
    # waiver exists to create entirely absent — a blank waiver silently skips
    # the entity in Check#measurement_problems, which is the strongest thing
    # this tool can do for you, handed out for free.
    def incomplete?
      expires.nil? ||
        [ key, owner, reason ].any? { |field| !field.is_a?(String) || field.strip.empty? }
    end
  end

  # Compares the head measurement against the merge base's and the waiver list.
  class Check
    def initialize(actual:, base:, waivers: [], today: Date.today)
      @actual = actual
      @base = base
      @waivers = waivers
      @today = today
    end

    def problems
      @problems ||= waiver_problems + measurement_problems
    end

    def blocking_problems
      problems.select(&:blocking?)
    end

    def pass?
      blocking_problems.empty?
    end

    private

    attr_reader :actual, :base, :waivers, :today

    def waived
      @waived ||= waivers.to_h { |waiver| [ waiver.key, waiver ] }
    end

    def waiver_problems
      waivers.filter_map do |waiver|
        if (reason = waiver.invalid_reason(today))
          problem(:invalid_waiver, waiver.key, reason, blocking: true)
        elsif waiver.expires < today
          problem(:expired_waiver, waiver.key,
            "waiver owned by #{waiver.owner} expired on #{waiver.expires} — fix the entity or renew it deliberately",
            blocking: true)
        elsif !actual.key?(waiver.key)
          problem(:unused_waiver, waiver.key, "waiver is no longer needed; delete it", blocking: false)
        end
      end
    end

    # An entity that shrank, or dropped under budget entirely, produces nothing
    # at all. Under the old committed-baseline design an improvement was a
    # blocking `stale` problem — the baseline had to be re-recorded in the same
    # PR or CI stayed red. Measuring the merge base leaves no record to keep in
    # sync, so improving code is simply allowed.
    def measurement_problems
      actual.filter_map do |key, value|
        next if waived.key?(key)

        recorded = base[key]
        if recorded.nil?
          problem(:new_offense, key, "#{value} exceeds the budget and is not over budget at the merge base", blocking: true)
        elsif value > recorded
          problem(:regression, key, "grew from #{recorded} to #{value}", blocking: true)
        end
      end
    end

    def problem(kind, key, message, blocking:)
      Problem.new(kind: kind, key: key, message: message, blocking: blocking)
    end
  end


  class << self
    # RuboCop prints AbcSize as a float; keep whole numbers as integers so a
    # reported value reads 38 rather than 38.0.
    def normalize(value)
      rounded = value.round(2)
      rounded == rounded.to_i ? rounded.to_i : rounded
    end

    def load_waivers(path)
      return [] unless File.exist?(path)

      document = YAML.safe_load_file(path, permitted_classes: [ Date ]) || {}
      Array(document["waivers"]).map do |entry|
        Waiver.new(
          key: entry["key"],
          owner: entry["owner"],
          reason: entry["reason"],
          expires: parse_date(entry["expires"])
        )
      end
    end

    def parse_date(value)
      case value
      when Date then value
      when String then (Date.parse(value) rescue nil)
      end
    end

    # The one thing the merge-base comparison cannot see for itself. Both sides
    # are measured with THIS branch's budget, deliberately — otherwise a PR that
    # tightens a Max would report every pre-existing entity as new debt. The
    # cost of that choice is that raising a Max is invisible to the comparison:
    # RuboCop simply stops emitting the offenses that cop held, on both sides at
    # once, and the gate goes green while every future entity inherits the
    # weaker limit.
    #
    # Measured on this repo: MethodLength 25 -> 200 silences 160 of 438
    # entities and reports nothing.
    #
    # The rule is an allowlist, not a list of known tricks: `Max` may fall, and
    # everything else in this file must stay put. Enumerating the ways to widen
    # a cop's reach is a losing game — `Max` is only the loudest one, and
    # `Exclude`, `Include`, `AllowedMethods`, `AllowedPatterns` and `CountAsOne`
    # all silence offenses just as completely while the `Max` on the line above
    # still reads as strict. A tightening that trips this is not blocked, only
    # made explicit: it goes through the reset label like any other budget
    # change, which is the point.
    def verify_budget(before, after)
      return [] if before.nil?

      cop_problems(before, after) + exclude_problems(before, after) + global_problems(before, after)
    end

    private

    # A cop that was gating has to keep gating, at a limit no higher, over a
    # scope no smaller, with no new escape valve bolted on. A cop that only
    # appears in `after` is new coverage and is left alone.
    def cop_problems(before, after)
      metrics(before).filter_map do |cop, body|
        current = after[cop]

        if !enabled?(current)
          problem(:budget_disabled, cop,
            "was enabled in #{CONFIG_PATH} and is now off or gone — switching a cop off silences every entity it holds")
        elsif body["Max"] && current["Max"].nil?
          problem(:budget_implicit, cop,
            "lost its explicit Max in #{CONFIG_PATH} — an inherited limit moves on a gem upgrade and cannot be compared next PR")
        elsif body["Max"] && !(current["Max"].is_a?(Numeric) && current["Max"].finite? && current["Max"] >= 0) then problem(:budget_invalid_max, cop, "Max must be finite and nonnegative in #{CONFIG_PATH} (got #{current['Max'].inspect})")
        elsif body["Max"] && current["Max"] > body["Max"]
          problem(:budget_loosened, cop,
            "budget raised from #{body['Max']} to #{current['Max']} in #{CONFIG_PATH} — the ratchet only turns one way")
        else
          settings_problem(cop, body, current)
        end
      end
    end

    # Everything that is not `Enabled` or `Max`. RuboCop has no shortage of keys
    # that make a cop stop reporting without touching its limit — a per-cop
    # `Exclude: ['**/*']` disables MethodLength repository-wide while the config
    # still says `Max: 25` — so the check is "unchanged", not "not one of the
    # ones I thought of".
    def settings_problem(cop, before, after)
      changed = (before.keys | after.keys).reject { |key| %w[Enabled Max].include?(key) }
        .reject { |key| before[key] == after[key] }
      return nil if changed.empty?

      problem(:budget_setting_changed, cop,
        "#{changed.sort.join(', ')} changed in #{CONFIG_PATH} — keys like Exclude, Include, AllowedMethods, " \
        "AllowedPatterns and CountAsOne silence offenses without moving Max")
    end

    def metrics(config)
      config.select { |cop, body| cop.start_with?("Metrics/") && enabled?(body) }
    end

    def enabled?(body)
      body.is_a?(Hash) && body["Enabled"] == true
    end

    # Excluding a path is the .rubocop_todo.yml amnesty this whole design exists
    # to avoid: excluded code is invisible to every cop and can grow without
    # limit. Removing an exclude widens the scan, so only additions are rejected.
    def exclude_problems(before, after)
      (excludes(after) - excludes(before)).map do |path|
        problem(:budget_scope_narrowed, path,
          "added to AllCops/Exclude in #{CONFIG_PATH} — excluded code is invisible to the ratchet and can grow without limit")
      end
    end

    def excludes(config)
      Array(config.dig("AllCops", "Exclude"))
    end

    # Everything outside the Metrics cops: `inherit_gem`/`inherit_from` (an
    # inherited config can widen AllCops/Exclude), `inherit_mode` (which decides
    # whether Exclude merges with the inherited list or replaces it), and
    # AllCops keys other than Exclude, which is compared above because it is the
    # one that may legitimately shrink.
    def global_problems(before, after)
      keys = (before.keys | after.keys).reject { |key| key.start_with?("Metrics/") || key == "AllCops" }

      keys.filter_map { |key|
        next if before[key] == after[key]

        problem(:budget_inherit_changed, key,
          "#{key} changed in #{CONFIG_PATH} (#{before[key].inspect} -> #{after[key].inspect}) — " \
          "an inherited or global setting can widen AllCops/Exclude")
      } + allcops_problems(before, after)
    end

    # AllCops/Exclude is compared by #exclude_problems, because it is the one
    # key here that may legitimately shrink. The rest — Include, NewCops,
    # EnabledByDefault — has to hold still.
    def allcops_problems(before, after)
      mine, theirs = [ before, after ].map { |config| (config["AllCops"] || {}).except("Exclude") }
      return [] if mine == theirs

      changed = (mine.keys | theirs.keys).reject { |key| mine[key] == theirs[key] }.sort
      [ problem(:budget_scope_narrowed, "AllCops",
        "#{changed.join(', ')} changed in #{CONFIG_PATH} — narrowing what RuboCop reads hides entities from the ratchet") ]
    end

    def problem(kind, key, message)
      Problem.new(kind: kind, key: key, message: message, blocking: true)
    end
  end
end

require_relative "complexity_ratchet/measurement"
