module Creatives
  module Filters
    class ProgressFilter < BaseFilter
      def active?
        params[:progress_filter].present?
      end

      def match
        case params[:progress_filter]
        when "completed"
          scope.where("progress >= ?", 1.0).pluck(:id)
        when "incomplete"
          scope.where("progress < ?", 1.0).pluck(:id)
        else
          scope.pluck(:id) # "all" or unknown
        end
      end
    end
  end
end
