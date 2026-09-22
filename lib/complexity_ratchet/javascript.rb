# frozen_string_literal: true

require "json"
require "open3"

module ComplexityRatchet
  # The JavaScript half of the ratchet.
  #
  # The Ruby half has been gating the core engine's ~40,000 lines of app code
  # since the `complexity` job landed. The same engine ships ~35,000 lines of
  # non-test JavaScript that nothing measured at all: the repository has no
  # ESLint config, no lint job for it and no devDependency, and RuboCop
  # obviously does not read `.js`. That is where the two largest source files in
  # the engine live.
  #
  # Rather than a second gate with its own semantics, this produces the same
  # {entity key => value} hash ComplexityRatchet::Measurement produces, so the
  # merge-base comparison, the waiver format and the reporting are literally the
  # same code. The measuring is delegated to Node (see bin/js_complexity.mjs)
  # because ESLint is the only thing here that can parse modern JS and JSX.
  module Javascript
    CONFIG_PATH = ".eslint_metrics.yml"
    SCRIPT_PATH = "bin/js_complexity.mjs"

    INSTALL_HINT = "run `npm ci` first — the JavaScript ratchet needs ESLint from the repository's node_modules"

    # Measures a tree with the *tool root's* ESLint and budget. The base side of
    # the ratchet is a detached worktree with neither, and mixing the two would
    # reintroduce the bug the Ruby half documents at length: measuring each side
    # with its own budget makes a PR that tightens a limit report every
    # pre-existing entity as brand-new debt.
    class Measurement
      def self.call(root:, tool_root:, config: nil)
        new(root: root, tool_root: tool_root, config: config).call
      end

      def initialize(root:, tool_root:, config: nil)
        @root = root
        @tool_root = tool_root
        @config = config || File.join(tool_root, CONFIG_PATH)
      end

      def call
        JSON.parse(run)
      end

      private

      attr_reader :root, :tool_root, :config

      def run
        command = [ "node", File.join(tool_root, SCRIPT_PATH), "--root", root, "--config", config ]
        stdout, stderr, status = Open3.capture3(*command, chdir: tool_root)
        raise Error, failure_message(status, stderr) unless status.success?

        # Open3 tags the pipe with Encoding.default_external, which a shell
        # without LANG set leaves as US-ASCII — and the first entity name
        # carrying an em dash then dies inside JSON.parse. The script always
        # writes UTF-8. (ComplexityRatchet::Measurement reads source files with
        # the same explicit encoding, for the same reason.)
        stdout.force_encoding(Encoding::UTF_8)
      end

      def failure_message(status, stderr)
        hint = stderr.include?("Cannot find package") ? " — #{INSTALL_HINT}" : ""
        "#{SCRIPT_PATH} failed (#{status.exitstatus})#{hint}: #{stderr.strip}"
      end
    end

    # The budget file is compared against the merge base's copy for the same
    # reason .rubocop_metrics.yml is: both trees are measured with this branch's
    # copy, so raising a threshold silences the same entities on both sides at
    # once and the comparison sees nothing.
    #
    # It is an allowlist. Exactly three edits pass — lowering a threshold,
    # widening `include`, and shrinking `exclude` — and anything else is
    # reported, including keys that do not exist yet. The budget file holds
    # nothing but numbers and globs by design (rule options live in
    # lib/js_complexity/measure.js), which is what makes an allowlist this short
    # possible; the RuboCop side needs a much longer one because a cop can be
    # silenced through Exclude, Include, AllowedMethods, AllowedPatterns or
    # CountAsOne without its Max moving at all.
    KNOWN_KEYS = %w[include exclude rules].freeze

    class << self
      def verify_budget(before, after)
        return [] if before.nil?

        rule_problems(before, after) +
          scope_problems(before, after) +
          unknown_key_problems(before, after)
      end

      private

      def rule_problems(before, after)
        rules(before).filter_map do |rule, limit|
          current = rules(after)[rule]

          if current.nil?
            problem(:js_budget_disabled, rule,
              "was in #{CONFIG_PATH} and is gone — dropping a rule silences every entity it holds")
          elsif !current.is_a?(Integer) || current.negative?
            problem(:js_budget_invalid_max, rule,
              "threshold must be a non-negative integer in #{CONFIG_PATH} (got #{current.inspect})")
          elsif current > limit
            problem(:js_budget_loosened, rule,
              "budget raised from #{limit} to #{current} in #{CONFIG_PATH} — the ratchet only turns one way")
          end
        end
      end

      # `include` may grow and `exclude` may shrink: both widen what is measured.
      # The opposite of each hides code from the gate, which is the amnesty this
      # design exists to avoid.
      def scope_problems(before, after)
        dropped = (list(before, "include") - list(after, "include")).map do |pattern|
          problem(:js_budget_scope_narrowed, pattern,
            "removed from `include` in #{CONFIG_PATH} — unmeasured code can grow without limit")
        end

        added = (list(after, "exclude") - list(before, "exclude")).map do |pattern|
          problem(:js_budget_scope_narrowed, pattern,
            "added to `exclude` in #{CONFIG_PATH} — excluded code is invisible to the ratchet")
        end

        dropped + added
      end

      # A key this checker does not know about cannot be judged, and an
      # unjudged key in a budget file is a bypass waiting to be written. The
      # next version of the measurement script may add one; adding it here is
      # the deliberate step that makes it reviewable.
      def unknown_key_problems(before, after)
        ((before.keys | after.keys) - KNOWN_KEYS).sort.filter_map do |key|
          next if before[key] == after[key]

          problem(:js_budget_unknown_key, key,
            "#{key} changed in #{CONFIG_PATH} and is not a key the ratchet knows how to compare")
        end
      end

      def rules(config)
        config["rules"].is_a?(Hash) ? config["rules"] : {}
      end

      def list(config, key)
        Array(config[key])
      end

      def problem(kind, key, message)
        Problem.new(kind: kind, key: key, message: message, blocking: true)
      end
    end
  end
end
