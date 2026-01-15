module Creatives
  module Filters
    class ProgressFilter < BaseFilter
      def active?
        params[:min_progress].present? || params[:max_progress].present?
      end

      def match
        result = scope

        if params[:min_progress].present?
          result = result.where("progress >= ?", params[:min_progress].to_f)
        end

        if params[:max_progress].present?
          result = result.where("progress <= ?", params[:max_progress].to_f)
        end

        result.pluck(:id)
      end
    end
  end
end
