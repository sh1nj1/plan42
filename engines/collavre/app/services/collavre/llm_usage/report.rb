# frozen_string_literal: true

module Collavre
  class LlmUsage
    class Report
      PERIODS = %w[day week month].freeze
      GROUPS = %w[owner requester agent model].freeze
      FILTERS = %w[owner_id requester_id agent_id model].freeze
      attr_reader :period, :group, :from, :to

      def initialize(user:, params: {})
        @user = user
        @params = params.to_h.stringify_keys
        @period = @params.fetch("period", "day")
        @group = @params.fetch("group", "agent")
        @from = date("from", Time.current.in_time_zone("Asia/Seoul").to_date.beginning_of_month)
        @to = date("to", Time.current.in_time_zone("Asia/Seoul").to_date)
        raise ArgumentError unless PERIODS.include?(period) && GROUPS.include?(group)
        raise ArgumentError unless to >= from && (to - from).to_i <= 366
      end

      def rows
        relation.group(Arel.sql(bucket), Arel.sql(group_column)).pluck(
          Arel.sql("#{bucket} AS period_start"), Arel.sql("#{group_column} AS group_value"), Arel.sql("COUNT(*) AS records"),
          Arel.sql("COUNT(DISTINCT execution_id) AS executions"), *token_aggregates
        ).map { |values| row(values) }.sort_by { |item| [ item[:period].to_s, item[:group].to_s ] }
      end

      def range
        zone = ActiveSupport::TimeZone["Asia/Seoul"]
        zone.local(from.year, from.month, from.day)...zone.local(to.year, to.month, to.day).advance(days: 1)
      end

      def totals
        values = relation.pick(Arel.sql("COUNT(*)"), Arel.sql("COUNT(DISTINCT execution_id)"), *token_aggregates)
        row([ nil, nil, *values ]).except(:period, :group)
      end

      private

      def date(key, fallback)
        @params[key].present? ? Date.iso8601(@params[key]) : fallback
      end

      def relation
        scope = LlmUsage.visible_to(@user).where(occurred_at: range)
        FILTERS.each do |key|
          next if @params[key].blank?

          scope = key == "requester_id" ? scope.merge(LlmUsage.requested_by(@params[key])) : scope.where(key => @params[key])
        end
        scope
      end

      def group_column
        return "CASE WHEN requester_kind = 'joint' THEN 'joint' ELSE CAST(requester_id AS TEXT) END" if group == "requester"

        group == "model" ? "model" : "#{group}_id"
      end

      def bucket
        if LlmUsage.connection.adapter_name == "PostgreSQL"
          "date_trunc('#{period}', occurred_at AT TIME ZONE 'UTC' AT TIME ZONE 'Asia/Seoul')::date"
        else
          sqlite_bucket
        end
      end

      def sqlite_bucket
        local = "datetime(occurred_at, '+9 hours')"
        case period
        when "day" then "date(#{local})"
        when "month" then "date(#{local}, 'start of month')"
        when "week" then "date(#{local}, '-' || ((CAST(strftime('%w', #{local}) AS INTEGER) + 6) % 7) || ' days')"
        end
      end

      def token_aggregates
        table = LlmUsage.arel_table
        count = Arel::Nodes::Count.new([ Arel.star ])
        LlmUsage::TOKEN_FIELDS.flat_map do |field|
          [ table[field].sum, Arel::Nodes::Subtraction.new(count, table[field].count) ]
        end
      end

      def row(values)
        date, identity, records, executions, *tokens = values
        result = { period: date.to_s, group: identity, records: records, executions: executions }
        LlmUsage::TOKEN_FIELDS.each_with_index do |field, index|
          result[field] = tokens[index * 2]&.to_i
          result["#{field}_missing".to_sym] = tokens[index * 2 + 1]
        end
        result
      end
    end
  end
end
