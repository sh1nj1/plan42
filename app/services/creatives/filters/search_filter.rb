module Creatives
  module Filters
    class SearchFilter < BaseFilter
      def active?
        params[:search].present?
      end

      def match
        query = "%#{params[:search]}%"
        scope.where("description LIKE ?", query).pluck(:id)
      end
    end
  end
end
