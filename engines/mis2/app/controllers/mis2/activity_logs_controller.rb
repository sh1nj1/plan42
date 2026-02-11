module Mis2
  class ActivityLogsController < Mis2::ApplicationController
    include Mis2::Paginatable

    def index
      scope = Mis2::ActivityLog.order(created_at: :desc)
      @logs = paginate(scope)
    end
  end
end
