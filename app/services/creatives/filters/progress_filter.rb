module Creatives
  module Filters
    class ProgressFilter < BaseFilter
      def active?
        params[:min_progress].present? || params[:max_progress].present?
      end

      def match
        min_val = params[:min_progress].presence&.to_f
        max_val = params[:max_progress].presence&.to_f

        query = scope
        query = query.where("progress >= ?", min_val) if min_val
        query = query.where("progress <= ?", max_val) if max_val
        query.pluck(:id)
      end
    end
  end
end
