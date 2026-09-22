# frozen_string_literal: true

module Collavre
  class LlmUsagesController < ApplicationController
    def index
      @report = LlmUsage::Report.new(user: Current.user, params: report_params)
      @rows = @report.rows
      @names = group_names
      @filters = filter_options
      respond_to do |format|
        format.html
        format.json { render json: { timezone: "Asia/Seoul", period: @report.period, group: @report.group, rows: @rows } }
      end
    rescue ArgumentError
      render plain: I18n.t("collavre.llm_usages.invalid_range"), status: :unprocessable_entity
    end

    private

    def report_params
      params.permit(:from, :to, :period, :group, :owner_id, :requester_id, :agent_id, :model)
    end

    def filter_options
      visible = LlmUsage.visible_to(Current.user)
      LlmUsage::Report::FILTERS.to_h do |field|
        values = filter_values(visible, field)
        options = field == "model" ? values.sort : User.where(id: values).order(:name).pluck(:name, :id)
        [ field, options ]
      end
    end

    def filter_values(visible, field)
      return visible.distinct.pluck(field).compact unless field == "requester_id"

      LlmUsage::Requester.where(llm_usage_id: visible.select(:id)).distinct.pluck(:user_id)
    end

    def group_names
      return {} if @report.group == "model"

      User.where(id: @rows.filter_map { |row| row[:group] }).pluck(:id, :name).to_h.transform_keys(&:to_s)
    end
  end
end
