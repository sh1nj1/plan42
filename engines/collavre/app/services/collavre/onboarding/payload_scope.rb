# frozen_string_literal: true

module Collavre
  module Onboarding
    # Filter at the database boundary; do not load/deserialise unrelated jobs.
    module PayloadScope
      def self.matching(scope, column, path, ids)
        return scope.none if ids.empty?

        connection = scope.connection
        column = connection.quote_column_name(column)
        expression = if connection.adapter_name.match?(/sqlite/i)
          json_path = path.reduce("$") { |value, key| value + (key.match?(/\A\d+\z/) ? "[#{key}]" : ".#{key}") }
          "CAST(json_extract(#{column}, #{connection.quote(json_path)}) AS TEXT)"
        else
          "#{column}::jsonb #>> #{connection.quote("{#{path.join(',')}}")}"
        end
        scope.where("#{expression} IN (?)", ids.map(&:to_s))
      end
    end
  end
end
