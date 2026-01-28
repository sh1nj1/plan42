module Mis2
  class ActivityLogsController < Mis2::ApplicationController
    def index
      @page = (params[:page] || 1).to_i
      @page = 1 if @page < 1
      @per_page = 20

      @total_count = Mis2::ActivityLog.count
      @total_pages = (@total_count.to_f / @per_page).ceil

      @logs = Mis2::ActivityLog.order(created_at: :desc)
                               .offset((@page - 1) * @per_page)
                               .limit(@per_page)
    end
  end
end
