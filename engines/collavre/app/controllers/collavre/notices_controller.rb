module Collavre
  class NoticesController < ApplicationController
    def dismiss
      key = params[:key].to_s

      Current.user.with_lock do
        dismissed = Current.user.dismissed_notices || []
        Current.user.update!(dismissed_notices: (dismissed + [ key ]).uniq)
      end

      render json: { success: true, dismissed_notices: Current.user.dismissed_notices }
    end

    def restore_all
      Current.user.update!(dismissed_notices: [])

      render json: { success: true, dismissed_notices: Current.user.dismissed_notices }
    end
  end
end
