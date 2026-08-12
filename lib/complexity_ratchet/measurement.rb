# frozen_string_literal: true

require "json"
require "open3"

module ComplexityRatchet
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
      command = [ "bundle", "exec", "rubocop", "-c", config, "--ignore-disable-comments",
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
      ordinal && ordinal > 1 ? "#{base}[fallback:#{ordinal}]" : base
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
end
