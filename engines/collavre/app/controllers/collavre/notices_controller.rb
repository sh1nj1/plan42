module Collavre
  class NoticesController < ApplicationController
    def dismiss
      key = params[:key].to_s
      dismissed = Current.user.dismissed_notices || []
      Current.user.update!(dismissed_notices: (dismissed + [ key ]).uniq)

      render json: { success: true, dismissed_notices: Current.user.dismissed_notices }
    end

    def restore_all
      Current.user.update!(dismissed_notices: [])

      render json: { success: true, dismissed_notices: Current.user.dismissed_notices }
    end
  end
end
