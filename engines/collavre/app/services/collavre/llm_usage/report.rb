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
          Arel.sql(bucket), Arel.sql(group_column), Arel.sql("COUNT(*)"),
          Arel.sql("COUNT(DISTINCT execution_id)"), *token_aggregates
        ).map { |values| row(values) }.sort_by { |item| [ item[:period].to_s, item[:group].to_s ] }
      end

      private

      def date(key, fallback)
        @params[key].present? ? Date.iso8601(@params[key]) : fallback
      end

      def relation
        zone = ActiveSupport::TimeZone["Asia/Seoul"]
        scope = LlmUsage.visible_to(@user).where(occurred_at: zone.local(from.year, from.month, from.day)...zone.local(to.year, to.month, to.day).advance(days: 1))
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
        LlmUsage::TOKEN_FIELDS.flat_map do |field|
          [ Arel.sql("SUM(#{field})"), Arel.sql("COUNT(*) - COUNT(#{field})") ]
        end
      end

      def row(values)
        date, identity, records, executions, *tokens = values
        result = { period: date.to_s, group: identity, records: records, executions: executions }
        LlmUsage::TOKEN_FIELDS.each_with_index do |field, index|
          result[field] = tokens[index * 2]
          result["#{field}_missing".to_sym] = tokens[index * 2 + 1]
        end
        result
      end
    end
  end
end
