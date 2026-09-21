# frozen_string_literal: true

module Collavre
module Creatives
  class FilterState
    FILTER_KEYS = %i[
      tags min_progress max_progress search has_comments has_cron due_before
      due_after has_due_date assignee_id unassigned
    ].freeze

    def initialize(params, include_archived: false)
      @params = params
      @keys = include_archived ? FILTER_KEYS + [ :show_archived ] : FILTER_KEYS
    end

    def active?
      params[:comment] == "true" || keys.any? { |key| params[key].present? }
    end

    private

    attr_reader :params, :keys
  end
end
end
