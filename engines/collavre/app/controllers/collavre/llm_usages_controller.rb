# frozen_string_literal: true

module Collavre
  class LlmUsagesController < ApplicationController
    def index
      @report = LlmUsage::Report.new(user: Current.user, params: report_params)
      @rows = @report.rows
      @tool_rows = ToolUsage::Report.new(user: Current.user, range: @report.range, params: report_params).rows
      @names = group_names
      @filters = filter_options
      respond_to do |format|
        format.html
        format.json { render json: { timezone: "Asia/Seoul", period: @report.period, group: @report.group, rows: @rows, tools: @tool_rows } }
      end
    rescue ArgumentError
      render plain: I18n.t("collavre.llm_usages.invalid_range"), status: :unprocessable_entity
    end

    private

    def report_params
      params.permit(:from, :to, :period, :group, :owner_id, :requester_id, :agent_id, :model)
    end

    def filter_options
      LlmUsage::Report::FILTERS.to_h do |field|
        next [ field, filter_values(LlmUsage, field).sort ] if field == "model"

        values = filter_values(LlmUsage, field) | filter_values(ToolUsage, field)
        [ field, User.where(id: values).order(:name).pluck(:name, :id) ]
      end
    end

    def filter_values(usage, field)
      visible = usage.visible_to(Current.user)
      return visible.distinct.pluck(field).compact unless field == "requester_id"

      usage::Requester.where("#{usage.model_name.element}_id" => visible.select(:id)).distinct.pluck(:user_id)
    end

    def group_names
      return {} if @report.group == "model"

      User.where(id: @rows.filter_map { |row| row[:group] }).pluck(:id, :name).to_h.transform_keys(&:to_s)
    end
  end
end
