module Creatives
  module Filters
    class ProgressFilter < BaseFilter
      def active?
        params[:min_progress].present? || params[:max_progress].present?
      end

      def match
        min_val = params[:min_progress].presence&.to_f
        max_val = params[:max_progress].presence&.to_f

        # Linked Creatives use origin's progress, regular creatives use their own
        query = scope
          .joins("LEFT JOIN creatives origins ON creatives.origin_id = origins.id")

        effective_progress = "COALESCE(origins.progress, creatives.progress)"
        query = query.where("#{effective_progress} >= ?", min_val) if min_val
        query = query.where("#{effective_progress} <= ?", max_val) if max_val
        query.pluck("creatives.id")
      end
    end
  end
end
