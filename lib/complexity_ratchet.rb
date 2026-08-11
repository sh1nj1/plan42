# frozen_string_literal: true

require "date"
require "json"
require "open3"
require "prism"
require "yaml"

# Entity-level monotonic complexity ratchet.
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
# So the baseline here is recorded per ENTITY (a specific class, module, method,
# or block) rather than per cop or per file:
#
#   * every entity already over budget is pinned at its current value and may
#     only shrink — growth fails CI
#   * every entity NOT in the baseline must fit the budget in
#     .rubocop_metrics.yml — new code gets no amnesty from old debt
#   * shrinking an entity requires updating the baseline in the same PR, so the
#     ratchet only ever turns one way
#   * the baseline cannot be loosened: `--verify-baseline` rejects any PR whose
#     baseline raises a value or adds a key
#   * the single escape hatch is a waiver with an owner, a reason, and an expiry
#     date; an expired waiver fails CI
#
# Entities are keyed by their fully-qualified name, not by line number, so
# inserting code above a method does not invalidate its baseline entry.
module ComplexityRatchet
  Error = Class.new(StandardError)

  CONFIG_PATH   = ".rubocop_metrics.yml"
  BASELINE_PATH = ".complexity_baseline.yml"
  WAIVERS_PATH  = ".complexity_waivers.yml"
  # The rest of the budget: CONFIG_PATH sets Enabled and Max and inherits every
  # other Metrics setting from the RuboCop gems pinned here. See #verify_toolchain.
  LOCK_PATH     = "Gemfile.lock"

  # The measured value inside a RuboCop Metrics message:
  #   "Method has too many lines. [38/25]"                    -> 38
  #   "Assignment Branch Condition size ... [<7, 42, 8> 43.55/35]" -> 43.55
  # Metrics/BlockNesting carries no number; those offenses are counted instead.
  VALUE_PATTERN = /\[(?:<[^>]*>\s*)?([\d.]+)\/[\d.]+\]/

  SEPARATOR = " | "

  BASELINE_HEADER = <<~YAML
    # Complexity ratchet baseline — DO NOT hand-edit to make CI pass.
    #
    # Each entry pins one entity (class / module / method / block) that is
    # already over the budget in .rubocop_metrics.yml at the size it had when it
    # was recorded. The value may only go DOWN. `bin/complexity_check
    # --verify-baseline <ref>` fails any PR that raises a value or adds a key,
    # so regenerating this file cannot be used to turn CI green.
    #
    # Regenerate after a refactor that shrinks or removes an entity:
    #
    #     bin/complexity_check --regenerate
    #
    # Structure: <path>: <cop>: <entity>: <value>. Tool output and waiver keys
    # use the flattened form "<path> | <cop> | <entity>".
  YAML

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

  # The two keys --verify-baseline understands well enough to judge a change to:
  # `Enabled` must stay true, `Max` may only fall. Every other key a Metrics cop
  # accepts is compared for equality instead, because a loosening dressed up as
  # a setting (`Exclude`, `AllowedPatterns`, `CountAsOne`) is indistinguishable
  # from a tightening without re-implementing RuboCop's scope resolution.
  BUDGET_KEYS = %w[Enabled Max].freeze

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
      map = new
      Prism.parse(source).value.accept(map)
      map
    end

    def initialize
      @paths = {}
      @ranges = {}
      @enclosures = []
      @stack = []
      @fallback_statements = Hash.new { |hash, key| hash[key] = [] }
      @occurrences = Hash.new(0)
      @sibling_anchors = Hash.new { |hash, key| hash[key] = [] }
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
      nest("#{node.receiver ? '.' : '#'}#{node.name}", node.location) { super }
    end

    # Record direct statements while their enclosing scope is on the stack.
    def visit_statements_node(node)
      node.body.each do |statement|
        @fallback_statements[[ path, statement.location.slice.lines.first.strip.gsub(/\s+/, " ") ]] << [ statement.location.start_line, statement.location.end_line ]
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
      nest_block(node, "[block:#{node.name}]") { super }
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
      nest("[lambda]", node.location) { super }
    end

    # Baseline entries only exist for scopes that are currently over budget,
    # but sibling ordinals are assigned to every scope. Keep that population so
    # --verify-baseline can notice when an unrecorded sibling disappears and a
    # recorded sibling shifts onto its key.
    def sibling_populations
      @occurrences.select { |_path, count| count > 1 }
    end

    # Ordinals distinguish sibling scopes in the measurement, but their order
    # can change without their count changing. Retain a stable-enough anchor
    # for literal blocks — the call prefix through `do`/`{`, excluding the body
    # whose size is being measured — so verification can notice `first.each`
    # and `second.each` swapping places instead of transferring their budgets.
    def sibling_anchors
      @sibling_anchors.select { |path, anchors| @occurrences[path] > 1 }
    end

    private

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
      block_offset = node.block.location.start_offset - node.location.start_offset
      node.location.slice[0...block_offset].gsub(/\s+/, " ").strip
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
      @sibling_anchors[sibling_path] << anchor
      occurrence = (@occurrences[sibling_path] += 1)
      occurrence == 1 ? segment : "#{segment}(#{occurrence})"
    end

    # "Collavre::AgentOrchestrator#run[block:each]" — `::` between namespaces,
    # `#`/`.`/`[` already carry their own separator.
    def path
      @stack.each_with_object(+"") { |segment, acc| join(acc, segment) }
    end

    def join(prefix, segment)
      prefix << "::" unless prefix.empty? || segment.start_with?("#", ".", "[")
      prefix << segment
    end
  end

  # Runs RuboCop's Metrics department and folds the offenses into
  # {entity key => measured value}.
  class Measurement
    def self.call(root:, config: CONFIG_PATH)
      new(root: root, config: config).call
    end

    def initialize(root:, config: CONFIG_PATH)
      @root = root
      @config = config
    end

    def call
      fold(run_rubocop)
    end

    # Split out from #call so the folding — which is where the entity keys and
    # the max-vs-count rules live — can be tested against a fixture payload
    # instead of a two-second RuboCop run.
    def fold(payload)
      payload.fetch("files").each_with_object({}) do |file, acc|
        offenses = file["offenses"]
        next if offenses.nil? || offenses.empty?

        absorb(acc, relative_path(file["path"]), offenses)
      end
    end

    private

    attr_reader :root, :config

    def run_rubocop
      command = [ "bundle", "exec", "rubocop", "-c", config,
                  "--only", "Metrics", "--format", "json", "--no-color" ]
      stdout, stderr, status = Open3.capture3(*command, chdir: root)
      # RuboCop exits 1 whenever offenses exist, which is the normal case here.
      # Only a missing JSON document means the run itself failed.
      raise Error, "rubocop failed (#{status.exitstatus}): #{stderr}" if stdout.strip.empty?

      JSON.parse(stdout)
    end

    def absorb(acc, path, offenses)
      source = File.read(File.join(root, path))
      entities = EntityMap.for(source)
      lines = source.lines
      offenses.sort_by { |offense| [ offense.dig("location", "start_line") || offense.dig("location", "line"), offense.dig("location", "last_line") || 0 ] }.each do |offense|
        line = offense.dig("location", "start_line") || offense.dig("location", "line")
        last_line = offense.dig("location", "last_line")
        key = [ path, offense["cop_name"], entities[line, last_line] || fallback_name(entities, lines, line, last_line) ].join(SEPARATOR)
        record(acc, key, offense["message"])
      end
    end

    # Metrics/BlockNesting and friends point at a bare statement rather than a
    # definition. The normalised source line and enclosing scope identify the
    # usual case; include below-budget twins in the ordinal population too.
    def fallback_name(entities, lines, line, last_line)
      text = lines[line - 1].to_s.strip.gsub(/\s+/, " ")
      text = "#{text[0, 97]}..." if text.length > 100
      base = [ entities.enclosing_path(line, last_line), "~#{text}" ].compact.join
      ordinal = entities.fallback_ordinal(line, last_line, text)
      ordinal && ordinal > 1 ? "#{base}(#{ordinal})" : base
    end

    def record(acc, key, message)
      measured = message[VALUE_PATTERN, 1]
      if measured
        acc[key] = ComplexityRatchet.normalize([ acc[key].to_f, measured.to_f ].max)
      else
        acc[key] = acc[key].to_i + 1
      end
    end

    def relative_path(path)
      absolute = File.expand_path(path)
      prefix = "#{File.expand_path(root)}/"
      absolute.start_with?(prefix) ? absolute.delete_prefix(prefix) : path
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
    # What makes a waiver count lives here rather than inside Check because two
    # commands have to agree on it. If --regenerate honoured a waiver that
    # --check rejects, `--regenerate` would exit 0 on debt that fails CI; if it
    # ignored one --check honours, the documented refactor workflow would exit 1
    # demanding a waiver that is already there. Two copies of this rule drift.
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

  # Compares a measurement against the baseline and the waiver list.
  class Check
    def initialize(actual:, baseline:, waivers: [], today: Date.today)
      @actual = actual
      @baseline = baseline
      @waivers = waivers
      @today = today
    end

    def problems
      @problems ||= waiver_problems + measurement_problems + resolved_problems
    end

    def blocking_problems
      problems.select(&:blocking?)
    end

    def pass?
      blocking_problems.empty?
    end

    private

    attr_reader :actual, :baseline, :waivers, :today

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

    def measurement_problems
      actual.filter_map do |key, value|
        next if waived.key?(key)

        recorded = baseline[key]
        if recorded.nil?
          problem(:new_offense, key, "#{value} exceeds the budget and has no baseline entry", blocking: true)
        elsif value > recorded
          problem(:regression, key, "grew from #{recorded} to #{value}", blocking: true)
        elsif value < recorded
          problem(:stale, key, "improved from #{recorded} to #{value} — run bin/complexity_check --regenerate", blocking: true)
        end
      end
    end

    def resolved_problems
      (baseline.keys - actual.keys).map do |key|
        problem(:stale, key, "is now within budget — run bin/complexity_check --regenerate", blocking: true)
      end
    end

    def problem(kind, key, message, blocking:)
      Problem.new(kind: kind, key: key, message: message, blocking: blocking)
    end
  end

  class << self
    # RuboCop prints AbcSize as a float; keep whole numbers as integers so the
    # baseline diff reads 38 rather than 38.0.
    def normalize(value)
      rounded = value.round(2)
      rounded == rounded.to_i ? rounded.to_i : rounded
    end

    def load_baseline(path)
      return {} unless File.exist?(path)

      flatten(YAML.safe_load_file(path) || {})
    end

    def dump_baseline(path, entries)
      File.write(path, BASELINE_HEADER + YAML.dump(nest(entries), line_width: -1))
    end

    # On disk the baseline nests path -> cop -> entity; in memory it is a flat
    # map of "path | cop | entity" keys. Nesting is not cosmetic: YAML falls
    # back to the `? key` / `: value` explicit form once a mapping key passes
    # 128 characters, and a flat key made of a full engine path plus a
    # namespaced method name blows through that constantly — producing a
    # three-line diff per entity instead of one.
    def nest(entries)
      entries.sort.each_with_object({}) do |(key, value), acc|
        file, cop, entity = key.split(SEPARATOR, 3)
        ((acc[file] ||= {})[cop] ||= {})[entity] = value
      end
    end

    def flatten(nested)
      nested.each_with_object({}) do |(file, cops), acc|
        cops.each do |cop, entities|
          entities.each { |entity, value| acc[[ file, cop, entity ].join(SEPARATOR)] = value }
        end
      end
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

    # A regenerated baseline must be a subset-or-tightening of the previous one.
    # Without this, "just regenerate the baseline" would be a one-command way to
    # legalise any regression — the same hole that makes .rubocop_todo.yml
    # useless as a gate.
    #
    # `before` is nil when the base ref predates the baseline file, which is the
    # bootstrap commit and has nothing to compare against. That is not a hole
    # worth plugging: skipping the gate afterwards means deleting a 438-entry
    # file, which is a reviewable event, whereas the path this actually closes —
    # `--regenerate` to make CI green — is a single command.
    def verify_monotonic(before, after, before_siblings: {}, after_siblings: {}, before_sibling_anchors: {}, after_sibling_anchors: {})
      return [] if before.nil?

      after.filter_map { |key, value|
        recorded = before[key]
        if recorded.nil?
          Problem.new(kind: :baseline_addition, key: key, blocking: true,
            message: "added to the baseline (#{value}) — new debt needs a fix or a waiver, not a baseline entry")
        elsif value > recorded
          Problem.new(kind: :baseline_loosened, key: key, blocking: true,
            message: "baseline raised from #{recorded} to #{value} — the ratchet only turns one way")
        end
      } + sibling_problems(before, after, before_siblings:, after_siblings:, before_sibling_anchors:, after_sibling_anchors:)
    end

    # The baseline cannot describe an under-budget sibling because RuboCop does
    # not emit an offense for it. Compare the parsed scope populations from the
    # base ref and the branch too: otherwise deleting a 90-line sibling next to
    # an unrecorded 60-line sibling lets the latter grow to 80 under the former
    # key, and every baseline-only comparison calls that an improvement.
    def sibling_populations(sources)
      sources.each_with_object({}) do |(path, source), populations|
        next if source.nil?

        EntityMap.for(source).sibling_populations.each do |entity, count|
          populations[[ path, entity.gsub(/\(\d+\)/, "") ].join(SEPARATOR)] = count
        end
      end
    end

    # Population catches a deleted sibling that was below budget and therefore
    # absent from the baseline. Anchors catch the other positional transfer:
    # two named calls can swap order while keeping the same population, making
    # every ordinal key look individually tighter even though the smaller
    # sibling grew under the larger sibling's allowance.
    def sibling_anchors(sources)
      sources.each_with_object({}) do |(path, source), anchors|
        next if source.nil?

        EntityMap.for(source).sibling_anchors.each do |entity, values|
          anchors[[ path, entity.gsub(/\(\d+\)/, "") ].join(SEPARATOR)] = values
        end
      end
    end

    # Raising a Max in .rubocop_metrics.yml is the quiet way to unwind the
    # ratchet, and verify_monotonic cannot see it: RuboCop stops emitting the
    # offenses that cop held, `--regenerate` drops their baseline entries, and
    # verify_monotonic only inspects the keys that remain. Both gates go green
    # while every future entity inherits the weaker limit — no reset label, no
    # diff to the baseline except deletions that look like a refactor.
    #
    # Measured on this repo: MethodLength 25 -> 200 deletes 160 of 438 entries,
    # reports zero new debt, and passes.
    #
    # Deletions themselves cannot be rejected — a real refactor deletes entries
    # too, and that is the ratchet working. So the budget is pinned instead.
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

    # The budget is not only what .rubocop_metrics.yml says. That file sets
    # `Enabled` and `Max` and inherits everything else from the RuboCop gems, so
    # a version bump moves the effective budget while the file it is compared
    # against is byte-identical:
    #
    #   Metrics/MethodLength in .rubocop_metrics.yml : Enabled, Max
    #   Metrics/MethodLength in effect               : Enabled, Max,
    #     AllowedMethods, AllowedPatterns, CountAsOne, CountComments
    #
    # Four of six keys live in the gem. Measured on this repo by widening one of
    # them the way an upgrade would, changing nothing in the repository:
    # measurement drops 438 entities to 277, `--regenerate` deletes all 161
    # MethodLength entries, and both `--verify-baseline` and `--check` exit 0.
    # MethodLength is then off repository-wide with no reset label.
    #
    # Comparing *resolved* configs does not close this. Resolution uses the gems
    # that are installed, and CI installs only this branch's — so the base
    # config would be resolved with the new RuboCop and come out identical. The
    # version is the only evidence of the base's behaviour that survives into
    # the PR build, so that is what is compared.
    #
    # A toolchain change is not blocked, only made explicit: it goes through
    # `complexity-baseline-reset` like any other budget change, which is the
    # case that label was written for.
    def verify_toolchain(before_lock, after_lock)
      return [] if before_lock.nil?

      before, after = [ before_lock, after_lock ].map { |lock| rubocop_versions(lock) }

      (before.keys | after.keys).sort.filter_map do |gem_name|
        next if before[gem_name] == after[gem_name]

        problem(:toolchain_changed, gem_name,
          "#{gem_name} #{before[gem_name] || '(absent)'} -> #{after[gem_name] || '(absent)'} — " \
          "the Metrics budget inherits AllowedMethods, AllowedPatterns, CountAsOne and CountComments " \
          "from these gems, so an upgrade can silence offenses and delete baseline entries " \
          "while #{CONFIG_PATH} stays identical")
      end
    end

    # Keys present in the measurement but absent from the baseline are NOT
    # added: adding them is what --verify-baseline exists to reject. They are
    # returned so the CLI can point at the real fix.
    # Returns the tightened baseline plus the keys that are new debt.
    #
    # A live waiver is not new debt — it is debt that has already been argued
    # for, named an owner, and given an expiry. Counting it here made the
    # documented refactor workflow unrunnable: --check passed on the waiver
    # while --regenerate wrote the improved baseline and then exited 1, telling
    # you to waive an entity that was waived on the line above. Verified on this
    # repo before the fix — `--check` green, `--regenerate` exit 1 on the same
    # two keys.
    #
    # Only *live* waivers are subtracted. An expired or malformed one is a
    # blocking problem in Check, so honouring it here would let --regenerate
    # exit 0 on something CI rejects.
    #
    # Values may only fall. Writing the measurement unconditionally let a
    # waived entity's growth be copied into the baseline by the next unrelated
    # refactor: Check skips waived keys, so nothing objected, and the value the
    # waiver was meant to be temporary about became the permanent record.
    # Measured on this repo — an entity baselined at 31, grown to 41 under a
    # live waiver, came back 41 after --regenerate, --verify-baseline then
    # blocked the branch, and deleting the expired waiver left zero blocking
    # problems at 41. Taking the minimum makes this command structurally
    # incapable of raising a value, so a waiver decays back to the recorded
    # limit instead of laundering past it.
    def regenerate(baseline, actual, waivers: [], today: Date.today)
      updated = baseline.filter_map do |key, recorded|
        [ key, [ recorded, actual[key] ].min ] if actual.key?(key)
      end.to_h
      live = waivers.select { |waiver| waiver.live?(today) }.map(&:key)
      [ updated, actual.keys - baseline.keys - live ]
    end

    private

    # Same-named siblings are told apart by a positional ordinal, and position
    # is not identity. Delete the first of two `[block:each]` siblings and the
    # second is renamed onto the first's key — inheriting the first's allowance
    # along with it. Measured: siblings recorded at 88 and 78, first deleted,
    # survivor grown 78 -> 83; `--check` called that "improved from 88 to 83",
    # `--regenerate` wrote 83, and every gate went green on five lines of real
    # growth.
    #
    # Per-key comparison cannot see it, because the two keys are separately
    # monotonic. So a family that *shrank* is compared as a whole: nobody knows
    # which sibling survived, so every survivor is held to the smallest limit
    # the family had. That is conservative on purpose — it also fires when the
    # smaller sibling is the one deleted and nothing grew at all. There is no
    # information in the baseline that distinguishes those two cases, so the
    # choice is which way to be wrong, and a false positive here costs a
    # reviewer applying `complexity-baseline-reset` while a false negative
    # unwinds the ratchet silently.
    def sibling_problems(before, after, before_siblings:, after_siblings:, before_sibling_anchors:, after_sibling_anchors:)
      recorded = before.group_by { |key, _| family(key) }
      after.group_by { |key, _| family(key) }.flat_map do |name, entries|
        sibling_family_problems(
          entries, recorded[name], before,
          before_siblings:, after_siblings:, before_sibling_anchors:, after_sibling_anchors:
        )
      end
    end

    def sibling_family_problems(entries, siblings, before, before_siblings:, after_siblings:, before_sibling_anchors:, after_sibling_anchors:)
      return [] if siblings.nil?

      changes = sibling_family_changes(
        entries, siblings,
        before_siblings:, after_siblings:, before_sibling_anchors:, after_sibling_anchors:
      )
      return [] unless changes.values.any?

      entries.filter_map { |key, value| sibling_entry_problem(key, value, before, siblings.map(&:last).min, changes, before_siblings.fetch(sibling_population_key(key), 0) > siblings.size) }
    end

    def sibling_family_changes(entries, siblings, before_siblings:, after_siblings:, before_sibling_anchors:, after_sibling_anchors:)
      {
        baseline_shrank: entries.size < siblings.size,
        population_shrank: entries.any? do |key, _|
          before_siblings.fetch(sibling_population_key(key), 0) > after_siblings.fetch(sibling_population_key(key), 0)
        end,
        anchors_reordered: entries.any? { |key, _| sibling_anchors_reordered?(key, before_sibling_anchors, after_sibling_anchors) },
        anchors_ambiguous: entries.any? do |key, _|
          sibling_anchors_ambiguous?(key, entries, siblings, before_sibling_anchors, after_sibling_anchors)
        end
      }
    end

    def sibling_entry_problem(key, value, before, floor, changes, baseline_incomplete)
      return unless before.key?(key) && (value > floor || !changes.values_at(:baseline_shrank, :anchors_reordered, :anchors_ambiguous).any? || changes[:anchors_reordered] && baseline_incomplete)

      Problem.new(kind: :baseline_sibling_shift, key: key, blocking: true,
        message: sibling_problem_message(value, floor, changes[:baseline_shrank], changes[:anchors_reordered], changes[:anchors_ambiguous], baseline_incomplete))
    end

    def sibling_problem_message(value, floor, baseline_shrank, anchors_reordered, anchors_ambiguous, baseline_incomplete)
      if baseline_shrank
        "a same-named sibling was removed, so this entry may have inherited that sibling's " \
          "allowance — #{value} is above the #{floor} the family was recorded at"
      elsif anchors_reordered && baseline_incomplete
        "same-named siblings changed order while at least one sibling was not baselined, so an " \
          "allowance may have moved to a previously unrecorded entity"
      elsif anchors_reordered
        "same-named siblings changed order, so this entry may have inherited that sibling's " \
          "allowance — #{value} is above the #{floor} the family was recorded at"
      elsif anchors_ambiguous
        "same-named siblings have indistinguishable anchors, so a changed baseline cannot safely " \
          "transfer their allowances — #{value} is above the #{floor} the family was recorded at"
      else
        "a same-named sibling disappeared from the source, so this entry's ordinal may have " \
          "transferred from that sibling — reset the baseline only after reviewing the change"
      end
    end

    # Siblings share every part of a key except their ordinal.
    def family(key) = key.gsub(/\(\d+\)/, "")

    def sibling_population_key(key)
      key.split(SEPARATOR, 3).then { |file, _cop, entity| [ file, entity.gsub(/\(\d+\)/, "") ].join(SEPARATOR) }
    end

    def sibling_anchors_reordered?(key, before, after)
      sibling_key = sibling_population_key(key)
      previous = before[sibling_key]
      current = after[sibling_key]
      previous && current && previous.size == current.size && previous != current
    end

    # Two `items.each` blocks have the same call prefix. If their measured
    # values change, no source-only identity can say which one supplied the
    # old limit; holding both to the family floor is the conservative choice.
    # Do not flag an unchanged baseline, or every PR would fail merely because
    # an existing ambiguous family exists.
    def sibling_anchors_ambiguous?(key, entries, siblings, before, after)
      return false if entries.sort_by(&:first) == siblings.sort_by(&:first)

      sibling_key = sibling_population_key(key)
      previous = before[sibling_key]
      current = after[sibling_key]
      previous && current && previous.size == current.size && previous.uniq.size < previous.size
    end

    # A cop that was gating has to keep gating, at a limit no higher, over a
    # scope no smaller, with no new escape valve bolted on. A cop that only
    # appears in `after` is new coverage and is left alone.
    def cop_problems(before, after)
      metrics(before).filter_map do |cop, body|
        current = after[cop]

        if !enabled?(current)
          problem(:budget_disabled, cop,
            "was enabled in #{CONFIG_PATH} and is now off or gone — switching a cop off deletes every baseline entry it holds")
        elsif body["Max"] && current["Max"].nil?
          problem(:budget_implicit, cop,
            "lost its explicit Max in #{CONFIG_PATH} — an inherited limit moves on a gem upgrade and cannot be compared next PR")
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
      changed = (before.keys | after.keys).reject { |key| BUDGET_KEYS.include?(key) }
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

    # Every resolved `rubocop*` gem in a Gemfile.lock, as name => version.
    #
    # Gemfile.lock indents a resolved spec by four spaces and its dependencies
    # by six, so the anchored four-space match takes each gem once and ignores
    # the dependency lines that repeat it with a constraint instead of a
    # version. Scoped to the rubocop family because they are the ones that ship
    # config: rubocop's own default.yml, rubocop-rails-omakase's rubocop.yml
    # named in `inherit_gem`, and the rubocop-ast the metrics are computed with.
    def rubocop_versions(lock)
      lock.to_s.scan(/^ {4}(rubocop[\w-]*) \(([^)]+)\)$/).to_h
    end

    def problem(kind, key, message)
      Problem.new(kind: kind, key: key, message: message, blocking: true)
    end
  end
end
