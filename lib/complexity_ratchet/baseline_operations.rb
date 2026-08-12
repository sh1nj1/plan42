# frozen_string_literal: true

module ComplexityRatchet
  # Baseline serialisation is independent from the comparison rules. Keeping
  # it separate also ensures the gate's root module stays within its own budget.
  module BaselineOperations
    # RuboCop prints AbcSize as a float; keep whole numbers as integers so the
    # baseline diff reads 38 rather than 38.0.
    def normalize(value)
      rounded = value.round(2)
      rounded == rounded.to_i ? rounded.to_i : rounded
    end

    def load_baseline(path) = File.exist?(path) ? flatten(YAML.safe_load_file(path) || {}).tap { |entries| validate_baseline_values!(entries) } : {}

    def dump_baseline(path, entries)
      File.write(path, BASELINE_HEADER + YAML.dump(nest(entries), line_width: -1))
    end

    # Baselines are nested on disk, but flattened to `path | cop | entity` in memory.
    # Nesting prevents YAML from expanding long keys into its multi-line explicit form.
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

    def validate_baseline_values!(entries) = entries.each { |key, value| raise Error, "baseline entry #{key.inspect} must be a finite nonnegative number (got #{value.inspect})" unless value.is_a?(Numeric) && value.finite? && value >= 0 }
  end
end
