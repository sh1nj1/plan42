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
      @stack = []
      @occurrences = Hash.new(0)
      super()
    end

    # `last_line` is optional so a caller with only a line still gets an answer,
    # but passing it is what separates two scopes that open on the same line.
    def [](line, last_line = nil)
      @ranges[[ line, last_line ]] || @paths[line]
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

    # RuboCop reports Metrics/BlockLength against the whole `send + block`
    # range, so the offense line is the call's line rather than the `do`. The
    # `do` line is recorded too, as a fallback for anything that points there.
    #
    # `node.block` is a BlockArgumentNode for `foo(&blk)`, which has no body and
    # is not a scope — only a literal BlockNode introduces one.
    def visit_call_node(node)
      return super unless node.block.is_a?(Prism::BlockNode)

      node.receiver&.accept(self)
      node.arguments&.accept(self)
      nest("[block:#{node.name}]", node.location, node.block.location.start_line) do
        node.block.body&.accept(self)
      end
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

    private

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
    def nest(segment, location, *extra_lines)
      @stack.push(disambiguate(segment))
      @ranges[[ location.start_line, location.end_line ]] ||= path
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
    def disambiguate(segment)
      occurrence = (@occurrences[join(path, segment)] += 1)
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

      offenses.each do |offense|
        line = offense.dig("location", "start_line") || offense.dig("location", "line")
        last_line = offense.dig("location", "last_line")
        key = [ path, offense["cop_name"], entity_name(entities, lines, line, last_line) ].join(SEPARATOR)
        record(acc, key, offense["message"])
      end
    end

    def entity_name(entities, lines, line, last_line = nil)
      entities[line, last_line] || fallback_name(lines, line)
    end

    # Metrics/BlockNesting and friends point at a bare statement rather than a
    # definition. The normalised source line is the only identity available.
    def fallback_name(lines, line)
      text = lines[line - 1].to_s.strip.gsub(/\s+/, " ")
      text = "#{text[0, 97]}..." if text.length > 100
      "~#{text}"
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
    def verify_monotonic(before, after)
      return [] if before.nil?

      after.filter_map do |key, value|
        recorded = before[key]
        if recorded.nil?
          Problem.new(kind: :baseline_addition, key: key, blocking: true,
            message: "added to the baseline (#{value}) — new debt needs a fix or a waiver, not a baseline entry")
        elsif value > recorded
          Problem.new(kind: :baseline_loosened, key: key, blocking: true,
            message: "baseline raised from #{recorded} to #{value} — the ratchet only turns one way")
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
    def regenerate(baseline, actual, waivers: [], today: Date.today)
      updated = baseline.filter_map { |key, _| [ key, actual[key] ] if actual.key?(key) }.to_h
      live = waivers.select { |waiver| waiver.live?(today) }.map(&:key)
      [ updated, actual.keys - baseline.keys - live ]
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

    def problem(kind, key, message)
      Problem.new(kind: kind, key: key, message: message, blocking: true)
    end
  end
end
