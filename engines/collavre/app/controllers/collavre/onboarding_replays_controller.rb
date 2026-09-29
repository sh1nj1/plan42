module Collavre
  class OnboardingReplaysController < ApplicationController
    def create
      Notices::OnboardingReplay.call(Current.user)
      redirect_to creatives_path, status: :see_other, notice: t("collavre.notices.replay.restarted")
    end
  end
end
