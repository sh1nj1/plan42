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

    def reset_onboarding
      Collavre::Onboarding::Seeder.reset!(user: Current.user)

      redirect_to collavre_engine.creatives_path, notice: t("collavre.onboarding.reset.notice")
    end
  end
end
