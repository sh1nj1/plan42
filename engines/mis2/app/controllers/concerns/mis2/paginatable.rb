module Mis2
  module Paginatable
    extend ActiveSupport::Concern

    private

    def paginate(scope, per_page: 20)
      @page = [(params[:page] || 1).to_i, 1].max
      @per_page = per_page

      @total_count = scope.unscope(:select).count
      @total_pages = [(@total_count.to_f / @per_page).ceil, 1].max

      scope.offset((@page - 1) * @per_page).limit(@per_page)
    end
  end
end
