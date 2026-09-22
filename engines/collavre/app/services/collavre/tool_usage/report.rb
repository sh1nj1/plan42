# frozen_string_literal: true

module Collavre
  class ToolUsage
    # Per-tool-name totals over the token report's date range and identity filters.
    class Report
      FILTERS = %w[owner_id requester_id agent_id].freeze

      def initialize(user:, range:, params: {})
        @user = user
        @range = range
        @params = params.to_h.stringify_keys
      end

      def rows
        relation.group(:tool_name).pluck(
          :tool_name, Arel.sql("COUNT(*)"), Arel.sql("SUM(CASE WHEN succeeded THEN 0 ELSE 1 END)"), Arel.sql("AVG(duration_ms)")
        ).map do |tool_name, calls, failures, average|
          { tool_name: tool_name, calls: calls, failures: failures.to_i, average_duration_ms: average&.to_f&.round }
        end.sort_by { |row| [ -row[:calls], row[:tool_name] ] }
      end

      private

      def relation
        scope = ToolUsage.visible_to(@user).where(occurred_at: @range)
        FILTERS.each do |key|
          next if @params[key].blank?

          scope = key == "requester_id" ? scope.merge(ToolUsage.requested_by(@params[key])) : scope.where(key => @params[key])
        end
        # Only agent tool calls belong to a model, through the execution they share.
        scope = scope.where(execution_id: LlmUsage.where(model: @params["model"]).select(:execution_id)) if @params["model"].present?
        scope
      end
    end
  end
end
